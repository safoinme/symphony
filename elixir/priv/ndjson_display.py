#!/usr/bin/env python3
"""
Unbuffered NDJSON tee with human-readable terminal display.

Reads Claude Code stream-json from stdin, writes raw NDJSON to an output
file (flushed per-line), and prints a human-readable summary to the terminal.

Usage:  claude ... --output-format stream-json 2>&1 | python3 ndjson_display.py output.ndjson
"""

import json
import os
import sys


def display_event(data: dict) -> None:
    t = data.get("type", "")
    st = data.get("subtype", "")

    if t == "system" and st == "init":
        sid = data.get("session_id", "")[:12]
        model = data.get("model", "")
        mcp = data.get("mcp_servers", [])
        connected = sum(1 for s in mcp if s.get("status") == "connected")
        total = len(mcp)
        print(f"\033[2m  session {sid}  model={model}  mcp={connected}/{total}\033[0m")

    elif t == "system" and st == "task_progress":
        desc = data.get("description", "")
        tool = data.get("last_tool_name", "")
        if desc:
            print(f"  \033[36m→ {desc}\033[0m")
        elif tool:
            print(f"  \033[36m→ {tool}\033[0m")

    elif t == "assistant":
        msg = data.get("message", {})
        for c in msg.get("content", []):
            ct = c.get("type", "")
            if ct == "text":
                txt = c.get("text", "").strip()
                if txt:
                    # Truncate very long text blocks for display
                    if len(txt) > 600:
                        txt = txt[:600] + "..."
                    print(txt)
            elif ct == "tool_use":
                name = c.get("name", "tool")
                desc = c.get("input", {}).get("description", "")
                prompt_text = c.get("input", {}).get("prompt", "")
                if desc:
                    print(f"  \033[33m⚙ {name}: {desc}\033[0m")
                elif prompt_text:
                    short = prompt_text[:80].replace("\n", " ")
                    print(f"  \033[33m⚙ {name}: {short}...\033[0m")
                else:
                    print(f"  \033[33m⚙ {name}\033[0m")

    elif t == "result":
        dur = data.get("duration_ms", 0) // 1000
        cost = data.get("total_cost_usd", 0)
        err = data.get("is_error", False)
        if err:
            print(f"\n\033[31m✗ Failed after {dur}s\033[0m")
        else:
            print(f"\n\033[32m✓ Done in {dur}s (${cost:.2f})\033[0m")


def main():
    if len(sys.argv) < 2:
        print("Usage: ndjson_display.py <output_file>", file=sys.stderr)
        sys.exit(1)

    output_path = sys.argv[1]

    with open(output_path, "ab", buffering=0) as out_file:
        for raw_line in sys.stdin.buffer:
            # Write raw bytes to file immediately (unbuffered)
            out_file.write(raw_line)

            # Parse and display human-readable version
            line = raw_line.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            try:
                data = json.loads(line)
                display_event(data)
            except json.JSONDecodeError:
                pass

            # Flush terminal
            sys.stdout.flush()


if __name__ == "__main__":
    main()
