# Milestone Contract: super-oc-cli Generalization

## Architecture (LOCKED)
- Runtime: bash 4.4+ / jq 1.5+
- Install target: `~/.super-oc/` (XDG-friendly default)
- Config: JSON files in `~/.super-oc/`
- No new dependencies beyond bash, jq, curl, tmux

## Research Brief
The 8 libs + oc-start currently hardcode paths (`/home/pook/`), models (`qwopus3.6`), MCP servers (homelab-mcp, warden-mcp), hardware tuning (RTX 4090), and personal dirs (obsidian-vault). Generalization means: config-driven defaults, auto-detection where possible, graceful skip of optional infra.

---

## Wave 0: Foundation (installer + config system)

### M1: Config Schema + Loader
- Create `~/.super-oc/config.json` schema with defaults for: home_dir, lib_dir, model_default, gateway_port, ollama_port, mcp_servers[], extra_dirs[], node_options
- Add `_oc_config_load()` function to read config with jq, fall back to built-in defaults for every field
- **MUST**: All 8 libs resolve paths via config, not hardcoded strings
- **Verification**: `source oc-engine.sh && _oc_config_get home_dir` returns `~/.super-oc/`

### M2: oc-install.sh
- Creates `~/.super-oc/{lib,config,sessions,agents}/`
- Copies libs + default configs
- Symlinks `oc-start` to `~/.local/bin/` (or user-chosen prefix)
- Detects GPU via `nvidia-smi` — sets VRAM/node tuning accordingly, or safe defaults for CPU-only
- **MUST**: Fresh machine with bash+jq+tmux+ollama can `bash oc-install.sh && oc-start` successfully
- **Verification**: `rm -rf ~/.super-oc && bash oc-install.sh && ls ~/.super-oc/lib/oc-engine.sh`

## Wave 1: Decouple personal infra

### M3: Strip Hardcoded Paths
- Replace all `/home/pook/` references with config-resolved `$OC_HOME`
- Replace `~/openclaude-workspace/lib/` with `$OC_LIB_DIR` from config
- Remove `--add-dir /home/pook/obsidian-vault` — make it config `extra_dirs[]`
- **MUST**: `grep -r '/home/pook' lib/ bin/` returns zero matches
- **Verification**: `grep -rn 'home/pook' lib/ bin/oc-start | wc -l` == 0

### M4: MCP Servers Optional
- Wrap homelab-mcp, warden-mcp startup in config guard: only start if `mcp_servers` config lists them
- Default config ships with empty `mcp_servers[]`
- Existing users add their servers to config — no behavior change for them
- **MUST**: `oc-start --no-mcp` works (already does). Default config with empty mcp_servers also skips them.
- **Verification**: `oc-start` with default config produces no MCP-related errors

### M5: Model Defaults from Config
- `model_default` field in config replaces hardcoded `qwopus3.6-27b-v2`
- Model start scripts (start-qwopus36-mtp.sh, start-gemma4-26b.sh) become config `model_scripts{}` map
- Users without custom scripts fall through to plain `ollama run <model>`
- **MUST**: Changing `model_default` in config changes what `oc-start` (no args) launches
- **Verification**: Set `model_default: "llama3.2"` in config, run `oc-start --dry-run`, confirm model resolves to `llama3.2`

## Wave 2: Polish + docs

### M6: Hardware Auto-Detection
- Detect GPU model + VRAM via `nvidia-smi --query-gpu=name,memory.total --format=csv,noheader`
- Set NODE_OPTIONS, UV_THREADPOOL_SIZE, MAX_TOOL_USE_CONCURRENCY proportionally
- CPU-only fallback: conservative defaults (4GB node heap, 4 threads, 2 concurrency)
- **MUST**: No crashes on a machine without nvidia-smi
- **Verification**: `_oc_detect_hardware` on GPU machine returns valid JSON with gpu_name, vram_mb, tuning params

### M7: --dry-run Flag
- `oc-start --dry-run` prints the generated `/tmp/.oc-launch.sh` without executing
- Shows resolved config values, model, gateway, flags
- **MUST**: No side effects (no tmux session, no model switching, no MCP starts)
- **Verification**: `oc-start --dry-run 2>&1 | grep -c 'tmux'` == 0

### M8: README for Public Consumption
- Installation instructions (one-liner)
- Configuration reference (all config.json fields with defaults)
- Example configs: minimal (CPU + ollama), full (GPU + MCP + gateway)
- Troubleshooting section
- **MUST**: A stranger can install and run from the README alone
- **Verification**: README contains sections: Install, Config, Examples, Troubleshoot

---

## Success Criteria

### MUST (blocks ship)
- [ ] M1: Config loader with defaults for all fields
- [ ] M2: `oc-install.sh` works on clean machine
- [ ] M3: Zero hardcoded `/home/pook/` paths
- [ ] M4: MCP servers skip cleanly when unconfigured
- [ ] M5: Model default from config
- [ ] M8: README covers install → run for new users

### SHOULD (ship with known gaps)
- [ ] M6: Hardware auto-detection
- [ ] M7: --dry-run flag

### NICE (defer)
- [ ] Shell completions for oc-start flags
- [ ] `oc-start --doctor` to diagnose missing deps

## Risk Register

| Risk | Mitigation |
|------|-----------|
| Config migration breaks existing setup | M1 loader falls back to current hardcoded defaults when no config exists |
| nvidia-smi parsing varies across driver versions | M6 uses `--format=csv` which is stable; fallback to conservative defaults |
| Installer overwrites user customizations | M2 uses `cp -n` (no-clobber) for configs, always overwrites libs |

## Estimates
- Wave 0: 2 milestones (foundation)
- Wave 1: 3 milestones (decoupling)
- Wave 2: 3 milestones (polish)
- Total: 8 milestones across 3 waves
