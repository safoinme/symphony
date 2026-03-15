defmodule SymphonyElixir.PlanTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Plan

  describe "new/1" do
    test "creates plan with defaults" do
      plan = Plan.new()
      assert plan.tasks == []
      assert plan.affected_files == []
      assert plan.risks == []
      assert plan.created_at != nil
      assert plan.updated_at != nil
    end

    test "creates plan from atom-keyed map" do
      plan =
        Plan.new(%{
          issue_identifier: "TEST-1",
          scope: "medium",
          approach: "Add OAuth2 module",
          tasks: [
            %{id: "t1", description: "Create auth module", file_paths: ["lib/auth.ex"]},
            %{id: "t2", description: "Add tests"}
          ],
          affected_files: ["lib/auth.ex", "test/auth_test.exs"],
          risks: ["OAuth provider may change API"]
        })

      assert plan.issue_identifier == "TEST-1"
      assert plan.scope == "medium"
      assert length(plan.tasks) == 2
      assert hd(plan.tasks).id == "t1"
      assert hd(plan.tasks).status == :pending
      assert plan.affected_files == ["lib/auth.ex", "test/auth_test.exs"]
    end

    test "creates plan from string-keyed map" do
      plan =
        Plan.new(%{
          "issue_identifier" => "TEST-2",
          "scope" => "small",
          "tasks" => [
            %{"id" => "t1", "description" => "Fix bug", "status" => "completed"}
          ]
        })

      assert plan.issue_identifier == "TEST-2"
      assert hd(plan.tasks).status == :completed
    end
  end

  describe "to_json/1 and from_json/1 round-trip" do
    test "serializes and deserializes plan" do
      original =
        Plan.new(%{
          issue_identifier: "RT-1",
          scope: "large",
          approach: "Rewrite the auth system",
          tasks: [
            %{id: "t1", description: "Extract module", file_paths: ["lib/auth.ex"], status: :in_progress},
            %{id: "t2", description: "Write tests", status: :pending}
          ],
          affected_files: ["lib/auth.ex"],
          risks: ["Breaking change"]
        })

      json = Plan.to_json(original)
      assert is_binary(json)

      {:ok, restored} = Plan.from_json(json)
      assert restored.issue_identifier == "RT-1"
      assert restored.scope == "large"
      assert length(restored.tasks) == 2
      assert hd(restored.tasks).id == "t1"
      assert hd(restored.tasks).status == :in_progress
      assert restored.affected_files == ["lib/auth.ex"]
    end

    test "from_json returns error on invalid JSON" do
      assert {:error, {:json_decode_error, _}} = Plan.from_json("not json")
    end

    test "from_json returns error on non-map JSON" do
      assert {:error, :invalid_plan_format} = Plan.from_json("[1, 2, 3]")
    end
  end

  describe "update_task_status/3" do
    test "updates existing task status" do
      plan =
        Plan.new(%{
          tasks: [
            %{id: "t1", description: "Task 1"},
            %{id: "t2", description: "Task 2"}
          ]
        })

      {:ok, updated} = Plan.update_task_status(plan, "t1", :completed)

      [task1, task2] = updated.tasks
      assert task1.status == :completed
      assert task2.status == :pending
      assert updated.updated_at != plan.updated_at
    end

    test "returns error for non-existent task" do
      plan = Plan.new(%{tasks: [%{id: "t1", description: "Task 1"}]})
      assert {:error, :task_not_found} = Plan.update_task_status(plan, "nonexistent", :completed)
    end
  end

  describe "complete?/1" do
    test "returns true when all tasks completed" do
      plan =
        Plan.new(%{
          tasks: [
            %{id: "t1", description: "Done", status: :completed},
            %{id: "t2", description: "Also done", status: :completed}
          ]
        })

      assert Plan.complete?(plan)
    end

    test "returns false when some tasks pending" do
      plan =
        Plan.new(%{
          tasks: [
            %{id: "t1", description: "Done", status: :completed},
            %{id: "t2", description: "Not done", status: :pending}
          ]
        })

      refute Plan.complete?(plan)
    end

    test "returns false when no tasks" do
      plan = Plan.new()
      refute Plan.complete?(plan)
    end
  end

  describe "to_checklist/1" do
    test "renders plan as markdown checklist" do
      plan =
        Plan.new(%{
          approach: "Step by step approach",
          tasks: [
            %{id: "t1", description: "First task", status: :completed},
            %{id: "t2", description: "Second task", file_paths: ["lib/foo.ex"], status: :pending}
          ],
          affected_files: ["lib/foo.ex"],
          risks: ["May break things"]
        })

      checklist = Plan.to_checklist(plan)
      assert checklist =~ "## Implementation Plan"
      assert checklist =~ "[x] First task"
      assert checklist =~ "[ ] Second task (lib/foo.ex)"
      assert checklist =~ "### Affected Files"
      assert checklist =~ "### Risks"
    end
  end
end
