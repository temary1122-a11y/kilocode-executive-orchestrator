---
name: working-memory
description: Рабочие инструменты для оперативного управления задачами через PowerShell скрипты
---
# Working Memory Tools v2.1

## Онтология сущностей

```
Task: {task_id, type, priority, status, objective, created_at, completed_at, parent_id, depends_on[], parallel_group, max_agents, estimated_complexity}
User: {user_id, preferences{models[], coding_style, favorite_commands[]}, task_patterns[], project_context{}, created_at, last_updated}
Fact: {id, source_task, content, created_at, category}
Decision: {id, topic, choice, rationale, created_at, task_id}
Dependency: {task_id, depends_on[], reason, resolved}
```

## Task Graph Operations

### add-task-with-dependencies

Создать задачу с зависимостями:

```powershell
.\.kilocode\tools\memory-tools\memory-tools.ps1 add-task -Type coding -Priority p1 -Objective "<текст>" -Agent <agent_name> -DependsOn "task_001,task_002" -EstimatedComplexity high
```

### task-dependency

Управление зависимостями:

```powershell
.\.kilocode\tools\memory-tools\memory-tools.ps1 task-dependency -Action graph -Format table
.\.kilocode\tools\memory-tools\memory-tools.ps1 task-dependency -Action read -TaskId task_001
.\.kilocode\tools\memory-tools\memory-tools.ps1 task-dependency -Action add -TaskId task_002 -DependsOn "task_001"
.\.kilocode\tools\memory-tools\memory-tools.ps1 task-dependency -Action set -TaskId task_002 -DependsOn '["task_001"]'
.\.kilocode\tools\memory-tools\memory-tools.ps1 task-dependency -Action validate
```

## User Profile Operations

### read-user-profile

```powershell
.\.kilocode\tools\memory-tools\memory-tools.ps1 user-profile -Action read
```

### record-preference

```powershell
.\.kilocode\tools\memory-tools\memory-tools.ps1 user-profile -Action record-preference -Category models -Value "kilo/kilo-auto/free"
.\.kilocode\tools\memory-tools\memory-tools.ps1 user-profile -Action record-preference -Category favorite_commands -Value "agent-status -Watch -Status running"
```

### update-user-profile

```powershell
.\.kilocode\tools\memory-tools\memory-tools.ps1 user-profile -Action update -Key coding_style -Value "concise"
.\.kilocode\tools\memory-tools\memory-tools.ps1 user-profile -Action update-project-context -Key important_path -Value ".kilocode/tools/memory-tools"
```

### record-task-completion

Автоматически вызывается `update-task -Status completed`, но можно вызвать явно:

```powershell
.\.kilocode\tools\memory-tools\memory-tools.ps1 user-profile -Action record-task-completion -TaskId task_001 -TaskType coding -Priority p1 -Agent coding-agent -Objective "Finish feature"
```

## Protocols

### create_task

Создать задачу в Working Memory:

```powershell
.\.kilocode\tools\memory-tools\memory-tools.ps1 add-task -Type <research|coding|verification|memory> -Priority <p0|p1|p2> -Objective "<текст>" -Agent <agent_name> [-ParentId <task_id>] [-DependsOn "task_a,task_b"] [-EstimatedComplexity low|medium|high]
```

### update_task_status

Обновить статус задачи:

```powershell
.\.kilocode\tools\memory-tools\memory-tools.ps1 update-task -TaskId <task_id> -Status <pending|in_progress|completed|failed|blocked> [-CompletedAt "<ISO8601>"]
```

При `completed` скрипт также обновляет `user-profile.jsonl` через `record-task-completion`.

### get_active_tasks

Получить активные задачи:

```powershell
.\.kilocode\tools\memory-tools\memory-tools.ps1 get-tasks [-Filter <type>] [-Priority <p0|p1|p2>]
```

### get_last_task

Получить ID последней созданной задачи:

```powershell
.\.kilocode\tools\memory-tools\memory-tools.ps1 get-last-task
```

### get_current_task

Получить ID задачи в статусе in_progress:

```powershell
.\.kilocode\tools\memory-tools\memory-tools.ps1 get-current-task
```

### record_decision

Записать решение:

```powershell
.\.kilocode\tools\memory-tools\memory-tools.ps1 log-decision -Topic "<тема>" -Problem "<проблема>" -Choice "<выбор>" -Rationale "<обоснование>" [-Task <task_id>]
```

### Aliases

```powershell
.\.kilocode\tools\memory-tools\init-memory-tools.ps1
# Now use: add-task, update-task, log-decision, get-tasks, get-last-task, get-current-task, task-dependency, user-profile
```

### Handoff Integration

При получении handoff-контракта:
1. `.\.kilocode\tools\memory-tools\memory-tools.ps1 add-task` с objective из контракта
2. `.\.kilocode\tools\memory-tools\memory-tools.ps1 update-task -Status in_progress`
3. После выполнения → `update-task -Status completed` + `log-decision` для findings
4. Если задача имеет зависимости, проверь граф через `task-dependency -Action validate`
