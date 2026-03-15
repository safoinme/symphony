# Symphony Fork: DevRel Brief

> Notes, bullet points, and technical details for creating a blog post about the Symphony Elixir fork enhancements.

---

## One-Line Summary

We forked OpenAI's Symphony orchestrator and built a **three-phase AI development pipeline** (Plan → Implement → Review) with **Claude Code as a first-class backend**, **cmux-based agent visibility**, and **harness engineering patterns** inspired by OpenAI's own internal practices.

---

## The Problem We Solved

OpenAI's Symphony is a great orchestrator — it polls Linear, dispatches agents to work on issues, manages workspaces. But out of the box:

- **One mode: "just run Codex"** — no separation between planning and implementation
- **Blind agents** — agents burn millions of tokens exploring codebases with no context map
- **Invisible execution** — agents run as headless subprocesses; you can't see what they're doing
- **No human checkpoints** — agents auto-transition issues, no gate for human review of plans
- **Codex-only** — no way to use Claude Code (or any other backend) alongside Codex
- **No plan persistence** — if an agent fails, all reasoning is lost

---

## What We Built

### 1. Three-Phase Pipeline: Plan → Implement → Review

Instead of throwing an agent at a ticket and hoping for the best, we split the work into phases mapped to Linear board states:

| Linear State | Action | What Happens |
|---|---|---|
| **Todo** | `plan` | Agent investigates the repo, produces `PLAN.md`, posts summary to Linear. Waits for human to approve. |
| **In Progress** | `agent` | Agent reads `PLAN.md` and implements. Multi-turn sessions with continuation context. |
| **In Review** | `review` | Agent reviews the diff, posts verdict. APPROVED → Done, Changes → feedback comment. |

**Key insight from OpenAI's "Harness Engineering" article:** Plans should be first-class artifacts, not ephemeral reasoning. Our `PLAN.md` persists in the workspace and feeds directly into implementation.

**The human gate:** When planning completes, the issue stays in "Todo". A human reviews the plan (posted as a Linear comment) and moves to "In Progress" when satisfied. This prevents agents from going off the rails on misunderstood requirements.

**The question/answer loop:** If the issue description is too vague, the planning agent asks questions (saved as `QUESTIONS.md`). Symphony detects new human replies on the Linear issue and re-dispatches planning with the answers as context.

### 2. Claude Code as a Backend

