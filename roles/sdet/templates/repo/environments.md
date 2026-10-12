<!--
  environments.md — per-repo map of the targets automated tests can hit, how to prove what is
  deployed there (merged ≠ deployed), how auth works, which flags differ per env, and known drift.
  READ by: /cover (run target, flag reads for deterministic skips), /triage (env-or-data
  classification, deployed sha for bug drafts), /log (env + sha in bug descriptions).
  WRITTEN by: /triage (drift rows), /ci-check post-deploy re-check outcomes, /learn (lessons at
  the second occurrence).
  Seeding: one row per target from the Playwright config's baseURL handling and the deploy model in
  the repo profile. No URLs that are secret; env-var names where the value is.
-->
<!-- last-updated: YYYY-MM-DD -->

# Environments — {repo-name}

> Where tests run, what is actually deployed there, and what differs between targets.

## Targets
<!-- `deploy-check` is the ONE command that answers "which sha is serving this target right now".
     A failure reproduced against a target that does not yet serve the merged fix is not a bug. -->

| name | base URL (var) | serves | deploy-check | when to use |
|---|---|---|---|---|
| local | `PLAYWRIGHT_BASE_URL=<e2e.local_base_url>` | THIS branch (local app + dev backend) | `git rev-parse --short HEAD` | pre-merge — the only target that can prove new behaviour |
| dev | config default | last merged + deployed base | `<kubectl get deploy … -o jsonpath image | lambda get-function | argo app get>` → compare to `git log origin/<base>` | post-deploy re-check, triage of nightly reds |
| qa / staging | `TEST_ENV=qa` | release candidate | same, per the profile `deploy:` block | release regression |

_Source: code-observation (playwright config, repo profile `deploy:`)_

## Auth
- Method: <auth `setup` project writing `storageState` | API token in header `X-…` | none>.
- Cookies are domain-scoped: a storage state captured on dev does not sign in on local — let the setup project re-run when switching targets.
- Rate limits on the shared account: <known limits, or "unknown">.

_Source: code-observation_

## Flags per environment
<!-- The deterministic read /cover uses for gated skips. A skip reads the flag VALUE from here/the
     client — never infers it from whether an element rendered. -->

| flag | local | dev | qa | how a test reads it |
|---|---|---|---|---|
| `ITEMS_V2` | on | on | off | `isFlagEnabled('ITEMS_V2')` from the flag client / `process.env.FLAG_ITEMS_V2` |

_Source: code-observation_

## Known drift
<!-- Things that differ between targets and have bitten a run. One row each; /triage appends. -->

| date | target | drift | effect on tests | status |
|---|---|---|---|---|
| YYYY-MM-DD | dev | backend image two commits behind `<base>` | `GET /items` 503 across unrelated specs | resolved when deploy landed |

## AUTO:ENV-LOG
<!-- Append-only, written by /triage (env-or-data clusters, env-blocked status) and /cover (run
     target used, static exploration because the server was down). Format:
     - YYYY-MM-DD <slug> target=<name> class=<deploy-lag|auth|rate-limit|network|flag-mismatch> detail=<one line> -->

## Environment lessons
<!-- Written by /learn at the second occurrence of a class (promote_at: 2). -->
