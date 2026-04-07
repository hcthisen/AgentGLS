@AGENTS.md

## Claude-specific notes

- Use the working directory under `/opt/agentgls/runtime/<channel>/` so session continuity stays isolated by channel.
- One-shot and resume execution should go through the host provider adapter rather than an ad-hoc Claude command path.
- Keep all repo and GoalLoop policy in `AGENTS.md`.
