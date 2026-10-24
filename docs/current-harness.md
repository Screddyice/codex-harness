# Current harness profile — 2026-10-23

The checked-in current profile follows the installed stock host runtime, with
ClaudeMem task state, Corpus retrieval, JEV routing and optional cross-CLI review.
It is a portable template, not a backup of private account state.

## Instructions and task state

Read the global host instructions, workspace instructions and nearest repository
instructions. Resolve the Git root and origin before choosing an organization or
account. Preserve unrelated working-tree changes and tenant boundaries.

Read ClaudeMem lists with `includeClosed=true`; use one named list per task and
record scope, evidence, decisions and next steps. Close only verified work. Native
host memory and ClaudeMem are distinct; do not edit generated memory or publish
shared context without the user's request.

Retrieve Corpus lessons before unfamiliar work, costly-to-undo actions, unexplained
failures or retrying a failed approach. Cite applied lesson row IDs. Corpus health
work is separate from operational lesson retrieval.

Use JEV for bounded semantic decisions, not writing or arithmetic. Keep confidential
or unapproved personal data out of its external requests. Preserve probabilities
and receipts; it never grants permission for external actions. The full routing
block is in the global instruction example.

## Optional cross-CLI review

Install the `llmjury` CLI separately and confirm `llmjury review-hook --help` works.
The example registers `llmjury review-hook --host codex` as a Stop hook with a
600-second timeout. The other CLI reviews uncommitted changes: first against HEAD,
then against the previous session snapshot. Review state lives under
`~/.llmjury/review-hook/`.

Clean trees, non-Git directories, excluded origins, nested calls and an explicit
`LLMJURY_CROSS_REVIEW=off` are skipped. A missing CLI, timeout or error allows the
turn to finish. Silence is not proof of approval. Supported findings still need
fixes and the repository's real checks. The hook never grants merge, deploy or
sending permission.

Merge hook entries into the active settings; do not overwrite unrelated hooks.
This repository does not vendor the review engine, ClaudeMem, Corpus, JEV or gstack.
Their installed versions and credentials are managed separately.

## Browser and verification

Prefer available connector/API tools, then the host browser surface when UI work
is needed. Read installed skill instructions and resolve symlinks before editing.
Run the repository's documented checks. A registered plugin or server is not proof
of a working connection; verify the specific runtime action before claiming it.

Retired feature/checkpoint scaffolding is not required. Existing optional utility
scripts remain for compatibility, but are not installed by the current profile.

## What stays local

Do not copy auth stores, `.env` files, tokens, account identifiers, private hostnames,
organization context, installed plugin caches, transcripts or memory databases.
Account-specific ClaudeMem login recovery and organization-specific context hooks
remain separate local services; the examples neither install nor modify them.

Global template: [`AGENTS.md.global.example`](../examples/AGENTS.md.global.example).

Codex reads `~/.codex/config.toml` and the optional `~/.codex/hooks.json`.
The example puts model/access settings at TOML root (not under `[features]`).
Its full-access/no-prompt values mirror the observed local profile; change them
before use when narrower access is appropriate. MCP examples use placeholders.
The older scaffold/auto-push hooks are in `hooks.legacy.json.example`; do not
install them just to enable cross-review.
