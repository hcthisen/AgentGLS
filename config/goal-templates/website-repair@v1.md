---
title: "Repair Website Surface"
priority: high
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
template: website-repair@v1
parent: null
notify_chat_id: null
---

## Objective

Repair a broken website surface, restore the intended user experience, and verify that the production issue is actually resolved.

## Finish Criteria

- [ ] The broken page, flow, or component is identified with a reproducible failure case.
- [ ] The production change is applied or deployed to the intended surface.
- [ ] Verification proves the target path works after the change.
- [ ] Proof and any rollback notes are saved under `proof/<goal-slug>/`.

## Context

- Pull domain, stack, access path, and business impact from `_context.md`.
- Record the exact broken path, device constraints, and any error messages in the goal body.
- Note whether the repair is content, configuration, or code.

## Constraints

- Lock shared production surfaces before mutating them.
- Do not claim success based only on code changes; verify the live outcome.
- Pause the goal if the fix depends on unavailable credentials, approvals, or third-party support.

## Scoreboard

| Metric | Value | Updated |
|--------|-------|---------|
| Reproduced issue | no | - |
| Verified fix | no | - |
| Incidents remaining | 1 | - |

## Run Log

## Runbook (goal-specific)
