<!-- last-updated: 2026-10-12 -->
# `harvest-profile.py` output schema (v1)

`core/scripts/harvest-profile.py` is the "findings, not files" path out of a confidential install: it reads a mature workspace `.claude/` and emits `profile.json` + `profile.md` made of **aggregates and shapes only**. This document lists every field so the owner can audit what leaves before carrying the files to the public repo.

## The no-raw-content rule

Nothing in the output is a copy of anything in the workspace. Concretely:

- **Never emitted:** file bodies, entry text, rule text, ticket keys, branch names, URLs (including `baseURL`), filesystem paths, people, emails, PR/run titles, permission strings, env values, workflow names in clear, repo names in clear.
- **Emitted as values only (never as JSON keys):** the free-text strings the profile does carry — H2 titles, agent names, process-ledger class labels, UI-fidelity surface names, proposal target command names, local-only file names, Playwright project names, non-schema status words. Each one passes through the `upstream.py` sanitizer rules (`build_rules` — paths, denied domains, emails, ticket prefixes, repo aliases, denylist). Anything that still trips `upstream.py check` (config rules + generic heuristics + the always-on secret patterns) is replaced by `<redacted-title-N>` (title-like keys) or `<redacted-N>`, and the run re-checks. If a hit survives that single redaction round, **nothing is written** and the offending JSON paths are printed (exit 2).
- **Repo identity:** a repo appears under its alias from `upstream.json` `repo_aliases`; a repo without an alias appears as `repo-<sha256(name)[:8]>`. The single-repo layout uses `root`.
- **Workflow identity:** CI workflows appear as `sha256(workflowName)[:12]`.
- The whole rendered output (`profile.json` + `profile.md`) is run through `upstream.py check` once more before it is copied out of the temp dir — the final fail-closed gate.

Exit codes: `0` written clean · `1` usage / config error (an empty or placeholder denylist is an error — fail-closed) · `2` leak check failed, nothing written.

## Top level

| Field | Type | Meaning |
|---|---|---|
| `schema_version` | int | `1` |
| `generated_at` | ISO-8601 UTC | run time |
| `tool` | string | `harvest-profile.py` |
| `sanitization.denylist_hash` | hex[12] | sha256 of the `upstream.json` used — ties the profile to a denylist version, never its content |
| `sanitization.redactions` | `{rule: n}` | how many sanitizer substitutions fired per rule class (`path`, `domain`, `url`, `email`, `ticket`, `ticket-any`, `repo`, `denylist`) |
| `sanitization.redacted_strings` | int | strings replaced by `<redacted-…>` after the check loop |
| `sanitization.check` | `"pass"` | present only on a written profile |
| `workspace` | object | see below |
| `repos` | `{alias: RepoProfile}` | one per discovered repo |
| `ci` | object | `{present: false}` without `--ci-runs` |
| `drift` | object | `{compared: false}` without `--public-core` |

## `workspace`

| Field | Meaning |
|---|---|
| `layout` | `workspace` (root holds `.claude/` + repos) or `single-repo` |
| `repos` | number of repos profiled |
| `workflow_version` | `version:` from `workflow-version.md` frontmatter |
| `commands.count` | `commands/*.md` installed |
| `commands.in_public_core` / `commands.local_only` | command names split against `--public-core` (null without it). Names are values; local-only names pass the sanitizer + check |
| `archived_commands.count` / `.in_public_core` | `_archived-commands/*.md` |
| `agents[]` | workspace-level agents: `{name, tools[], model, lines}` — frontmatter fields only |
| `root_docs_lines` | `{filename: line count}` for the known system docs present (business-context, stack-connections, project-map, shared patterns, capability-manifest, routing) — size only |
| `api_reference_files` | count of files under `api-reference/` |
| `repo_profiles` | count of `repo-profiles/*.yaml` (excluding `_schema.yaml`) |
| `capability_enums` | histograms over repo profiles: `type`, `tracker_system`, `component_organization`, `ui_surface`, `e2e_enabled`, `e2e_framework`, `e2e_sideload_only`, `deploy_model`, `base_branch_is_default` (the branch name itself is never emitted — only whether it is `main/master/develop/trunk`) |
| `capability_manifest` | `{present, decisions: {KEEP: n, PRUNE: n, …}}` from the manifest table's Decision column |
| `settings` | `{present, local_present, permissions_allow (count), permissions_by_tool ({Bash: n, Read: n, …} — prefixes only), hooks ({event: n}), env_keys ([names only])}` |
| `state_index` | see below |
| `proposals` | see below |
| `metrics` | `{snapshots, schema_versions[], metric_keys[], span_days}` from `metrics/*.json` — keys only |
| `schema_drift` | `{present, lines, distinct_statuses: [{label, n}]}` from `state/schema-drift.log` |
| `mine_runs` | number of `state/mine/<date>/` directories |

