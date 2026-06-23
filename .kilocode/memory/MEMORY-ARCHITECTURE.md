# Three-Level Memory Architecture for Kilo Code

## Memory Levels Overview

| Level | Location | Purpose | Retention |
|-------|----------|---------|-----------|
| **Working Memory** | `.kilocode/memory/working-memory/` | Current tasks, statuses, immediate context | Session-scoped |
| **Semantic Memory** | `.kilocode/memory/semantic-memory/` | Architectural decisions, rules, factual knowledge | Persistent |
| **Procedural Memory** | `.kilocode/memory/procedural-memory/` | Workflows, patterns, best practices | Persistent |

## Working Memory

### Structure:
- `current-task.json` — активная задача
- `task-queue.jsonl` — очередь задач с приоритетами
- `dependencies.json` — зависимости между задачами
- `context-cache.json` — кэш текущего контекста (5-10 последних файлов)

### Operations:
- load_task() — загрузить текущую задачу
- update_status() — обновить статус задачи
- resolve_dependencies() — разрешить блокирующие задачи

## Semantic Memory

### Structure:
- `decisions-archive.md` — архив всех архитектурных решений
- `facts.db.jsonl` — структурированные факты (ключ-значение)
- `knowledge-graph.json` — связи между концептами

### Operations:
- add_fact(key, value, source) — добавить факт
- query_fact(key) — найти факт
- add_decision(topic, choice, rationale) — зафиксировать решение

## Procedural Memory

### Structure:
- `workflows.md` — процедурные workflow (RPXV, handoff, reflection)
- `patterns.md` — кодовые паттерны и best practices
- `rituals.md` — ритуалы перехода между этапами

### Operations:
- get_workflow(name) — получить workflow
- apply_pattern(context) — применить паттерн
- validate_ritual(ritual_name) — проверить выполнение ритуала

## Integration Points

### With RPXV Cycle:
- Research → update Working Memory + add facts to Semantic
- Planning → add plans to Procedural Memory
- Execution → use patterns из Procedural
- Verification → fix facts в Semantic Memory
- Reflection → archive в Semantic + improve Procedural
