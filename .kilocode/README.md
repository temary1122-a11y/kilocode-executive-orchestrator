# Executive Orchestrator for Kilo Code

**Status: Early Beta**

Executive Orchestrator is a mode and tooling layer for Kilo Code that coordinates complex multi-step activities through a structured 7-phase lifecycle: Intake, Research, Planning, Context Enrichment, Delegation, Monitoring, and Verification. It is designed for scenarios that involve multi-agent delegation, memory-backed audit trails, and observable orchestration.

This is an early beta. It is functional for basic orchestration flows, but some advanced capabilities are still being hardened.

---

## What is this?

- A **Kilo Code mode** (`executive-orchestrator`) that governs how complex tasks are processed.
- A **memory-tools layer** that records tasks, decisions, execution traces, and bus events into `.kilocode/memory/`.
- A **delegation dispatch path** that attempts real execution via available backends and falls back to a pending manifest when no automatic executor is present.
- An **event bus** backed by JSONL for observable lifecycle events.

It does not replace specialist agents. It routes work to them, tracks outcomes, and verifies contracts before completion.

---

## Who is it for?

- Kilo Code users running non-trivial workflows (multi-step refactors, research + coding, migrations, review cycles).
- Early adopters comfortable with PowerShell-based tooling and beta limitations.
- Users who want explicit traceability: task queues, decision logs, and delegation manifests they can inspect.

---

## Current status: Early Beta

**Working today:**

- 7-phase runner parses and executes from `phase-runner.ps1`.
- `common.ps1` loads cleanly and provides JSONL memory helpers.
- Delegation is enabled by default (`task: allow`). Explicit `task: deny` still blocks delegation.
- Dispatch attempts are audited via execution traces and bus events written to `.kilocode/memory/bus/events.jsonl`.
- Fallback stub (`.kilocode/delegation/kilo-sdk-delegate.js`) creates a pending manifest when no real backend is connected.
- Path resolution is automatic via `Resolve-KiloBasePath`; no hardcoded user paths are required.

**Known limitations:**

- Without a connected `agent_manager` or similar backend, delegation does not execute domain work automatically. The fallback creates a `pending_manual_invoke` manifest.
- Full self-healing loop is not closed yet.
- Some multi-platform support is incomplete (Windows PowerShell-first).
- Advanced features (MCP integrations, UI plugin, dependency graph scheduler) are deferred.

---

## Requirements

- **Kilo Code** environment with mode support.
- **PowerShell** (Windows).
- **Git** repository or project workspace.
- **Node.js** is optional but recommended; it enables the fallback delegation stub.
- PowerShell execution policy that allows running local scripts.

---

## Quick Start

### 1. Place the tooling

Copy or clone the `.kilocode/` directory into the root of your project workspace.

### 2. Prepare a PowerShell execution policy

