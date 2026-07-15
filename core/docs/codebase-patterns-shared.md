<!-- last-updated: 2026-06-15 -->
# Shared Codebase Patterns (cross-repo)

Workspace-level patterns that apply to every repo, referenced by each repo's `codebase-patterns.md`. `/clarify`, `/build`, and `/refactor` honor these alongside the repo-specific file.

## Minimalism ladder (lazy-senior default)

_Source: philosophy adapted from the ponytail skill (DietrichGebert, MIT) — evaluated 2026-06-15; the philosophy was borrowed, the tool was not adopted. Reconciled to our hard rules below._

Before writing code, stop at the **first rung that holds** — take the highest applicable rung and move on; the first lazy solution that works is the right one:

1. **Does this need to exist at all?** Speculative need → skip it, say so in one line. (YAGNI)
2. **Does something here already do it?** Reuse the existing util/hook/component/service before building. (Rebuilding what already exists is our most common over-engineering mistake.)
3. **Stdlib / native platform feature covers it?** Use it — CSS over JS, a DB constraint over app code, `slices.Sort` over a hand-rolled sort.
4. **An already-installed dependency solves it?** Use it. Never add a new dep for what a few lines do.
5. **Can it be one line?** One line.
6. **Only then:** the minimum code that works.

Plus: no unrequested abstractions (no interface with one implementation, no factory for one product, no config for a value that never changes), no scaffolding "for later", deletion over addition, fewest files, shortest working diff.

**Lazy, not negligent — never simplify away:** input validation at trust boundaries, error handling that prevents data loss, security, accessibility, or anything the spec explicitly asked for.

### Reconciled to our rules (these OVERRIDE the ladder)

Where we deliberately diverge from ponytail's defaults:

1. **Tests are never optional.** Ignore ponytail's "trivial one-liners need no test / no frameworks, no fixtures." We always add tests (each repo's `testing-patterns.md` conventions); `/verify` Step 2.1 blocks on any modified source file without a matching test.
2. **Comments stay lean.** A kept simplification earns *at most* a non-obvious WHY comment, and only when genuinely surprising. **Never** the literal `ponytail:` prefix; **never** an "upgrade path / add-later" TODO in the comment — deferred work goes in the Jira ticket, not the code. **Never** put ticket numbers (`PROJ-XXXX`), section/spec refs (`§16`, `NEW-2`), AC refs (`AC3`), bug-letter labels (`Bug C`), or before→after history in a comment — git + the PR carry that. Default to no comment. Machine-enforced by the **Comment Hygiene Gate** (`/verify` §3.4 + `/pr` §5e, BLOCKING) and written into every repo's `codebase-patterns.md` § "Code comment hygiene".
3. **UI fidelity beats "use the platform".** Rung 3 is for logic/stdlib — NOT for swapping a design-system / atomic component for a native control (`<input type="date">`) that can't be styled to the visual target or verified for a11y/i18n. Keep the component library; match the visual target, then iterate.
4. **"Second caller" is usually the default here.** Our frontends all call api-bff and several features ship across repos, so a shared client/proxy/abstraction typically has ≥2 callers — don't defer the thin abstraction the way single-caller YAGNI would. Promote to `_common` when the 2nd concrete caller exists (often immediately). The BFF proxy is the "installed dependency" path; never reach past it to a DS/dev-api directly.

### When it applies

Cleanest on logic/internal code with a single caller and no UI or trust boundary. On customer-facing UI, apply rungs 1–2 (don't build what exists, don't over-abstract) but read rungs 3–6 through the UI-fidelity and atomic-design lens above.
