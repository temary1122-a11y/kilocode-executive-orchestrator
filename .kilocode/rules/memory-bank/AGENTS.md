# Memory Bank Rules

## Назначение
Директория memory-bank предназначена для долговременного хранения критически важных решений и контекста.

## Как использовать
- Фиксируй архитектурные решения в decisions.md
- Веди task graph в tasks.jsonl
- Сохраняй execution traces после каждого существенного этапа
- Используй AGENTS.md как справочник по структуре памяти

## Workflow
1. Research → Planning → Execution → Verification (RPXV цикл)
2. После каждого этапа — запуск memory skill для фиксации
3. Перед новым сезоном — чтение истории задач

## ⚠️ ВАЖНО: План миграции в глобальные директории

После тестирования и финализации необходимо перенести:
- modes/ → ~/.kilocode/modes/ или ~/.kilo/modes/
- skills/ → ~/.kilocode/skills/ или ~/.kilo/skills/
- .kilo/kilo.jsonc → ~/.kilo/kilo.jsonc

Это обеспечит работу Executive Orchestrator независимо от текущего проекта.
