---
name: task-summary
description: Автоматическое создание сводки после завершения задачи
---
# Task Summary Skill

## Когда использовать
После завершения каждой значимой задачи (Research, Coding, Verification завершены).

## Workflow

### Шаг 1: Собрать данные
```powershell
# Получить список выполненных задач:
.\.kilocode\memory\scripts\get-active-tasks.ps1 | Where-Object { $_.status -eq "completed" }

# Прочитать decisions.md для последних решений:
Get-Content .kilocode\memory\decisions.md | Select-String "### \d{4}-\d{2}-\d{2}" -Context 5
```

### Шаг 2: Сформировать сводку
```markdown
## Task Summary: <task_id>

**What was done:**
- <кратко о выполненной работе>

**Decisions made:**
- <ключевые решения>

**Remaining tasks:**
- <что ещё нужно сделать>

**Next steps:**
- <рекомендации>
```

### Шаг 3: Зафиксировать
```powershell
# Добавить в decisions.md через record-decision.ps1:
.\record-decision.ps1 -Topic "Summary: <task_id>" -Problem "<цель>" -Choice "Completed with findings" -Rationale "<краткое содержание>" -Task <task_id>
```

## Template
```
## Task Summary: <id>
- Done: <what>
- Decisions: <list>
- Blocked: <list>
- Next: <recommendations>
```