# Milestone Contract — OpenCode Feature Extraction into OpenClaude

**Generated:** 2026-06-07
**Owner:** pookNast + Claude Code
**Source repo:** github.com/anomalyco/opencode (TypeScript monorepo)
**Target:** github.com/Gitlawb/openclaude + `~/bin/oc-start`
**Review cadence:** Weekly
**Budget ceiling:** $6/session (Sonnet swarm agents, Haiku research)
**Runtime estimate:** 3 waves, ~90 min per wave
**VRAM Constraint:** Sub-agent spawning OFF table — sequential state machine only

---

## GEM Findings: OpenCode Agent Mode System

### GEM-1: Agent Mode Model Binding (AgentV2.Info)

Each agent mode binds to a specific model. When agent mode switches, model switches. No parallel sub-agents — sequential state machine.

```typescript
// Source: packages/core/src/agent.ts
AgentV2.Info = {
  id: ID,                             // "explorer", "planner", "builder", "reviewer"
  model: ModelV2.Ref | undefined,    // ← BOUND to this model
  request: ProviderV2.Request,        // headers, body overrides
  system: string | undefined,         // mode-specific system prompt
  description: string | undefined,
  mode: "subagent" | "primary" | "all",   // visibility gate
  hidden: boolean,
  steps: PositiveInt | undefined,     // ← STEP BUDGET — handoff when exhausted
  permissions: PermissionSchema.Ruleset, // per-mode permissions
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

### GEM-4: Agentic Loop Pattern

Sequential phase transitions, NOT parallel sub-agents:

```
Research (cheap model, steps: 15)
  ↓ [budget exhausted / phase complete]
Plan (expensive model, steps: 10)
  ↓
Implement (cheap model, steps: 30)
  ↓
