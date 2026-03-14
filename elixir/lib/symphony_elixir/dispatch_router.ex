defmodule SymphonyElixir.DispatchRouter do
  @moduledoc """
  Pure function module that routes issues to the appropriate runner
  based on their Kanban state's configured action.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  @type route_result ::
          {:agent, module(), keyword()}
          | :gate
          | {:plan, module(), keyword()}
          | {:review, module(), keyword()}
          | :skip

  @spec route(Issue.t()) :: route_result()
  def route(%Issue{state: state}) do
    case Config.state_action(state) do
      nil ->
        {:agent, Config.agent_backend_module(), []}

      %{"action" => "agent"} = config ->
        {:agent, backend_module(config), backend_opts(config)}

      %{"action" => "plan"} = config ->
        {:plan, backend_module(config), backend_opts(config)}

      %{"action" => "gate"} ->
        :gate

      %{"action" => "review"} = config ->
        {:review, backend_module(config), backend_opts(config)}

      %{"action" => "transition"} ->
        :skip

      _ ->
        {:agent, Config.agent_backend_module(), []}
    end
  end

  defp backend_module(%{"backend" => backend}) do
    Config.agent_backend_module(backend)
  end

  defp backend_module(_config) do
    Config.agent_backend_module()
  end

  defp backend_opts(config) do
    []
    |> maybe_put(:max_turns, Map.get(config, "max_turns"))
    |> maybe_put(:model, Map.get(config, "model"))
  end

  defp maybe_put(opts, :max_turns, turns) when is_integer(turns) and turns > 0,
    do: Keyword.put(opts, :max_turns, turns)

  defp maybe_put(opts, :model, model) when is_binary(model) and model != "",
    do: Keyword.put(opts, :model, model)

  defp maybe_put(opts, _key, _value), do: opts
end
