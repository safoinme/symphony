defmodule SymphonyElixir.AgentBackend do
  @moduledoc """
  Behaviour defining a pluggable agent backend for Symphony orchestration.

  Implementations wrap a specific AI agent (Codex, Claude Code, etc.) behind a
  uniform session lifecycle: start → run_turn(s) → stop.
  """

  @type session :: term()
  @type workspace :: Path.t()

  @doc "Start a new agent session rooted at `workspace`."
  @callback start_session(workspace(), opts :: keyword()) ::
              {:ok, session()} | {:error, term()}

  @doc "Run a single conversational turn within `session`."
  @callback run_turn(session(), prompt :: String.t(), issue :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Execute a client-side tool call on behalf of the agent.

  Backends that manage their own tools (e.g. Claude Code via MCP) may return
  an error map instead.
  """
  @callback handle_tool_call(session(), tool_name :: String.t(), arguments :: map()) ::
              map()

  @doc "Tear down the session, releasing any resources."
  @callback stop_session(session()) :: :ok

  @doc """
  Whether the backend supports dynamic tool injection from the orchestrator.

  Codex accepts `dynamicTools` in the thread/start handshake; Claude Code
  relies on MCP servers configured externally.
  """
  @callback supports_tool_injection?() :: boolean()
end
