defmodule SymphonyElixir.ReviewRunner do
  @moduledoc """
  Executes an automated review of completed work for a Linear issue.
  Gathers the diff, runs a review agent, and transitions the issue
  based on the review verdict.
  """

  require Logger
  alias SymphonyElixir.{Linear.Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @approved_signals ["APPROVED", "LGTM", "APPROVE"]
  @rejected_signals ["CHANGES_REQUESTED", "REQUEST_CHANGES", "REJECT"]

  @spec run(Issue.t(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, update_recipient \\ nil, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    Logger.info("Starting review run for #{issue_context(issue)}")

    case open_workspace(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_review_turn(workspace, issue, update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        Logger.error("Review run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Review run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp open_workspace(issue, worker_host) do
    Workspace.create_for_issue(issue, worker_host)
  end

  defp run_review_turn(workspace, issue, update_recipient, opts, worker_host) do
    backend = Keyword.get(opts, :backend, SymphonyElixir.AgentBackend.Codex)

    case gather_diff(workspace, worker_host) do
      {:ok, diff} ->
        prompt = PromptBuilder.build_review_prompt(issue, Keyword.put(opts, :diff, diff))

        with {:ok, session} <- backend.start_session(workspace, worker_host: worker_host) do
          try do
            result = run_single_turn(backend, session, prompt, issue, update_recipient, opts)
            handle_review_result(result, issue)
          after
            backend.stop_session(session)
          end
        end

      {:error, reason} ->
        Logger.error("Failed to gather diff for #{issue_context(issue)}: #{inspect(reason)}")
        {:error, {:diff_failed, reason}}
    end
  end

  defp run_single_turn(backend, session, prompt, issue, update_recipient, opts) do
    run_turn_opts =
      [on_message: agent_message_handler(update_recipient, issue)]
      |> maybe_put_opt(:model, Keyword.get(opts, :model))

    backend.run_turn(session, prompt, issue, run_turn_opts)
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp gather_diff(workspace, nil) do
    case System.cmd("git", ["diff", "main...HEAD"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output}

      {output, _status} ->
        case System.cmd("git", ["diff", "HEAD"], cd: workspace, stderr_to_stdout: true) do
          {fallback_output, 0} -> {:ok, fallback_output}
          {error_output, _} -> {:error, {:git_diff_failed, output <> "\n" <> error_output}}
        end
    end
  end

  defp gather_diff(workspace, worker_host) when is_binary(worker_host) do
    script = "cd #{shell_escape(workspace)} && git diff main...HEAD 2>/dev/null || git diff HEAD"

    case SymphonyElixir.SSH.run(worker_host, script, stderr_to_stdout: true) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, _status}} -> {:error, {:git_diff_failed, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_review_result({:ok, response}, issue) do
    review_text = extract_review_text(response)
    verdict = parse_verdict(review_text)

    case verdict do
      :approved ->
        Logger.info("Review APPROVED for #{issue_context(issue)}")

        case Tracker.update_issue_state(issue.id, "Done") do
          :ok -> :ok
          {:error, reason} -> {:error, {:state_transition_failed, reason}}
        end

      :changes_requested ->
        Logger.info("Review CHANGES_REQUESTED for #{issue_context(issue)}")
        post_feedback_and_rework(issue, review_text)
    end
  end

  defp handle_review_result({:error, reason}, issue) do
    Logger.error("Review turn failed for #{issue_context(issue)}: #{inspect(reason)}")
    {:error, reason}
  end

  defp extract_review_text(response) when is_map(response) do
    Map.get(response, :content) || Map.get(response, "content") ||
      Map.get(response, :text) || Map.get(response, "text") || ""
  end

  defp extract_review_text(response) when is_binary(response), do: response
  defp extract_review_text(_response), do: ""

  defp parse_verdict(review_text) when is_binary(review_text) do
    uppercased = String.upcase(review_text)

    cond do
      Enum.any?(@approved_signals, &String.contains?(uppercased, &1)) ->
        :approved

      Enum.any?(@rejected_signals, &String.contains?(uppercased, &1)) ->
        :changes_requested

      true ->
        # Default to changes_requested for safety — require explicit approval
        :changes_requested
    end
  end

  defp post_feedback_and_rework(issue, review_text) do
    feedback_comment = format_review_comment(review_text)

    with :ok <- Tracker.create_comment(issue.id, feedback_comment) do
      case Tracker.update_issue_state(issue.id, "Fix/Rework") do
        :ok ->
          Logger.info("Review run completed for #{issue_context(issue)} — sent to Fix/Rework")
          :ok

        {:error, reason} ->
          Logger.error(
            "Failed to transition #{issue_context(issue)} to Fix/Rework: #{inspect(reason)}"
          )

          {:error, {:state_transition_failed, reason}}
      end
    else
      {:error, reason} ->
        Logger.error(
          "Failed to post review feedback for #{issue_context(issue)}: #{inspect(reason)}"
        )

        {:error, {:comment_post_failed, reason}}
    end
  end

  defp format_review_comment(review_text) do
    """
    ## Automated Code Review

    #{review_text}

    ---
    _Generated by Symphony review agent_
    """
  end

  defp agent_message_handler(recipient, issue) do
    fn message ->
      send_agent_update(recipient, issue, message)
    end
  end

  defp send_agent_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_agent_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
