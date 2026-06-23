---
name: memory
description: Практические инструменты для работы с памятью (tasks + decisions)
---
# Memory Tools v2 — Practical Edition

## add_task

**Добавить задачу в tasks.jsonl:**

```markdown
# ШАГ 1: Создаём запись
task_record = {
  "task_id": "task_{timestamp}",  # пример: task_1406142325
  "type": "research|coding|verification|memory",
  "priority": "p0|p1|p2",
  "status": "pending",
  "parent_id": null,  # или ID родительской задачи
  "objective": "<краткая цель>",
  "assigned_agent": "research-agent|coding-agent|verification-agent",
  "created_at": "2026-06-14T23:25:00Z"
}

# ШАГ 2: Добавляем в конец файла
echo '{"task_id":"task_1406142325","type":"coding","priority":"p1","status":"pending","parent_id":null,"objective":"...","assigned_agent":"coding-agent","created_at":"2026-06-14T23:25:00Z"}' >> .kilocode/memory/tasks.jsonl
```

## update_task_status

**Изменить статус задачи:**

```markdown
# ЧИТАЕМ текущий файл
# НАХОДИМ нужную строку по task_id
# МЕНЯЕМ status + добавляем completed_at если completed

# ПРИМЕР:
# Было: {"task_id":"task_001","status":"in_progress"}
# Стало: {"task_id":"task_001","status":"completed","completed_at":"2026-06-14T23:30:00Z"}
```

## get_active_tasks

**Получить список активных задач (pending/in_progress):**

```markdown
# ЧИТАЕМ .kilocode/memory/tasks.jsonl
# ФИЛЬТРУЕМ: status="pending" OR status="in_progress"
# ВОЗВРАЩАЕМ список task_id + objective
```

## record_decision

**Зафиксировать решение в decisions.md:**

```markdown
# ДОБАВЛЯЕМ в конец файла:

### YYYY-MM-DD Тема решения

**Вход:**
- Проблема: <описание>

**Выбор:**
- Решено: <что выбрано>
- Обоснование: <почему>

**Артефакты:**
- <что создано>
```

## promote_to_semantic

**Перенести выводы из Working в Semantic память:**

```markdown
# ПОСЛЕ выполнения задачи:
# 1. Выделяем 3 ключевых вывода
# 2. ДОБАВЛЯЕМ в decisions.md (как record_decision)
# 3. МЕНЯЕМ статус task на completed + completed_at
```

## Handoff Integration

При получении handoff-контракта:
1. **add_task** → создаём задачу
2. **update_task_status("in_progress")** → работаем
3. **promote_to_semantic()** → после завершения

## Quick Reference Examples

### Пример добавления задачи:
```markdown
echo '{"task_id":"task_1406142330","type":"coding","priority":"p0","status":"pending","parent_id":null,"objective":"Создать аутентификацию","assigned_agent":"coding-agent","created_at":"2026-06-14T23:30:00Z"}' >> .kilocode/memory/tasks.jsonl
```

### Пример обновления статуса:
```markdown
# Заменяем строку:
# {"task_id":"task_1406142330","status":"pending"}
# На:
# {"task_id":"task_1406142330","status":"in_progress"}
```
