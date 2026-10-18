<!--
  regression-map.md — which manual steps earn a place in the regression set. Log-only: /learn
  appends, you decide. Two lists grow from delivered `kind: qa` sidecars: steps whose rows found
  a real bug (keep running them before releases) and steps that passed every run (candidates to
  drop or automate). Project-owned: seeded once, never overwritten.
-->
<!-- last-updated: YYYY-MM-DD -->

# Regression map — {project}

## AUTO:REGRESSION-LOG
<!-- - YYYY-MM-DD <key> area=<area> step="<step>" found_bug=<key>            (keep)      -->
<!-- - YYYY-MM-DD <key> area=<area> step="<step>" passed_runs=<n>             (consider dropping) -->

## Regression set (curated by you)
<!-- the steps you re-run before a release, grouped by area; promote from the log above -->

## Retired steps
<!-- steps you stopped running, with the date and why (automated in /cover? never failed?) -->
