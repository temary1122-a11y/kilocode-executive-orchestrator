---
name: handoff-contracts
description: Структурированные контракты передачи работы между агентами
---
# Typed Handoff Contracts v2

## Contract Template (Enhanced)
```yaml
handoff_contract:
  contract_id: handoff_<timestamp>
  from_agent: executive-orchestrator
  to_agent: <target_mode>
  task_name: "<краткое название>"
  objective: "<чёткая цель на 1-2 предложения>"
  context:
    files_to_read: [<files>]
    key_facts: [<facts>]
  constraints:
    - tech_stack: <stack>
    - forbidden: [<paths>]
    - deadline: <optional>
  success_criteria:
    - must_deliver: [<artifacts>]
    - quality_gates: [<checks>]
  output_format: yaml | markdown | code
  preferred_model: <model_id, optional>
```

## Example: Research Handoff
```yaml
handoff_contract:
  contract_id: handoff_20260613_research
  from_agent: executive-orchestrator
  to_agent: research-agent
  task_name: "Project Architecture Analysis"
  objective: |
    Проанализировать структуру проекта и выявить архитектурные риски
  context:
    files_to_read: []
    key_facts:
      - "Project uses TypeScript + Express"
      - "Target: migrate to Next.js 15"
  constraints:
    tech_stack: ["TypeScript", "Express"]
    deadline: "2 days"
  success_criteria:
    must_deliver: ["Research Report в YAML"]
    quality_gates: ["Все файлы проекта проанализированы"]
  output_format: yaml
  preferred_model: "anthropic/claude-opus"
```
