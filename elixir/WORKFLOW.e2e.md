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
      max_turns: 5
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

You are working on a Linear issue.

Identifier: {{ issue.identifier }}
Title: {{ issue.title }}

Body:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

## Instructions

1. Read the issue carefully and understand the requirements.
2. Explore the codebase to understand the existing architecture.
3. Implement the changes following existing patterns and conventions.
4. Write tests for your changes.
5. When done, use the `linear_graphql` tool to:
   - Post a comment summarizing what you did
   - Move the issue to "In Review" state

## Guidelines

- Follow existing code style and patterns
- Keep changes minimal and focused
- Write clear commit messages
- Do not modify files unrelated to the issue
