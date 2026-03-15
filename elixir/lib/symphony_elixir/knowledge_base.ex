defmodule SymphonyElixir.KnowledgeBase do
  @moduledoc """
  Cross-session knowledge base for archiving completed plans and
  loading context from prior work. Persists to the base repo (not
  individual workspaces) and is gated by the knowledge_base.enabled
  config flag.
  """

  require Logger

  alias SymphonyElixir.{Config, Plan}

  @default_kb_path "docs/exec-plans"

  @spec archive_plan(String.t(), Plan.t(), Path.t()) :: :ok | {:error, term()}
  def archive_plan(issue_id, %Plan{} = plan, base_path) when is_binary(issue_id) do
    with {:ok, kb_cfg} <- fetch_kb_config() do
      do_archive_plan(issue_id, plan, base_path, kb_cfg.path)
    else
      :disabled -> :ok
    end
  end

  @spec load_recent_plans(Path.t(), pos_integer()) :: [Plan.t()]
  def load_recent_plans(base_path, limit \\ 10) do
    case fetch_kb_config() do
      {:ok, kb_cfg} -> do_load_recent_plans(base_path, limit, kb_cfg.path)
      :disabled -> []
    end
  end

  @spec append_lesson(Path.t(), String.t()) :: :ok | {:error, term()}
  def append_lesson(base_path, lesson) when is_binary(lesson) do
    with {:ok, kb_cfg} <- fetch_kb_config() do
      do_append_lesson(base_path, lesson, kb_cfg.path)
    else
      :disabled -> :ok
    end
  end

  @spec load_module_context(Path.t(), String.t()) :: String.t() | nil
  def load_module_context(base_path, module_name) when is_binary(module_name) do
    case fetch_kb_config() do
      {:ok, kb_cfg} -> do_load_module_context(base_path, module_name, kb_cfg.path)
      :disabled -> nil
    end
  end

  @spec enabled?() :: boolean()
  def enabled? do
    match?({:ok, _}, fetch_kb_config())
  end

  # Single config fetch that gates on enabled and returns the path.
  defp fetch_kb_config do
    settings = Config.settings!()

    case Map.get(settings, :knowledge_base) do
      %{enabled: true, path: path} when is_binary(path) and path != "" -> {:ok, %{path: path}}
      %{enabled: true} -> {:ok, %{path: @default_kb_path}}
      _ -> :disabled
    end
  end

  # --- Private ---

  defp do_archive_plan(issue_id, plan, base_path, kb_path) do
    completed_dir = Path.join([base_path, kb_path, "completed"])

    case File.mkdir_p(completed_dir) do
      :ok ->
        safe_id = sanitize_identifier(issue_id)
        file_path = Path.join(completed_dir, "#{safe_id}.json")
        json = Plan.to_json(plan)

        case File.write(file_path, json) do
          :ok ->
            Logger.info("Archived plan for #{issue_id} to #{file_path}")
            :ok

          {:error, reason} ->
            Logger.error("Failed to archive plan for #{issue_id}: #{inspect(reason)}")
            {:error, {:archive_write_failed, reason}}
        end

      {:error, reason} ->
        Logger.error("Failed to create knowledge base directory: #{inspect(reason)}")
        {:error, {:mkdir_failed, reason}}
    end
  end

  defp do_load_recent_plans(base_path, limit, kb_path) do
    completed_dir = Path.join([base_path, kb_path, "completed"])

    case File.ls(completed_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort_by(fn file ->
          case File.stat(Path.join(completed_dir, file), time: :posix) do
            {:ok, %{mtime: mtime}} -> -mtime
            _ -> 0
          end
        end)
        |> Enum.take(limit)
        |> Enum.flat_map(fn file ->
          path = Path.join(completed_dir, file)

          case File.read(path) do
            {:ok, json} ->
              case Plan.from_json(json) do
                {:ok, plan} -> [plan]
                {:error, _} -> []
              end

            {:error, _} ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp do_append_lesson(base_path, lesson, kb_path) do
    lessons_path = Path.join([base_path, kb_path, "lessons.md"])

    case File.mkdir_p(Path.dirname(lessons_path)) do
      :ok ->
        timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
        entry = "\n## #{timestamp}\n\n#{lesson}\n"

        case File.write(lessons_path, entry, [:append]) do
          :ok -> :ok
          {:error, reason} -> {:error, {:lesson_write_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:mkdir_failed, reason}}
    end
  end

  defp do_load_module_context(base_path, module_name, kb_path) do
    completed_dir = Path.join([base_path, kb_path, "completed"])

    case File.ls(completed_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.find_value(fn file ->
          path = Path.join(completed_dir, file)

          with {:ok, json} <- File.read(path),
               {:ok, plan} <- Plan.from_json(json) do
            if module_relevant?(plan, module_name) do
              summarize_plan_for_context(plan)
            end
          else
            _ -> nil
          end
        end)

      {:error, _} ->
        nil
    end
  end

  defp module_relevant?(%Plan{affected_files: files}, module_name) do
    downcased = String.downcase(module_name)

    Enum.any?(files, fn file ->
      file |> String.downcase() |> String.contains?(downcased)
    end)
  end

  defp summarize_plan_for_context(%Plan{} = plan) do
    parts =
      [
        if(plan.approach, do: "Approach: #{plan.approach}"),
        if(plan.affected_files != [], do: "Files: #{Enum.join(plan.affected_files, ", ")}"),
        if(plan.scope, do: "Scope: #{plan.scope}")
      ]

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp sanitize_identifier(id) when is_binary(id) do
    String.replace(id, ~r/[^a-zA-Z0-9._-]/, "_")
  end
end
