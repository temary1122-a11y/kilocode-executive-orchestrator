# Chat Noise Audit — Visible Shell/PowerShell Noise Sources & Migration Plan

Audit date: 2026-06-23
Scope: `.kilocode/tools/memory-tools/scripts/` PowerShell tooling invoked by Executive Orchestrator (EO) and memory-tools.

---

## 1. Top Sources of Visible Shell Noise

### Tier 1 — High-Frequency Console Writers
| Script | Function / Pattern | Approx. Noise Level | Notes |
|--------|--------------------|---------------------|-------|
| `common.ps1` | `Write-Log` (uses `Write-Host` with color) | **Very High** | Called by almost every trace, health-check, and memory operation. Writes timestamped `[DEBUG/INFO/WARN/ERROR]` directly to host. |
| `common.ps1` | `Write-OrchestratorUiStatus` / `Write-OrchestratorUiParallelStatus` | **Very High** | `[UI] EO |` status dumps on every phase transition, delegation attempt, and heartbeat. |
| `phase-runner.ps1` | `Write-PhaseLine` | **High** | `[{Phase}] [{Status}] {Detail}` on each phase of the 7-phase lifecycle. Invoked many times per run. |
| `update-heartbeat.ps1` | `Write-Host "Heartbeat updated for $TaskId"` | **High** | Executed periodically to prevent circuit-breaker false positives (every few steps in a subagent loop). |
| `update-task-status.ps1` | `Write-Host "Task $TaskId status updated to $Status"` | **Medium** | Fires on every state change (`pending` → `in_progress` → `completed`, etc.). |
| `parallel-runner.ps1` | `Write-PlanSummary`, `Write-Host`, `Write-RunnerError` | **Medium** | Prints full parallel plan, batch counts, agent assignments, and per-task scope lines before live run. |
| `consolidate-results.ps1` | `Write-Host` (Phase 1/2), `Write-Warning` | **Medium** | Two-phase commit dump + git merge logs + selected/rejected output. |
| `self-heal.ps1` | `Write-Host` in DryRun/Apply/default, `Write-Log` | **Medium** | Prints full remediation JSON and warning banners when invoked. |
| `file-scope-guard.ps1` | `Write-Error` on overlap | **Low** | Only surfaces when conflict is detected, but the error stream is noisy. |

### Tier 2 — Structural / Duplicate Noise
| Source | Description | Impact |
|--------|-------------|--------|
| `phase-runner.ps1` lines 751–899 | Duplicated `Write-Log`, `Read-Jsonl`, `Write-Jsonl`, `Write-JsonlSafe`, file-lock, `Test-TraceQuality`, `Export-TraceSet`, `Start-TraceReplay`, `Analyze-TraceData`, `Update-SystemState`, `Sync-SystemStateFromTasks`, `Get-LatestTaskRecord`, `Get-CurrentTaskRecord` headers from `common.ps1`. Although dot-sourced comments do not write to console, they bloat the loaded module surface and confuse observability. | **Code smell / maintenance noise** |
| `Invoke-PhaseScript` stdout capture | `phase-runner.ps1` spawns child PowerShell processes with `RedirectStandardOutput = $true` but child scripts still emit via `Write-Host` (direct host stream), which bypasses stdout redirection in the host process and appears in the EO interactive transcript. | **Loss of batching / quiet mode** |

---

## 2. Quiet / Batch / MCP Migration Path

### Guiding Principles
1. **Default to quiet**: All helper scripts must be silent unless explicitly invoked with `-Verbose` or an explicit `-Quiet:$false` switch.
2. **Structured batch first**: Diagnostics should be returned as JSON objects (or JSONL events) that the orchestrator can concatenate and present once, not streamed line-by-line.
3. **MCP as silent backend**: `Write-Log` and UI status lines become lifecycle *events* published to the local JSONL bus (`.kilocode/memory/bus/events.jsonl`) and remembered, not printed.
4. **Host presentation layer**: The only entity that should talk to the user is the Executive Orchestrator's final/summary surface, after phases complete or on explicit `-Progress` request.
5. **Native tools only for simple read-only or emergency fallback**: Built-in tools should only be used for basic operations or when MCP is unavailable.

### Phase 0 — Chat Noise Audit (Sprint 1)
- [ ] Audit top noisy scripts (`common.ps1`, `phase-runner.ps1`, `parallel-runner.ps1`, `update-heartbeat.ps1`, etc.).
- [ ] Add Quiet/Json/NoProgress support to identified scripts.
- [ ] Consider batch memory operations for consolidated output.

### Phase 1 — Immediate Quiet Mode (no breaking changes)
- Add an environment gate: `if ($env:KILO_QUIET -eq '1') { return }` inside `Write-Log`, `Write-OrchestratorUiStatus`, `Write-OrchestratorUiParallelStatus`, and all direct `Write-Host` calls in scripts.
- Users and CI can set `KILO_QUIET=1` for silent runs; interactive sessions leave it unset.
- No API changes; keep all parameters for backward compatibility.

