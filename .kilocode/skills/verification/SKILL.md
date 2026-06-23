---
name: verification
description: Критика и проверка результатов перед финальной передачей
---
# Verification Protocol v2

## MCP Integration

**Sequential Thinking** — для структурированного анализа
**Grill Me** — для стресс-теста планов и решений

## Verification Checklist
1. ✅ Соответствие objective
2. ✅ Качество кода (clean code, best practices)
3. ✅ Security issues (OWASP Top 10)
4. ✅ Performance implications
5. ✅ Test coverage (если есть тесты)

## Output Format
```yaml
verification_report:
  status: PASS | FAIL | NEEDS_REVIEW
  checks:
    - name: objective_match
      passed: true
      notes: "..."
    - name: code_quality
      passed: true
      notes: "..."
```