If scripts are blocked, run PowerShell as Administrator and allow local scripts:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
```

### 3. Activate the mode

In Kilo Code, select **Executive Orchestrator** mode for your session.

### 4. Run a task

Submit a complex multi-step request through Kilo Code. The orchestrator will progress through its 7 phases and write artifacts into `.kilocode/memory/`.

---

## Basic usage examples

### Medium coding task (delegation allowed)

- Objective: *"Add a health-check endpoint and basic tests for the user service."*
- Expected flow: Intake → Research → Planning → Context Enrichment → Delegation attempt → Monitoring snapshot → Verification.
- If `agent_manager` is unavailable, the run completes with a pending manifest in `.kilocode/memory/delegation/pending/`.

### Inspect delegation fallback

```powershell
# From repository root, after a run:
Get-Content '.kilocode/memory/delegation/pending/' | ForEach-Object { $_ }
```

### Monitor event bus

```powershell
. '.kilocode/tools/memory-tools/scripts/common.ps1'
Get-BusEvents | Format-Table timestamp, type, data -AutoSize
```

---

## Key paths

| Path | Purpose |
|------|---------|
| `.kilocode/modes/executive-orchestrator.md` | Mode contract and policy. |
| `.kilocode/tools/memory-tools/scripts/phase-runner.ps1` | Main 7-phase orchestration runner. |
| `.kilocode/tools/memory-tools/scripts/common.ps1` | Memory helpers, event bus, locking. |
| `.kilocode/tools/memory-tools/scripts/parallel-runner.ps1` | Parallel delegation runner. |
| `.kilocode/delegation/kilo-sdk-delegate.js` | Fallback delegation stub. |
| `.kilocode/memory/bus/events.jsonl` | Event bus (JSONL). |
| `.kilocode/memory/delegation/pending/` | Pending manual-invocation manifests. |
| `.kilocode/memory/decisions.jsonl` | Decision audit log. |
| `.kilocode/memory/execution-traces/` | Execution trace files. |

Runtime directories such as `bus/`, `delegation/pending/`, and `execution-traces/` are created automatically if missing.

---

## Delegation behavior

### Default policy

- Default is **allow**.
- Explicit `task: deny` in `.kilocode/modes/executive-orchestrator.md` still disables delegation.
- Environment variable `KILO_DELEGATE_TASK` can override the mode file for a single run.

### Backend order

1. **`agent_manager`** CLI, if available.
2. Existing wired backend (if connected in your environment).
3. **`kilo-sdk-delegate.js`** fallback (Node.js).
4. **Pending manifest** if no real executor is reachable.

### Fallback stub is not fake success

When no real backend is available, the stub writes a manifest to `.kilocode/memory/delegation/pending/` and returns:

```json
{
  "ok": false,
  "invoked": false,
  "backend": "kilo-sdk-delegate",
  "reason": "manual_invoke_required",
  "manifestPath": "..."
}
```

Do not treat this as completed delegated work. Use the manifest to perform the delegation manually outside the orchestrator.

---

## Troubleshooting

### PowerShell blocks script execution

If you see execution policy errors, run:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
```

### `agent_manager` is not found

The orchestrator will continue in fallback mode. Check that the Kilo Code Agent Manager extension is installed and that `agent_manager` is on PATH.

### Node.js is not installed

The fallback delegation stub requires Node.js. Without it, the orchestrator creates a pending manifest directly.

### Delegation creates pending manifests instead of running

This is expected if no backend is connected. Inspect the manifest in `.kilocode/memory/delegation/pending/` and invoke the task manually.

### Event bus file is not created

The bus file (`.kilocode/memory/bus/events.jsonl`) is created on the first `Publish-Event` call. Ensure `.kilocode/memory/bus/` is writable.

### Syntax / load check

```powershell
# Check common.ps1
powershell -NoProfile -NonInteractive -Command "try { `$null = [System.Management.Automation.Language.Parser]::ParseFile('.kilocode/tools/memory-tools/scripts/common.ps1', [ref]`$null, [ref]`$null); Write-Host 'OK' } catch { Write-Host 'FAIL' }"

# Check Node stub
node --check .kilocode/delegation/kilo-sdk-delegate.js
```

---

## Limitations

- **Early Beta.** APIs and behavior may change between runs.
- **No autonomous coding without a backend.** The orchestrator coordinates; actual agent execution requires a connected executor.
- **Self-healing loop is not closed.** Remediation hints are available but not automatically applied in all paths.
- **Windows / PowerShell first.** Linux/macOS support is not verified.
- **No standalone MCP bundling.** External MCPs (Tavily, Sequential Thinking, etc.) must be provided by your Kilo Code environment if needed.

---

## Development checks

Useful commands when working on the orchestrator itself:

- Parse check: `powershell -NoProfile -NonInteractive -Command "try { `$null = [System.Management.Automation.Language.Parser]::ParseFile('<script.ps1>', [ref]`$null, [ref]`$null); Write-Host 'OK' } catch { Write-Host 'FAIL' }"`
- Dot-source check: `. '.kilocode/tools/memory-tools/scripts/common.ps1'`
- Node stub check: `node --check .kilocode/delegation/kilo-sdk-delegate.js`
- Manual stub test: `node .kilocode/delegation/kilo-sdk-delegate.js <payload.json>`
