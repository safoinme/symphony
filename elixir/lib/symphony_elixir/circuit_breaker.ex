defmodule SymphonyElixir.CircuitBreaker do
  @moduledoc """
  Tracks failures per backend provider using an Agent.
  States: :closed → :open (after threshold failures) → :half_open (after cooldown) → :closed (on success).
  """

  use Agent

  @default_failure_threshold 5
  @default_reset_timeout_ms 60_000

  @type state :: :closed | :open | :half_open
  @type provider :: atom()

  defmodule ProviderState do
    @moduledoc false
    @default_failure_threshold 5
    @default_reset_timeout_ms 60_000

    defstruct [
      :state,
      :last_failure_at,
      failure_count: 0,
      failure_threshold: @default_failure_threshold,
      reset_timeout_ms: @default_reset_timeout_ms
    ]
  end

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{} end, name: name)
  end

  @spec check(provider(), GenServer.server()) :: :ok | {:error, :circuit_open}
  def check(provider, server \\ __MODULE__) do
    Agent.get(server, fn providers ->
      case Map.get(providers, provider) do
        %ProviderState{state: :open} = ps ->
          if cooldown_elapsed?(ps), do: :ok, else: {:error, :circuit_open}

        _ ->
          :ok
      end
    end)
  end

  @spec record_failure(provider(), GenServer.server()) :: :ok
  def record_failure(provider, server \\ __MODULE__) do
    Agent.update(server, fn providers ->
      ps = Map.get(providers, provider, new_provider_state())
      now = System.monotonic_time(:millisecond)

      updated =
        %{ps | failure_count: ps.failure_count + 1, last_failure_at: now}
        |> maybe_open_circuit()

      Map.put(providers, provider, updated)
    end)
  end

  @spec record_success(provider(), GenServer.server()) :: :ok
  def record_success(provider, server \\ __MODULE__) do
    Agent.update(server, fn providers ->
      case Map.get(providers, provider) do
        nil ->
          providers

        %ProviderState{state: :closed, failure_count: 0} ->
          providers

        _ps ->
          Map.put(providers, provider, new_provider_state())
      end
    end)
  end

  @spec get_state(provider(), GenServer.server()) :: state()
  def get_state(provider, server \\ __MODULE__) do
    Agent.get(server, fn providers ->
      case Map.get(providers, provider) do
        nil -> :closed
        %ProviderState{state: :open} = ps -> if cooldown_elapsed?(ps), do: :half_open, else: :open
        %ProviderState{state: state} -> state
      end
    end)
  end

  @spec reset(provider(), GenServer.server()) :: :ok
  def reset(provider, server \\ __MODULE__) do
    Agent.update(server, fn providers ->
      Map.delete(providers, provider)
    end)
  end

  # --- Private ---

  defp new_provider_state do
    %ProviderState{
      state: :closed,
      failure_count: 0,
      last_failure_at: nil,
      failure_threshold: @default_failure_threshold,
      reset_timeout_ms: @default_reset_timeout_ms
    }
  end

  defp maybe_open_circuit(%ProviderState{failure_count: count, failure_threshold: threshold} = ps)
       when count >= threshold do
    %{ps | state: :open}
  end

  defp maybe_open_circuit(ps), do: ps

  defp cooldown_elapsed?(%ProviderState{last_failure_at: nil}), do: true

  defp cooldown_elapsed?(%ProviderState{last_failure_at: last, reset_timeout_ms: timeout}) do
    now = System.monotonic_time(:millisecond)
    now - last >= timeout
  end
end
