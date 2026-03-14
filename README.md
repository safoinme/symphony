# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## What's New: Claude Code Backend + cmux Visibility

This fork extends the upstream Symphony with a **Claude Code agent backend** and deep **cmux terminal integration**, adding a full Kanban pipeline (Plan → Implement → Review) with live observability.

### Claude Code as a first-class agent backend

Symphony's original implementation targets OpenAI Codex in App Server mode. This fork adds `AgentBackend.ClaudeCode`, which spawns `claude -p` as a subprocess with full NDJSON streaming. Key differences from the Codex backend:

- **Per-turn subprocess model** — Claude Code exits after each invocation; session continuity via `--resume <id>`
- **PTY requirement** — Claude Code requires a TTY for `--output-format stream-json`; the backend wraps headless Ports with `script -q /dev/null` to allocate a pseudo-TTY
- **MCP tool access** — tools are provided through `.mcp.json` in the workspace, not client-side injection
- **cmux visibility** — when enabled, agents run in visible cmux terminal tabs instead of headless Erlang Ports

### Pipeline state actions

Issues flow through a configurable Kanban pipeline where each state triggers a different action:

| State | Action | What happens |
|-------|--------|-------------|
| **Todo** | `plan` | Agent explores the repo, produces a structured `PLAN.md`, posts summary to Linear |
| **In Progress** | `agent` | Agent implements the plan with multi-turn execution |
| **In Review** | `review` | Agent reviews the diff, auto-transitions based on verdict |

Each action can independently specify its backend (`codex` or `claude_code`), model, and turn limits.

### cmux integration

When `cmux_visibility: true` is set in `WORKFLOW.md`:

- Each agent spawns in a **named cmux workspace** with a human-readable display filter
- The orchestrator **streams events in real-time** by polling the output file (1s interval)
- The dashboard exposes a **`cmux select-workspace <ref>`** command to attach to any running agent
- Workspaces **auto-close** after the agent completes

The display filter (`priv/ndjson_display.py`) replaces raw NDJSON with readable output:

```
  session f31137de-827  model=claude-sonnet-4-6  mcp=5/9
  ⚙ Agent: Explore codebase structure
  → Running Find all documentation files
  ⚙ Read: docs/README.md
  → Reading backend/pyproject.toml
  ...
  ✓ Done in 123s ($0.46)
```

### Real-time observability dashboard

The web dashboard at `http://127.0.0.1:4000` shows:

- **Token usage** — input/output/total tokens per agent and globally
- **Session tracking** — Claude Code session IDs with copy button
- **Live event stream** — last tool use, timestamps, turn counts
- **Retry queue** — backoff status for failed/stalled agents

### Key implementation details

| Component | What it does |
|-----------|-------------|
| `AgentBackend.ClaudeCode` | Spawns `claude -p`, streams NDJSON, handles PTY/cmux modes |
| `NdjsonParser` | Stateful line accumulator that maps Claude Code events to Symphony atoms |
| `DispatchRouter` | Routes issues to plan/agent/review/gate based on `pipeline.state_actions` |
| `PlanningRunner` | Single planning turn → saves `PLAN.md` → posts summary to Linear |
| `ReviewRunner` | Reviews diff → auto-transitions on APPROVED/CHANGES_REQUESTED |
| `Cmux` | Workspace lifecycle: create, rename, close, signal, select |
| `ndjson_display.py` | Unbuffered NDJSON tee + human-readable terminal filter |

---

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use the Elixir reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation.

### Option 3. Use this fork with Claude Code + cmux

1. Install [cmux](https://cmux.com) and ensure `claude` CLI is on your PATH
2. Copy `elixir/WORKFLOW.e2e.md` to your repo as `WORKFLOW.md`
3. Configure `workspace.projects` to map your Linear projects to local repos
4. Set `LINEAR_API_KEY` and run:

```bash
cd elixir && mise exec -- ./bin/symphony start --workflow path/to/WORKFLOW.md
```

The orchestrator will poll Linear, dispatch agents in cmux workspaces, and stream progress to the dashboard at `http://127.0.0.1:4000`.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
