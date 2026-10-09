# Client boundary

`codex-harness` is the Codex source of truth. It owns Codex configuration examples,
Codex lifecycle hooks, `.codex-harness/` initialization, and Codex plugin marketplace
examples.

Claude Code has a separate source of truth in
[`Screddyice/claude-code-harness`](https://github.com/Screddyice/claude-code-harness).
Keep Claude plugin manifests and Claude-only installers there.

The shared machine exceptions remain explicit: ClaudeMem, TMN skills, gstack, and
the dedicated JEV/OpenRouter decision path. A repository split does not copy
credentials or silently install either client's plugins.
