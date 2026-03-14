---
tracker:
  kind: memory

polling:
  interval_ms: 5000

workspace:
  root: /tmp/symphony-local-test

hooks:
  after_create: |
    git init
    git commit --allow-empty -m "init"

agent:
  max_concurrent_agents: 1
  max_turns: 3

pipeline:
  default_backend: codex
  state_actions:
    "planning":
      action: plan
      backend: claude_code
      max_turns: 3
    "human review":
      action: gate
    "in progress":
      action: agent
      max_turns: 5
    "in review":
      action: review
      backend: claude_code
      max_turns: 2

codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write

claude_code:
  command: claude
  permission_mode: bypassPermissions
  max_budget_usd: 1.00
  model: claude-sonnet-4-20250514
---

You are working on a test issue.

Identifier: {{ issue.identifier }}
Title: {{ issue.title }}

{{ issue.description }}

Keep your changes minimal. This is a test run.