Symphony originally only supported Codex (OpenAI's agent). We added Claude Code as a pluggable backend:

```yaml
pipeline:
  state_actions:
    "todo":
      action: plan
      backend: claude_code    # Use Claude for planning
      max_turns: 5
    "in progress":
      action: agent
      backend: claude_code    # Use Claude for implementation
      max_turns: 20
```

**How it works:**
- Spawns `claude -p "<prompt>" --output-format stream-json` as a subprocess
- Parses NDJSON events in real-time (same event model as Codex but different wire format)
- Session continuity via `--resume <session_id>` — agent remembers across turns and retries
- Session ID persisted to `.symphony-session-id` in the workspace
- MCP tool access via `.mcp.json` in the workspace (Linear GraphQL, RepoPrompt, etc.)

**Backend abstraction:** Both Codex and Claude Code implement the same `AgentBackend` behaviour (`start_session`, `run_turn`, `stop_session`). The `DispatchRouter` picks the backend per state — you can even mix: Claude for planning, Codex for implementation.

### 3. cmux Visibility — Watch Your Agents Work

The biggest frustration with headless agents: you can't see what they're doing. Our solution: run agents in visible **cmux** (terminal multiplexer) tabs.

When `cmux_visibility: true`:
- Each dispatched agent gets its own **cmux workspace tab** (named "SES-5 In Progress", etc.)
- The Claude Code process runs visibly — you see NDJSON events streaming in real-time
- Output is simultaneously saved to `.symphony-output.ndjson` for Symphony to parse
- After the agent finishes, it signals completion via `cmux wait-for`
- If cmux isn't available, falls back to headless Port mode (zero config required)

**What this looks like in practice:** Your Symphony dashboard shows "Agents: 3/3" and you have three cmux tabs open, each showing a Claude Code agent working on a different issue. You can switch tabs to watch any agent in real-time.

### 4. RepoPrompt MCP Integration — Focused Context, Not Blind Exploration

Instead of letting agents `find . -name "*.ex"` their way through a codebase, we integrated **RepoPrompt** as an MCP server:

- The `repoprompt_cli` MCP server binary runs **standalone** (no desktop app needed)
- Configured in `.mcp.json` alongside Linear GraphQL
- Planning agents are **instructed to use `context_builder`** as their first step
- `context_builder` auto-selects relevant files and builds a codemap — focused context, not a full repo dump
- Also provides `get_code_structure` (function signatures), `file_search`, `get_file_tree`

**If CLAUDE.md doesn't exist** in the workspace, the `after_create` hook auto-generates a minimal one from the repo tree via `rp-cli`. Claude Code reads `CLAUDE.md` natively.

### 5. Dispatch Router — Clean State-to-Action Routing

A pure-function router that maps issue states to actions:

```elixir
DispatchRouter.route(%Issue{state: "Todo"})
# → {:plan, SymphonyElixir.AgentBackend.ClaudeCode, [max_turns: 5]}

DispatchRouter.route(%Issue{state: "In Progress"})
# → {:agent, SymphonyElixir.AgentBackend.ClaudeCode, [max_turns: 20]}
```

Config-driven, no code changes needed to add new states or swap backends. Supports: `agent`, `plan`, `review`, `gate` (manual), `transition` (auto).

### 6. Prompt Engineering — Lessons from OpenAI's WORKFLOW.md

We studied OpenAI's own Symphony workflow prompt (~330 lines of structured agent instructions) and adopted key patterns:

- **Workpad pattern:** Single persistent Linear comment (`## Workpad`) for progress tracking — plan checklist, acceptance criteria, validation results. Updated in-place throughout execution.
- **Continuation context:** Retry attempts know they're retries: "This is retry attempt #N. Resume from current workspace state."
- **Plan handoff:** Implementation prompt includes `{{ implementation_plan }}` — the full PLAN.md content, so the agent follows the plan instead of re-investigating.
- **Structured instructions:** Clear unattended-mode rules: never ask humans for follow-up, only stop for true blockers, update workpad as you go.

### 7. Smart Dispatch Guards — No Infinite Loops

A subtle but critical fix: preventing re-dispatch of already-handled issues.

**Planning guard:** Before dispatching a planning run, the orchestrator checks:
- `PLAN.md` exists? → Skip, planning is complete. Wait for human to move to "In Progress".
- `QUESTIONS.md` exists but no `PLAN.md`? → Check for new human replies on Linear.
  - No new replies → Skip, waiting for human answers.
  - New replies found → Re-dispatch planning with human feedback as context.

**Agent state-change detection:** When the agent moves an issue (e.g., from "In Progress" to "In Review" via the Linear MCP tool), the multi-turn loop detects the state change and stops — instead of continuing to run turns on an issue that's already moved to a different phase.

---

## Architecture Diagram

```
                    ┌─────────────────────┐
                    │   Linear Board      │
                    │                     │
                    │  Backlog → Todo     │
                    │  Todo → In Progress │
                    │  In Progress → ...  │
                    └────────┬────────────┘
                             │ polls
                    ┌────────▼────────────┐
                    │    Orchestrator      │
                    │  (GenServer loop)    │
                    └────────┬────────────┘
                             │ routes
                    ┌────────▼────────────┐
                    │   DispatchRouter    │
                    │  (pure function)    │
                    └────────┬────────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
     ┌────────▼───┐  ┌──────▼─────┐  ┌─────▼──────┐
     │  Planning   │  │   Agent    │  │   Review   │
     │  Runner     │  │   Runner   │  │   Runner   │
     └────────┬───┘  └──────┬─────┘  └─────┬──────┘
              │              │              │
              └──────────────┼──────────────┘
                             │
                    ┌────────▼────────────┐
                    │   AgentBackend      │
                    │   (behaviour)       │
                    ├─────────┬───────────┤
                    │  Codex  │ ClaudeCode│
                    └─────────┴───────────┘
                                    │
                         ┌──────────┼──────────┐
                         │ Port     │ cmux     │
                         │ (hidden) │ (visible)│
                         └──────────┴──────────┘
```

---

## By the Numbers

| Metric | Value |
|---|---|
| New Elixir modules | 7 (PlanningRunner, ReviewRunner, DispatchRouter, Cmux, ClaudeCode backend, NdjsonParser, AgentBackend behaviour) |
| Lines added | ~4,000+ |
| Test coverage | 308 tests, 0 failures |
| Config schema fields added | 8 (cmux_visibility, pipeline state_actions, claude_code block) |
| Supported backends | 2 (Codex, Claude Code) |
| Pipeline phases | 3 (Plan, Implement, Review) |
| MCP integrations | 2 (Linear GraphQL, RepoPrompt) |

---

## Inspiration & References

- **[Unlocking the Codex Harness](https://openai.com/index/unlocking-the-codex-harness/)** — The Codex App Server architecture (JSON-RPC, threads, turns, sandboxing)
- **[Harness Engineering](https://openai.com/index/harness-engineering/)** — OpenAI's internal methodology: AGENTS.md as table of contents, plans as first-class artifacts, mechanical enforcement
- **[Unrolling the Codex Agent Loop](https://openai.com/index/unrolling-the-codex-agent-loop/)** — The agent turn execution model
- **[Codex App Server Docs](https://developers.openai.com/codex/app-server/)** — Full protocol specification

---

## Suggested Blog Post Angles

1. **"We Replaced Codex with Claude Code in OpenAI's Symphony — Here's What Happened"** — The backend abstraction story, comparing Codex and Claude Code as agent backends
2. **"Planning Before Coding: How We Added a Human Gate to AI Agent Pipelines"** — The three-phase pipeline, PLAN.md as artifact, question/answer loop
3. **"Making AI Agents Visible: cmux Integration for Agent Observability"** — The cmux visibility feature, watching agents work in real-time
4. **"Harness Engineering in Practice: Applying OpenAI's Patterns to Our Own Workflow"** — Adopting AGENTS.md/CLAUDE.md, workpad pattern, structured prompts
5. **"From Blind Exploration to Focused Context: RepoPrompt MCP for AI Agents"** — How context_builder prevents token waste

---

## Key Quotes / Talking Points

- "The agent doesn't explore blindly anymore. It calls `context_builder` first, gets a focused codemap, then plans."
- "When the plan is done, the issue stays in Todo. A human reviews it in Linear and moves to In Progress. That's the gate."
- "Every agent gets its own cmux tab. You can watch three agents working on three different issues simultaneously."
- "Session continuity means if an agent fails on turn 5, turn 6 picks up where it left off — same conversation, same context."
- "We studied OpenAI's own 330-line WORKFLOW.md prompt and adopted their best patterns: workpad comments, continuation context, structured planning before implementation."
