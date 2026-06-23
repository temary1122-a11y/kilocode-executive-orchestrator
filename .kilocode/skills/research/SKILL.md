---
name: research
description: Глубокое исследование проекта, лучших практик, рисков и контекста перед планированием
---
# Research Protocol v2

## Workflow Steps
1. **Project Structure Analysis** — используй codebase_search с запросами: "architecture", "project structure"
2. **Pattern Discovery** — найди схожие решения в codebase
3. **Risk Assessment** — выяви проблемные зоны
4. **Best Practices Match** — сопоставь с известными паттернами

## Research Report Template
```yaml
task_id: <task_id>
findings:
  architecture: <структура проекта>
  entry_points: [<точки входа>]
  data_flow: <поток данных>
risks:
  - type: architectural | performance | security | maintenance
    severity: high | medium | low
    description: <описание>
recommendations:
  - pattern: <название паттерна>
    applicability: <насколько применимо>
    implementation: <краткое описание>
```

## Tools Priority
1. codebase_search — главное
2. glob — для навигации
3. grep — для поиска паттернов

## MCP Integration

**Tavily Search** (приоритет)
```
tavily-search query: "<техническая тема>"
```

**Context7 Documentation**
```
context7-search library: "<название библиотеки>" version: "<версия>"
```

**Playwright/Puppeteer**
Для интерактивного тестирования UI/веб-приложений
