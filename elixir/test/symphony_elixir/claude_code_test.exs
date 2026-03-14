defmodule SymphonyElixir.AgentBackend.ClaudeCodeTest do
  use ExUnit.Case

  alias SymphonyElixir.AgentBackend.ClaudeCode
  alias SymphonyElixir.AgentBackend.ClaudeCode.NdjsonParser

  describe "ClaudeCode backend" do
    test "implements AgentBackend behaviour" do
      behaviours =
        ClaudeCode.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert SymphonyElixir.AgentBackend in behaviours
    end

    test "start_session returns session struct" do
      assert {:ok, session} = ClaudeCode.start_session("/tmp/test-workspace", [])
      assert session.workspace == "/tmp/test-workspace"
      assert is_nil(session.session_id)
    end

    test "start_session accepts model override" do
      assert {:ok, session} = ClaudeCode.start_session("/tmp/test-workspace", model: "claude-opus-4-20250514")
      assert session.config.model == "claude-opus-4-20250514"
    end

    test "start_session uses default model when not overridden" do
      assert {:ok, session} = ClaudeCode.start_session("/tmp/test-workspace", [])
      assert session.config.model == "claude-sonnet-4-6"
    end

    test "stop_session is a no-op" do
      session = %ClaudeCode.Session{workspace: "/tmp/test"}
      assert :ok = ClaudeCode.stop_session(session)
    end

    test "supports_tool_injection? returns false" do
      refute ClaudeCode.supports_tool_injection?()
    end

    test "handle_tool_call returns error map" do
      session = %ClaudeCode.Session{workspace: "/tmp/test"}
      result = ClaudeCode.handle_tool_call(session, "some_tool", %{})
      assert result["success"] == false
      assert is_binary(result["output"])
    end
  end

  describe "NdjsonParser" do
    test "parses complete JSON line" do
      parser = NdjsonParser.new()

      {events, parser} =
        NdjsonParser.feed(
          parser,
          ~s|{"type":"system","subtype":"init","session_id":"abc123"}\n|
        )

      assert [{:session_init, decoded}] = events
      assert decoded["session_id"] == "abc123"
      assert parser.buffer == ""
    end

    test "handles partial lines across feeds" do
      parser = NdjsonParser.new()

      {events1, parser} = NdjsonParser.feed(parser, ~s|{"type":"sys|)
      assert events1 == []

      {events2, _parser} =
        NdjsonParser.feed(parser, ~s|tem","subtype":"init","session_id":"x"}\n|)

      assert [{:session_init, _}] = events2
    end

    test "parses multiple lines in single feed" do
      parser = NdjsonParser.new()

      input =
        ~s|{"type":"system","subtype":"init","session_id":"a"}\n{"type":"result","subtype":"success","result":"done"}\n|

      {events, _parser} = NdjsonParser.feed(parser, input)
      assert length(events) == 2
      assert {:session_init, _} = Enum.at(events, 0)
      assert {:turn_completed, _} = Enum.at(events, 1)
    end

    test "handles invalid JSON lines as malformed events" do
      parser = NdjsonParser.new()

      {events, _parser} =
        NdjsonParser.feed(
          parser,
          ~s|not valid json\n{"type":"system","subtype":"init","session_id":"ok"}\n|
        )

      assert [{:malformed, _}, {:session_init, _}] = events
    end

    test "maps system init event type" do
      assert :session_init =
               NdjsonParser.map_event_type(%{"type" => "system", "subtype" => "init"})
    end

    test "maps result success event type" do
      assert :turn_completed =
               NdjsonParser.map_event_type(%{"type" => "result", "subtype" => "success"})
    end

    test "maps result error event type" do
      assert :turn_error =
               NdjsonParser.map_event_type(%{"type" => "result", "subtype" => "error"})
    end

    test "maps assistant message with tool_use" do
      assert :tool_use =
               NdjsonParser.map_event_type(%{
                 "type" => "assistant",
                 "message" => %{
                   "content" => [%{"type" => "tool_use", "name" => "Read"}]
                 }
               })
    end

    test "maps plain assistant message" do
      assert :assistant_message = NdjsonParser.map_event_type(%{"type" => "assistant"})
    end

    test "flush returns remaining buffered data" do
      parser = NdjsonParser.new()
      {[], parser} = NdjsonParser.feed(parser, ~s|{"type":"system","subtype":"init"|)
      assert parser.buffer != ""

      {events, flushed} = NdjsonParser.flush(parser)
      # Incomplete JSON can't be decoded successfully
      assert [{:malformed, _}] = events
      assert flushed.buffer == ""
    end
  end
end
