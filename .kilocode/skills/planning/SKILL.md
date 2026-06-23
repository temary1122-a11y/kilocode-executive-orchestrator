---
name: planning
description: Создание Typed Execution Plan с декомпозицией задач и зависимостями
---
# Planning Protocol v2

## Когда использовать
После получения Research Report и перед Execution Layer.

## Инструкции

### Typed Execution Plan
```yaml
execution_plan:
  plan_id: plan_<timestamp>
  tasks:
    - task_id: task_001
      name: "Task name"
      description: "Detailed description"
      priority: high | medium | low
      dependencies: [<task_ids>]
      agent: research-agent | coding-agent | verification-agent
      estimated_time: "<time>"
      status: pending
```

### Handoff Contracts Integration
После создания плана — генерируй handoff-контракты для каждой задачи

## MCP Tools
- Sequential Thinking: для мастеринга зависимостей между задачами