### `workspace.state_index`

| Field | Meaning |
|---|---|
| `present`, `version`, `entries` | index presence, schema version, entry count |
| `by_kind`, `by_status` | histograms |
| `archived`, `with_pr` | counts |
| `by_repo_alias` | entries per aliased repo |
| `tags_layer`, `tags_kind`, `tagged_by`, `tag_confidence` | histograms over the tag fields (`untagged` / `none` when absent) |
| `key_suffixes` | histogram of the part of `key` after the ticket id (`(none)`, `-clarify`, `-visual-spec`, …) or `slug` for non-ticket keys — **the id itself is dropped** |
| `cycle_time_days_created_to_last_update` | `{n, mean, median, p90, max}` in days, over entries with status `delivered`/`learned` (an upper bound on cycle time — `updated` is the last write, not the merge) |
| `cycle_time_by_tag_kind` | the same stats grouped by `tags.kind` |

### `workspace.proposals` (from `command-proposals.md`)

| Field | Meaning |
|---|---|
| `blocks` | `### [YYYY-MM-DD]` blocks |
| `by_status` | histogram of `**Status:**` first word (`NO-STATUS` when missing) |
| `by_status_and_age` | `[{status, age_bucket: <21d / 21-90d / >90d, n}]` — age from the bracket date |
| `targets` | `[{label, n}]` — the `**Target:** <cmd>.md` command name, folded to `other` when not in `--public-core` |
| `occurrences` | histogram of `**Occurrences:**` values (as strings) |
| `reviewed_stamps` | count of `**Reviewed:**` |

## `repos.<alias>` (RepoProfile)

| Field | Meaning |
|---|---|
| `has_profile`, `profile_type`, `profile_keys_filled` | repo-profile presence, its `type` enum, number of non-empty keys |
| `claude_dir_files` | histogram of what sits in `.claude/`: `dir:<name>` for directories (`tickets`, `agents`, …) and `ext:<suffix>` for files — names of directories only |
| `state_files` | `{tickets: n, debug: n, builds: n, refactors: n, e2e: n, qa: n}` for the dirs present |
| `codebase_patterns`, `testing_patterns` | MarkdownStructure (below); `{present: false}` when absent |
| `ticket_checklist` | `{present, lines, checkboxes}` |
| `process_ledger` | `{present, log_rows, classes: [{label, n, with_debug, mean_sessions, mean_phases, mean_fix_iter, mean_days}], lessons_h3, lessons_bullets}` — parsed from `AUTO:PROCESS-LOG` lines; ticket ids and debug slugs are dropped |
| `ui_fidelity_ledger` | `{present, meta_lessons, surfaces: [{label, n}], clusters: {class: n}, kpi_stamps}` |
| `agents[]` | repo agent overrides: `{name, tools[], model, lines}` |
| `hooks`, `scripts` | file counts in `.claude/hooks/`, `.claude/scripts/` |
| `e2e` | E2EShape (below) |
| `playwright_config` | PlaywrightShape (below) |

### MarkdownStructure (`codebase_patterns`, `testing_patterns`)

| Field | Meaning |
|---|---|
| `lines`, `h2`, `h3` | size and heading counts |
| `h2_titles[]` | the H2 titles — the emergent topic structure. Sanitized; any residual hit becomes `<redacted-title-N>` |
| `entry_lines` | `{n, mean, median, p90, max}` non-blank lines per `###` entry |
| `entries_le_8_lines` | entries within the `/learn` ≤8-line rule |
| `tags` | histogram of `### [Tag]:` tags |
| `source_mix` | `{ticket, session, code_observation, mined, seed_pack, other}` counts over `_Source:` / `Source:` / `Provenance:` lines |
| `index_lines`, `index_coverage` | `- [` lines under `## Index`, and that count ÷ `h3` |
| `last_run_lines` | stacked `<!-- last-run / prev-run -->` comments (a proxy for append-only drift) |
| `code_blocks` | fenced blocks |
| `has_shared_pointer`, `has_comment_hygiene_h2`, `has_lessons_learned_h2`, `has_seed_banner` | booleans |
| testing only: `has_e2e_repo_awareness_h2`, `has_e2e_drift_taxonomy_h2`, `has_e2e_suite_health_h2`, `suite_health_stamps` | canonical E2E sections present, stamp count |

