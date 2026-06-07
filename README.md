# super-oc-cli — oc-start

Agentic CLI harness with multi-phase pipelines, provider routing, context epochs, and cost tracking. Extracted from [anomalyco/opencode](https://github.com/anomalyco/opencode) architectural patterns.

## Quick Start

```bash
# Interactive mode (default — simple watchdog)
oc-start                          # qwopus3.6 on local RTX 4090
oc-start devstral                 # switch model
oc-start glm --bare --no-mcp     # minimal mode

# Pipeline mode — agentic step loop
oc-start --pipeline               # research → plan → implement → verify
oc-start --pipeline --agent explorer
```

## Architecture

8 bash libraries (3,826 LOC, 158 functions) providing:

| Library | Purpose |
|---------|---------|
| `oc-engine.sh` | Bounded agentic step loop with MAX_STEPS, needsContinuation, overflow detection |
| `oc-routes.sh` | Provider route abstraction — Ollama, HiveMind, Anthropic, OpenAI with fallback chains |
| `oc-agents.sh` | Agent profiles with step budgets, @mention dispatch, CLI selection |
| `oc-epochs.sh` | Context epochs — immutable baselines per agent tenure, snapshot diffs |
| `oc-compaction.sh` | Auto-compaction at configurable threshold with keep-last-N strategy |
| `oc-permissions.sh` | Wildcard permission engine with deny-overrides, multi-effect model, warden-mcp integration |
| `oc-tools.sh` | Scoped MCP tool registry with lifetime tokens, staleness detection, output bounding |
| `oc-cost.sh` | Per-model cost tracking, VRAM monitoring, session summaries |

## Pipeline Phases

Default pipeline (`config/pipeline.json`):

| Phase | Agent | Model | Steps | Cost |
|-------|-------|-------|-------|------|
| Research | explorer | qwopus3.6 (local) | 15 | FREE |
| Plan | planner | claude-sonnet (API) | 10 | 1x |
| Implement | builder | qwopus3.6 (local) | 30 | FREE |
| Verify | reviewer | claude-opus (API) | 10 | 5x |

## Configuration

All config lives in `~/.openclaude/`:

```
~/.openclaude/
  routes.json          # Provider endpoints, auth, fallback chains
  pipeline.json        # Phase definitions with step budgets
  permissions.json     # Per-agent permission rulesets
  costs.json           # Per-model token pricing
  agents/
    explorer.json      # Read-only, local model
    planner.json       # Read + plan, API model
    builder.json       # Full access, local model
    reviewer.json      # Read + test, API model (Opus)
```

## Requirements

- bash 4.4+, jq
- Ollama with local models (RTX 4090 recommended)
- tmux
- OpenClaude CLI (`openclaude` in PATH)

## License

MIT
