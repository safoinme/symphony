defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @default_planning_prompt """
  You are a planning agent for issue {{ issue.identifier }}: {{ issue.title }}.

  Description:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  {% if rp_context %}

  ## Repository Analysis (from repo-prompt)
  {{ rp_context }}
  {% endif %}
  {% if human_replies %}

  ## Human Feedback (replies to previous questions)
  {{ human_replies }}

  Incorporate the answers above into your plan. If all questions are resolved, produce the full plan.
  {% endif %}

  Your task is to investigate the repository and produce a detailed implementation plan.

  If you have access to RepoPrompt MCP tools (e.g. `context_builder`), use them to gather deeper
  context about relevant files and modules before planning.

  Steps:
  1. Explore the codebase to understand the architecture and relevant modules.
  2. Identify all files that will need to be created or modified.
  3. Define a clear, step-by-step approach for implementing the change.
  4. Flag any risks, edge cases, or areas of uncertainty.
  5. Estimate the scope (small / medium / large) with justification.

  If the issue description is too vague to produce a plan, output your questions under a
  "QUESTIONS" heading. Do NOT include "## Approach" or "## Affected Files" sections when
  asking questions — only include those when you have a complete plan.

  When you have enough information, output a structured Markdown plan with these sections:
  - **## Affected Files** — list of files to create or modify
  - **## Approach** — step-by-step implementation plan
  - **## Risks** — edge cases and areas of uncertainty
  - **## Scope Estimate** — small / medium / large with justification
  """

  @default_review_prompt """
  You are a code review agent for issue {{ issue.identifier }}: {{ issue.title }}.

  Review the following diff for correctness, code quality, test coverage, and security.

  ```diff
  {{ diff }}
  ```

  Evaluate the changes against these criteria:
  1. **Correctness**: Does the code do what the issue requires? Are there logic errors?
  2. **Code Quality**: Is the code readable, well-structured, and following project conventions?
  3. **Test Coverage**: Are there adequate tests for the changes?
  4. **Security**: Are there any security concerns (injection, auth bypass, data leaks)?

  End your review with exactly one of these verdicts on its own line:
  - APPROVED (if the changes are ready to merge)
  - CHANGES_REQUESTED (if issues need to be addressed)
  """

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map(),
        "implementation_plan" => Keyword.get(opts, :implementation_plan)
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  @spec build_planning_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_planning_prompt(issue, opts \\ []) do
    rp_context = Keyword.get(opts, :rp_context)
    human_replies = Keyword.get(opts, :human_replies)
    template_text = planning_prompt_template()

    context = %{
      "issue" => issue |> Map.from_struct() |> to_solid_map(),
      "rp_context" => rp_context,
      "human_replies" => human_replies
    }

    template_text
    |> parse_template!()
    |> Solid.render!(context, @render_opts)
    |> IO.iodata_to_binary()
  end

  @spec build_review_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_review_prompt(issue, opts \\ []) do
    diff = Keyword.get(opts, :diff, "")
    template_text = review_prompt_template()

    template_text
    |> parse_template!()
    |> Solid.render!(
      %{
        "issue" => issue |> Map.from_struct() |> to_solid_map(),
        "diff" => diff
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  defp planning_prompt_template do
    case Config.settings!().pipeline.planning_prompt_file do
      path when is_binary(path) and path != "" -> load_template_file(path)
      _ -> @default_planning_prompt
    end
  end

  defp review_prompt_template do
    case Config.settings!().pipeline.review_prompt_file do
      path when is_binary(path) and path != "" -> load_template_file(path)
      _ -> @default_review_prompt
    end
  end

  defp load_template_file(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, reason} -> raise RuntimeError, "Failed to read template file #{path}: #{inspect(reason)}"
    end
  end

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
