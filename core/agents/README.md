# Agents

Reusable subagents invoked via the Task tool. Commands delegate repeated work (codebase investigation, Jira fetching, etc.) to these so each command stays focused and the shared logic improves in one place.

## How commands invoke an agent

```
Task(
  subagent_type: "codebase-investigator",
  description: "Investigate addin-fe for [[PROJ-5901]]",
  prompt: "{inputs per the agent's invocation contract}"
)
```

Before invoking, the command checks the agent exists:
```bash
[ -f "$WORKSPACE_ROOT/.claude/agents/{name}.md" ] && use-agent || use-inline-fallback
```

Every command that invokes an agent MUST have an inline fallback — agents are an optimization, not a dependency.

## Agents at v0.1.0

| Agent | Purpose | Callers |
|-------|---------|---------|
| `codebase-investigator` | Parallel investigation of a repo for a feature area. Returns similar features, file-placement recommendation, reusable components (by atomic level), API surface, interactive patterns, permissions. | `/clarify`, `/ticket`, `/verify`, `/qa`, `/build`, `/refactor`, `/review-pr` |
| `jira-context-loader` | Parallel Jira fetch — primary ticket + linked + epic siblings + subtasks + blockers. Normalizes MCP vs CLI output. | `/clarify`, `/ticket`, `/verify`, `/project-debug`, `/status` |
| `commit-drafter` | Draft a conventional commit message from a diff + ticket context. Respects the no-AI-attribution rule and 72-char subject limit. | `/pr`, `/queue` |
| `contract-verifier` | Compare TypeScript (or Zod/Go) types against swagger AND/OR a live API response. Catches FE/BFF/backend contract drift. Supports cross-repo consumer trace. | `/verify`, `/clarify` |

## Planned agents (next)

| Agent | Purpose | Likely callers |
|-------|---------|----------------|
| `repo-mapper` | Given a repo, map routes/handlers/types/DB signals. | `/project-context`, `/bootstrap` |
| `test-generator` | Generate unit tests following the repo's `testing-patterns.md`. | `/test`, `/verify` |
| `pr-reviewer` | Review a branch against repo conventions. | `/pr`, `/review-pr` |

Add any new agent here before committing — callers decide whether to adopt it.

## Agent-spec contract

Every agent file has:
1. **Frontmatter** — `name`, `description`, `model`, `tools` list
2. **Invocation contract** — exactly what inputs the caller passes
3. **Operating rules** — including "always parallelize" where applicable
4. **Output format** — a single structured markdown block the caller consumes
5. **Failure modes** — what the agent does when inputs are missing or tools fail

Keep agent prompts tight — they should be usable across many commands without modification.
