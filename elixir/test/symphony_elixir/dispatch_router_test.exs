defmodule SymphonyElixir.DispatchRouterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.DispatchRouter
  alias SymphonyElixir.Linear.Issue

  defp issue(state) do
    %Issue{
      id: "issue-1",
      identifier: "TEST-1",
      title: "Test issue",
      description: "Test description",
      state: state,
      labels: [],
      blocked_by: [],
      assigned_to_worker: true
    }
  end

  describe "route/1 with no pipeline config" do
    test "returns agent action with Codex backend by default" do
      assert {:agent, SymphonyElixir.AgentBackend.Codex, _opts} =
               DispatchRouter.route(issue("In Progress"))
    end

    test "returns agent action for any unconfigured state" do
      assert {:agent, SymphonyElixir.AgentBackend.Codex, _opts} =
               DispatchRouter.route(issue("Todo"))
    end
  end

  describe "route/1 with pipeline config" do
    test "routes gate action for Human Review state" do
      write_workflow_file!(Workflow.workflow_file_path(),
        pipeline_state_actions: %{
          "human review" => %{"action" => "gate"}
        }
      )

      assert :gate = DispatchRouter.route(issue("Human Review"))
    end

    test "routes plan action for Planning state" do
      write_workflow_file!(Workflow.workflow_file_path(),
        pipeline_state_actions: %{
          "planning" => %{"action" => "plan", "backend" => "claude_code"}
        }
      )

      assert {:plan, SymphonyElixir.AgentBackend.ClaudeCode, _opts} =
               DispatchRouter.route(issue("Planning"))
    end

    test "routes review action for In Review state" do
      write_workflow_file!(Workflow.workflow_file_path(),
        pipeline_state_actions: %{
          "in review" => %{"action" => "review"}
        }
      )

      assert {:review, _backend, _opts} = DispatchRouter.route(issue("In Review"))
    end

    test "routes agent action with specific backend" do
      write_workflow_file!(Workflow.workflow_file_path(),
        pipeline_state_actions: %{
          "in progress" => %{"action" => "agent", "backend" => "claude_code"}
        }
      )

      assert {:agent, SymphonyElixir.AgentBackend.ClaudeCode, _opts} =
               DispatchRouter.route(issue("In Progress"))
    end

    test "passes max_turns from state config" do
      write_workflow_file!(Workflow.workflow_file_path(),
        pipeline_state_actions: %{
          "in progress" => %{"action" => "agent", "max_turns" => 5}
        }
      )

      assert {:agent, _backend, opts} = DispatchRouter.route(issue("In Progress"))
      assert Keyword.get(opts, :max_turns) == 5
    end

    test "passes model from state config" do
      write_workflow_file!(Workflow.workflow_file_path(),
        pipeline_state_actions: %{
          "planning" => %{"action" => "plan", "backend" => "claude_code", "model" => "claude-opus-4-20250514"}
        }
      )

      assert {:plan, SymphonyElixir.AgentBackend.ClaudeCode, opts} =
               DispatchRouter.route(issue("Planning"))

      assert Keyword.get(opts, :model) == "claude-opus-4-20250514"
    end

    test "model absent when not configured" do
      write_workflow_file!(Workflow.workflow_file_path(),
        pipeline_state_actions: %{
          "in progress" => %{"action" => "agent"}
        }
      )

      assert {:agent, _backend, opts} = DispatchRouter.route(issue("In Progress"))
      assert Keyword.get(opts, :model) == nil
    end

    test "passes both model and max_turns" do
      write_workflow_file!(Workflow.workflow_file_path(),
        pipeline_state_actions: %{
          "in review" => %{"action" => "review", "model" => "claude-sonnet-4-20250514", "max_turns" => 3}
        }
      )

      assert {:review, _backend, opts} = DispatchRouter.route(issue("In Review"))
      assert Keyword.get(opts, :model) == "claude-sonnet-4-20250514"
      assert Keyword.get(opts, :max_turns) == 3
    end
  end
end
