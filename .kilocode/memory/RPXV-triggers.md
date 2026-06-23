# RPXV Triggers — Автоматические триггеры выполнения цикла

## Обзор

Триггеры автоматически активируют слои RPXV (Research → Planning → Execution → Verification). Каждый триггер — это жёсткое правило, а не рекомендация.

---

## 1. Research Triggers

### `task_complexity > 2_actions`
**Условие:** Задача требует более 2 действий для выполнения
**Действие:** 
```yaml
TRIGGER: auto_start_research
skill: research
agent: research-agent
output: Research Report
```

### `unknowns > 3`
**Условие:** Более 3 неизвестных факторов в задаче
**Действие:** Тот же flow, что выше

### `architecture_change = true`
**Условие:** Требуется изменение архитектурных решений
**Действие:** Research + Tavily/Context7 обязательны

---

## 2. Planning Triggers

### `research_report.status == "complete"`
**Условие:** Research Report завершён и содержит findings
**Действие:**
```yaml
TRIGGER: auto_start_planning
skill: planning
output: Typed Execution Plan
memory: add_task(task_id, objective)
```

### `dependencies_identified = true`
**Условие:** Выявлены зависимости между подзадачами
**Действие:** Sequential Thinking MCP для разбивки на параллельные задачи

---

## 3. Execution Triggers

### `execution_plan.tasks_count > 0`
**Условие:** План содержит выполняемые задачи
**Действие:**
```yaml
TRIGGER: auto_delegate_tasks
FOR EACH task IN plan:
  - create_handoff_contract(task)
  - delegate_to_coding_agent(task)
```

### `handoff_contract.created`
**Условие:** Контракт создан для конкретной подзадачи
**Действие:** Немедленное делегирование coding-agent

---

## 4. Verification Triggers

### `all_tasks.completed`
**Условие:** Все подзадачи отмечены как completed
**Действие:**
```yaml
TRIGGER: auto_start_verification
skill: verification
agent: verification-agent
mcp: grill-me (stress-test)
```

### `timeout_reached`
**Условие:** Истекло время выполнения
**Действие:** Вынужденный запуск Verification с partial results

---

## 5. Reflection Triggers

### `verification.status == "PASS"`
**Условие:** Все проверки пройдены успешно
**Действие:**
```yaml
TRIGGER: auto_start_reflection
skill: reflection
output: memory_add_reflection(task_id, successes, errors, improvements)
memory: add_decision(topic, outcome)
```

### `verification.status == "FAIL"`
**Условие:** Обнаружены критические ошибки
**Действие:** Loop back to Planning с учётом ошибок

---

## Исключения (НЕЛЬЗЯ нарушать)

| Сценарий | Триггер | Обязательный слой |
|----------|---------|-------------------|
| "Это просто исправление бага" | — | Research (если > 2 строк кода) |
| "Код работает" | — | Verification |
| "Всё понятно" | — | Planning |
| "Готово" | — | Memory Layer |

---

## MCP Tool Mapping

| Слой | Разрешённые MCP | Запрещённые MCP |
|------|-----------------|-----------------|
| Research | Tavily, Context7 | Sequential Thinking |
| Planning | Sequential Thinking | Tavily, Context7 |
| Execution | — | Все (только кодинг) |
| Verification | Grill Me, Sequential Thinking | Tavily, Context7 |
| Memory | memory tools | Внешние MCP |

---

## Model Routing Defaults

| Слой | Модель | Fallback |
|------|--------|----------|
| Research | kilo/kilo-auto/free | claude-opus |
| Planning | kilo/kilo-auto/free | claude-sonnet |
| Execution | kilo/kilo-auto/free | специализированные |
| Verification | openai/o3-mini | gemma |
| Reflection | kilo/kilo-auto/free | — |