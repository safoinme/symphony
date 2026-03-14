defmodule SymphonyElixir.AgentBackend.ClaudeCode.NdjsonParser do
  @moduledoc """
  Stateful line accumulator for NDJSON streamed from a Claude Code Port.

  Port output may arrive as partial lines. This module accumulates bytes until
  a newline boundary is found, then decodes each complete JSON line and maps
  Claude Code event types to Symphony event atoms.
  """

  @type t :: %__MODULE__{buffer: binary()}
  defstruct buffer: ""

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Feed raw binary data from the Port into the parser.

  Returns `{complete_events, updated_parser}` where `complete_events` is a
  list of `{event_atom, decoded_map}` tuples for each complete NDJSON line.
  """
  @spec feed(t(), binary()) :: {[{atom(), map()}], t()}
  def feed(%__MODULE__{buffer: buffer} = parser, data) when is_binary(data) do
    combined = buffer <> data
    {lines, remainder} = split_lines(combined)

    events =
      lines
      |> Enum.map(&decode_line/1)
      |> Enum.reject(&is_nil/1)

    {events, %{parser | buffer: remainder}}
  end

  @doc """
  Flush any remaining buffered data as a final event (if valid JSON).
  """
  @spec flush(t()) :: {[{atom(), map()}], t()}
  def flush(%__MODULE__{buffer: ""} = parser), do: {[], parser}

  def flush(%__MODULE__{buffer: buffer} = parser) do
    case decode_line(buffer) do
      nil -> {[], %{parser | buffer: ""}}
      event -> {[event], %{parser | buffer: ""}}
    end
  end

  # --- Private ---

  defp split_lines(data) do
    case :binary.split(data, "\n", [:global]) do
      [] -> {[], ""}
      parts -> {Enum.slice(parts, 0..-2//1), List.last(parts)}
    end
  end

  defp decode_line(line) do
    trimmed = String.trim(line)

    if trimmed == "" do
      nil
    else
      case Jason.decode(trimmed) do
        {:ok, decoded} -> {map_event_type(decoded), decoded}
        {:error, _} -> {:malformed, %{"raw" => trimmed}}
      end
    end
  end

  @doc """
  Map a decoded Claude Code JSON event to a Symphony event atom.
  """
  @spec map_event_type(map()) :: atom()
  def map_event_type(%{"type" => "system", "subtype" => "init"}), do: :session_init
  def map_event_type(%{"type" => "system"}), do: :system
  def map_event_type(%{"type" => "assistant", "message" => %{"content" => content}})
      when is_list(content) do
    if Enum.any?(content, &(&1["type"] == "tool_use")),
      do: :tool_use,
      else: :assistant_message
  end
  def map_event_type(%{"type" => "assistant"}), do: :assistant_message
  def map_event_type(%{"type" => "user"}), do: :user_message
  def map_event_type(%{"type" => "result", "subtype" => "success"}), do: :turn_completed
  def map_event_type(%{"type" => "result", "subtype" => "error"}), do: :turn_error
  def map_event_type(%{"type" => "result"}), do: :turn_result
  def map_event_type(%{"type" => type}) when is_binary(type), do: String.to_atom(type)
  def map_event_type(_), do: :unknown
end