Verify (expensive model, steps: 10)
```

**RLM Mapping**:
| RLM Phase | Agent Mode | Model | Steps |
|-----------|-----------|-------|-------|
| A0-A2 (Research) | explorer | qwen3.6-27b (local) | 15 |
| B0-B5 (PRD/Plan) | planner | claude-sonnet | 10 |
| C0-C1 (Implement) | builder | qwen3.6-27b (local) | 30 |
| D0-D3 (Verify) | reviewer | claude-opus | 10 |

**Cost math** (Max plan): Opus ~5x Sonnet per token. Local Qwen3.6-27b = FREE. Route cheap work through local model.

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

## Source arch Reference

OpenCode structured `packages/core` (session, agents, tools, permissions), `packages/llm` (provider routes, model catalog), and `packages/tui` (Solid.js terminal UI).

| OpenCode Component | Key Files | Extraction Target |
|-------------------|-----------|-------------------|
| Agentic Loop | `core/src/session/runner/llm.ts` | oc-start step engine |
| Route Abstraction | `llm/src/route/client.ts` | Provider switching layer |
| Agent Registry | `core/src/agent.ts` | Agent profile system |
| Permission Ruleset | `core/src/permission.ts` | warden-mcp integration |
| Context Epochs | `core/src/session/context-epoch.ts` | Context isolation |
| Tool Registry | `core/src/tool/registry.ts` | MCP tool scoping |
| Compaction | `core/src/session/compaction.ts` | Auto-compaction |
| Cost Tracking | `core/src/model.ts` | VRAM/token accounting |
| Agent Model Binding | `core/src/session/runner/model.ts` | Per-mode model routing |
| Config Agent Schema | `core/src/config/agent.ts` | Config file model binding |

---

## Gaps in Current OpenClaude

| Gap | Impact | OpenCode Solution |
|-----|--------|-------------------|
| No agent mode model binding | Can't route work to correct model | AgentV2.Info binds model per mode |
| No step budgets | No automatic handoff | `steps` field enforces phase transitions |
| No Context Epoch tracking | Agent transitions not persisted | Durable epoch journal per session |
| Coordinator mode incomplete | No agent state machine | `feature('COORDINATOR_MODE')` needs flesh |
| No `/loop` skill | No agentic pipeline runner | Pipeline definition → sequential phases |

---

## Contract Terms

Each milestone **acceptance criteria** that must pass before marking complete.
Status key: `⬜ TODO` · `🔨 PROGRESS` · `✅ DONE` · `🚫 BLOCKED`

---

## Phase 1 — Agent Loop + Model Routing (Core Engine)

### M-1: Bounded Agentic Step Loop
**Priority:** P0 — Foundation
**Target:** 2026-06-14
**Status:** ⬜ TODO

| # | Deliverable | Acceptance Criteria |
|---|-------------|-------------------|
| 1.1 | Step engine with MAX_STEPS bound (configurable, default 25) | Loop terminates at limit, logs warning |
| 1.2 | `needsContinuation` flag — tool calls trigger next step | Multi-tool chains execute sequentially without user intervention |
| 1.3 | Overflow detection + auto-compaction trigger | When context exceeds threshold, compaction fires and loop retries |
| 1.4 | Interruption handling — clean abort of pending tool calls | Ctrl-C kills in-flight tools, persists partial state |
| 1.5 | Integration with oc-start watchdog loop | Step engine runs inside existing tmux session, watchdog wraps |

**Source:** `packages/core/src/session/runner/llm.ts:173-395`
**Agent:** Sonnet swarm
**Blocker:** None

---

### M-2: Route-Based Provider Abstraction
**Priority:** P0 — Foundation
**Target:** 2026-06-14
**Status:** ⬜ TODO

| # | Deliverable | Acceptance Criteria |
|---|-------------|-------------------|
| 2.1 | `Route<Body, Prepared>` interface ported to shell/config layer | Provider config file defines routes for Ollama, HiveMind, OpenAI-compat |
| 2.2 | Endpoint + auth resolution per route | Each route resolves base URL + auth (env var, static, none) |
| 2.3 | Model alias → route mapping in oc-start | `oc-start devstral` resolves correct provider route |
| 2.4 | Hot-swap: change model mid-session without restart | `@model glm` prompt triggers route switch at next turn boundary |
| 2.5 | Fallback chain: primary → secondary route on failure | If HiveMind :8400 down, falls back to Ollama :11434 |

**Source:** `packages/llm/src/route/client.ts:36-120`
**Agent:** Sonnet swarm
**Blocker:** None

---

### M-3: Agent Profile System (Primary + Subagent)
**Priority:** P1 — High Value
**Target:** 2026-06-21
**Status:** ⬜ TODO

| # | Deliverable | Acceptance Criteria |
|---|-------------|-------------------|
| 3.1 | Agent profile schema: name, mode (primary/subagent), model, tools, system prompt, steps | JSON/YAML config per agent in `~/.openclaude/agents/` |
| 3.2 | Primary agents shown in selection UI / CLI flag | `oc-start --agent coder` selects agent profile |
| 3.3 | Subagent invocation via `@mention` in prompts | `@explore find auth middleware` spawns subagent with explore profile |
| 3.4 | Agent-scoped tool permissions | Each agent profile declares allowed/denied tool patterns |
| 3.5 | Agent context isolation — separate system prompt per agent | Switching agent resets system context without losing conversation history |

**Source:** `packages/core/src/agent.ts:11-72`, `packages/core/src/session/prompt.ts:27-49`
**Agent:** Sonnet swarm
**Blocker:** M-2 (route abstraction needed for model binding)

---

## Phase 2 — Context Management + Safety

### M-4: Context Epochs
**Priority:** P1 — Prevents context corruption
**Target:** 2026-06-21
**Status:** ⬜ TODO

| # | Deliverable | Acceptance Criteria |
|---|-------------|-------------------|
| 4.1 | Epoch struct: baseline text + snapshot + source checksums | Epoch persists to session state file |
| 4.2 | Snapshot diff for context refresh | Only changed sources trigger mid-turn system message |
| 4.3 | Epoch fence on agent switch | New agent = new epoch, old baseline archived |
| 4.4 | Safe turn boundary enforcement | Context changes queue until current tool settlement completes |

**Source:** `packages/core/src/session/context-epoch.ts:42-100`, `CONTEXT.md`
**Agent:** Sonnet swarm
**Blocker:** M-1 (step loop defines turn boundaries)

---

### M-5: Auto-Compaction Engine
**Priority:** P1 — 256K context window management
**Target:** 2026-06-28
**Status:** ⬜ TODO

| # | Deliverable | Acceptance Criteria |
|---|-------------|-------------------|
| 5.1 | Token counting per turn (input + output + cache) | Token counts logged per step |
| 5.2 | Threshold trigger: compact at 80% context window | Automatic compaction fires, verified via log |
| 5.3 | Keep-last-N-tokens strategy with buffer headroom | Recent context preserved, old messages summarized/pruned |
| 5.4 | New epoch started post-compaction | Clean baseline, no stale snapshots |
| 5.5 | Manual trigger: `/compact` command | User can force compaction anytime |

**Source:** `packages/core/src/config/compaction.ts`, `packages/core/src/session/compaction.ts`
**Agent:** Sonnet swarm
**Blocker:** M-4 (epoch system needed)

---

### M-6: Permission Ruleset Engine
**Priority:** P2 — Security layer
**Target:** 2026-06-28
**Status:** ⬜ TODO

| # | Deliverable | Acceptance Criteria |
|---|-------------|-------------------|
| 6.1 | Wildcard action/resource matcher (`read/*`, `file.write`) | Pattern matching passes unit tests (10+ cases) |
| 6.2 | Multi-effect model: ask, allow, deny, once, always, reject | Each effect behaves correctly in isolation |
| 6.3 | Per-agent permission binding | Agent "explore" gets read-only; agent "coder" gets full access |
| 6.4 | warden-mcp integration | Permission checks route through warden with audit logging |
| 6.5 | Default-deny unknown agents | Unregistered agent gets zero tool access |

**Source:** `packages/core/src/permission.ts:1-120`
**Agent:** Sonnet swarm
**Blocker:** M-3 (agent profiles define permission scope)

---

## Phase 3 — Tool Infrastructure + Observability

### M-7: Scoped Tool Registry
**Priority:** P2 — MCP reliability
**Target:** 2026-07-05
**Status:** ⬜ TODO

| # | Deliverable | Acceptance Criteria |
|---|-------------|-------------------|
| 7.1 | Tool registration with lifetime token | Token-based cleanup on MCP server disconnect |
| 7.2 | Identity-based staleness detection | Calling deregistered tool returns error, not silent failure |
| 7.3 | Dynamic register/unregister on MCP reconnect | homelab-mcp restart re-registers tools without session restart |
| 7.4 | Output bounding per tool call | Oversized tool output truncated with managed file fallback |

**Source:** `packages/core/src/tool/registry.ts:39-138`
**Agent:** Sonnet swarm
**Blocker:** M-6 (permissions gate tool access)

---

### M-8: Cost + Capacity Tracking
**Priority:** P3 — Observability
**Target:** 2026-07-05
**Status:** ⬜ TODO

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

| Wave | Milestones | Model | Estimated Runtime | Gate |
|------|-----------|-------|-------------------|------|
| W1 | M-1, M-2 | Sonnet swarm (3 agents) | ~90 min | Step loop runs 25-step chain with model hot-swap |
| W2 | M-3, M-4, M-5 | Sonnet swarm (3 agents) | ~90 min | Agent switch triggers new epoch + compaction |
| W3 | M-6, M-7, M-8 | Sonnet swarm (3 agents) | ~90 min | Permission-denied tool call logged to warden |

**Wave gate:** All deliverables in wave pass acceptance criteria before next wave starts.
**Retry escalation:** Attempt 1 Sonnet/60t → Attempt 2 Opus/80t
**Night queue eligible:** W2, W3 (no interactive debugging needed)

---

## Success Criteria

- [ ] `oc-start` runs bounded agentic loops (not just crash-restart watchdog)
- [ ] Model hot-swap works mid-session via `@model` mention
- [ ] Agent profiles with distinct tool permissions load from config
- [ ] Context epochs prevent corruption on agent/model switch
- [ ] Auto-compaction keeps 256K window from overflowing
- [ ] warden-mcp enforces permission rulesets per agent
- [ ] MCP tool registration survives server reconnect
- [ ] Session cost summary prints on exit
- [ ] Step budget exhaustion triggers automatic agent handoff
- [ ] Agent mode transitions visible in session log

---

## Risk Register

| Risk | Impact | Mitigation |
|------|--------|------------|
| OpenCode source TypeScript; oc-start is bash | High | Extract patterns, not code — reimplement in bash + jq/python |
| Context epoch concept too complex for shell | Medium | Simplify to file-based snapshots with checksum comparison |
| 256K compaction needs accurate token counting | Medium | Use Ollama `/api/show` tokenizer for approximate char count |
| Permission system overkill for local LLM | Low | Start with allow/deny only, add granular effects later |
| VRAM bottleneck blocks sub-agent spawning | Critical | Sequential state machine only — no parallel agents |
| Model routing latency on handoff | Medium | Cache resolved model per agent mode |
| Step budget too short causes premature handoff | Medium | Configurable per-mode, user override via `@continue` |
