defmodule SymphonyElixir.Plan do
  @moduledoc """
  Structured implementation plan as a first-class artifact.
  Plans are persisted as PLAN.json and provide machine-parseable
  task tracking with completion gates.
  """

  alias __MODULE__

  defmodule Task do
    @moduledoc false

    @type status :: :pending | :in_progress | :completed | :blocked

    @type t :: %__MODULE__{
            id: String.t(),
            description: String.t(),
            file_paths: [String.t()],
            status: status()
          }

    @enforce_keys [:id, :description]
    defstruct [:id, :description, file_paths: [], status: :pending]

    @valid_statuses [:pending, :in_progress, :completed, :blocked]

    @spec valid_status?(atom()) :: boolean()
    def valid_status?(status), do: status in @valid_statuses
  end

  @type t :: %__MODULE__{
          issue_identifier: String.t() | nil,
          scope: String.t() | nil,
          approach: String.t() | nil,
          tasks: [Task.t()],
          affected_files: [String.t()],
          risks: [String.t()],
          created_at: String.t() | nil,
          updated_at: String.t() | nil
        }

  @enforce_keys []
  defstruct [
    :issue_identifier,
    :scope,
    :approach,
    tasks: [],
    affected_files: [],
    risks: [],
    created_at: nil,
    updated_at: nil
  ]

  @spec new(map()) :: t()
  def new(attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    tasks =
      attrs
      |> get_field(:tasks, [])
      |> Enum.map(&build_task/1)

    %Plan{
      issue_identifier: get_field(attrs, :issue_identifier),
      scope: get_field(attrs, :scope),
      approach: get_field(attrs, :approach),
      tasks: tasks,
      affected_files: get_field(attrs, :affected_files, []),
      risks: get_field(attrs, :risks, []),
      created_at: get_field(attrs, :created_at, now),
      updated_at: get_field(attrs, :updated_at, now)
    }
  end

  # Looks up a key in a map by atom first, then string key.
  defp get_field(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  @spec to_json(t()) :: String.t()
  def to_json(%Plan{} = plan) do
    plan
    |> to_map()
    |> Jason.encode!(pretty: true)
  end

  @spec from_json(String.t()) :: {:ok, t()} | {:error, term()}
  def from_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, data} when is_map(data) ->
        {:ok, new(data)}

      {:ok, _} ->
        {:error, :invalid_plan_format}

      {:error, reason} ->
        {:error, {:json_decode_error, reason}}
    end
  end

  @spec update_task_status(t(), String.t(), Task.status()) :: {:ok, t()} | {:error, :task_not_found}
  def update_task_status(%Plan{} = plan, task_id, new_status) when is_binary(task_id) do
    if Task.valid_status?(new_status) do
      case find_and_update_task(plan.tasks, task_id, new_status) do
        {:ok, updated_tasks} ->
          {:ok, %{plan | tasks: updated_tasks, updated_at: DateTime.utc_now() |> DateTime.to_iso8601()}}

        :not_found ->
          {:error, :task_not_found}
      end
    else
      {:error, :invalid_status}
    end
  end

  @spec complete?(t()) :: boolean()
  def complete?(%Plan{tasks: []}), do: false

  def complete?(%Plan{tasks: tasks}) do
    Enum.all?(tasks, fn task -> task.status == :completed end)
  end

  @spec to_checklist(t()) :: String.t()
  def to_checklist(%Plan{} = plan) do
    header = "## Implementation Plan\n\n"

    approach =
      if plan.approach do
        "### Approach\n#{plan.approach}\n\n"
      else
        ""
      end

    tasks_section =
      if plan.tasks != [] do
        task_lines =
          plan.tasks
          |> Enum.map(fn task ->
            checkbox = if task.status == :completed, do: "[x]", else: "[ ]"
            status_label = status_indicator(task.status)
            files = if task.file_paths != [], do: " (#{Enum.join(task.file_paths, ", ")})", else: ""
            "- #{checkbox} #{task.description}#{files} #{status_label}"
          end)
          |> Enum.join("\n")

        "### Tasks\n#{task_lines}\n\n"
      else
        ""
      end

    files_section =
      if plan.affected_files != [] do
        file_lines = Enum.map_join(plan.affected_files, "\n", &"- #{&1}")
        "### Affected Files\n#{file_lines}\n\n"
      else
        ""
      end

    risks_section =
      if plan.risks != [] do
        risk_lines = Enum.map_join(plan.risks, "\n", &"- #{&1}")
        "### Risks\n#{risk_lines}\n"
      else
        ""
      end

    header <> approach <> tasks_section <> files_section <> risks_section
  end

  # --- Private ---

  defp build_task(%Task{} = task), do: task

  defp build_task(attrs) when is_map(attrs) do
    %Task{
      id: Map.get(attrs, :id, Map.get(attrs, "id", generate_task_id())),
      description: Map.get(attrs, :description, Map.get(attrs, "description", "")),
      file_paths: Map.get(attrs, :file_paths, Map.get(attrs, "file_paths", [])),
      status: parse_status(Map.get(attrs, :status, Map.get(attrs, "status", "pending")))
    }
  end

  defp build_task(_), do: %Task{id: generate_task_id(), description: ""}

  defp parse_status(status) when is_atom(status) and status in [:pending, :in_progress, :completed, :blocked],
    do: status

  defp parse_status("pending"), do: :pending
  defp parse_status("in_progress"), do: :in_progress
  defp parse_status("completed"), do: :completed
  defp parse_status("blocked"), do: :blocked
  defp parse_status(_), do: :pending

  defp find_and_update_task(tasks, task_id, new_status) do
    {updated, found?} =
      Enum.map_reduce(tasks, false, fn task, found ->
        if task.id == task_id do
          {%{task | status: new_status}, true}
        else
          {task, found}
        end
      end)

    if found?, do: {:ok, updated}, else: :not_found
  end

  defp to_map(%Plan{} = plan) do
    %{
      "issue_identifier" => plan.issue_identifier,
      "scope" => plan.scope,
      "approach" => plan.approach,
      "tasks" => Enum.map(plan.tasks, &task_to_map/1),
      "affected_files" => plan.affected_files,
      "risks" => plan.risks,
      "created_at" => plan.created_at,
      "updated_at" => plan.updated_at
    }
  end

  defp task_to_map(%Task{} = task) do
    %{
      "id" => task.id,
      "description" => task.description,
      "file_paths" => task.file_paths,
      "status" => Atom.to_string(task.status)
    }
  end

  defp generate_task_id do
    Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)
  end

  defp status_indicator(:pending), do: ""
  defp status_indicator(:in_progress), do: "(in progress)"
  defp status_indicator(:completed), do: ""
  defp status_indicator(:blocked), do: "(blocked)"
end
