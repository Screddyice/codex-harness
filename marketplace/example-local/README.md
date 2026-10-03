# Local Codex Marketplace Stub

This directory shows the structure for a local Codex plugin marketplace.

Register it with:

```bash
codex plugin marketplace add /absolute/path/to/marketplace/example-local
```

Codex marketplaces use `.agents/plugins/marketplace.json`. Each plugin entry points to
a plugin directory containing `.codex-plugin/plugin.json`.

Use a local marketplace when you want in-house plugins available on your own machine
without publishing them publicly.
