---
name: swarm-dispatch
description: "Fan 2+ independent bounded coding tasks out to parallel headless Codex workers. Each worker edits in an isolated git worktree; the engine commits; you review and fold."
---

# swarm — parallel Codex workers

Dispatch bounded tasks to headless `codex exec` workers so bounded tasks work
while this session continues. The
`swarm` engine creates a git worktree per task, workers edit only, the engine
commits, and you review and fold the branches you accept.

## When to use

- 2 or more INDEPENDENT, well-specified tasks that don't need this session's
  context and can be verified with tests/lint/build.
- You want them progressing in parallel while this Codex session keeps working.

Do NOT use for: judgment-heavy or sequenced work, RS21 repositories (the
engine refuses), or a single small task.

## Workflow

1. Ensure the working tree is committed — the engine refuses a dirty tree by
   default (workers branch from HEAD).
2. Write `tasks.json`: unique `id`, self-contained `task` brief (scope,
   acceptance, checks to run), optional advisory `files` scope hints (the
   engine warns on overlap between tasks). State in each brief
   "create/modify ONLY <files>; do not edit README or other files" —
   parallel workers otherwise both touch shared docs and collide at fold
   time. Ensure .gitignore covers build artifacts (worker checks generate
   them; the engine commits everything untracked).
3. Run with the terminal tool:

```bash
swarm run --workspace . --tasks tasks.json --via codex --json
```

   Exit codes: 0 = all tasks completed, 2 = partial, 3 = none. 2 is not an
   error — read the per-task statuses. `provider_limited` /
   `provider_unavailable` means the Codex CLI is unavailable or keeps failing
   fast; those tasks were skipped, never fatal.

4. Review: `swarm status <run-id>`; per branch inspect
   `git diff <base>..swarm/<run-id>/<task-id>` plus the handoff summary,
   checks, and blockers.
5. Fold accepted branches into the session branch with
   `git merge --squash swarm/<run-id>/<task-id>` and commit. Never push
   worker branches or open PRs from them.
6. `swarm clean <run-id>` removes worktrees and scratch branches; it refuses
   to delete unfolded or uncommitted work unless `--force`.

## Guardrails

- Defaults: 3 Codex workers, 4 total (`--max-total`). Worker CLIs are
  ~0.5GB each — do not raise the cap while local Ollama models are loaded.
- Workers run permission-scoped to their worktree with a scrubbed
  environment and prompts that forbid git writes, nested llmjury/local
  models, and subagents.
- A `blocked` task leaves its worktree uncommitted for inspection.
