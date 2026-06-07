# Milestone Contract — OpenCode Feature Extraction into OpenClaude
**Generated:** 2026-06-07
**Owner:** pookNast + Claude Code
**Source repo:** github.com/anomalyco/opencode (TypeScript monorepo)
**Target:** github.com/Gitlawb/openclaude + `~/bin/oc-start`
**Review cadence:** Weekly
**Budget ceiling:** $6/session (Sonnet swarm agents, Haiku research)
**Runtime estimate:** 3 waves, ~90 min per wave

### Hardware Constraint
**VRAM bottleneck:** RTX 4090 (24GB) runs one model at a time. Sub-agent spawning is OFF the table — sequential state machine only. All agent mode transitions are serial handoffs, not parallel forks.

---

## GEM Findings: OpenCode Agent Architecture

Six architectural patterns extracted from source. These define the extraction targets.

### GEM-1: Agent Mode Model Binding

Each agent mode binds to a specific model. When agent mode switches, model switches. No parallel sub-agents — sequential state machine.

```typescript
// Source: packages/core/src/agent.ts
AgentV2.Info = {
  id: ID,                             // "explorer", "planner", "builder", "reviewer"
  model: ModelV2.Ref | undefined,     // ← BOUND to this model
  request: ProviderV2.Request,        // headers, body overrides
  system: string | undefined,         // mode-specific system prompt
  description: string | undefined,
  mode: "subagent" | "primary" | "all",   // visibility gate
  hidden: boolean,
  steps: PositiveInt | undefined,     // ← STEP BUDGET — handoff when exhausted
  permissions: PermissionSchema.Ruleset,  // per-mode permissions
}
```

**Key insight**: `steps` field is a step budget. When budget exhausted → handoff to next phase.

### GEM-2: Cross-Model Handoff Protocol

Agent mode switch = Context Epoch replacement = new model + new system prompt + same history.

```
AgentV2.select(newAgentID)
  → Context Epoch replacement (baseline-replacing transition)
  → New model resolved via SessionRunnerModel.resolve(session)
  → New system prompt rendered
  → Conversation history preserved
```

**Durable tracking**: Context Epoch durably records effective agent. Baseline System Context stored durably, reused across process restarts.

### GEM-3: Context Epoch Rules (from CONTEXT.md)

- Switching agent requests Context Epoch replacement
- Cross-agent replacement MUST complete before another provider turn
- Unavailable admitted context blocks replacement instead of exposing prior agent's baseline
- Compaction starts new Context Epoch (baseline replaced without preserving prior provider cache)
- Model/provider switch always starts new Context Epoch while preserving chronological history
- Context Epoch preparation retries until stable after optimistic revision mismatches

### GEM-4: Agentic Loop — Sequential Phase Transitions

NOT parallel sub-agents. Sequential phase transitions with step budgets:

```
Research (cheap model, steps: 15)
  ↓ [budget exhausted / phase complete]
Plan (expensive model, steps: 10)
  ↓
Implement (cheap model, steps: 30)
  ↓
Verify (expensive model, steps: 10)
```

**RLM Phase Mapping** (cost-optimized for Max plan):

| RLM Phase | Agent Mode | Model | Steps | Cost |
|-----------|-----------|-------|-------|------|
| A0-A2 (Research) | explorer | qwen3.6-27b (local) | 15 | FREE |
| B0-B5 (PRD/Plan) | planner | claude-sonnet | 10 | 1x |
| C0-C1 (Implement) | builder | qwen3.6-27b (local) | 30 | FREE |
| D0-D3 (Verify) | reviewer | claude-opus | 10 | 5x |

**Cost math**: Opus ~5x Sonnet per token. Local Qwen3.6-27b = FREE. Route cheap work through local model, reserve API tokens for judgment-intensive phases.

### GEM-5: Model Resolution Chain

```
SessionRunnerModel.resolve(session)
  → catalog.model.get(providerID, modelID)
  → fromCatalogModel() → AISDK routing (OpenAI/Anthropic/OpenAI-compatible)
  → withDefaults(model, route) → withVariant(model, variantID)
```

Supports variants via `withVariant(model, variantID)` — session can select non-default variant.

### GEM-6: What OpenCode Does NOT Do

- No parallel sub-agent spawning (sequential only)
- No process-level agent isolation (no forks, no subprocesses)
- One active agent mode at a time

