---
name: self-improvement
description: Lightweight self-improvement layer for identifying tool gaps and suggesting solutions
---
# Self-Improvement Layer v1

## When to Use
After encountering missing tools, persistent errors, or repeated manual interventions.

## Diagnostic Flow

### Step 1: Identify Gap
When a task fails due to missing capability:
```powershell
.\memory-tools.ps1 suggest-tool -Problem "Cannot parse XML config" -Context "Config validation step" -Suggestion "Use xmllint or PowerShell XML module" -Task <task_id>
```

### Step 2: Review Topics
Check `.kilocode\memory\topics.md` for pending suggestions:
```powershell
Get-Content .kilocode\memory\topics.md | Select-String -Pattern "Status: pending"
```

### Step 3: Create Skill (if needed)
If same problem occurs repeatedly, create a reusable skill:
```powershell
# Use skill-creator to generate:
# - .kilocode\skills\<skill-name>\SKILL.md
# - .kilocode\skills\<skill-name>\prompt.md
```

## Integration with Skill Creator
If tool gap requires custom logic:
1. Record diagnostic with `suggest-tool.ps1`
2. Run skill-creator to make reusable skill
3. The skill becomes available for future similar tasks

## Topics Format
```markdown
### [Timestamp] Diagnostic: <Problem>

**Context:** <Where it happened>
**Suggestion:** <What could help>
**Status:** pending | implemented | dismissed
**Task:** <task_id for correlation>
```

## Best Practices
- Record gaps immediately when encountered
- Check topics.md weekly for patterns
- Convert repeated solutions to skills
- Keep suggestions actionable and specific