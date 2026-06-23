# Task Template (Beads 2.0)

## Task Structure

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| task_id | string | yes | Unique identifier (task_[timestamp]) |
| type | enum | yes | research/coding/verification/execution |
| priority | enum | yes | p0 (critical)/p1 (high)/p2 (normal) |
| status | enum | yes | pending/in_progress/completed/blocked/failed |
| dependencies | array | no | List of task_id dependencies |
| assigned_agent | string | no | research-agent/coding-agent/etc |
| objective | string | yes | Clear, actionable goal |
| context_files | array | no | Files to read before work |
| constraints | array | no | Rules/limitations for agent |
| success_criteria | array | yes | Measurable outcomes |
| model_preference | string | no | Model ID or "auto" |
| created_at | ISO | yes | Creation timestamp |
| completed_at | ISO | no | Completion timestamp |
| error_log | string | no | If failed, why |

## Status Transitions
pending → in_progress → completed
pending → in_progress → blocked → in_progress → completed
pending → in_progress → failed