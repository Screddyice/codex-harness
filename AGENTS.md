# Codex Harness

This repository contains the Codex-native harness template. Keep examples free of
company names, credentials, hostnames, account IDs, and private project identifiers.

## Verification

Run before handoff:

```bash
find scripts -name '*.sh' -print0 | xargs -0 bash -n
scripts/test-codex-local-diff-review.sh
scripts/test-shared-hooks.sh
scripts/test-track-branch-pr.sh
scripts/test-install-llmjury-orchestration.sh
scripts/audit-codex-harness.sh /path/to/workspace
git diff --check
```

The audit is read-only. It checks the Codex config, hook registration, instruction files,
and per-repository scaffold without modifying the target workspace.

## Working Rules

- Preserve idempotence in initialization scripts.
- Prefer documented Codex-native surfaces: `AGENTS.md`, `.codex/config.toml`, hooks,
  skills, plugins, MCP, and `codex exec`.
- Keep Codex configuration changes idempotent and scoped to the harness.
- Do not modify a user's existing configuration unless the installation command names it.
- After the first commit on a work branch, run `scripts/track-branch-pr.sh` to push it
  and open a draft PR. Run it after later commits so review tracks ongoing progress.
- Never leave a committed work branch without a PR, and never self-merge it.

## Workspace root

On this machine the multi-org workspace is `~/projects` (not a single git repo). Harness
hooks install into user config (`~/.codex`) so they apply to any cwd under a workspace.
Workspace instructions live in `AGENTS.md`; org identity still comes from git `origin`.
Do not require re-installing the harness per org.
