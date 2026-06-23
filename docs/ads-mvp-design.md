# Sponsored Block MVP Design — Local-First, Opt-In, Labeled Ad Placements

Version: 0.1 — Design only (no implementation yet).
Audience: Kilo Engineering, Product.

---

## 1. Problem Statement

Users who run Kilo against local-only or air-gapped workspaces need a way to intentionally surface **endorsed tools, skills, or models** inside the tooling workflow without spam, tracking, or unconsented data flow.

## 2. MVP Constraints (Non-Negotiable)
1. **Disabled by default**: Ads must be explicitly opted into via `KILO_ADS_ENABLED=true`.
2. **User must opt in**: No ads are displayed unless the user enables them.
3. **Always labeled**: Every placement must include `Sponsored` and disclosing party.
4. **Local-only**: No external network calls in MVP. All linked content is a local markdown file or internal MCP route. Default source is a local JSON file in `.kilocode/ads/`.
5. **Max 1 per task**: Only one sponsored block may be rendered per orchestrator task/cycle (`KILO_ADS_MAX_PER_TASK=1`).
6. **No ads during errors/security/privacy warnings**: Sponsored blocks are never shown when errors, security issues, or privacy warnings are present.
7. **No sensitive targeting**: No prompts, task objectives, or file scopes are used for targeting. The catalog is static JSON.
8. **No production code changes this sprint**: Defines the contract only.
9. **MVP is local-only**: No remote calls or external tracking in MVP.

---

## 3. Sponsored Block Contract

A sponsored block is a **read-only, inert block** inserted by the rendering layer (UI, MCP, or custom mode prompt).

```json
{
  "id": "sp_001",
  "title": "Try the agent-status skill",
  "body": "Monitor agent health with real-time heartbeats.",
  "sponsor": "Kilo",
  "link_type": "local_file",
  "link_target": ".kilocode/skills/agent-status/SKILL.md",
  "impression_scope": "task_only",
  "expire_at": "2026-12-31T23:59:59Z",
  "local_only": true
}
```

**Invariants enforced by renderer:**
- `local_only == true` ⇒ no `<img>` src, no remote fetch.
- `max_per_task == 1` ⇒ renderer ignores second+ blocks in the same task cycle.
- `impression_scope` controls whether the block is shown once per session, once per task, or once per agent; MVP supports only `task_only`.
- Insertion point: **after the termination protocol's executors screen and before the final STOP** (not inside the user's chat turn).

---

## 4. Capability Boundaries

### A. Custom Mode Only
- Can render a markdown Sponsored block in assistant output.
- Cannot guarantee true UI banner rendering.
- Cannot guarantee hidden tool calls.

### B. MCP (Proposed)
- Can provide memory/profile/ad selection tools via `mcp.kilo.local/sponsored`.
- Can reduce shell/PowerShell noise through structured event bus.
- Does not guarantee invisible UI (plugin required for true visual rendering).

### C. UI / Plugin (Future)
- Required for true visual banner component.
- Requires future Kilo Code UI/plugin/extension research.

---

## 5. Privacy and Consent Rules

| Rule | Implementation |
|------|----------------|
| **Default off** | `KILO_ADS_ENABLED=false` in `.kilocode/kilo.jsonc`. Must be explicitly toggled to `true`. |
| **Personalization opt-in** | `KILO_ADS_PERSONALIZATION=local_only` restricts targeting to local profile data only. |
| **Local-only delivery** | No DNS lookups, no embed tags, no fetch() in MVP. All linked content is a local markdown file or internal MCP route. |
| **Impression re-auth** | Impression IDs stored in `.kilocode/ads/impressions/.gitkeep`. Once per task per sponsor per session, a unique `impression_id` is generated; re-requests within same task cycle are no-ops. |
| **Do not learn from user chat** | No prompts, task objectives, or file scopes are sent to the catalog. The catalog is static JSON. |
| **Transparency** | Each block must display `Sponsored` label and a `Why am I seeing this?` link to a local markdown doc explaining opt-out. |
| **Migration path to remote later** | If a future sprint adds remote networks, it must be gated behind explicit `KILO_ADS_REMOTE_CONSENT=1` plus a per-host allowlist in `kilo.jsonc`. This sprint does not implement remote. |

---

## 6. Implementation Roadmap

### Sprint 1
- [ ] Chat noise reduction audit
- [ ] Quiet/Json/NoProgress design
- [ ] Batch memory operations design
- [ ] Ads MVP design (this document)
- [ ] No production ad display yet

### Sprint 2
- [ ] Ad config example (`.kilocode/ads/config.example.json`)
- [ ] Ad catalog example (`.kilocode/ads/catalog.example.jsonl`)
- [ ] Local ad selector (MCP stub)
- [ ] Markdown Sponsored block policy
- [ ] Local impression logging (`.kilocode/ads/impressions/.gitkeep`)
- [ ] Unit tests for gate logic

### Sprint 3 (Design + Optional Prototype)
- [ ] Memory/profile/ad MCP design
- [ ] Example MCP config, not enabled by default

### Sprint 4
- [ ] UI/plugin integration research for real banner rendering

---

## 7. Security Review Notes
- **XSS**: Since blocks are local-only JSON rendered as markdown by the plugin, treat all fields as plain text; no HTML interpolation.
- **Path traversal**: `link_target` must be validated against `KILO_BASE` / `.kilocode/` root before the kernel opens it.
- **Privilege**: Sponsored blocks execute with no elevated filesystem permissions; they cannot trigger scripts.