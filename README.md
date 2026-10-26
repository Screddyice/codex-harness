# codex-harness

`codex-harness` is a Codex-native developer harness for macOS and Linux workspaces.
It packages the useful parts of the shared agent setup around Codex's own configuration,
hooks, MCP registry, plugins, and `codex exec` interface.

The repository keeps Codex settings and plugins separate from Claude Code.
The optional cross-review hook invokes the installed Claude CLI through `llmjury`;
it does not install Claude settings or plugins.

## Current profile (2026-10-23)

The current profile uses stock Codex, ClaudeMem work state, Corpus retrieval, JEV
routing and the optional Claude ↔ Codex review hook. See
[the current profile](docs/current-harness.md) and
[global instructions](examples/AGENTS.md.global.example).

The config example mirrors the installed model/access defaults without account
state. Merge examples into existing files; do not overwrite unrelated settings.
Legacy scaffold and auto-push utilities remain optional and are not prerequisites.

## Client boundary

This repository is the Codex source of truth. It owns Codex configuration examples,
lifecycle hooks, `.codex-harness/` initialization, and Codex plugin marketplace examples.
Claude plugin manifests and Claude-only installers live in
[`claude-code-harness`](https://github.com/Screddyice/claude-code-harness).

Run `scripts/audit-client-boundary.sh` after changing plugin or installer files.

## What it provides

- `AGENTS.md` templates for workspace and project guidance.
- ClaudeMem work-state guidance; optional legacy `.codex-harness/` scaffolding.
- An optional cross-CLI Stop review hook plus legacy PR/review utilities.
- Read-only diagnostics for Codex, MCP startup, provider reachability, and hook registration.
- A resource-aware `qwen` launcher for local Codex and Qwen Code sessions.
- A Codex-only swarm runner that isolates bounded tasks in git worktrees.
- Example Codex config, hooks, MCP, and local plugin marketplace files.

## Install

```bash
git clone https://github.com/Screddyice/codex-harness.git
cd codex-harness

# Review and merge these files into the matching user configuration:
# examples/config.toml.example         -> ~/.codex/config.toml
# examples/hooks.json.example          -> ~/.codex/hooks.json
# examples/AGENTS.md.global.example     -> ~/.codex/AGENTS.md
# Edit placeholder paths and install the optional llmjury CLI before using its hook.
```

The install examples do not create accounts, connect OAuth services, or copy secret
values. Register MCP servers with `codex mcp add` and authenticate each server separately.

## Configuration

Codex reads user configuration from `~/.codex/config.toml`. Keep durable project rules in
`AGENTS.md`. Use `examples/config.toml.example` as a starting point and replace its trust
path before use.

Codex hooks receive a JSON event on stdin. The current `examples/hooks.json.example`
registers `llmjury review-hook --host codex` on Stop. Install `llmjury` separately,
merge the hook with existing entries and verify the command is available.

`examples/hooks.legacy.json.example` retains the older initializer, auto-push and
local-review profile for deliberate opt-in. It is not part of the current default.

The PR hook is inert unless `HARNESS_PR_OWNERS` names the GitHub owners it may handle.
It skips trunk, detached heads, repositories listed as excluded, and repositories without `origin`.

To keep the hooks, the local reviewer and the swarm out of a repository, list a fragment of
its origin URL or folder name in `~/.config/agent-harness/excluded-repos`, one per line, or
in `HARNESS_EXCLUDED_REPOS`. The list stays on your machine, so private client names never
enter this repository.

### Selected integration profile

The maintained profile covers Gmail, Google Calendar, Slack, browser and computer-use
tools, visualization, PDF and office document formats, template creation, and code
review. It also supports ClaudeMem, Corpus search, JEV, and the Node REPL through MCP.

Enable the corresponding entries in `~/.codex/config.toml` and authenticate each
service separately. The checked-in example keeps paths generic and never includes
credential values.

#### JEV routing and Superpowers

`[mcp_servers.jev]` starts `~/.local/bin/jev-mcp`. The guidance that tells Codex
when to call `jev_decide` sits between `jev-routing` markers in `~/.codex/AGENTS.md`.
It comes from `deploy/jev/routing.md` in your private deploy repository, and that repo's
installer writes both the server entry and the guidance block. The 2026-10-09
cleanup deleted the block, and Codex made no JEV calls until the installer was
rerun on 2026-10-11. After resetting `~/.codex`, rerun the installer:

```bash
python3 deploy/jev/install.py --runtime "$(readlink ~/.local/share/jev/current)" --node /opt/homebrew/bin/node
```

The guidance includes a batch rule: when the same judgment repeats across many
items, Codex works a few by hand, then writes a script. JEV answers each typed
question, and Codex handles only the items JEV marks for review. Every call is
logged to `~/.config/jev/usage.jsonl`.

The [Superpowers](https://github.com/obra/superpowers) plugin adds skills for
test-first work, systematic debugging, planning, and checking before claiming
success. Install it with `codex plugin add superpowers@openai-curated-remote`.
Superpowers ranks `AGENTS.md` and direct requests above its own skills.

## Quieter ClaudeMem capture

Use `scripts/configure-claudemem-capture.py` to opt into **summaries plus explicit
notes**. It retains request summaries and direct saved notes while suppressing
individual tool events, including unknown future connector names. Both observer
provider concurrency limits become six; the selected provider is preserved.

```bash
python3 scripts/configure-claudemem-capture.py check \
  --settings "$HOME/.claude-mem/settings.json" \
  --plugin-root /path/to/installed/claude-mem/13.34.2
```

Name the installed Codex plugin version directory. Repeat `--plugin-root` for
any additional active profiles sharing this memory worker. `check` is read-only
and exits nonzero when changes are needed or a build is unsupported. After
safely draining and stopping the memory worker, replace `check` with `apply`.
Keep sessions, hooks and editors stopped until apply finishes so they cannot
restart the worker or write through an already-open file. The installer resolves
the effective data directory from `CLAUDE_MEM_DATA_DIR` or the default settings;
if the named settings file is only a pointer, it reports the effective file to use.
It refuses to change a running worker, creates private backups, preserves unrelated
settings and credentials, and never starts or restarts it. Concurrent path changes
are preserved with exclusive file creation; recovery paths are reported if a
conflict prevents restoration. A failed restoration does not stop the remaining
files from being rolled back. Conflicting policy environment variables are
rejected; the actual worker and hook launch environments must agree with these
settings because ClaudeMem gives environment variables precedence.

This is a checksum-pinned local fix for ClaudeMem 13.34.2, not an automatic updater.
Before a plugin upgrade, verify equivalent wildcard support or review a compatible
patch: `*` alone is not a deny-all setting in an unpatched build. Do not apply the
patch to an unknown build. Summaries depend on the assistant's reported outcomes;
explicitly save critical decisions or results that need their own durable record.
After installation, verify a newly saved summary, explicit note and work-state
entry by reading each back; an accepted or queued response is insufficient.

## Diagnostics

Run this before changing a working Codex installation:

```bash
scripts/codex-diagnostics.sh
```

The command reports Codex version, config paths, hook targets, MCP startup status, and the
current repository's `AGENTS.md` and `.codex-harness/` state.
It does not print environment values or mutate configuration. Add `--probe` to send a small
request through the configured Codex provider.

Audit the installed wiring before launching the desktop app:

```bash
scripts/audit-codex-harness.sh /path/to/repository
```

The audit checks `~/.codex/hooks.json`, the enabled hook feature, per-repository Codex
state, and stale Claude-harness paths. It does not change user configuration. A successful
`codex-diagnostics.sh --probe` proves the configured request path can answer; it does not
prove that every MCP server initialized.

Recent Codex versions can persist lifecycle registrations in `config.toml` under
`[hooks.state]` instead of using a standalone `~/.codex/hooks.json`. The audit accepts
that plugin-managed form, reports when the harness hooks are not installed, and still
fails on stale Claude hook state.

### Desktop troubleshooting checkpoint

If the desktop app shows startup error codes, run `codex-diagnostics.sh` from a terminal and
compare the results after restarting the app. MCP registration and lifecycle hooks are separate
systems: an optional MCP can fail during startup while hooks continue to run. The diagnostics
classify MCP failures, hook wiring, and provider reachability separately. A healthy provider
probe does not clear an MCP startup failure.

## Optional legacy per-repository state

```bash
scripts/init-codex-harness.sh /path/to/repository
```

This older initializer is not needed for current ClaudeMem task tracking. If
explicitly selected, it creates this state only when it is missing:

```text
.codex-harness/
├── agents/context.json
├── config.json
├── features/{active.json,archive.json}
├── impact/{change-log.json,dependency-graph.json}
├── memory/{learned,episodic,semantic,procedural}/...
├── prd/analyst-prompts.json
├── session-briefing.md
└── sessions/.current-session-id
```

Generated working state stays ignored. Commit `session-briefing.md` when a project wants a
durable handoff.

## Local Qwen

`scripts/qwen` checks native macOS memory pressure, coordinates the shared compute lock,
records model residency through Ollama, and keeps the Codex config unchanged by passing
provider overrides on the command line. macOS and Ollama own RAM admission; the wrapper
does not maintain a second byte budget.

```bash
scripts/qwen
scripts/qwen codex
scripts/qwen 27b codex
scripts/qwen status
scripts/qwen stop
```

Use `--mcp none` for a disconnected session. The default `cmem` option requires
`CMEM_PRO_TOKEN` and only references the variable; it never writes the secret to a file.

## Codex swarm

The swarm runner dispatches bounded tasks to `codex exec` in isolated worktrees. Each worker
edits its worktree, reports a structured handoff, and lets the engine commit the branch.

```bash
scripts/swarm/install.sh
swarm run --workspace . --tasks tasks.json
swarm status RUN_ID
swarm clean RUN_ID
```

Task files use this shape:

```json
{
  "tasks": [
    {
      "id": "fix-parser",
      "files": ["src/parser.py"],
      "task": "Fix the parser and run its focused tests."
    }
  ]
}
```

The Codex worker is the only provider. Excluded repositories and dirty trees stay blocked by
default. Review each generated branch before folding it into project work.

## Verification

`main` is protected: changes land through a pull request with linear history, and
`scripts/verify.sh` is the gate the QA review bot runs before it approves or merges a PR
(configured in `.shawns-qa.toml`).

```bash
find scripts -name '*.sh' -print0 | xargs -0 bash -n
scripts/test-codex-local-diff-review.sh
scripts/test-shared-hooks.sh
scripts/test-track-branch-pr.sh
scripts/test-install-llmjury-orchestration.sh
scripts/test-codex-diagnostics.sh
scripts/test-swarm.sh
scripts/test-audit-codex-harness.sh
scripts/audit-codex-harness.sh /path/to/repository
git diff --check
```

The tests use temporary repositories and mocked CLIs. They do not send mail, mutate
production systems, call external accounts, or show desktop notifications. The kernel-zone
watchdog tests suppress notifications while exercising synthetic thresholds.

## Sanitization

This repository contains no credentials, OAuth tokens, private hosts, customer names,
account IDs, or machine-specific paths. Keep those boundaries intact when adding examples.
Test fixtures use placeholder owners and reviewers such as `example-owner` and
`reviewer-a`, never real GitHub handles or private repository names.

## License

[MIT](LICENSE)