### Phase 2 — Batch / Structured Output
- Replace inline `Write-Host` in tool scripts with `Write-StructuredOutput` helper that writes JSON to stdout when called directly, and to the bus when called from phase-runner.
- `update-heartbeat.ps1`, `update-task-status.ps1`, `consolidate-results.ps1`, `file-scope-guard.ps1`: return structured result objects and suppress console output under `KILO_QUIET`.
- `phase-runner.ps1` collects structured phase results and prints a single tabular or JSON summary at the end of each phase (or at end-of-run).
- **Sprint 1B — Batch Memory Operations MVP (Implemented 2026-06-23)**
  - Added `batch-memory.ps1` supporting `add-task`, `record-decision`, `update-task-status` via `-InputFile` or `-InputJson`.
  - Wired through `memory-tools.ps1 batch` command.
  - Exactly one JSON object output when `-Quiet -Json` is used.
  - Eliminates subprocess fan-out by dot-sourcing `common.ps1` and reusing internal helpers.

### Phase 3 — MCP Event Bus Migration
- Convert `Write-Log` from `Write-Host` to `Publish-Event` with `type: log.{level}`.
- Create a small MCP server schema (`mcp.kilo.local/logs`) that exposes:
  - `tail_logs` (filtered replay)
  - `stream_events` (live SSE or polling)
  - `clear_log_buffer`
- The desktop plugin / UI / custom mode reads from the bus rather than parsing raw console output.

### Phase 4 — Plugin / UI Surface
- Move all `[UI]`-prefixed status (`Write-OrchestratorUiStatus`, `Write-OrchestratorUiParallelStatus`) into an MCP server endpoint (`mcp.kilo.local/orchestrator/status`) or a websocket stream consumed by the Kilo plugin.
- The plugin renders a live progress palette (similar to `top`/`htop` or VS Code terminal task progress) without flooding the main chat transcript.

### Phase 5 — Cleanup
- Remove duplicated doc-block headers in `phase-runner.ps1` that mirror `common.ps1`.
- Audit all scripts for `Write-Host` usage and standardize on `Write-Log` (which can itself be silenced via env var).

---

## 3. Privacy & Consent Implications of Migration
- All output moves to local JSONL by default (`.kilocode/memory/`); no cloud telemetry implied.
- Any new MCP server must respect a `KILO_DISABLE_MCP` env var to preserve fully offline behavior.
- No PII from task objectives, file scopes, or error messages may leak to an external MCP without explicit `KILO_TELEMETRY_CONSENT=1`.

---

## 4. Success Criteria for Noise Reduction
- Fresh runs of `phase-runner.ps1` in non-interactive mode produce **zero** unexpected lines of console output unless `-Quiet:$false` is passed.
- The JSONL bus accumulates a full machine-readable history of every phase transition, delegation decision, and error.
- UI rendering is shifted from stdout text to a structured stream consumed by the Kilo plugin or *proposed* `mcp.kilo.local/*` namespace tools.
- Sponsored Block MVP (local-only, opt-in, max 1 per task) is designed after noise reduction foundations.

### Sprint 1A — Quiet/Json/NoProgress MVP (Implemented 2026-06-23)

#### Shared Helpers Added
- `common.ps1`: `Test-QuietMode`, `Write-QuietAwareHost`, `Write-JsonResult`
- `common.ps1`: `Write-Log` updated with optional `-Quiet` switch; respects `KILO_QUIET=1` and `KILO_QUIET=true`

#### Scripts with -Quiet and -Json Support
| Script | -Quiet | -Json | Notes |
|--------|--------|-------|-------|
| `add-task.ps1` | ✅ | ✅ | JSON emits `{ ok, operation, task_id }` |
| `update-task-status.ps1` | ✅ | ✅ | JSON emits `{ ok, operation, task_id, status }` |
| `record-decision.ps1` | ✅ | ✅ | JSON emits `{ ok, operation, id }` |
| `update-heartbeat.ps1` | ✅ | ✅ | JSON emits `{ ok, operation, task_id }` |
| `health-check.ps1` | ✅ | ✅ | JSON emits passed/failed result with error array |

#### Remaining Known Noisy Scripts (post-Sprint 1B)
- `parallel-runner.ps1`: emits full plan summary and per-task scope lines.
- `consolidate-results.ps1`: emits two-phase commit dump and git merge logs.
- `self-heal.ps1`: emits remediation JSON and warning banners.
- `phase-runner.ps1`: noisy orchestrator lifecycle output (target for later sprint).
- `Write-OrchestratorUiStatus` / `Write-OrchestratorUiParallelStatus` in `common.ps1`: UI status lines suppressed in quiet mode but remain loud in interactive mode.

#### Batch Operations Supported (post-Sprint 1B)
- `batch-memory.ps1`: `add-task`, `record-decision`, `update-task-status` via single `-Quiet -Json` call.
- `memory-tools.ps1 batch`: passthrough for batch operations.

#### Backward Compatibility Status
- No breaking changes introduced. Existing invocations without `-Quiet`, `-Json`, or `KILO_QUIET` continue to display human-readable output as before.
