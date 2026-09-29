<!-- SPDX-License-Identifier: CC0-1.0 -->
# Session handoff — Issue #30 evidence-driven ci-health rework (PR #54)

State at handoff: **branch pushed, PR open, conflict-free, local gates all green.**

- Branch: `arena/01a0edde-metadatastician-governance`, single commit
  `9c3347e` ("ci-health: B-OFFBRANCH+B-PERMS detection, lockfix restore-then-verify,
  digest-pin oikosbot, retire codeql/probe") on top of `origin/main` (`43a2a2e`).
- PR: https://github.com/metadatastician/metadatastician-governance/pull/54
  — OPEN, `mergeable: MERGEABLE`, 19 files, +961/−507. `BLOCKED` status refers to
  required checks finishing, not to conflicts.
- Push mechanics (important for the next session): the sandbox `GH_TOKEN` is
  git-transport-scoped only. `git push` must use
  `git -c http.extraHeader="Authorization: Basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)" push …`
  directly (no credential helper exists in the sandbox). Direct REST POSTs to
  api.github.com with `Authorization: Bearer $GH_TOKEN` work for issues/pulls
  (read **and** write — the PR was created that way); `/user` identity scope 403s;
  `gh` CLI only works behind a shim because hosts.yml-based auth is ignored by
  the installed gh version without GH_TOKEN set. A working shim is at
  `~/arena-bin/gh` (outside the repo; do not commit it).

## What's in the PR (commit summary)

1. `scripts/ci-health/detect.sh` — new `B-OFFBRANCH` (reusable ref not an ancestor
   of callee default branch) and `B-PERMS` (caller under-grant vs reusable
   `permissions:`) classes, parsed via `scripts/lib/yaml.sh` (nickel; Y-1).
   Verified live: B-PERMS attributed exactly the workflows whose run-page banners
   were read 2026-09-29 (consent-aware-web ×3, chronicles-of-slavia ×1);
   0 B-OFFBRANCH estate-wide.
2. `scripts/ci-health/lockfix.sh` — standards#981 restore-then-verify: restore
   `before/*.{yml,yaml}`, keep only the new `actions.lock`, re-gate with
   `check-lock-sync.sh` + `check-lock-pins.sh --offline`; `PROPOSED … lock-only
   diff` on pass, `REPORT … standards#981 … NO PR` on fail. Tests cover silence,
   firing, and both mutants.
3. `scripts/ci-health/sweep.sh` — `gh actions-lock --pin` stderr triage
   (empty-repo 409 → `SKIP <repo> empty repository`); failure kinds locked by
   `ERR-*-9xx` codes.
4. `.github/workflows/codeql.yml` **deleted** — job `36551067938` logs showed the
   local job can never go green while CodeQL default setup exists; scanning
   continues there. Pin arithmetic recorded in `CI-CD-COVERAGE.adoc`
   (`2892aa5e…` = v4.38.2, `b96794f0…` = v4.38.0).
5. `.github/workflows/oikosbot.yml` — image digest-pinned to
   `@sha256:cc9b731d…` (verified on the public
   `hyperpolymath/oikosbot → Packages → oikos` page 2026-09-29; `:latest` shared
   with `sha-2f47a61`), provenance comment + resolved-digest record step;
   `upload-sarif` re-pinned to the true v4.38.0 SHA with the old pin/comment
   contradiction logged next to it.
6. `.github/workflows/zz-probe-actions-lock.yml` **deleted** — probe answered by
   runner logs (unlisted workflows START; listed-and-diverged REFUSE).
   KYAML census updated: 22/9/12/**421** (431 − 37 codeql + 20 oikosbot + 7 sweep).
7. Docs refreshed: `CI-CD-COVERAGE.adoc`, `ADOPTION-AND-DEVIATIONS.adoc`
   (D-A re-grounded, D-C digest-pinned, census table), `TEST-NEEDS.adoc`
   (runner evidence job `36551068185`, 140 local assertions; **grade untouched**
   per the side-effect rule), `METADATASTICIAN-STARTUP-WORKLIST.md`
   (12/13 formerly-unclassified runs classified: 8 B-PERMS, 3 allow-list gaps,
   1 B-LOCKFILE; 1 open = pong-ping `36350353285`).

## Gates run before commit (all PASS)

`run-shell-test-suite.sh` 11/11 · `check-lock-sync.sh` (nickel parser) ·
`check-lock-pins.sh --offline` smoke · `check-root-shape.sh` · `kyaml-census.sh`
(22/9/12/421) · SPDX headers on all touched files · `git diff --check`.
Known local-only caveat: `check-workflows-parse.sh` needs yq/ruby (absent at
home); its 5 mutants score on the runner — measured 29/29 + 18/18 + 6/6,
0 NOT SCORED, recorded in `TEST-NEEDS.adoc` Category 10.

## What remains (not blockers for the squash-merge)

1. **13 carried repos** in the worklist are marked `*(carried)*` — re-run
   `CHECK_ALLOWLIST=false scripts/ci-health/detect.sh <repo>` over them once the
   next session's token can read Actions; 11/24 are already re-measured *(fresh)*.
2. **pong-ping** `sonarqube.yml` run `36350353285` — no banner, still
   UNCLASSIFIED; re-detect with a working token.
3. If the sweep's nightly run regenerates worklist rows, the refreshed
   `METADATASTICIAN-STARTUP-WORKLIST.md` is written so a naive
   `git checkout --theirs` does NOT silently overwrite the 2026-09-30 provenance
   caveats (§0 header) — re-measure first instead.
4. Merge: squash-merge PR #54 when required checks are green; the branch is a
   single commit, so squash = identical tree.
