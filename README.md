# super-oc-cli

Agentic CLI harness with multi-phase pipelines, provider routing, context epochs, and cost tracking. Wraps [OpenClaude CLI](https://github.com/Gitlawb/openclaude) with local LLM orchestration. Extracted from [anomalyco/opencode](https://github.com/anomalyco/opencode) architectural patterns.

## Install

```bash
git clone https://github.com/pookNast/super-oc-cli.git
cd super-oc-cli
bash oc-install.sh
```

This creates `~/.super-oc/` with libs, configs, and symlinks `oc-start` to `~/.local/bin/`.

### Requirements

- bash 4.4+, jq, tmux, curl
- [Ollama](https://ollama.com) with at least one model pulled
- [OpenClaude CLI](https://github.com/Gitlawb/openclaude) (`openclaude` in PATH)

GPU optional — the installer auto-detects NVIDIA GPUs and tunes accordingly.

## Quick Start

```bash
# Interactive mode (default — watchdog loop)
oc-start                          # uses model_default from config
oc-start llama3.2                 # override model
oc-start --bare --no-mcp          # minimal mode

# Pipeline mode — agentic 4-phase loop
oc-start --pipeline               # research → plan → implement → verify
oc-start --pipeline --agent explorer

# Debug
oc-start --dry-run                # print launch script without executing
```

## Configuration

All config lives in `~/.super-oc/config.json`. Edit to customize:

```json
{
  "model_default": "qwen2.5:7b",
  "ollama_port": 11434,
  "gateway_port": 8400,
  "gateway_enabled": true,
  "mcp_enabled": true,
  "mcp_servers": [],
  "extra_dirs": [],
  "skip_permissions": true
}
```

### Config Reference

| Field | Default | Description |
|-------|---------|-------------|
| `model_default` | `qwen2.5:7b` | Model to load when no arg given |
| `model_aliases` | `{"fast":"qwen2.5:7b"}` | Short names → full model IDs |
| `model_scripts` | `{}` | Model name → startup script path |
| `ollama_port` | `11434` | Ollama API port |
| `gateway_port` | `8400` | Optional gateway proxy port |
| `gateway_enabled` | `true` | Try gateway before direct Ollama |
| `mcp_enabled` | `true` | Enable MCP server management |
| `mcp_config` | `~/.mcp.json` | MCP config file path |
| `mcp_servers` | `[]` | Array of `{name, health_url, start_cmd, stop_cmd}` |
| `extra_dirs` | `[]` | Additional dirs to pass as `--add-dir` |
| `extra_oc_flags` | `""` | Extra flags appended to openclaude command |
| `skip_permissions` | `true` | Pass `--dangerously-skip-permissions` |
| `tmux_session` | `"oc"` | tmux session name |
| `work_dir` | `~/.super-oc/workspace` | Working directory for OpenClaude |
| `max_output_tokens` | `16384` | Max output tokens per turn |
| `context_window` | `262144` | Context window size |
| `auto_compact_threshold` | `60` | Auto-compact at this % |
| `node_max_old_space` | `4096` | Node.js heap (MB) — auto-tuned by installer |
| `node_semi_space` | `64` | Node.js semi-space (MB) |
| `uv_threadpool_size` | `4` | libuv threads |
| `max_tool_concurrency` | `8` | Parallel tool calls |

### MCP Servers

Add custom MCP servers to config:

```json
{
  "mcp_servers": [
    {
      "name": "my-mcp",
      "health_url": "http://localhost:3101/health",
      "start_cmd": "bash ~/bin/my-mcp.sh start",
      "stop_cmd": "bash ~/bin/my-mcp.sh stop"
    }
  ]
}
```

### Custom Model Scripts

Map models to startup scripts for non-Ollama setups:

```json
{
  "model_scripts": {
    "my-custom-model": "~/scripts/start-my-model.sh"
  }
}
```

## Architecture

9 bash libraries providing:

| Library | Purpose |
|---------|---------|
| `oc-config.sh` | Config loader with built-in defaults, tilde expansion, hardware detection |
| `oc-engine.sh` | Bounded agentic step loop with MAX_STEPS, needsContinuation, overflow detection |
| `oc-routes.sh` | Provider route abstraction — Ollama, gateway, Anthropic, OpenAI with fallback chains |
| `oc-agents.sh` | Agent profiles with step budgets, @mention dispatch, CLI selection |
| `oc-epochs.sh` | Context epochs — immutable baselines per agent tenure, snapshot diffs |
| `oc-compaction.sh` | Auto-compaction at configurable threshold with keep-last-N strategy |
| `oc-permissions.sh` | Wildcard permission engine with deny-overrides, multi-effect model |
| `oc-tools.sh` | Scoped MCP tool registry with lifetime tokens, staleness detection, output bounding |
| `oc-cost.sh` | Per-model cost tracking, VRAM monitoring, session summaries |

## Pipeline Phases

Default pipeline (configurable via `~/.super-oc/config/pipeline.json`):

| Phase | Agent | Model | Steps | Cost |
|-------|-------|-------|-------|------|
| Research | explorer | local model | 15 | FREE |
| Plan | planner | claude-sonnet (API) | 10 | 1x |
| Implement | builder | local model | 30 | FREE |
| Verify | reviewer | claude-opus (API) | 10 | 5x |

## Example Configs

### Minimal (CPU + Ollama)

```json
{
  "model_default": "llama3.2:3b",
  "gateway_enabled": false,
  "mcp_enabled": false,
  "node_max_old_space": 2048,
  "max_tool_concurrency": 2
}
```

### Full (GPU + MCP + Gateway)

```json
{
  "model_default": "qwen2.5:32b",
  "gateway_enabled": true,
  "gateway_port": 8400,
  "mcp_enabled": true,
  "mcp_config": "~/.mcp.json",
  "mcp_servers": [
    {"name": "homelab-mcp", "health_url": "http://localhost:3101/health", "start_cmd": "bash ~/bin/homelab-mcp.sh start"}
  ],
  "extra_dirs": ["~/notes"],
  "node_max_old_space": 8192,
  "max_tool_concurrency": 8
}
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `FATAL: Cannot find oc-config.sh` | Run `bash oc-install.sh` first |
| `jq: command not found` | Install jq: `sudo apt install jq` or `brew install jq` |
| Model not switching | Check `ollama_port` in config matches your Ollama instance |
| Gateway fallback every time | Set `gateway_enabled: false` if you don't use a proxy |
| MCP errors on startup | Set `mcp_servers: []` or `mcp_enabled: false` |
| tmux session name collision | Change `tmux_session` in config |
| High memory usage | Lower `node_max_old_space` and `max_tool_concurrency` |

## Env Vars

| Variable | Description |
|----------|-------------|
| `SUPER_OC_HOME` | Override install dir (default: `~/.super-oc`) |
| `OPENAI_BASE_URL` | Skip gateway detection, use this URL directly |
| `ANTHROPIC_API_KEY` | Required for pipeline verify phase (Opus) |

## Built With

- Bash / jq
- Claude Code (Anthropic)
- Ollama
- tmux
- Linux

## License

MIT
