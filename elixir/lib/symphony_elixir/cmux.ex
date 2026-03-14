defmodule SymphonyElixir.Cmux do
  @moduledoc """
  Thin wrapper around the cmux CLI for programmatic workspace/pane management.
  Enables running agent processes in visible cmux tabs for observability.
  """

  require Logger

  @cmux_timeout_ms 5_000

  @spec available?() :: boolean()
  def available? do
    case System.find_executable("cmux") do
      nil -> false
      _path -> ping?()
    end
  end

  @spec new_workspace(String.t()) :: {:ok, String.t()} | {:error, term()}
  def new_workspace(command) do
    case run_cmux(["new-workspace", "--command", command]) do
      {:ok, output} ->
        case parse_workspace_ref(output) do
          {:ok, ref} -> {:ok, ref}
          :error -> {:ok, String.trim(output)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec wait_for(String.t(), non_neg_integer()) :: :ok | {:error, :timeout | term()}
  def wait_for(signal_name, timeout_seconds) do
    args = ["wait-for", signal_name, "--timeout", to_string(timeout_seconds)]

    case System.cmd("cmux", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, :timeout}
    end
  end

  @spec close_workspace(String.t()) :: :ok | {:error, term()}
  def close_workspace(ref) when is_binary(ref) and ref != "" do
    case run_cmux(["close-workspace", "--workspace", ref]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def close_workspace(_ref), do: :ok

  @spec select_workspace(String.t()) :: :ok | {:error, term()}
  def select_workspace(ref) when is_binary(ref) do
    case run_cmux(["select-workspace", "--workspace", ref]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec rename_workspace(String.t(), String.t()) :: :ok | {:error, term()}
  def rename_workspace(ref, title) when is_binary(ref) and is_binary(title) do
    case run_cmux(["rename-workspace", "--workspace", ref, title]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec capture_pane(keyword()) :: {:ok, String.t()} | {:error, term()}
  def capture_pane(opts \\ []) do
    args =
      ["capture-pane"]
      |> maybe_add("--workspace", Keyword.get(opts, :workspace))
      |> maybe_add("--surface", Keyword.get(opts, :surface))
      |> maybe_add_flag("--scrollback", Keyword.get(opts, :scrollback, false))
      |> maybe_add("--lines", Keyword.get(opts, :lines))

    run_cmux(args)
  end

  # --- Private ---

  defp ping? do
    case System.cmd("cmux", ["ping"], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp run_cmux(args) do
    task =
      Task.async(fn ->
        System.cmd("cmux", args, stderr_to_stdout: true)
      end)

    case Task.yield(task, @cmux_timeout_ms) do
      {:ok, {output, 0}} ->
        {:ok, output}

      {:ok, {output, status}} ->
        {:error, {:cmux_error, status, output}}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :cmux_timeout}
    end
  end

  defp parse_workspace_ref(output) do
    trimmed = String.trim(output)

    cond do
      # Match "workspace:N" format
      match?([_], Regex.run(~r/workspace:\d+/, trimmed)) ->
        [ref] = Regex.run(~r/workspace:\d+/, trimmed)
        {:ok, ref}

      # Match "OK <UUID>" format from new-workspace
      match?([_, _], Regex.run(~r/^OK\s+([0-9A-Fa-f-]{36})/, trimmed)) ->
        [_, uuid] = Regex.run(~r/^OK\s+([0-9A-Fa-f-]{36})/, trimmed)
        {:ok, uuid}

      true ->
        :error
    end
  end

  defp maybe_add(args, _flag, nil), do: args
  defp maybe_add(args, flag, value), do: args ++ [flag, to_string(value)]

  defp maybe_add_flag(args, _flag, false), do: args
  defp maybe_add_flag(args, flag, true), do: args ++ [flag]
end
