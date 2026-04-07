---
title: "Produce Content Batch"
priority: medium
brief_status: draft
run_state: idle
run_id: null
run_started_at: null
heartbeat_minutes: 60
created: null
last_run: null
next_eligible_at: null
measurement_due_at: null
deadline_at: null
approval_policy: auto
approved_for_next_run: null
template: content-batch@v1
parent: null
notify_chat_id: null
---

## Objective

Create and deliver a batch of content assets that match the business context, target channel, and current campaign priorities.

## Finish Criteria

- [ ] The batch scope and target surfaces are defined in the goal body.
- [ ] All content items in scope are produced and staged in their final destination.
- [ ] Each shipped asset is verified with proof under `proof/<goal-slug>/`.
- [ ] The scoreboard reflects batch progress and the next measurement checkpoint.

## Context

- Use `_context.md` for audience, offer, tone, and channel guidance.
- Capture the required asset count, delivery format, and due date in this goal file.
- Record dependencies such as images, approvals, or source material.

## Constraints

- Keep each asset aligned with the stated audience and offer.
- Do not mark content done until it is verified in its destination or staging surface.
- Pause the goal if required inputs or approvals are missing.

## Scoreboard

| Metric | Value | Updated |
|--------|-------|---------|
| Assets planned | 0 | - |
| Assets shipped | 0 | - |
| Assets verified | 0 | - |

## Run Log

## Runbook (goal-specific)
