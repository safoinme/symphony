defmodule SymphonyElixir.PlanningRunner do
  @moduledoc """
  Executes a planning phase for a Linear issue: investigates the repo,
  saves a structured plan to PLAN.md, and posts a summary to Linear.
  Does NOT auto-transition — human moves to "In Progress" when ready.
  """

  require Logger
  alias SymphonyElixir.{Linear.ImageDownloader, Linear.Issue, Plan, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @spec planning_complete?(Path.t()) :: boolean()
  def planning_complete?(workspace) do
    plan_json_exists?(workspace) or plan_md_exists?(workspace)
  end

  defp plan_json_exists?(workspace), do: workspace |> Path.join("PLAN.json") |> File.exists?()
  defp plan_md_exists?(workspace), do: workspace |> Path.join("PLAN.md") |> File.exists?()

  @spec questions_pending?(Path.t()) :: boolean()
  def questions_pending?(workspace) do
    has_questions = workspace |> Path.join("QUESTIONS.md") |> File.exists?()
    has_plan = planning_complete?(workspace)
    has_questions and not has_plan
  end

  @max_planning_attempts 3

  @spec planning_attempts_exhausted?(Path.t()) :: boolean()
  def planning_attempts_exhausted?(workspace) do
    read_planning_attempts(workspace) >= @max_planning_attempts
  end

  @spec increment_planning_attempts(Path.t()) :: :ok
  def increment_planning_attempts(workspace) do
    count = read_planning_attempts(workspace) + 1
    path = Path.join(workspace, ".planning-attempts")
    File.write!(path, Integer.to_string(count))
    :ok
  end

  defp read_planning_attempts(workspace) do
    path = Path.join(workspace, ".planning-attempts")

    case File.read(path) do
      {:ok, content} ->
        case Integer.parse(String.trim(content)) do
          {count, _} -> count
          :error -> 0
        end

      _ ->
        0
    end
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
        case check_planning_state(issue, workspace) do
          :dispatch ->
            send_worker_runtime_info(update_recipient, issue, worker_host, workspace)
            ImageDownloader.download_for_issue(issue, workspace)

            try do
              with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
                run_planning_turn(workspace, issue, update_recipient, opts, worker_host)
              end
            after
              Workspace.run_after_run_hook(workspace, issue, worker_host)
            end

          :already_complete ->
            Logger.info("Planning already complete for #{issue_context(issue)}, ensuring approval label is applied")
            apply_waiting_approval_label(issue)
            :ok

          :questions_pending ->
            Logger.info("Questions pending for #{issue_context(issue)}, ensuring feedback label is applied")
            apply_waiting_feedback_label(issue)
            :ok

          :attempts_exhausted ->
            Logger.warning("Planning attempts exhausted for #{issue_context(issue)}, ensuring feedback label is applied")
            apply_waiting_feedback_label(issue)
            :ok
        end

      {:error, reason} ->
        Logger.error("Planning run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Planning run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp check_planning_state(issue, workspace) do
    cond do
      planning_complete?(workspace) ->
        :already_complete

      questions_pending?(workspace) ->
        if has_new_human_replies?(issue, workspace), do: :dispatch, else: :questions_pending

      planning_attempts_exhausted?(workspace) ->
        :attempts_exhausted

      true ->
        :dispatch
    end
  end

  defp has_new_human_replies?(issue, workspace) do
    questions_mtime = questions_file_mtime(workspace)

    case {questions_mtime, Tracker.fetch_issue_comments(issue.id)} do
      {nil, _} ->
        false

      {_mtime, {:ok, comments}} ->
        Enum.any?(comments, fn comment ->
          not comment.is_bot and newer_than_mtime?(comment.created_at, questions_mtime)
        end)

      _ ->
        false
    end
  end

  defp newer_than_mtime?(comment_timestamp, mtime) when is_binary(comment_timestamp) do
    case DateTime.from_iso8601(comment_timestamp) do
      {:ok, comment_dt, _offset} -> DateTime.compare(comment_dt, mtime) == :gt
      _ -> false
    end
  end

  defp newer_than_mtime?(_comment_timestamp, _mtime), do: false

  defp create_workspace(issue, worker_host) do
    Workspace.create_for_issue(issue, worker_host)
  end

  defp run_planning_turn(workspace, issue, update_recipient, opts, worker_host) do
    increment_planning_attempts(workspace)
    run_before_plan_hook(workspace, issue, worker_host)
    rp_context = read_rp_context(workspace)

    backend = Keyword.get(opts, :backend, SymphonyElixir.AgentBackend.Codex)

    prompt_opts =
      opts
      |> maybe_put_rp_context(rp_context)
      |> maybe_put_human_replies(issue, workspace)

    prompt = PromptBuilder.build_planning_prompt(issue, prompt_opts)

    with {:ok, session} <- backend.start_session(workspace, worker_host: worker_host) do
      try do
        result = run_single_turn(backend, session, prompt, issue, update_recipient, opts)

        case result do
          {:ok, response} ->
            raw_text = extract_raw_text(response)

            case classify_plan_output(raw_text) do
              {:structured, plan} ->
                result = save_structured_plan_and_notify(issue, plan, workspace)
                Workspace.run_after_plan_hook(workspace, issue, worker_host)
                result

              {:complete, plan_text} ->
                plan_markdown = format_plan(plan_text)
                result = save_plan_and_notify(issue, plan_markdown, workspace)
                Workspace.run_after_plan_hook(workspace, issue, worker_host)
                result

              {:questions, text} ->
                save_questions(issue, text, workspace)

              {:empty, message} ->
                # Agent may have written PLAN.md directly via Write tool — check workspace
                handle_empty_plan_output(issue, workspace, worker_host, message)
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

  defp maybe_put_human_replies(opts, issue, workspace) do
    case Tracker.fetch_issue_comments(issue.id) do
      {:ok, comments} when comments != [] ->
        human_comments = Enum.reject(comments, & &1.is_bot)
        ImageDownloader.download_comment_images(human_comments, workspace)

        human_replies =
          human_comments
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
    case extract_json_plan(text) do
      {:ok, plan} ->
        {:structured, plan}

      :no_json ->
        if questions_only?(text) do
          {:questions, text}
        else
          {:complete, text}
        end
    end
  end

  defp classify_plan_output(_text) do
    {:empty, "Planning agent produced no output."}
  end

  @json_fence_regex ~r/```json\s*\n([\s\S]*?)\n\s*```/

  defp extract_json_plan(text) do
    case Regex.run(@json_fence_regex, text) do
      [_, json_block] ->
        case Plan.from_json(json_block) do
          {:ok, plan} -> {:ok, plan}
          {:error, _} -> :no_json
        end

      nil ->
        :no_json
    end
  end

  defp questions_only?(text) do
    has_questions = String.contains?(text, ["QUESTIONS", "?"])
    has_plan_sections = String.contains?(text, ["## Approach", "## Affected Files", "## Implementation"])
    has_questions and not has_plan_sections
  end

  defp handle_empty_plan_output(issue, workspace, worker_host, message) do
    cond do
      plan_json_exists?(workspace) ->
        Logger.info("Agent wrote PLAN.json directly for #{issue_context(issue)}, notifying Linear")
        {:ok, json} = File.read(Path.join(workspace, "PLAN.json"))

        case Plan.from_json(json) do
          {:ok, plan} ->
            result = notify_plan(issue, Plan.to_checklist(plan), workspace)
            Workspace.run_after_plan_hook(workspace, issue, worker_host)
            result

          {:error, _} ->
            notify_plan(issue, json, workspace)
        end

      plan_md_exists?(workspace) ->
        Logger.info("Agent wrote PLAN.md directly for #{issue_context(issue)}, notifying Linear")
        {:ok, content} = File.read(Path.join(workspace, "PLAN.md"))
        result = notify_plan(issue, content, workspace)
        Workspace.run_after_plan_hook(workspace, issue, worker_host)
        result

      true ->
        Logger.warning("#{message} for #{issue_context(issue)}")
        {:error, :empty_planning_output}
    end
  end

  defp notify_plan(issue, plan_markdown, workspace) do
    summary = build_plan_summary(plan_markdown, Path.join(workspace, "PLAN.md"))

    case Tracker.create_comment(issue.id, summary) do
      :ok ->
        apply_waiting_approval_label(issue)
        Logger.info("Planning complete for #{issue_context(issue)}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to post plan summary for #{issue_context(issue)}: #{inspect(reason)}")
        {:error, {:comment_post_failed, reason}}
    end
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

  defp save_structured_plan_and_notify(issue, %Plan{} = plan, workspace) do
    plan = %{plan | issue_identifier: issue.identifier}
    json_path = Path.join(workspace, "PLAN.json")
    File.write!(json_path, Plan.to_json(plan))
    Logger.info("Structured plan saved to #{json_path} for #{issue_context(issue)}")

    # Also save markdown version for backward compatibility
    plan_markdown = Plan.to_checklist(plan)
    md_path = Path.join(workspace, "PLAN.md")
    File.write!(md_path, plan_markdown)

    summary = build_plan_summary(plan_markdown, json_path)

    case Tracker.create_comment(issue.id, summary) do
      :ok ->
        apply_waiting_approval_label(issue)
        Logger.info("Planning complete for #{issue_context(issue)}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to post plan summary for #{issue_context(issue)}: #{inspect(reason)}")
        {:error, {:comment_post_failed, reason}}
    end
  end

  defp save_plan_and_notify(issue, plan_markdown, workspace) do
    plan_path = Path.join(workspace, "PLAN.md")
    File.write!(plan_path, plan_markdown)
    Logger.info("Plan saved to #{plan_path} for #{issue_context(issue)}")

    summary = build_plan_summary(plan_markdown, plan_path)

    case Tracker.create_comment(issue.id, summary) do
      :ok ->
        apply_waiting_approval_label(issue)
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
    apply_waiting_feedback_label(issue)
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

  @waiting_approval_label "Waiting Humain Approval"
  @waiting_feedback_label "Waiting Humain Feedback"

  defp apply_waiting_approval_label(issue) do
    case Tracker.add_label(issue.id, @waiting_approval_label) do
      :ok ->
        Logger.info("Applied '#{@waiting_approval_label}' label to #{issue_context(issue)}")

      {:error, reason} ->
        Logger.warning("Failed to apply '#{@waiting_approval_label}' label to #{issue_context(issue)}: #{inspect(reason)}")
    end
  end

  defp apply_waiting_feedback_label(issue) do
    case Tracker.add_label(issue.id, @waiting_feedback_label) do
      :ok ->
        Logger.info("Applied '#{@waiting_feedback_label}' label to #{issue_context(issue)}")

      {:error, reason} ->
        Logger.warning("Failed to apply '#{@waiting_feedback_label}' label to #{issue_context(issue)}: #{inspect(reason)}")
    end
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
