# Hermes plugins

Source of truth for files that are otherwise hand-deployed to the Hermes boxes and exist
nowhere else. A rebuilt box should be able to copy from here.

## `plugins/cmem` — the cmem memory provider

Deploy to `~/.hermes/plugins/cmem/` on each Hermes box, with `memory.provider: cmem` in
the box's `~/.hermes/config.yaml`.

Reads go to the hosted MCP `memory_search` so a box sees every device's memory, falling back
to the local worker's `/api/search` when the cloud is unreachable. Writes go to the **local**
worker on `127.0.0.1:37701`, which queues durably before any AI work and syncs to the hub, so
a worker restart loses nothing.

**One project per box.** The project is `CMEM_PROJECT` if set. Otherwise the plugin maps
the hostname through `CMEM_HOST_PROJECTS` (`host-a=hermes-a,host-b=hermes-b`), and any
unmapped host gets `hermes-<hostname>`. Set either variable in the box's environment, not in
this repository. Version 1 wrote every box to a single project `hermes`, and turned the
`cmem_remember` *category* into a project name, which left stray per-category projects.
`cmem_remember` accepts `user`, `project` and `agent`, plus any categories listed in
`CMEM_CATEGORIES`.

**Nothing is written at construction.** Every `hermes -z` one-shot builds a provider — the
corpus classifier and the compressor shim both do — and version 1 posted a `"session start"`
prompt in `initialize()`. That produced 912 empty sessions on the hub in a few days, which the
corpus ingest then tried to classify as learnings. A session now reaches the worker only when
something is remembered, or when a conversation with at least two user turns ends.

The bearer token is read from `CMEM_PRO_TOKEN`, else from `~/.hermes/cmem.env` (mode 600).
Never log it, and never store secret values in memory — locations only.

### Deploy

```bash
scp hermes/plugins/cmem/__init__.py <box>:~/.hermes/plugins/cmem/__init__.py
ssh <box> 'systemctl --user restart hermes-gateway'   # via hermesctl on src
```

Run `python3 -m pytest -q hermes/tests` after changing the plugin. The tests stub the Hermes
runtime and check the host and category settings.
