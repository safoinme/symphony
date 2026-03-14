defmodule SymphonyElixir.AgentBackend.Codex do
  @moduledoc """
  AgentBackend implementation that delegates to the Codex app-server.

  This is a thin wrapper — all real logic lives in `Codex.AppServer` and
  `Codex.DynamicTool`. The wrapper exists so the orchestrator can treat Codex
  as one of several interchangeable backends.
  """

  @behaviour SymphonyElixir.AgentBackend

  alias SymphonyElixir.Codex.{AppServer, DynamicTool}

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, AppServer.session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    AppServer.start_session(workspace, opts)
  end

  @impl true
  @spec run_turn(AppServer.session(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    AppServer.run_turn(session, prompt, issue, opts)
  end

  @impl true
  @spec handle_tool_call(AppServer.session(), String.t(), map()) :: map()
  def handle_tool_call(_session, tool_name, arguments) do
    DynamicTool.execute(tool_name, arguments)
  end

  @impl true
  @spec stop_session(AppServer.session()) :: :ok
  def stop_session(session) do
    AppServer.stop_session(session)
  end

  @impl true
  @spec supports_tool_injection?() :: boolean()
  def supports_tool_injection?, do: true
end
