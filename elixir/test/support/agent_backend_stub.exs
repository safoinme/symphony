defmodule SymphonyElixir.AgentBackend.Stub do
  @moduledoc """
  Test stub implementing AgentBackend for use in tests.
  Stores calls in the process dictionary and returns configurable responses.
  """

  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(workspace, opts) do
    record_call(:start_session, {workspace, opts})

    case Process.get(:stub_start_session_result) do
      nil -> {:ok, %{workspace: workspace, opts: opts, stub: true}}
      result -> result
    end
  end

  @impl true
  def run_turn(session, prompt, issue, opts) do
    record_call(:run_turn, {session, prompt, issue, opts})
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)

    on_message.(%{
      event: :turn_completed,
      timestamp: DateTime.utc_now(),
      details: %{},
      metadata: %{}
    })

    case Process.get(:stub_run_turn_result) do
      nil -> {:ok, %{result: :turn_completed, session_id: "stub-session", thread_id: "stub-thread"}}
      result -> result
    end
  end

  @impl true
  def handle_tool_call(session, tool_name, arguments) do
    record_call(:handle_tool_call, {session, tool_name, arguments})

    case Process.get(:stub_handle_tool_call_result) do
      nil -> %{"success" => true, "output" => "stub result", "contentItems" => []}
      result -> result
    end
  end

  @impl true
  def stop_session(session) do
    record_call(:stop_session, {session})
    :ok
  end

  @impl true
  def supports_tool_injection?, do: false

  # Test helpers

  @spec configure(atom(), term()) :: :ok
  def configure(callback, result) do
    Process.put(:"stub_#{callback}_result", result)
    :ok
  end

  @spec calls(atom()) :: [term()]
  def calls(callback) do
    Process.get(:"stub_#{callback}_calls", [])
  end

  @spec reset() :: :ok
  def reset do
    for key <- [:start_session, :run_turn, :handle_tool_call, :stop_session] do
      Process.delete(:"stub_#{key}_calls")
      Process.delete(:"stub_#{key}_result")
    end

    :ok
  end

  defp record_call(callback, args) do
    key = :"stub_#{callback}_calls"
    Process.put(key, Process.get(key, []) ++ [args])
  end
end
