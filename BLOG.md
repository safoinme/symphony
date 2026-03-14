# I Made Claude Code Work Inside Symphony's Agent Orchestrator — Here's What Broke (and How I Fixed It)

**TL;DR:** I extended OpenAI's Symphony orchestrator to use Claude Code as an agent backend with live terminal visibility via cmux. It took debugging 6 cascading failures — from a missing `--json` flag to discovering that Claude Code produces zero output without a TTY. The result: a Kanban pipeline where Linear issues automatically get planned, implemented, and reviewed by AI agents you can watch in real-time.

---

## The starting point

[Symphony](https://github.com/openai/symphony) is OpenAI's open-source orchestrator that polls Linear for issues and dispatches coding agents to work on them. The reference implementation is in Elixir/OTP and targets Codex in App Server mode.

I wanted to swap in **Claude Code** as the agent backend and add **cmux** (the terminal multiplexer that ships with Claude Code) for live visibility into what agents are doing. The idea: issues move through a Kanban pipeline — **Todo** (planning) → **In Progress** (implementation) → **In Review** (code review) — with each stage backed by a Claude Code agent running in a visible terminal tab.

<!-- [IMAGE: Screenshot of the Linear Kanban board showing an issue in Todo state with the Symphony orchestrator running] -->

Simple enough, right?

## Failure #1: The agent never starts

First sign something was wrong: the dashboard showed an issue claimed for 3+ minutes with zero tokens, no session, and "no codex message yet."

<!-- [IMAGE: Screenshot of the Symphony dashboard showing SES-5 stuck in Todo with 0 tokens and n/a session] -->

The orchestrator had dispatched the issue. The task process was alive. But nothing was happening.

**Diagnosis:** I checked the logs and found:

```
cmux workspace creation failed, falling back to Port:
  {:cmux_error, 1, "Error: new-workspace: unknown flag '--json'. Known flags: --command <text>"}
```

The `Cmux.new_workspace` function was passing `--json` to get structured output. That flag doesn't exist. Every cmux workspace creation attempt failed, silently falling back to Erlang Port mode.

**Fix:** Remove the invalid flag. One line.

## Failure #2: Port mode produces zero output

OK, so the fallback to Port mode should work. Claude Code runs as a subprocess, stdout piped through the Erlang Port. But after 5 minutes of nothing, the stall detector killed the agent and restarted it. Same result. An infinite loop of silence.

I tested manually:

```elixir
# From an Erlang Port — ZERO output after 15 seconds
port = Port.open({:spawn_executable, claude_path}, [:binary, :exit_status, ...])
receive do
  {^port, {:data, data}} -> IO.puts("GOT DATA")
after
  15_000 -> IO.puts("TIMEOUT: no data")
end
# => TIMEOUT: no data
```

Then from a terminal:

```bash
# From a terminal — instant output
claude -p "say hello" --output-format stream-json | head -3
# => {"type":"system","subtype":"init",...}
```

**Root cause:** Claude Code requires a TTY to produce `--output-format stream-json` output. When stdout is a pipe (as in an Erlang Port), it produces literally nothing. No error, no warning — just silence.

**Fix:** Wrap the Port with `script -q /dev/null` to allocate a pseudo-TTY:

```elixir
Port.open(
  {:spawn_executable, script_path},
  [:binary, :exit_status, :stderr_to_stdout,
   args: ["-q", "/dev/null", "/bin/sh", "-c", cli_args_str],
   cd: workspace]
)
```

Verified: data flows immediately through the PTY wrapper.

## Failure #3: cmux works, but the file is empty

With the `--json` flag fixed, cmux workspace creation succeeded. The agent ran beautifully in a visible cmux tab — I could see the full NDJSON stream scrolling past. But the orchestrator still showed zero events.

The streaming code reads from an output file that `tee` writes to:

```bash
claude ... --output-format stream-json 2>&1 | tee output.ndjson
```

The file was 3,889 bytes — only the `session_init` event. The agent had produced 200+ events visible in the terminal, but `tee` had buffered the file writes.

**Root cause:** macOS `tee` uses full buffering for file output. The streaming parser read the file every second, saw nothing new, and the stall detector killed the agent after 5 minutes.

**Fix:** Replace `tee` with an unbuffered Python display filter:

```python
with open(output_path, "ab", buffering=0) as out_file:
    for raw_line in sys.stdin.buffer:
        out_file.write(raw_line)  # unbuffered write
        display_event(json.loads(raw_line))  # human-readable terminal output
```

This solved two problems at once: unbuffered file writes for the streaming parser, and human-readable output in the cmux tab instead of raw NDJSON.

<!-- [IMAGE: Screenshot of the cmux terminal showing the readable display filter output with tool names, progress indicators, and the "Done in 123s ($0.46)" completion message] -->

## Failure #4: Session ID and tokens show as n/a and 0

Events were finally streaming to the orchestrator! The dashboard showed "session started" in the event column. But the SESSION field showed `n/a` and tokens showed `0`.

**Root cause:** The orchestrator's `session_id_for_update` and `extract_token_usage` functions were written for the Codex backend, which sends flat update maps with `session_id` at the top level. Claude Code's NDJSON events nest everything inside a `payload` map:

```elixir
# Codex: %{session_id: "abc", ...}
# Claude Code: %{event: :session_init, payload: %{"session_id" => "abc", ...}}
```

**Fix:** Add payload-aware extraction:

```elixir
defp session_id_for_update(existing, %{payload: payload}) when is_map(payload) do
  case payload["session_id"] || payload["sessionId"] do
    id when is_binary(id) and id != "" -> id
    _ -> existing
  end
end
```

Same pattern for token extraction — added `get_in(update, [:payload, "usage"])` to the search paths.

## Failure #5: The streaming loop never exits

The agent completed ("Done in 123s" in the cmux tab). But the dashboard showed the task running for 3+ minutes and climbing. PLAN.md was never saved.

I had built a safety-net idle timeout: if we see a result event and no new data for 15 seconds, exit the loop. But it wasn't firing.

**Root cause:** Claude Code exited with `error_max_turns` (the agent hit the 5-turn limit). The NdjsonParser mapped this to `:turn_result` — but `maybe_update_result` only handled `:turn_completed` (for `success`) and `:turn_error` (for `error`). The `:turn_result` catch-all returned `nil`, so `last_result` was never set, and the idle timeout's `has_result` check was always false.

```elixir
# Before: only success and error handled
defp maybe_update_result(:turn_completed, payload), do: {:completed, payload}
defp maybe_update_result(:turn_error, payload), do: {:error, payload}
defp maybe_update_result(_event_type, _payload), do: nil  # :turn_result falls here!
```

**Fix:** Any result event means the turn is done:

```elixir
defp maybe_update_result(:turn_completed, payload), do: {:completed, payload}
defp maybe_update_result(:turn_result, payload), do: {:completed, payload}
defp maybe_update_result(:turn_error, payload), do: {:error, payload}
```

## Failure #6: Workspaces pile up

Every restart created a new cmux workspace. Old ones never closed because `Cmux.new_workspace` returns `"OK <UUID>"` but the workspace ref parser only matched `workspace:\d+`. The UUID was returned as `"OK 16F22B41-..."` — which cmux rejected for `close-workspace`.

**Fix:** Parse UUIDs from the "OK" response:

```elixir
# Match "OK <UUID>" format from new-workspace
match?([_, _], Regex.run(~r/^OK\s+([0-9A-Fa-f-]{36})/, trimmed)) ->
  [_, uuid] = Regex.run(~r/^OK\s+([0-9A-Fa-f-]{36})/, trimmed)
  {:ok, uuid}
```

## The result

After fixing all 6 issues, the full pipeline works:

<!-- [IMAGE: Screenshot of the Symphony dashboard showing SES-5 with session ID, 106,699 tokens, and the operations dashboard with token counts] -->

1. **Linear issue in Todo** → Symphony dispatches a planning agent
2. **Claude Code runs in a cmux workspace** with human-readable output
3. **Events stream in real-time** to the orchestrator dashboard (tokens, session, tool use)
4. **PLAN.md is saved** to the workspace and a summary is posted as a Linear comment
5. **Workspace auto-closes** after completion
6. **Dashboard shows an attach command** (`cmux select-workspace <ref>`) to jump into any running agent

<!-- [IMAGE: Screenshot of the Linear issue showing the "Planning Complete" comment with the plan summary and "Full plan saved to" path] -->

### What the cmux tab looks like

Instead of raw NDJSON:

```json
{"type":"system","subtype":"task_progress","task_id":"a7f4d5bb...","tool_use_id":"toolu_01R6...
```

You get:

```
  session f31137de-827  model=claude-sonnet-4-6  mcp=5/9
  ⚙ Agent: Explore codebase structure
  → Running Find all documentation files
  ⚙ Read: docs/README.md
  → Reading backend/pyproject.toml
  ✓ Done in 123s ($0.46)
```

## Architecture overview

```
Linear Board                    Symphony Orchestrator
┌──────────┐    poll/5s    ┌─────────────────────────┐
│ Todo     │◄──────────────│ Orchestrator (GenServer) │
│ SES-5    │               │  ├─ DispatchRouter       │
└──────────┘               │  ├─ PlanningRunner       │
                           │  ├─ AgentRunner          │
                           │  └─ ReviewRunner         │
                           └──────────┬──────────────┘
                                      │ spawn
                           ┌──────────▼──────────────┐
                           │ ClaudeCode Backend       │
                           │  ├─ cmux workspace       │──► visible terminal tab
                           │  ├─ NDJSON streaming     │──► orchestrator events
                           │  └─ PTY wrapper (Port)   │──► fallback mode
                           └──────────┬──────────────┘
                                      │ result
                           ┌──────────▼──────────────┐
                           │ Post-processing          │
                           │  ├─ Save PLAN.md         │
                           │  ├─ Post to Linear       │
                           │  └─ Close workspace      │
                           └─────────────────────────┘
```

## Lessons learned

**1. Always check the actual bytes on disk.** The cmux tab showed output. The dashboard showed events. But the file `tee` was writing to was nearly empty. Three different views of "the same data" told three different stories.

**2. TTY requirements are invisible.** Claude Code produces zero output — no error, no warning — when stdout isn't a terminal. This is a reasonable default for a CLI tool, but it creates a silent failure mode when running as a subprocess.

**3. Pattern matching edge cases compound.** The NdjsonParser correctly mapped 3 result subtypes. But `error_max_turns` was a 4th that fell through to a catch-all, which had no handler in the result processing chain. Each layer was individually correct but the composition had a gap.

**4. Buffering is the silent killer of streaming architectures.** macOS `tee` buffering, Claude Code TTY detection, and cmux signal delivery are all independently reasonable behaviors that combine into "nothing works."

**5. Safety nets need to cover all exit paths.** The idle timeout was a good idea but only checked for `{:completed, _}` results. A single missing pattern match kept it from ever firing.

## Try it yourself

The fork is at [github.com/safoinme/symphony](https://github.com/safoinme/symphony). You need:

- Elixir/Erlang (via mise)
- Claude Code CLI (`claude` on PATH)
- cmux (optional, for visible workspaces)
- A Linear API key

```bash
git clone https://github.com/safoinme/symphony
cd symphony/elixir
cp WORKFLOW.e2e.md ../your-repo/WORKFLOW.md
# Edit WORKFLOW.md: set your Linear project slug and workspace paths
LINEAR_API_KEY=lin_api_... mise exec -- ./bin/symphony start --workflow path/to/WORKFLOW.md
```

---

*Built during a single debugging session with Claude Code. The irony of using Claude to debug its own integration into an orchestrator was not lost on me.*
