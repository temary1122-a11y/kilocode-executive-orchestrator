---
name: model-router
description: Интеллектуальный выбор моделей для разных этапов и задач
---
# Model Router Protocol

## Routing Rules

| Stage | Free Models (Kilo Gateway) | Paid Models |
|-------|---------------------------|-------------|
| Research | minilm, phi3 | claude-opus, gpt-4 |
| Planning | minilm, gemma | claude-sonnet |
| Coding | gemma, qwen | claude-sonnet, deepseek-v3 |
| Verification | gemma, minilm | o3-mini, gemini-pro |

## Как использовать

### 1. При создании handoff-контракта:
```yaml
model_preference: "<model_id>" # явно указать
# или
model_preference: "auto" # использовать router
```

### 2. Router Logic:
```
IF task.type = research AND complexity > 0.7:
  SELECT claude-opus
ELIF task.type = coding AND cost_sensitive:
  SELECT kilo-auto/free
ELIF task.type = verification:
  SELECT o3-mini
ELSE:
  SELECT claude-sonnet
```

## Cost-Aware Selection
- Track tokens per $10 budget
- Fallback chain: premium → standard → free
- Log model usage в decisions.md