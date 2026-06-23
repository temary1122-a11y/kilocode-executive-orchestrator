---
name: agent-status
description: Show status of all Agent Manager sessions with control options
---
# Agent Status Monitor

## Purpose
Provides visibility into running agents so you can control them individually.

## Usage
```powershell
.\memory-tools.ps1 agent-status [-Kill <session_id>] [-Pause <session_id>]
.\memory-tools.ps1 agent-status  # Show all sessions
```

## Output Example
```
=== Agent Status Monitor ===
Worktree: C:\project

[abc12345] [coding] running | Refactor auth module
     ├─ Branch: feature/auth-refactor
[def67890] [research] idle | Research API patterns
[ghi24680] [debug] failed | Fix login error
```

## Status Colors
- **Green**: running
- **Yellow**: idle
- **Red**: failed/stuck
- **Gray**: unknown

## Controls
- `-Kill <session_id>` — Stop specific agent (doesn't affect others)
- `-Pause <session_id>` — Pause agent for inspection