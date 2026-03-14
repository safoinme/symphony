defmodule SymphonyElixir.PlanningRunner do
  @moduledoc """
  Executes a planning phase for a Linear issue: investigates the repo,
  saves a structured plan to PLAN.md, and posts a summary to Linear.
  Does NOT auto-transition — human moves to "In Progress" when ready.
  """

  require Logger
  alias SymphonyElixir.{Linear.Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @spec planning_complete?(Path.t()) :: boolean()
  def planning_complete?(workspace) do
    workspace |> Path.join("PLAN.md") |> File.exists?()
  end

  @spec questions_pending?(Path.t()) :: boolean()
  def questions_pending?(workspace) do
    has_questions = workspace |> Path.join("QUESTIONS.md") |> File.exists?()
    has_plan = planning_complete?(workspace)
    has_questions and not has_plan
  end

  @spec questions_file_mtime(Path.t()) :: DateTime.t() | nil
  def questions_file_mtime(workspace) do
    path = Path.join(workspace, "QUESTIONS.md")

    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        DateTime.from_unix!(mtime)

      _ ->
        nil
    end
  end

  @spec run(Issue.t(), pid() | nil, keyword()) :: :ok | {:error, term()} | no_return()
  def run(issue, update_recipient \\ nil, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    Logger.info("Starting planning run for #{issue_context(issue)}")

    case create_workspace(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_planning_turn(workspace, issue, update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        Logger.error("Planning run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Planning run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp create_workspace(issue, worker_host) do
    Workspace.create_for_issue(issue, worker_host)
  end

  defp run_planning_turn(workspace, issue, update_recipient, opts, worker_host) do
    run_before_plan_hook(workspace, issue, worker_host)
    rp_context = read_rp_context(workspace)

    backend = Keyword.get(opts, :backend, SymphonyElixir.AgentBackend.Codex)

    prompt_opts =
      opts
      |> maybe_put_rp_context(rp_context)
      |> maybe_put_human_replies(issue)

    prompt = PromptBuilder.build_planning_prompt(issue, prompt_opts)

    with {:ok, session} <- backend.start_session(workspace, worker_host: worker_host) do
      try do
        result = run_single_turn(backend, session, prompt, issue, update_recipient, opts)

        case result do
          {:ok, response} ->
            raw_text = extract_raw_text(response)

            case classify_plan_output(raw_text) do
              {:complete, plan_text} ->
                plan_markdown = format_plan(plan_text)
                save_plan_and_notify(issue, plan_markdown, workspace)

              {:questions, text} ->
                save_questions(issue, text, workspace)

              {:empty, message} ->
                Logger.warning("#{message} for #{issue_context(issue)}")
                {:error, :empty_planning_output}
            end

          {:error, reason} ->
            Logger.error("Planning turn failed for #{issue_context(issue)}: #{inspect(reason)}")
            {:error, reason}
        end
      after
        backend.stop_session(session)
      end
    end
  end

  defp run_single_turn(backend, session, prompt, issue, update_recipient, opts) do
    run_turn_opts =
      [on_message: agent_message_handler(update_recipient, issue)]
      |> maybe_put_opt(:model, Keyword.get(opts, :model))
      |> maybe_put_opt(:max_turns, Keyword.get(opts, :max_turns))

    backend.run_turn(session, prompt, issue, run_turn_opts)
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp run_before_plan_hook(workspace, issue, worker_host) do
    Workspace.run_before_plan_hook(workspace, issue, worker_host)
  end

  defp read_rp_context(workspace) do
    path = Path.join(workspace, ".rp-context.json")

    case File.read(path) do
      {:ok, content} when content != "" -> content
      _ -> nil
    end
  end

  defp maybe_put_rp_context(opts, nil), do: opts
  defp maybe_put_rp_context(opts, rp_context), do: Keyword.put(opts, :rp_context, rp_context)

  defp maybe_put_human_replies(opts, issue) do
    case Tracker.fetch_issue_comments(issue.id) do
      {:ok, comments} when comments != [] ->
        # Filter to non-bot comments only (human replies)
        human_replies =
          comments
          |> Enum.reject(& &1.is_bot)
          |> Enum.map(fn c -> "**#{c.user_name}** (#{c.created_at}):\n#{c.body}" end)
          |> Enum.join("\n\n---\n\n")

        if human_replies != "" do
          Keyword.put(opts, :human_replies, human_replies)
        else
          opts
        end

      _ ->
        opts
    end
  end

  # --- Output classification ---

  defp extract_raw_text({:ok, response}), do: extract_raw_text(response)

  defp extract_raw_text(response) when is_map(response) do
    # Try direct text/content/result keys (covers both atom and string keys)
    direct =
      Map.get(response, :text) || Map.get(response, "text") ||
        Map.get(response, :content) || Map.get(response, "content") ||
        Map.get(response, :result) || Map.get(response, "result")

    cond do
      is_binary(direct) and direct != "" ->
        direct

      # Claude Code backend: %{result: {:completed, payload}} where payload has the text
      match?({:completed, _}, Map.get(response, :result)) ->
        {:completed, payload} = Map.get(response, :result)
        extract_raw_text(payload)

      true ->
        ""
    end
  end

  defp extract_raw_text(response) when is_binary(response), do: response
  defp extract_raw_text(_response), do: ""

  defp classify_plan_output(text) when is_binary(text) and text != "" do
    if questions_only?(text) do
      {:questions, text}
    else
      {:complete, text}
    end
  end

  defp classify_plan_output(_text) do
    {:empty, "Planning agent produced no output."}
  end

  defp questions_only?(text) do
    has_questions = String.contains?(text, ["QUESTIONS", "?"])
    has_plan_sections = String.contains?(text, ["## Approach", "## Affected Files", "## Implementation"])
    has_questions and not has_plan_sections
  end

  # --- Plan persistence ---

  defp format_plan(plan_text) do
    """
    ## Implementation Plan

    #{plan_text}

    ---
    _Generated by Symphony planning agent_
    """
  end

  defp save_plan_and_notify(issue, plan_markdown, workspace) do
    plan_path = Path.join(workspace, "PLAN.md")
    File.write!(plan_path, plan_markdown)
    Logger.info("Plan saved to #{plan_path} for #{issue_context(issue)}")

    summary = build_plan_summary(plan_markdown, plan_path)

    case Tracker.create_comment(issue.id, summary) do
      :ok ->
        Logger.info("Planning complete for #{issue_context(issue)}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to post plan summary for #{issue_context(issue)}: #{inspect(reason)}")
        {:error, {:comment_post_failed, reason}}
    end
  end

  defp save_questions(issue, text, workspace) do
    questions_path = Path.join(workspace, "QUESTIONS.md")
    File.write!(questions_path, text)
    Logger.info("Questions saved to #{questions_path} for #{issue_context(issue)}, waiting for human replies")
    :ok
  end

  defp build_plan_summary(plan_markdown, plan_path) do
    preview = plan_markdown |> String.slice(0, 500) |> String.trim()
    truncated? = String.length(plan_markdown) > 500

    """
    ## Planning Complete

    #{preview}#{if truncated?, do: "\n\n_(truncated — see full plan below)_", else: ""}

    **Full plan saved to:** `#{plan_path}`

    Move this issue to **In Progress** when ready to start implementation.

    ---
    _Generated by Symphony planning agent_
    """
  end

  # --- Message handling ---

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

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
