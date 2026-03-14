defmodule SymphonyElixir.ReviewRunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentBackend
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.ReviewRunner

  setup do
    AgentBackend.Stub.reset()

    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-review-ws-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      pipeline_state_actions: %{
        "in review" => %{"action" => "review"}
      },
      # Init a git repo in the workspace so git diff works
      hook_after_create: "git init && git commit --allow-empty -m 'init'"
    )

    on_exit(fn ->
      File.rm_rf(workspace_root)
    end)

    :ok
  end

  defp test_issue do
    %Issue{
      id: "issue-rev-1",
      identifier: "REV-1",
      title: "Fix login bug",
      description: "Users cannot log in with special characters",
      state: "In Review",
      labels: [],
      blocked_by: [],
      assigned_to_worker: true
    }
  end

  describe "run/3" do
    test "creates workspace, runs review agent, and stops session" do
      issue = test_issue()

      assert :ok =
               ReviewRunner.run(issue, nil,
                 backend: AgentBackend.Stub,
                 issue_state_fetcher: fn _ids -> {:ok, [issue]} end
               )

      assert [_] = AgentBackend.Stub.calls(:start_session)
      assert [_] = AgentBackend.Stub.calls(:run_turn)
      assert [_] = AgentBackend.Stub.calls(:stop_session)
    end

    test "sends worker runtime info to recipient" do
      issue = test_issue()
      recipient = self()

      ReviewRunner.run(issue, recipient,
        backend: AgentBackend.Stub,
        issue_state_fetcher: fn _ids -> {:ok, [issue]} end
      )

      assert_received {:worker_runtime_info, "issue-rev-1", %{workspace_path: _}}
    end

    test "handles start_session failure" do
      issue = test_issue()
      AgentBackend.Stub.configure(:start_session, {:error, :review_session_failed})

      assert {:error, :review_session_failed} =
               ReviewRunner.run(issue, nil,
                 backend: AgentBackend.Stub,
                 issue_state_fetcher: fn _ids -> {:ok, [issue]} end
               )
    end
  end
end
