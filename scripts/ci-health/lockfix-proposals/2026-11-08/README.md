# SUPERSEDED — hand-generated lockfiles withdrawn (2026-11-08)

> **Do not use the patches/lockfiles that were previously banked here.**
> They were produced by a parser-based simulation of the generator and have
> been **deleted** (commit history retains them; they are not to be applied).
> Lockfiles in this estate are regenerated **only** with the official tool —
> never hand-edited.

## Why withdrawn

On review, the standing rule was restated: regenerate lockfiles only with
official `gh actions-lock`; preserve full-SHA pins and least privilege; a
merged PR or YAML parse is not acceptance. The official binary
(`github/gh-actions-lock` v0.1.6, the version pinned in
`.github/workflows/ci-health-sweep.yml`) could not be run in the authoring
sandbox — the release-asset download is blocked and there is no Go toolchain
to build it from source — so a compliant regeneration **cannot be produced
from that environment**. Rather than leave hand-written lockfiles looking
apply-ready, they are withdrawn and the correct procedure is recorded below.

## Correct procedure (owner machine / CI with the official tool)

For each of `metadatastician/_pathroot`, `metadatastician/first-post`,
`metadatastician/knot-knot`, on a branch off current `main`:

```bash
gh extension install github/gh-actions-lock --pin v0.1.6
gh actions-lock --no-migrate-local-actions   # regenerates .github/workflows/actions.lock
gh actions-lock --verify                     # must pass
./scripts/check-lock-sync.sh  # (from metadatastician-governance) must pass
git diff                               # review: lockfile only, no YAML churn
```

If the generator rewrites workflow YAML (the standards#981 hazard seen in
knot-knot), stop and report — do not hand-restore YAML around a generated
lock without an owner ruling.

Current drift to be cleared (re-measured 2026-11-08 against live `main`;
see governance#75): `_pathroot` `static-analysis-gate.yml`
(`download-artifact@v8.0.2` / `upload-artifact@v7.0.2` unrecorded);
`first-post` `codeql.yml` (leftover `checkout@v7.0.1`) and `pages.yml`
(`haskell-actions/setup@v2.12.1`); `knot-knot` `codeql.yml`
(`codeql-action@2892aa5…`), `push-email-notify.yml`
(`smtp-notify-action@v0.5.0`), `sonarqube.yml`
(`sonarqube-scan-action@v8.3.0`); plus reusable-only callers whose
hand-kept lock entries the generator scopes out (governance#73,
standards#969).

## Acceptance — runtime, not merge

A repo is done only when, after the regenerated lock lands, an actual run
on the new head shows:

- the previously `startup_failure` workflows **starting** (setup/startup
  failure is a separate class from scanner findings), and
- all three scanner contexts succeeding in the same Secret Scanner run:
  `scan / gitleaks`, `scan / rust-secrets`, `scan / shell-secrets`.

Missing check runs, API errors, or non-2xx responses are not success.

Scanner baseline measured 2026-11-08 (all three contexts `success` in one
run): metadatastician-governance run 42392209607 (head 4b25d51) and
42395133942 (ade047a); `_pathroot` run 42467816849; `first-post` run
42368966235; `knot-knot` run 42369713762. The scanner is *not* the blocked
item in the three target repos — the B-LOCKFILE drift is.

**standards#1108 stays open** until fleet-wide runtime acceptance is
verified; closing this repo's items does not close it.
