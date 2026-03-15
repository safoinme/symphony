---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  active_states:
    - Todo
    - In Progress
    - In Review
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done

polling:
  interval_ms: 5000

workspace:
  root: ~/code/symphony-e2e-workspaces
  strategy: worktree
  projects:
    seshat:
      slug: seshat-79c886f2b3ae
      repo: ~/work/seshat
    symphony:
      slug: symphony-f49dcfaf7e6c
      repo: ~/work/symphony

hooks:
  after_create: |
    # Write MCP config so Claude Code can access Linear and RepoPrompt
    cat > .mcp.json << 'MCPEOF'
    {
      "mcpServers": {
        "linear_graphql": {
          "command": "node",
          "args": ["SYMPHONY_HOME/priv/mcp_bridge/linear_graphql_server.js"],
          "env": { "LINEAR_API_KEY": "LINEAR_API_KEY_VALUE" }
        },
        "RepoPrompt": {
          "command": "/Users/safoineelkhabich/RepoPrompt/repoprompt_cli",
          "args": []
        }
      }
    }
    MCPEOF
    # Patch in real values
    SYMPHONY_DIR="$(cd "$(dirname "$0")" && pwd)"
    sed -i '' "s|SYMPHONY_HOME|${SYMPHONY_DIR}|g" .mcp.json 2>/dev/null || true
    sed -i '' "s|LINEAR_API_KEY_VALUE|${LINEAR_API_KEY}|g" .mcp.json 2>/dev/null || true
    # Generate a minimal CLAUDE.md from repo tree if none exists
    if [ ! -f CLAUDE.md ] && [ ! -f .claude/CLAUDE.md ]; then
      rp-cli -e 'tree' > .repo-tree.txt 2>/dev/null || true
      if [ -f .repo-tree.txt ] && [ -s .repo-tree.txt ]; then
        {
          echo "# Repository Guide"
          echo ""
          echo "## File Structure"
          echo ""
          cat .repo-tree.txt
        } > CLAUDE.md
        rm .repo-tree.txt
      fi
    fi
  after_run: |
    echo "Turn completed for {{ issue.identifier }}"
  timeout_ms: 120000

agent:
  max_concurrent_agents: 3
  max_turns: 20
  max_retry_backoff_ms: 300000
  max_concurrent_agents_by_state:
    "Todo": 2
    "In Progress": 2
    "In Review": 1

pipeline:
  default_backend: codex
  state_actions:
    "todo":
      action: plan
      backend: claude_code
    "in progress":
      action: agent
      backend: claude_code
      max_turns: 20
    "in review":
      action: review
      backend: claude_code
      max_turns: 3

codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_timeout_ms: 900000
  read_timeout_ms: 5000
  stall_timeout_ms: 300000

claude_code:
  command: claude
  permission_mode: bypassPermissions
  allowed_tools:
    - Read
    - Write
    - Edit
    - Glob
    - Grep
    - Bash(git *)
    - Bash(make *)
    - Bash(npm *)
    - Bash(mix *)
  max_budget_usd: 5.00
  model: claude-sonnet-4-6
  cmux_visibility: true
---

You are working on Linear issue `{{ issue.identifier }}`: {{ issue.title }}

{% if attempt %}
## Continuation context

This is retry attempt #{{ attempt }}. The ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation.
- Do not end the turn while the issue remains active unless you are blocked.
{% endif %}

## Issue

Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}
{% if handoff_context %}

## Codebase Context (from planning phase)

The planning agent analyzed the codebase and produced the following context.
Use this to understand file relationships and patterns. Do not re-explore these files.

{{ handoff_context }}
{% endif %}
{% if implementation_plan %}

## Implementation Plan (follow this)

A planning agent has already investigated this issue and produced the following plan.
Follow this plan. Do not re-investigate what has already been analyzed.

{{ implementation_plan }}
{% endif %}

## Instructions

This is an unattended orchestration session. Never ask a human to perform follow-up actions.
Only stop early for a true blocker (missing required auth/permissions/secrets).

1. Start by reading CLAUDE.md (or AGENTS.md) if present — it's your map of the repo.
2. If a plan is provided above, follow it. Otherwise, spend effort up front on planning before implementation.
3. Create or update a single persistent Linear comment (`## Workpad`) to track progress:
   - Hierarchical plan with checkboxes
   - Acceptance criteria
   - Validation results
   - Keep it updated as you work
4. Implement the changes following existing patterns and conventions.
5. Write tests for your changes.
6. Run tests and validation before considering work complete.
7. Commit your changes with clear commit messages.
8. When done, update the workpad comment with final status, then use `linear_graphql` to move the issue to "In Review".

## Guidelines

- Follow existing code style and patterns
- Keep changes minimal and focused
- Do not modify files unrelated to the issue
- When out-of-scope improvements are found, note them in the workpad rather than expanding scope
- If blocked, record the blocker in the workpad with what human action is needed to unblock