---

## Source Architecture Reference

| OpenCode Component | Key Files | Extraction Target |
|-------------------|-----------|-------------------|
| Agentic Loop | `core/src/session/runner/llm.ts` | oc-start step engine |
| Route Abstraction | `llm/src/route/client.ts` | Provider switching layer |
| Agent Registry | `core/src/agent.ts` | Agent profile system |
| Agent Model Binding | `core/src/session/runner/model.ts` | Per-mode model routing |
| Config Agent Schema | `core/src/config/agent.ts` | Config file model binding |
| Permission Ruleset | `core/src/permission.ts` | warden-mcp integration |
| Context Epochs | `core/src/session/context-epoch.ts` | Context isolation |
| Tool Registry | `core/src/tool/registry.ts` | MCP tool scoping |
| Compaction | `core/src/session/compaction.ts` | Auto-compaction |
| Cost Tracking | `core/src/model.ts` | VRAM/token accounting |

---

## Gaps in Current OpenClaude

| Gap | Impact | OpenCode Solution |
|-----|--------|-------------------|
| No agent mode model binding | Can't route work to correct model | AgentV2.Info binds model per mode |
| No step budgets | No automatic handoff between phases | `steps` field enforces phase transitions |
| No Context Epoch tracking | Agent transitions not persisted, context corruption risk | Durable epoch journal per session |
| Coordinator mode incomplete | No agent state machine | `feature('COORDINATOR_MODE')` needs flesh |
| No `/loop` skill | No agentic pipeline runner | Pipeline definition → sequential phases |

---

## Contract Terms

Each milestone has **acceptance criteria** that must pass before marking complete.
Status key: `⬜ TODO` · `🔨 IN PROGRESS` · `✅ DONE` · `🚫 BLOCKED`

---

## Phase 1 — Agent Loop + Model Routing (Core Engine)

### M-1: Bounded Agentic Step Loop
**Priority:** P0 — Foundation
**Target:** 2026-06-14
**Status:** ✅ DONE (2026-06-07)

| # | Deliverable | Acceptance Criteria |
|---|-------------|-------------------|
| 1.1 | Step engine with MAX_STEPS bound (configurable, default 25) | Loop terminates at limit, logs warning |
| 1.2 | `needsContinuation` flag — tool calls trigger next step | Multi-tool chains execute sequentially without user intervention |
| 1.3 | Overflow detection + auto-compaction trigger | When context exceeds threshold, compaction fires and loop retries |
| 1.4 | Interruption handling — clean abort of pending tool calls | Ctrl-C kills in-flight tools, persists partial state |
| 1.5 | Integration with oc-start watchdog loop | Step engine runs inside existing tmux session, watchdog wraps it |

**Source:** `packages/core/src/session/runner/llm.ts:173-395`
**Agent:** Sonnet swarm
**Blocker:** None

---

### M-2: Route-Based Provider Abstraction
**Priority:** P0 — Foundation
**Target:** 2026-06-14
**Status:** ✅ DONE (2026-06-07)

| # | Deliverable | Acceptance Criteria |
|---|-------------|-------------------|
| 2.1 | `Route<Body, Prepared>` interface ported to shell/config layer | Provider config file defines routes for Ollama, HiveMind, OpenAI-compat |
| 2.2 | Endpoint + auth resolution per route | Each route resolves base URL + auth (env var, static, none) |
| 2.3 | Model alias → route mapping in oc-start | `oc-start devstral` resolves to correct provider route |
| 2.4 | Hot-swap: change model mid-session without restart | `@model glm` in prompt triggers route switch at next turn boundary |
| 2.5 | Fallback chain: primary → secondary route on failure | If HiveMind :8400 down, falls back to Ollama :11434 |

**Source:** `packages/llm/src/route/client.ts:36-120`
**Agent:** Sonnet swarm
**Blocker:** None

---

### M-3: Agent Profile System with Step Budgets
**Priority:** P1 — High Value
**Target:** 2026-06-21
**Status:** ✅ DONE (2026-06-07)

