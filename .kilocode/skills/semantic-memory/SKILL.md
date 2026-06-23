---
name: semantic-memory
description: Инструменты для фиксации и получения решений
---
# Semantic Memory Tools

## record_decision

Записать решение:

```powershell
.\.kilocode\tools\memory-tools\memory-tools.ps1 log-decision -Topic "<тема>" -Problem "<проблема>" -Choice "<решение>" -Rationale "<обоснование>" [-Task <task_id>]
```

## get_recent_decisions

Получить последние решения:

```powershell
.\.kilocode\tools\memory-tools\memory-tools.ps1 get-recent-decisions [-Count <number>]
```

## Integration с RPXV

После Verification:
```powershell
# Фиксируем выводы:
.\record-decision.ps1 -Topic "Task Completion: <task_id>" -Problem "<что было сделано>" -Choice "<итог>" -Rationale "<результат>" -Task <task_id>
```