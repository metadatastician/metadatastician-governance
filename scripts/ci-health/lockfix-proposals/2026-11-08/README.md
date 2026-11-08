# Lockfix proposals — 2026-11-08 (governance#75, B-LOCKFILE)

Regenerated `.github/workflows/actions.lock` for the three repos still carrying
B-LOCKFILE (ERR-SEC-004) findings in metadatastician-governance#75. Each patch is
**lockfile-only — no workflow YAML is touched**.

## Why these are files here, not PRs there

The authoring token is an integration scoped to `metadatastician-governance`:
direct pushes and forks of `_pathroot`, `first-post` and `knot-knot` were both
refused (HTTP 403, "Resource not accessible by integration"). So the validated
regenerations are banked here for the owner to apply with one command each.

## What a patch does

1. **Changed refs** — `workflows:` entries that no longer matched the workflow
   YAML were set to the refs the YAML actually requests:
   - `_pathroot`: `static-analysis-gate.yml` → `actions/download-artifact@v8.0.2`,
     `actions/upload-artifact@v7.0.2` (this was the live `startup_failure`).
   - `first-post`: `codeql.yml` drops the leftover `actions/checkout@v7.0.1`;
     `pages.yml` → `haskell-actions/setup@v2.12.1`.
   - `knot-knot`: `codeql.yml` → `github/codeql-action@2892aa5…` (v4.38.2);
     `push-email-notify.yml` → `hyperpolymath/smtp-notify-action@v0.5.0`;
     `sonarqube.yml` → `sonarsource/sonarqube-scan-action@v8.3.0`.
2. **Missing refs** — matching `dependencies:` records were added, resolved via
   the GitHub API (annotated tags peeled to commits), in the record format the
   generator writes.
3. **Stale reusable entries** — job-level reusable-workflow callers
   (`governance`, `hypatia-scan`, `mirror`, `scorecard`, `secret-scanner`, plus
   `main-estate-audit`/`rust-ci` in knot-knot) became `'<workflow>': []`.
   `gh actions-lock` deliberately excludes job-level reusable calls from the
   lock map (governance#73); an empty entry is exactly what the generator
   writes. Nothing is "deleted from the allow-list" — see below.

Unused old `dependencies:` records were deliberately left in place (harmless;
some are transitive pins). A later real `gh actions-lock` run may prune them.

## Validation (all three repos, on `main` as of 2026-11-08)

- `scripts/check-lock-sync.sh` — pass: "every workflow agrees with actions.lock"
- `scripts/check-lock-pins.sh` — pass: every recorded pin resolves
- Patches re-verified with `git apply` against fresh clones of each repo.

Produced by a parser-based regeneration mirroring the generator's documented
scope, because the `gh actions-lock` v0.1.6 binary could not be downloaded in
the authoring sandbox (release-asset host unreachable, no Go toolchain).

## Apply (owner, one repo at a time)

```bash
gh repo clone metadatastician/_pathroot && cd _pathroot
git checkout -b ci/actions-lock-regen-2026-11-08
git apply /path/to/metadatastician-governance/scripts/ci-health/lockfix-proposals/2026-11-08/_pathroot-actions-lock.patch
git add .github/workflows/actions.lock
git commit -m "ci(actions.lock): regenerate lockfile in sync with workflow YAML (B-LOCKFILE, governance#75)"
git push -u origin ci/actions-lock-regen-2026-11-08
gh pr create --fill
```

(Repeat with `first-post` / `knot-knot`.) Alternatively copy the sibling
`<repo>/actions.lock` file over `.github/workflows/actions.lock` — same result.

## NOT the organisational allow-list

B-LOCKFILE findings live in **each repo's** `.github/workflows/actions.lock`.
They are nothing to do with the organisation Actions allow-list
(org Settings → Actions → Policies), which decides *which actions may run at
all* (B-ALLOWLIST, already in place). Do not add these refs to, or delete them
from, the org allow-list.