| # | Deliverable | Acceptance Criteria |
|---|-------------|-------------------|
| 3.1 | Agent profile schema: name, mode, model, tools, system prompt, **steps** | JSON/YAML config per agent in `~/.openclaude/agents/` |
| 3.2 | Primary agents shown in selection UI / CLI flag | `oc-start --agent coder` selects agent profile |
| 3.3 | Subagent invocation via `@mention` in prompts | `@explore find auth middleware` spawns subagent with explore profile |
| 3.4 | Agent-scoped tool permissions | Each agent profile declares allowed/denied tool patterns |
| 3.5 | Agent context isolation — separate system prompt per agent | Switching agent resets system context without losing conversation history |
| 3.6 | Step budget exhaustion → automatic handoff to next agent | Explorer (15 steps) → Planner transition fires without user intervention |

**Source:** `packages/core/src/agent.ts:11-72`, `packages/core/src/session/prompt.ts:27-49`
**Agent:** Sonnet swarm
**Blocker:** M-2 (route abstraction needed for model binding)

---

## Phase 2 — Context Management + Safety

### M-4: Context Epochs
**Priority:** P1 — Prevents context corruption
**Target:** 2026-06-21
**Status:** ✅ DONE (2026-06-07)

| # | Deliverable | Acceptance Criteria |
|---|-------------|-------------------|
| 4.1 | Epoch struct: baseline text + snapshot + source checksums | Epoch persists to session state file |
| 4.2 | Snapshot diff on context refresh | Only changed sources trigger mid-turn system message |
| 4.3 | Epoch fence on agent switch | New agent = new epoch, old baseline archived |
| 4.4 | Safe turn boundary enforcement | Context changes queue until current tool settlement completes |
| 4.5 | Durable epoch journal | Agent mode transitions logged with timestamps for audit trail |

**Source:** `packages/core/src/session/context-epoch.ts:42-100`, `CONTEXT.md`
**Agent:** Sonnet swarm
**Blocker:** M-1 (step loop defines turn boundaries)

---

### M-5: Auto-Compaction Engine
**Priority:** P1 — 256K context window management
**Target:** 2026-06-28
**Status:** ✅ DONE (2026-06-07)

| # | Deliverable | Acceptance Criteria |
|---|-------------|-------------------|
| 5.1 | Token counting per turn (input + output + cache) | Token counts logged per step |
| 5.2 | Threshold trigger: compact at 80% of context window | Automatic compaction fires, verified via log |
| 5.3 | Keep-last-N-tokens strategy with buffer headroom | Recent context preserved, old messages summarized or pruned |
| 5.4 | New epoch started post-compaction | Clean baseline, no stale snapshots |
| 5.5 | Manual trigger: `/compact` command | User can force compaction at any time |

**Source:** `packages/core/src/config/compaction.ts`, `packages/core/src/session/compaction.ts`
**Agent:** Sonnet swarm
**Blocker:** M-4 (epoch system needed)
**Note:** oc-start already sets `CLAUDE_CODE_AUTO_COMPACT_THRESHOLD=60` — this milestone adds epoch-aware compaction on top.

---

### M-6: Permission Ruleset Engine
**Priority:** P2 — Security layer
**Target:** 2026-06-28
**Status:** ✅ DONE (2026-06-07)

| # | Deliverable | Acceptance Criteria |
|---|-------------|-------------------|
| 6.1 | Wildcard action/resource matcher (`read/*`, `file.write`) | Pattern matching passes unit tests for 10+ cases |
| 6.2 | Multi-effect model: ask, allow, deny, once, always, reject | Each effect behaves correctly in isolation |
| 6.3 | Per-agent permission binding | Agent "explore" gets read-only; agent "coder" gets full access |
| 6.4 | warden-mcp integration | Permission checks route through warden for audit logging |
| 6.5 | Default-deny for unknown agents | Unregistered agent gets zero tool access |

**Source:** `packages/core/src/permission.ts:1-120`
**Agent:** Sonnet swarm
**Blocker:** M-3 (agent profiles define permission scope)

---

## Phase 3 — Tool Infrastructure + Observability

### M-7: Scoped Tool Registry
**Priority:** P2 — MCP reliability
**Target:** 2026-07-05
**Status:** ✅ DONE (2026-06-07)

