defmodule SymphonyElixir.AgentBackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentBackend

  describe "AgentBackend.Codex" do
    test "implements all required callbacks" do
      module = AgentBackend.Codex
      behaviours = module.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
      assert AgentBackend in behaviours
    end

    test "supports_tool_injection? returns true" do
      assert AgentBackend.Codex.supports_tool_injection?() == true
    end
  end

  describe "AgentBackend.Stub" do
    setup do
      AgentBackend.Stub.reset()
      :ok
    end

    test "start_session returns ok by default" do
      assert {:ok, session} = AgentBackend.Stub.start_session("/tmp/test", [])
      assert session.stub == true
      assert session.workspace == "/tmp/test"
    end

    test "run_turn returns ok by default" do
      session = %{workspace: "/tmp/test", stub: true}
      assert {:ok, result} = AgentBackend.Stub.run_turn(session, "prompt", %{}, [])
      assert result.result == :turn_completed
    end

    test "configure overrides return values" do
      AgentBackend.Stub.configure(:start_session, {:error, :test_error})
      assert {:error, :test_error} = AgentBackend.Stub.start_session("/tmp/test", [])
    end

    test "calls tracks invocations" do
      AgentBackend.Stub.start_session("/tmp/a", [])
      AgentBackend.Stub.start_session("/tmp/b", [])

      calls = AgentBackend.Stub.calls(:start_session)
      assert length(calls) == 2
      assert {"/tmp/a", []} = hd(calls)
    end

    test "stop_session returns ok" do
      assert :ok = AgentBackend.Stub.stop_session(%{})
    end

    test "supports_tool_injection? returns false" do
      refute AgentBackend.Stub.supports_tool_injection?()
    end
  end
end
