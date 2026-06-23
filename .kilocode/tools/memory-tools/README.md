# Memory Tools

PowerShell-утилиты для управления памятью Executive Orchestrator.

## Структура

```
.kilocode/tools/memory-tools/
├── scripts/    ← канонические реализации
├── tests/      ← Pester-тесты
└── README.md   ← этот файл
```

## Как использовать

Все скрипты вызываются через `memory-tools.ps1`:

```powershell
$mt = ".\.kilocode\tools\memory-tools\memory-tools.ps1"
& $mt add-task -Type memory -Priority p0 -Objective "..." -Agent orchestrator
& $mt log-decision -Topic "..." -Problem "..." -Choice "..."
& $mt task-dependency -Action validate
& $mt health-check
```

## Канонические пути

Все пути к памяти определены в `scripts/common.ps1`:

- `.kilocode/memory/tasks.jsonl` — реестр задач
- `.kilocode/memory/decisions.md` — лог решений
- `.kilocode/memory/decisions.jsonl` — структурированный лог решений
- `.kilocode/memory/state.json` — состояние системы
- `.kilocode/memory/checkpoints/` — чекпоинты
- `.kilocode/memory/context-enrichment/` — контекстные пакеты
- `.kilocode/memory/research-reports/` — исследовательские отчёты
- `.kilocode/memory/user-profile.jsonl` — профиль пользователя

## Доступные скрипты

| Скрипт | Назначение |
|--------|-----------|
| `add-task.ps1` | Создание задачи |
| `checkpoint-task.ps1` | Создание чекпоинта |
| `consolidate-results.ps1` | Консолидация результатов |
| `get-active-tasks.ps1` | Активные задачи |
| `get-current-task.ps1` | Текущая задача |
| `get-last-task.ps1` | Последняя задача |
| `get-recent-decisions.ps1` | Недавние решения |
| `health-check.ps1` | Проверка системы |
| `init-memory-tools.ps1` | Инициализация инфраструктуры |
| `memory-tools.ps1` | CLI-оркестратор |
| `record-decision.ps1` | Запись решения |
| `restore-checkpoint.ps1` | Восстановление чекпоинта |
| `suggest-tool.ps1` | Рекомендация инструментов |
| `task-dependency.ps1` | Управление зависимостями задач |
| `update-task-status.ps1` | Обновление статуса задачи |
| `user-profile.ps1` | Управление профилем пользователя |
| `agent-status.ps1` | Статус агентов |

## Статус

- Фаза 1 (чистка): ✅ Завершена — дубликаты удалены
- Фаза 2 (унификация): ✅ Завершена — canonical paths в common.ps1
- Фаза 3 (тестирование): 🔄 Pester-тесты частично покрывают agent-status и consolidate-results
