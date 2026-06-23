---
name: reflection
description: Структурированная рефлексия после выполнения задач для выделения выводов, ошибок и улучшений
---
# Reflection Protocol v1

## Когда использовать
После завершения значимых задач перед тем, как перейти к следующей.
Используется Executive Orchestrator после Verification Layer.

## Инструкции

### Шаг 1: Подведение итогов
```yaml
reflection:
  completed_task: "<название задачи>"
  original_objective: "<исходная цель>"
  final_result: "<что было в итоге>"
```

### Шаг 2: Выделение выводов
- 3 ключевых успеха (SUCCESS)
- 2 допущенные ошибки (ERRORS)
- 3 возможных улучшения (IMPROVEMENTS)

### Шаг 3: Анализ затрат
- Трудозатраты: <время, усилия>
- Токен-затраты: <приблизительно>
- ROI: <ожидаемая/фактическая польза>

### Шаг 4: Фиксация в decisions.md
```markdown
### [Дата] Reflection: <название задачи>

**Успехи:**
- ...

**Ошибки:**
- ...

**Улучшения:**
- ...
```

## Structured Critique Template
Verdict: PASS / FAIL / NEEDS_REVIEW

Issues Found:
- severity: high | medium | low
- category: correctness | efficiency | safety | completeness
- location: <где проблема>
- fix: <конкретный fix>

## Best Practices
- Одна рефлексия на задачу (избегать бесконечных циклов)
- Использовать для high-stakes задач
- Сохранять в memory для последующего анализа
- Бюджет: max 2 итерации reflection
