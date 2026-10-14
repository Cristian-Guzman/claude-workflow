# Agents

Reusable subagents invoked via the Task tool. Commands delegate repeated work (codebase investigation, Jira fetching, etc.) to these so each command stays focused and the shared logic improves in one place.

Agents live in core and are installed for every role. A role may add `roles/<role>/agents/*.md`; they install flat into `.claude/agents/` under the same collision rule (unique basenames across core + selected roles). A repo may override any agent with `{REPO_ROOT}/.claude/agents/<name>.md`, which takes precedence.

## How commands invoke an agent

```
Task(
  subagent_type: "codebase-investigator",
  description: "Investigate web-app for [[PROJ-5901]]",
  prompt: "{inputs per the agent's invocation contract}"
)
```

Before invoking, the command checks the agent exists:
```bash
[ -f "$WORKSPACE_ROOT/.claude/agents/{name}.md" ] && use-agent || use-inline-fallback
```

Every command that invokes an agent MUST have an inline fallback — agents are an optimization, not a dependency.

## Agents (7)

| Agent | Purpose | Callers |
|-------|---------|---------|
| `codebase-investigator` | Parallel investigation of a repo for a feature area. Returns similar features, file-placement recommendation, reusable components (by atomic level), API surface, interactive patterns, permissions. | `/clarify`, `/ticket`, `/verify`, `/qa`, `/build`, `/refactor`, `/review-pr`, `/cover` (cross tier) |
| `jira-context-loader` | Parallel Jira fetch — primary ticket + linked + epic siblings + subtasks + blockers. Normalizes MCP vs CLI output. | `/clarify`, `/ticket`, `/verify`, `/review-pr`, `/project-debug`, `/status`, `/log` (dedupe before minting) |
| `commit-drafter` | Draft a conventional commit message from a diff + ticket context. Respects the no-AI-attribution rule and 72-char subject limit. | `/pr-creation` |
| `contract-verifier` | Compare TypeScript (or Zod/Go) types against swagger AND/OR a live API response. Catches FE/BFF/backend contract drift. Supports cross-repo consumer trace. | `/verify`, `/clarify`, `/review-pr`, `/cover` (API mode), `/triage` (env-or-data vs real bug) |
| `verifier` | Goal-backward AC verification: gathers receipts per gate; never grades itself. Scoped `tools:` (no Write/Edit). | `/verify`, `/ticket` (final phase) |
| `pr-branch-reviewer` | Reviews the branch against `ticket-checklist.md` verbatim before `/pr-creation` hands off. Scoped `tools:`. | `/pr-creation` |
| `ui-fidelity` | Surface-aware design-fidelity check; reads `ui-fidelity-ledger.md` meta-lessons at step 0, hardens for live-data shapes. | `/clarify`, `/verify`, `/qa`, `/ui-fidelity`, `/learn` (ledger synthesis) |

Deferred: a `cluster-investigator` agent for parallel per-cluster reading in `/triage --batch` (the MVP reads clusters inline) — see `docs/roadmap.md`.

Add any new agent here before committing — callers decide whether to adopt it.

## Agent-spec contract

Every agent file has:
1. **Frontmatter** — `name`, `description`, `model`, `tools` list
2. **Invocation contract** — exactly what inputs the caller passes
3. **Operating rules** — including "always parallelize" where applicable
4. **Output format** — a single structured markdown block the caller consumes
5. **Failure modes** — what the agent does when inputs are missing or tools fail

Keep agent prompts tight — they should be usable across many commands without modification.
