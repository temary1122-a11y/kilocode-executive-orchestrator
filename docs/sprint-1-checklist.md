# Sprint 1 Prioritized Implementation Checklist — Sponsored Block MVP

**Note**: This checklist covers the Sponsored Block MVP portion of Sprint 1. Sprint 1 also includes Chat Noise Reduction (audit and Quiet/Json/NoProgress design) as its primary focus.

Sprint goal: Ship the contract, the local catalog, and the MCP stub only. Zero production code paths outside `KILO_ADS_ENABLED` are modified.

---

## P0 — Must Have (Definition of Done)
- [ ] **Schema lock**: `docs/ads-mvp-design.md` reviewed and accepted. No breaking changes to the `sponsored_block` JSON schema throughout the sprint.
- [ ] **Catalog file**: Create `.kilocode/ads/catalog.example.jsonl` with 3–5 placeholder entries. Each entry has `local_only: true`, `impression_scope: task_only`, `expire_at`, and a `link_target` pointing inside `.kilocode/skills/` or `.kilocode/modes/`.
- [ ] **Env-var gates**: Parse `KILO_ADS_ENABLED` (default `false`), `KILO_ADS_PERSONALIZATION=local_only`, and `KILO_ADS_MAX_PER_TASK=1` from `kilo.jsonc` and environment. Document in `executive-orchestrator.md` under a new `## Sponsored Blocks` section.
- [ ] **MCP server stub (local-only)**:
   - [ ] New script `.kilocode/tools/mcp-servers/sponsored-mcp.ps1` (or equivalent).
   - [ ] Implements `get_sponsored_block` returning one block keyed by last 8 chars of `task_id` hash modulo count, or `null` if quota reached.
   - [ ] Implements `log_impression` writing JSONL files inside `.kilocode/ads/impressions/`.
- [ ] **Phase-runner hook**: After phase 7 (or immediately after task creation), when `KILO_ADS_ENABLED=true`, call `get_sponsored_block` and attach to task metadata/context packet as `sponsored_block`. Never print it to console.
- [ ] **Gate unit tests**:
   - [ ] `max_per_task == 1` test (same task_id returns same block, second call returns `null`).
   - [ ] `local_only` enforcement (block containing `http://` or `https://` is filtered out).
   - [ ] `opt-in` enforcement (env var missing or false ⇒ no block).

---

## P1 — Should Have (Polishing)
- [ ] **Expiry filter**: `get_sponsored_block` ignores entries with `expire_at` in the past.
- [ ] **Impression dedup**: Re-delivering the same block within a `task_only` scope is a no-op (returns `null`).
- [ ] **JSON schema validation**: Validate block structure using JSON schema; reject blocks missing `id`, `sponsor`, `link_type`, or `local_only`.
- [ ] **Error path**: If catalog is missing or malformed, return `null` and emit a bus event `sponsored.catalog_error` (do not fail the task).

---

## P2 — Nice to Have (Optional)
- [ ] **Seed rotation**: Instead of a static hash, rotate block every 14 days via a cron-like check inside the MCP stub.
- [ ] **Plugin stubs**: Add a placeholder page in the Kilo UI plugin codebase showing where the card will render, behind the same env-var gate.
- [ ] **Local feedback doc**: Add a markdown template for users to submit feedback about sponsored blocks (saved to `.kilocode/ads/feedback-template.md`).

---

## Out of Scope for Sprint 1 (Explicitly Excluded)
- Any remote network call (telemetry, ad-serving, metrics).
- Modifications to `phase-runner.ps1` unless behind `KILO_ADS_ENABLED` and reversible via a single revert.
- Visual card styling / markdown rendering outside the MCP response envelope.
- Ads in user-facing chat transcript; MVP is context-packet surface only.
