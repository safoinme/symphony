defmodule SymphonyElixir.AgentBackend.ClaudeCode do
  @moduledoc """
  AgentBackend implementation that spawns `claude -p` as a subprocess.

  Unlike the Codex backend (long-running JSON-RPC process), Claude Code exits
  after each invocation. Session continuity is achieved via `--resume <id>`.
  Tool access is provided through MCP servers configured in the workspace's
  `.mcp.json`, not through client-side injection.

  When `cmux_visibility` is enabled in config, agents run in visible cmux
  workspace tabs instead of headless Erlang Ports.
  """

  @behaviour SymphonyElixir.AgentBackend

  require Logger
  alias SymphonyElixir.AgentBackend.ClaudeCode.NdjsonParser
  alias SymphonyElixir.Cmux

  defmodule Session do
    @moduledoc false
    @type t :: %__MODULE__{
            workspace: Path.t(),
            session_id: String.t() | nil,
            worker_host: String.t() | nil,
            config: map(),
            total_cost_usd: float(),
            total_tokens: non_neg_integer()
          }

    defstruct [
      :workspace,
      :session_id,
      :worker_host,
      config: %{},
      total_cost_usd: 0.0,
      total_tokens: 0
    ]
  end

  @default_config %{
    command: "claude",
    permission_mode: "bypassPermissions",
    allowed_tools: ["Read", "Write", "Edit", "Bash(git *)"],
    max_turns: 25,
    model: "claude-sonnet-4-6",
    max_budget_usd: 5.0,
    cmux_visibility: false
  }

  @port_read_timeout_ms 600_000
  @cmux_wait_timeout_seconds 900
  @cmux_stream_poll_ms 1_000
  @cmux_read_chunk_bytes 1_048_576

  # --- AgentBackend callbacks ---

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    config = build_config(opts)

    {:ok,
     %Session{
       workspace: workspace,
       worker_host: worker_host,
       config: config
     }}
  end

  @impl true
  @spec run_turn(Session.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_turn(%Session{} = session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    max_turns = Keyword.get(opts, :max_turns, session.config.max_turns)
    model = Keyword.get(opts, :model, session.config.model)

    args = build_cli_args(session, prompt, max_turns, model)

    Logger.info(
      "Claude Code starting turn for #{issue_context(issue)} workspace=#{session.workspace}"
    )

    result =
      if use_cmux?(session.config) do
        spawn_and_collect_cmux(session, args, on_message, issue)
      else
        spawn_and_collect_port(session, args, on_message, issue)
      end

    case result do
      {:ok, turn_result, updated_session} ->
        {:ok, %{result: turn_result, session: updated_session}}

      {:error, reason} ->
        Logger.warning("Claude Code turn failed for #{issue_context(issue)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  @spec handle_tool_call(Session.t(), String.t(), map()) :: map()
  def handle_tool_call(_session, tool_name, _arguments) do
    %{
      "success" => false,
      "output" =>
        "Claude Code manages tools via MCP servers, not client-side injection. " <>
          "Tool #{inspect(tool_name)} cannot be executed through this backend."
    }
  end

  @impl true
  @spec stop_session(Session.t()) :: :ok
  def stop_session(%Session{}), do: :ok

  @impl true
  @spec supports_tool_injection?() :: boolean()
  def supports_tool_injection?, do: false

  # --- CLI argument building ---

  defp build_cli_args(%Session{} = session, prompt, max_turns, model) do
    base_args = [
      "-p",
      prompt,
      "--output-format",
      "stream-json",
      "--max-turns",
      to_string(max_turns),
      "--model",
      model
    ]

    base_args
    |> maybe_add_resume(session.session_id)
    |> maybe_add_permission_mode(session.config.permission_mode)
    |> maybe_add_allowed_tools(session.config.allowed_tools)
    |> maybe_add_mcp_config(session.workspace)
  end

  defp maybe_add_resume(args, nil), do: args
  defp maybe_add_resume(args, session_id), do: args ++ ["--resume", session_id]

  defp maybe_add_permission_mode(args, nil), do: args
  defp maybe_add_permission_mode(args, mode), do: args ++ ["--permission-mode", mode]

  defp maybe_add_allowed_tools(args, []), do: args

  defp maybe_add_allowed_tools(args, tools) when is_list(tools) do
    tool_args = Enum.flat_map(tools, fn tool -> ["--allowedTools", tool] end)
    args ++ tool_args
  end

  defp maybe_add_mcp_config(args, workspace) do
    mcp_path = Path.join(workspace, ".mcp.json")

    if File.exists?(mcp_path) do
      args ++ ["--mcp-config", mcp_path]
    else
      args
    end
  end

  # --- cmux visibility mode ---

  defp use_cmux?(config) do
    visibility = Map.get(config, :cmux_visibility, false)
    available = if visibility, do: Cmux.available?(), else: false
    Logger.info("cmux check: cmux_visibility=#{visibility} cmux_available=#{available}")
    visibility and available
  end

  defp spawn_and_collect_cmux(%Session{} = session, args, on_message, issue) do
    output_path = Path.join(session.workspace, ".symphony-output.ndjson")
    signal_name = "symphony-#{sanitize_for_signal(issue)}-#{:erlang.unique_integer([:positive])}"
    issue_label = cmux_tab_label(issue)

    executable = resolve_executable(session.config.command)

    case executable do
      {:ok, path} ->
        # Build the shell command that runs in the cmux pane
        cli_args_str = Enum.map_join(args, " ", &shell_escape/1)
        display_filter = ndjson_display_filter_path()

        # Use unbuffered display filter instead of tee to avoid macOS tee buffering
        # which prevents the streaming parser from reading events from the file.
        tee_cmd =
          if display_filter do
            "python3 #{shell_escape(display_filter)} #{shell_escape(output_path)}"
          else
            "tee #{shell_escape(output_path)}"
          end

        wrapper_script = """
        printf '\\033]0;#{issue_label}\\007'
        cd #{shell_escape(session.workspace)} && \
        #{shell_escape(path)} #{cli_args_str} 2>&1 | #{tee_cmd}
        EXIT_CODE=${PIPESTATUS[0]:-$?}
        echo ""
        echo "━━━ Agent finished (exit $EXIT_CODE) ━━━"
        cmux wait-for -S #{signal_name}
        """

        Logger.info("Opening cmux workspace for #{issue_label}")

        case Cmux.new_workspace(wrapper_script) do
          {:ok, workspace_ref} ->
            Logger.info("cmux workspace created: #{workspace_ref} for #{issue_label}")
            Cmux.rename_workspace(workspace_ref, issue_label)

            # Emit workspace ref so the orchestrator can expose it in the dashboard
            emit_event(on_message, :cmux_workspace, %{
              "cmux_workspace_ref" => workspace_ref,
              "cmux_attach_cmd" => "cmux select-workspace #{workspace_ref}"
            })

            try do
              wait_and_stream_cmux(signal_name, output_path, session, on_message)
            after
              Logger.info("Closing cmux workspace #{workspace_ref} for #{issue_label}")
              Cmux.close_workspace(workspace_ref)
            end

          {:error, reason} ->
            Logger.warning("cmux workspace creation failed, falling back to Port: #{inspect(reason)}")
            spawn_and_collect_port(session, args, on_message, issue)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wait_and_stream_cmux(signal_name, output_path, session, on_message) do
    Logger.info("Streaming cmux output for signal: #{signal_name}")

    wait_task =
      Task.async(fn ->
        Cmux.wait_for(signal_name, @cmux_wait_timeout_seconds)
      end)

    parser = NdjsonParser.new()
    stream_cmux_loop(wait_task, output_path, parser, session, on_message, 0, nil)
  end

  # Extra arg: idle_since tracks when we last saw new data after a result event.
  # If we have a result and no new data for @cmux_result_idle_timeout_ms, exit
  # without the signal (safety net for when cmux signal delivery fails).
  @cmux_result_idle_timeout_ms 15_000

  defp stream_cmux_loop(wait_task, output_path, parser, session, on_message, bytes_read, last_result) do
    stream_cmux_loop(wait_task, output_path, parser, session, on_message, bytes_read, last_result, nil)
  end

  defp stream_cmux_loop(wait_task, output_path, parser, session, on_message, bytes_read, last_result, idle_since) do
    case Task.yield(wait_task, @cmux_stream_poll_ms) do
      nil ->
        {parser, session, last_result, new_bytes_read} =
          read_and_process_cmux_output(output_path, bytes_read, parser, session, on_message, last_result)

        got_new_data = new_bytes_read > bytes_read
        has_result = match?({:completed, _}, last_result) or match?({:error, _}, last_result)

        # Track idle time after seeing a result event
        idle_since =
          cond do
            not has_result -> nil
            got_new_data -> nil
            is_nil(idle_since) -> System.monotonic_time(:millisecond)
            true -> idle_since
          end

        # Safety net: if we have a result and no new data for N seconds, exit
        if has_result and idle_since != nil and
             System.monotonic_time(:millisecond) - idle_since > @cmux_result_idle_timeout_ms do
          Logger.info("cmux stream: result received and idle for #{@cmux_result_idle_timeout_ms}ms, completing without signal")
          Task.shutdown(wait_task, :brutal_kill)
          finalize_cmux_stream(parser, session, on_message, last_result)
        else
          stream_cmux_loop(wait_task, output_path, parser, session, on_message, new_bytes_read, last_result, idle_since)
        end

      {:ok, wait_result} ->
        if wait_result == {:error, :timeout} do
          Logger.warning("cmux agent timed out after #{@cmux_wait_timeout_seconds}s")
        end

        finalize_cmux_stream_with_read(output_path, bytes_read, parser, session, on_message, last_result)

      {:exit, reason} ->
        Logger.warning("cmux wait task crashed: #{inspect(reason)}")
        finalize_cmux_stream_with_read(output_path, bytes_read, parser, session, on_message, last_result)
    end
  end

  defp finalize_cmux_stream_with_read(output_path, bytes_read, parser, session, on_message, last_result) do
    {parser, session, last_result, _bytes} =
      read_and_process_cmux_output(output_path, bytes_read, parser, session, on_message, last_result)

    finalize_cmux_stream(parser, session, on_message, last_result)
  end

  defp finalize_cmux_stream(parser, session, on_message, last_result) do
    {flush_events, _} = NdjsonParser.flush(parser)
    {session, last_result} = process_events(flush_events, session, on_message, last_result)
    {:ok, last_result || :turn_completed, session}
  end

  defp read_and_process_cmux_output(output_path, bytes_read, parser, session, on_message, last_result) do
    case read_new_output(output_path, bytes_read) do
      {:ok, data, new_bytes_read} ->
        {events, updated_parser} = NdjsonParser.feed(parser, data)
        {updated_session, updated_result} = process_events(events, session, on_message, last_result)
        {updated_parser, updated_session, updated_result, new_bytes_read}

      :no_new_data ->
        {parser, session, last_result, bytes_read}
    end
  end

  defp read_new_output(output_path, bytes_read) do
    case :file.open(String.to_charlist(output_path), [:read, :binary, :raw]) do
      {:ok, fd} ->
        result =
          case :file.pread(fd, bytes_read, @cmux_read_chunk_bytes) do
            {:ok, data} when byte_size(data) > 0 ->
              {:ok, data, bytes_read + byte_size(data)}

            _ ->
              :no_new_data
          end

        :file.close(fd)
        result

      {:error, _reason} ->
        :no_new_data
    end
  end

  defp sanitize_for_signal(issue) do
    identifier = Map.get(issue, :identifier) || Map.get(issue, "identifier") || "unknown"
    String.replace(to_string(identifier), ~r/[^a-zA-Z0-9_-]/, "_")
  end

  defp cmux_tab_label(issue) do
    identifier = Map.get(issue, :identifier) || Map.get(issue, "identifier") || "agent"
    state = Map.get(issue, :state) || Map.get(issue, "state") || ""
    "#{identifier} #{state}" |> String.trim()
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  # --- Port-based subprocess management (headless mode) ---
  #
  # Claude Code requires a TTY to produce `--output-format stream-json` output.
  # Without a TTY, it produces nothing. We use `script -q /dev/null` to allocate
  # a pseudo-TTY when running as a headless Erlang Port.

  defp spawn_and_collect_port(%Session{} = session, args, on_message, issue) do
    executable = resolve_executable(session.config.command)

    case executable do
      {:ok, path} ->
        port = open_port_with_pty(path, args, session.workspace)
        collect_output(port, session, on_message, issue)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_executable(command) do
    case System.find_executable(command) do
      nil -> {:error, {:executable_not_found, command}}
      path -> {:ok, path}
    end
  end

  defp open_port_with_pty(executable, args, workspace) do
    script_path = System.find_executable("script")

    if script_path do
      # Use `script -q /dev/null` to provide a PTY for claude
      cli_args_str = Enum.map_join([executable | args], " ", &shell_escape/1)

      Port.open(
        {:spawn_executable, String.to_charlist(script_path)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(["-q", "/dev/null", "/bin/sh", "-c", cli_args_str], &String.to_charlist/1),
          cd: String.to_charlist(workspace)
        ]
      )
    else
      # Fallback: try without PTY (may not produce output)
      Logger.warning("'script' command not found; Claude Code may not produce stream-json output without a TTY")

      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(args, &String.to_charlist/1),
          cd: String.to_charlist(workspace)
        ]
      )
    end
  end

  defp collect_output(port, session, on_message, issue) do
    parser = NdjsonParser.new()
    collect_loop(port, parser, session, on_message, issue, nil)
  end

  defp collect_loop(port, parser, session, on_message, issue, last_result) do
    receive do
      {^port, {:data, data}} ->
        {events, updated_parser} = NdjsonParser.feed(parser, data)
        {updated_session, updated_result} = process_events(events, session, on_message, last_result)
        collect_loop(port, updated_parser, updated_session, on_message, issue, updated_result)

      {^port, {:exit_status, 0}} ->
        finalize(parser, session, on_message, last_result)

      {^port, {:exit_status, status}} ->
        {flush_events, _} = NdjsonParser.flush(parser)
        {updated_session, _} = process_events(flush_events, session, on_message, last_result)
        {:error, {:exit_status, status, updated_session}}
    after
      @port_read_timeout_ms ->
        safe_close_port(port)
        {:error, :timeout}
    end
  end

  defp finalize(parser, session, on_message, last_result) do
    {flush_events, _} = NdjsonParser.flush(parser)
    {updated_session, final_result} = process_events(flush_events, session, on_message, last_result)

    result = final_result || :turn_completed
    {:ok, result, updated_session}
  end

  # --- Shared event processing ---

  defp process_events(events, session, on_message, last_result) do
    Enum.reduce(events, {session, last_result}, fn {event_type, payload}, {sess, acc_result} ->
      emit_event(on_message, event_type, payload)
      updated_sess = maybe_update_session(sess, event_type, payload)
      updated_result = maybe_update_result(event_type, payload) || acc_result
      {updated_sess, updated_result}
    end)
  end

  defp maybe_update_session(session, :session_init, payload) do
    session_id = get_in(payload, ["session_id"]) || get_in(payload, ["sessionId"])

    if session_id do
      %{session | session_id: session_id}
    else
      session
    end
  end

  defp maybe_update_session(session, :turn_completed, payload) do
    cost = get_in(payload, ["cost_usd"]) || get_in(payload, ["costUsd"]) || 0.0
    tokens = get_in(payload, ["total_tokens"]) || get_in(payload, ["totalTokens"]) || 0

    %{
      session
      | total_cost_usd: session.total_cost_usd + cost,
        total_tokens: session.total_tokens + tokens
    }
  end

  defp maybe_update_session(session, _event_type, _payload), do: session

  defp maybe_update_result(:turn_completed, payload), do: {:completed, payload}
  # :turn_result is the catch-all for all "type":"result" events, including
  # error_max_turns, error_tool, etc. — the turn IS done regardless of subtype.
  defp maybe_update_result(:turn_result, payload), do: {:completed, payload}
  defp maybe_update_result(:turn_error, payload), do: {:error, payload}
  defp maybe_update_result(_event_type, _payload), do: nil

  defp emit_event(on_message, event_type, payload) when is_function(on_message, 1) do
    on_message.(%{
      event: event_type,
      payload: payload,
      timestamp: DateTime.utc_now()
    })
  end

  defp safe_close_port(port) do
    case :erlang.port_info(port) do
      :undefined -> :ok
      _ ->
        try do
          Port.close(port)
        rescue
          ArgumentError -> :ok
        end
    end
  end

  # --- Helpers ---

  defp build_config(opts) do
    claude_code_config = SymphonyElixir.Config.settings!().claude_code

    config_from_schema =
      %{
        command: claude_code_config.command,
        permission_mode: claude_code_config.permission_mode,
        allowed_tools: claude_code_config.allowed_tools,
        max_budget_usd: claude_code_config.max_budget_usd,
        model: claude_code_config.model,
        cmux_visibility: claude_code_config.cmux_visibility
      }

    overrides =
      opts
      |> Keyword.take([:command, :permission_mode, :allowed_tools, :max_turns, :model, :max_budget_usd, :cmux_visibility])
      |> Map.new()

    @default_config
    |> Map.merge(config_from_schema)
    |> Map.merge(overrides)
  end

  defp ndjson_display_filter_path do
    path = Application.app_dir(:symphony_elixir, "priv/ndjson_display.py")

    if File.exists?(path) do
      path
    else
      # Fallback: try relative to the project root
      fallback = Path.join([File.cwd!(), "priv", "ndjson_display.py"])
      if File.exists?(fallback), do: fallback, else: nil
    end
  end

  defp issue_context(%{id: id, identifier: identifier}), do: "issue_id=#{id} issue=#{identifier}"
  defp issue_context(issue) when is_map(issue), do: "issue=#{inspect(Map.get(issue, :identifier, "unknown"))}"

  defp default_on_message(_message), do: :ok
end
