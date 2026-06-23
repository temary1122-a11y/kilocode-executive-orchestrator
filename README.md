# Kilo Code Executive Orchestrator

**Early Beta** — `v0.9.0-beta`

## What is this

A custom mode + tooling bundle for [Kilo Code](https://kilo.ai) that adds a structured Executive Orchestrator workflow.

Key characteristics:
- **7-phase workflow** — Intake → Research → Planning → Context Enrichment → Delegation → Monitoring → Verification + Memory Closure.
- **Delegation fallback** — if no real backend is connected, the orchestrator writes a pending manifest and exits cleanly.
- **JSONL memory/audit bus** — tasks, decisions, and execution traces are written to `.kilocode/memory/` as JSONL files.
- **Pester E2E test suite** — smoke and recovery tests for the memory-tools layer.

> **Beta limitations**
> - Fallback manifest does not execute actual work; it is a stub for manual invocation.
> - Real delegation needs `agent_manager` / SDK backend.
> - Windows / PowerShell-first environment.
> - Self-healing loop is not fully closed.
> - Advanced MCP integrations (Tavily, Context7, Playwright, Sequential Thinking) are deferred unless you explicitly configure them.

## Install

```powershell
git clone https://github.com/temary1122-a11y/kilocode-executive-orchestrator.git
cd kilocode-executive-orchestrator
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Use `-TargetPath "C:\Path\To\Your\Project"` to install into an existing Kilo Code project instead of the current directory.

### Download via GitHub Release

Grab the packaged source from the [v0.9.0-beta release](https://github.com/temary1122-a11y/kilocode-executive-orchestrator/releases/tag/v0.9.0-beta).

## Key paths

| Path | Purpose |
|---|---|
| `.kilocode/modes/executive-orchestrator.md` | Mode contract and policy. |
| `.kilocode/modes/coding-agent.md` | Coding agent mode. |
| `.kilocode/modes/research-agent.md` | Research agent mode. |
| `.kilocode/modes/verification-agent.md` | Verification agent mode. |
| `.kilocode/delegation/kilo-sdk-delegate.js` | Fallback delegation stub (Node). |
| `.kilocode/tools/memory-tools/scripts/` | PowerShell scripts for memory, decisions, tasks, heartbeats. |
| `.kilocode/tools/memory-tools/tests/` | Pester E2E tests. |
| `.kilocode/skills/` | Skill definitions used by the orchestrator. |
| `.kilocode/rules/` | Routing and policy rules. |

## Run tests

```powershell
powershell -ExecutionPolicy Bypass -File ".kilocode\tools\memory-tools\tests\run-tests.ps1"
```

## Docs

- See `.kilocode/README.md` for the full user guide.
- See `.kilocode/memory/MEMORY-ARCHITECTURE.md` for the memory model.
- See `CHANGELOG.md` for the release history.

## Contributing

Contributions are welcome. Please open an issue first for non-trivial changes.

## License

MIT License. See [LICENSE](LICENSE).