| # | Deliverable | Acceptance Criteria |
|---|-------------|-------------------|
| 7.1 | Tool registration with lifetime token | Token-based cleanup on MCP server disconnect |
| 7.2 | Identity-based staleness detection | Calling a deregistered tool returns error, not silent failure |
| 7.3 | Dynamic register/unregister on MCP reconnect | homelab-mcp restart re-registers tools without session restart |
| 7.4 | Output bounding per tool call | Oversized tool output truncated with managed file fallback |

**Source:** `packages/core/src/tool/registry.ts:39-138`
**Agent:** Sonnet swarm
**Blocker:** M-6 (permissions gate tool access)

---

### M-8: Cost + Capacity Tracking
**Priority:** P3 — Observability
**Target:** 2026-07-05
**Status:** ✅ DONE (2026-06-07)

| # | Deliverable | Acceptance Criteria |
|---|-------------|-------------------|
| 8.1 | Per-model cost schema: input/output/cache token prices | Config file with pricing for each model alias |
| 8.2 | Per-session token accumulator | Running total displayed via `/cost` command |
| 8.3 | VRAM utilization proxy for local models | Ollama API polled for memory usage, logged per turn |
| 8.4 | Session cost summary on exit | Total tokens, estimated cost, VRAM peak printed at session end |

**Source:** `packages/core/src/model.ts:24-35`
**Agent:** Sonnet swarm
**Blocker:** None (can run parallel with Phase 2)

---

## Wave Execution Plan

| Wave | Milestones | Model | Runtime | Gate |
|------|-----------|-------|---------|------|
| W1 | M-1, M-2 | Sonnet swarm (3 agents) | ~90 min | Step loop runs 25-step chain with model hot-swap |
| W2 | M-3, M-4, M-5 | Sonnet swarm (3 agents) | ~90 min | Agent switch triggers new epoch + compaction |
| W3 | M-6, M-7, M-8 | Sonnet swarm (3 agents) | ~90 min | Permission-denied tool call logged by warden |

**Wave gate:** All deliverables in wave pass acceptance criteria before next wave starts.
**Retry escalation:** Attempt 1 Sonnet/60t → Attempt 2 Opus/80t
**Night queue eligible:** W2, W3 (no interactive debugging needed)

---

## Success Criteria

- [ ] `oc-start` runs bounded agentic loops (not just crash-restart watchdog)
- [ ] Model hot-swap works mid-session via `@model` mention
- [ ] Agent profiles with distinct tool permissions load from config
- [ ] Step budget exhaustion triggers automatic agent handoff
- [ ] Agent mode transitions visible in session log (epoch journal)
- [ ] Context epochs prevent corruption on agent/model switch
- [ ] Auto-compaction keeps 256K window from overflowing
- [ ] warden-mcp enforces permission rulesets per agent
- [ ] MCP tool registration survives server reconnect
- [ ] Session cost summary prints on exit

---

## Risk Register

| Risk | Impact | Mitigation |
|------|--------|------------|
| OpenCode source is TypeScript; oc-start is bash | High | Extract patterns, not code — reimplement in bash + jq/python |
| VRAM bottleneck blocks sub-agent spawning | Critical | Sequential state machine only — no parallel agents (GEM-6) |
| Context epoch concept too complex for shell | Medium | Simplify to file-based snapshots with checksum comparison |
| 256K compaction needs accurate token counting | Medium | Use Ollama `/api/show` tokenizer or approximate by char count |
| Model routing latency on handoff | Medium | Cache resolved model per agent mode |
| Step budget too short causes premature handoff | Medium | Configurable per-mode, user override via `@continue` |
| Permission system overkill for local LLM | Low | Start with allow/deny only, add granular effects later |

---

## Changelog

| Date | Change |
|------|--------|
| 2026-06-07 | Master contract created — merged v1 (8 milestones) + v2 (GEM findings, step budgets, RLM mapping, gap analysis, expanded risks) |
| 2026-06-07 | W1 complete — M-1 (oc-engine.sh, 464 LOC) + M-2 (oc-routes.sh, 518 LOC) + 6 config files |
| 2026-06-07 | W2 complete — M-3 (oc-agents.sh, 360 LOC) + M-4 (oc-epochs.sh, 474 LOC) + M-5 (oc-compaction.sh, 455 LOC) |
| 2026-06-07 | W3 complete — M-6 (oc-permissions.sh, 489 LOC) + M-7 (oc-tools.sh, 604 LOC) + M-8 (oc-cost.sh, 463 LOC) + costs.json |