### E2EShape (`e2e`)

Spec dir resolution: profile `e2e.spec_dir` → `testDir` in `playwright.config.*` → `e2e/`, `tests/e2e/`, `test/e2e/`, `playwright/`. `{present: false}` when none exists.

| Field | Meaning |
|---|---|
| `spec_dir_depth` | path depth of the spec dir (the path itself is not emitted) |
| `spec_files`, `helper_files`, `page_object_files`, `fixture_files`, `setup_files` | counts by filename / directory convention |
| `tests_total`, `describe_blocks` | `test(`/`it(` declarations incl. `.skip/.fixme/.only/.fail` variants; `test.describe(` |
| `selectors` | counts of `getByRole`, `getByLabel`, `getByTestId`, `getByText`, `getByPlaceholder`, `getByTitle`, `getByAltText`, `locator`, `locator_class_contains` (`[class*=`), `css_id_selector`, `xpath`, `waitForTimeout`, `networkidle` |
| `selector_share` | each `getBy*`/`locator` count ÷ their sum |
| `guards` | `{test_skip, test_fixme, test_only, test_fail, soft_guard (isVisible().catch(() => false)), skip_with_key (a BUG/FLAKY key inside the call)}` |
| `guard_density_per_100_tests` | each guard count ÷ `tests_total` × 100 |

### PlaywrightShape (`playwright_config`)

| Field | Meaning |
|---|---|
| `present`, `ext` | config found, its extension |
| `retries`, `workers` | `{ci, local}` when written as `process.env.X ? a : b`, `{all: n}` for a literal, `"expression"` otherwise |
| `reporters[]`, `reporter_is_env_conditional` | reporter type names found (`html`, `list`, `junit`, …); whether the reporter choice depends on an env var |
| `projects`, `project_names[]` | project count and names (sanitized values) |
| `trace`, `screenshot`, `video` | the enum strings |
| `timeout_ms` | top-level test timeout |
| `fully_parallel`, `forbid_only`, `has_base_url`, `has_web_server`, `has_global_setup`, `has_storage_state` | booleans — **`baseURL`'s value is never emitted** |

## `ci` (from `--ci-runs`, the `gh run list --json …` export)

| Field | Meaning |
|---|---|
| `runs`, `workflows` | totals |
| `by_workflow_hash.<sha256[:12]>` | per workflow: `runs`, `by_conclusion`, `failure_rate` (failure ÷ (success+failure)), `reruns` (attempt > 1), `same_sha_flips` (SHAs that both failed and succeeded), `events` histogram, `distinct_branches` (count only), `span_days` |

Run titles (`name`) and branch names (`headBranch`) are read for counting and never emitted.

## `drift` (from `--public-core`)

| Field | Meaning |
|---|---|
| `compared` | true when a core dir was given |
| `modified`, `missing` | counts |
| `files[]` | `{file, status: modified|missing, changed_lines, baseline_lines, installed_lines}` for every public-core file that differs; identical files are omitted. `file` is the public-core relative path (`commands/pr-creation.md`) — it names the upstream file, not a local one |
| `local_only_count`, `local_only[]` | installed `commands/`, `agents/`, `scripts/` files and root `*.md` system docs absent from public core. Project-owned root files (`codebase-patterns.md`, `business-context.md`, `command-proposals.md`, …) are excluded. Names pass the sanitizer + check |

## Reading `profile.md`

`profile.md` is a rendering of the same data: one repo table, a selector table and Playwright line per e2e repo, the H2 topic list per repo, state-index / proposal / capability / CI / drift sections. It contains no field the JSON lacks.

## Changing the schema

Bump `SCHEMA_VERSION` in the script and add the field here in the same commit. A new field must be a count, a ratio, a boolean, an enum from a closed vocabulary, a hash, or a sanitized title — never text copied from the workspace. `tests/b4-harvest-profile.test.py` plants a denylist term and the project alias and asserts neither reaches the output; extend it when adding a string-carrying field.
