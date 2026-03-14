defmodule SymphonyElixir.PlanningRunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentBackend
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PlanningRunner

  setup do
    AgentBackend.Stub.reset()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pipeline_state_actions: %{
        "todo" => %{"action" => "plan"}
      }
    )

    :ok
  end

  defp test_issue do
    %Issue{
      id: "issue-plan-1",
      identifier: "PLAN-1",
      title: "Implement user authentication",
      description: "Add OAuth2 support to the API",
      state: "Todo",
      labels: [],
      blocked_by: [],
      assigned_to_worker: true
    }
  end

  describe "run/3" do
    test "creates workspace, runs agent, saves PLAN.md, and stops session" do
      workspace_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-plan-save-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        pipeline_state_actions: %{
          "todo" => %{"action" => "plan"}
        }
      )

      issue = test_issue()
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      AgentBackend.Stub.configure(:run_turn, {:ok, %{text: "## Affected Files\n\n- src/auth.ex\n\n## Approach\n\nAdd OAuth2 module."}})

      assert :ok =
               PlanningRunner.run(issue, nil,
                 backend: AgentBackend.Stub,
                 issue_state_fetcher: fn _ids -> {:ok, [issue]} end
               )

      workspace = Path.join(workspace_root, "PLAN-1")
      assert File.exists?(Path.join(workspace, "PLAN.md"))

      plan_content = File.read!(Path.join(workspace, "PLAN.md"))
      assert plan_content =~ "Affected Files"
      assert plan_content =~ "Implementation Plan"

      # Verify comment was posted (summary, not full plan)
      assert_received {:memory_tracker_comment, "issue-plan-1", comment_body}
      assert comment_body =~ "Planning Complete"
      assert comment_body =~ "Move this issue to **In Progress**"

      # Verify NO state transition happened
      refute_received {:memory_tracker_state_update, _, _}

      assert [_] = AgentBackend.Stub.calls(:start_session)
      assert [_] = AgentBackend.Stub.calls(:run_turn)
      assert [_] = AgentBackend.Stub.calls(:stop_session)

      File.rm_rf(workspace_root)
    end

    test "saves QUESTIONS.md when agent asks questions without a plan" do
      workspace_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-plan-questions-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        pipeline_state_actions: %{
          "todo" => %{"action" => "plan"}
        }
      )

      issue = test_issue()

      AgentBackend.Stub.configure(:run_turn, {:ok, %{text: "QUESTIONS\n\n1. What OAuth2 provider should we use?\n2. Do we need refresh token support?"}})

      assert :ok =
               PlanningRunner.run(issue, nil,
                 backend: AgentBackend.Stub,
                 issue_state_fetcher: fn _ids -> {:ok, [issue]} end
               )

      workspace = Path.join(workspace_root, "PLAN-1")
      assert File.exists?(Path.join(workspace, "QUESTIONS.md"))
      refute File.exists?(Path.join(workspace, "PLAN.md"))

      File.rm_rf(workspace_root)
    end

    test "sends worker runtime info to recipient" do
      issue = test_issue()
      recipient = self()

      PlanningRunner.run(issue, recipient,
        backend: AgentBackend.Stub,
        issue_state_fetcher: fn _ids -> {:ok, [issue]} end
      )

      assert_received {:worker_runtime_info, "issue-plan-1", %{workspace_path: _}}
    end

    test "extracts plan from Claude Code response format" do
      workspace_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-plan-cc-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        pipeline_state_actions: %{
          "todo" => %{"action" => "plan"}
        }
      )

      issue = test_issue()
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      # Claude Code backend returns nested %{result: {:completed, payload}} structure
      claude_code_response =
        {:ok,
         %{
           result:
             {:completed,
              %{
                "type" => "result",
                "subtype" => "success",
                "result" => "## Affected Files\n\n- src/auth.ex\n\n## Approach\n\nUse OAuth2 library."
              }},
           session: %{}
         }}

      AgentBackend.Stub.configure(:run_turn, claude_code_response)

      assert :ok =
               PlanningRunner.run(issue, nil,
                 backend: AgentBackend.Stub,
                 issue_state_fetcher: fn _ids -> {:ok, [issue]} end
               )

      workspace = Path.join(workspace_root, "PLAN-1")
      assert File.exists?(Path.join(workspace, "PLAN.md"))
      plan_content = File.read!(Path.join(workspace, "PLAN.md"))
      assert plan_content =~ "OAuth2 library"

      assert_received {:memory_tracker_comment, "issue-plan-1", _}
      refute_received {:memory_tracker_state_update, _, _}

      File.rm_rf(workspace_root)
    end

    test "handles start_session failure" do
      issue = test_issue()
      AgentBackend.Stub.configure(:start_session, {:error, :session_failed})

      assert {:error, :session_failed} =
               PlanningRunner.run(issue, nil,
                 backend: AgentBackend.Stub,
                 issue_state_fetcher: fn _ids -> {:ok, [issue]} end
               )
    end

    test "runs before_plan hook before agent turn" do
      workspace_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-plan-hook-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        pipeline_state_actions: %{
          "todo" => %{"action" => "plan"}
        },
        hook_before_plan: "touch .before_plan_ran"
      )

      issue = test_issue()

      PlanningRunner.run(issue, nil,
        backend: AgentBackend.Stub,
        issue_state_fetcher: fn _ids -> {:ok, [issue]} end
      )

      workspace = Path.join(workspace_root, "PLAN-1")
      assert File.exists?(Path.join(workspace, ".before_plan_ran"))

      File.rm_rf(workspace_root)
    end

    test "includes rp_context in prompt when .rp-context.json exists" do
      workspace_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-plan-rp-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        pipeline_state_actions: %{
          "todo" => %{"action" => "plan"}
        },
        hook_after_create: "echo '{\"files\": [\"src/main.ex\"]}' > .rp-context.json"
      )

      issue = test_issue()

      PlanningRunner.run(issue, nil,
        backend: AgentBackend.Stub,
        issue_state_fetcher: fn _ids -> {:ok, [issue]} end
      )

      [{_session, prompt, _issue, _opts}] = AgentBackend.Stub.calls(:run_turn)
      assert prompt =~ "Repository Analysis"
      assert prompt =~ "src/main.ex"

      File.rm_rf(workspace_root)
    end

    test "gracefully skips missing .rp-context.json" do
      issue = test_issue()

      AgentBackend.Stub.configure(:run_turn, {:ok, %{text: "## Affected Files\n\n- foo.ex\n\n## Approach\n\nDo the thing."}})

      PlanningRunner.run(issue, nil,
        backend: AgentBackend.Stub,
        issue_state_fetcher: fn _ids -> {:ok, [issue]} end
      )

      [{_session, prompt, _issue, _opts}] = AgentBackend.Stub.calls(:run_turn)
      refute prompt =~ "Repository Analysis"
    end
  end

  describe "planning_complete?/1" do
    test "returns true when PLAN.md exists" do
      workspace = Path.join(System.tmp_dir!(), "symphony-plan-complete-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "PLAN.md"), "# Plan")

      assert PlanningRunner.planning_complete?(workspace)

      File.rm_rf(workspace)
    end

    test "returns false when PLAN.md does not exist" do
      workspace = Path.join(System.tmp_dir!(), "symphony-plan-incomplete-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)

      refute PlanningRunner.planning_complete?(workspace)

      File.rm_rf(workspace)
    end
  end

  describe "questions_pending?/1" do
    test "returns true when QUESTIONS.md exists but PLAN.md does not" do
      workspace = Path.join(System.tmp_dir!(), "symphony-plan-q-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "QUESTIONS.md"), "What provider?")

      assert PlanningRunner.questions_pending?(workspace)

      File.rm_rf(workspace)
    end

    test "returns false when both QUESTIONS.md and PLAN.md exist" do
      workspace = Path.join(System.tmp_dir!(), "symphony-plan-qp-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "QUESTIONS.md"), "What provider?")
      File.write!(Path.join(workspace, "PLAN.md"), "# Plan")

      refute PlanningRunner.questions_pending?(workspace)

      File.rm_rf(workspace)
    end

    test "returns false when neither file exists" do
      workspace = Path.join(System.tmp_dir!(), "symphony-plan-none-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)

      refute PlanningRunner.questions_pending?(workspace)

      File.rm_rf(workspace)
    end
  end
end
