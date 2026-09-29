# Metadatastician newest-run startup-failure worklist (2026-09-30 UTC refresh)

Method, unchanged from 2026-09-28: latest run per workflow within each repo's last
100 runs, filtered to API-active workflows; cause from the public run-page
annotation, not inferred from actor alone. New this refresh: `detect.sh` grew two
file-decidable classes (`B-OFFBRANCH`, `B-PERMS`), so each repo below carries a
measured attribution rather than just an annotation transcript, and the whole
2026-09-28 UNCLASSIFIED bucket was read off the public run pages on 2026-09-29.

**Provenance caveat, stated up front.** The 2026-09-30 re-census was cut short
mid-run when the session's GitHub token expired (`Bad credentials`, ~09:30 UTC).
11 of the 24 Issue-#30 repos were re-measured live with the upgraded detector
**today**; the other 13 repos and the organization policy read are **carried from
2026-09-28** and are marked *(carried)* — re-run before acting on any carried row.
Repos measured today are marked *(fresh)*.

## A. The 13 previously-UNCLASSIFIED runs: what they actually were

All 13 run pages were fetched 2026-09-29 (zero-job `startup_failure` runs expose
nothing in REST — no jobs, no check runs, no `annotations_url` — but the public
run page renders the banner under "Annotations"). 11 of 13 resolve to exact,
actionable causes; 2 needed the file-side detector, and one of those is now
solved as well.

| Repo | Run | Workflow | Cause |
|---|---:|---|---|
| consent-aware-web | 36070674570 | governance.yml (#L20) | **B-PERMS (standards#451)** — governance-reusable@092dedad requests `actions: read`; caller grants `actions: none` |
| consent-aware-web | 36070674576 | mirror.yml (#L15) | **B-PERMS** — mirror-reusable@092dedad, same scope |
| consent-aware-web | 36282215987 | hypatia-scan.yml (#L29) | **B-PERMS** — hypatia-scan-reusable@092dedad, same scope |
| project-ovine *(carried)* | 36293946035 | governance.yml | **B-PERMS** — governance-reusable@092dedad, same scope |
| project-ovine *(carried)* | 36293946059 | hypatia-scan.yml | **B-PERMS** — hypatia-scan-reusable@092dedad, same scope |
| sr71-blackglider *(carried)* | 35850400630 | mirror.yml | **B-PERMS** — mirror-reusable@092dedad, same scope |
| sr71-blackglider *(carried)* | 35850400705 | governance.yml | **B-PERMS** — governance-reusable@092dedad, same scope |
| sr71-blackglider *(carried)* | 36282044964 | hypatia-scan.yml | **B-PERMS** — hypatia-scan-reusable@092dedad, same scope |
| knot-knot *(carried)* | 36350620377 | julia-docs.yml | **Allow-list usage gap** — runner banner: `julia-actions/julia-buildpkg@e3eb439f…` "is not allowed"; it is absent from the effective patterns and from `action-superset.txt` |
| marid-relationship-explorer *(carried)* | 35710831820 | ci.yml | **Allow-list usage gap** — banner: `actions/checkout@v4` and `julia-actions/setup-julia@v2` not allowed (tag refs under the estate's pin-policy; actions created by GitHub are otherwise allowed, so the effective list at run time covered neither tag ref) |
| marid-relationship-explorer *(carried)* | 35710832878 | codeql.yml | **Allow-list usage gap** — banner: `actions/checkout@v7.0.1` not allowed, same shape |
| cleave | 35861081435 | codeql.yml | **B-LOCKFILE** — no banner was rendered; the upgraded detector attributes the run file-side today (`refs missing from the lockfile: actions/checkout@3d3c42e5…`), and the failed run id matches the drift finding exactly |
| pong-ping | 36350353285 | sonarqube.yml | **Still UNCLASSIFIED** — no banner, and the token outage cut the estate re-census before this repo. Next step: re-run `CHECK_ALLOWLIST=false scripts/ci-health/detect.sh pong-ping` once the token is restored |

All eight standards#451 runs pin `092dedada188f56c5915f74a5fd40aac093742c3`,
which **is** an ancestor of `hyperpolymath/standards/main` (the related
off-branch-pin class was audited and does not apply): no re-pointing is needed,
only the caller grant. Today's live detector output agrees — zero `B-OFFBRANCH`
across the 11 censused repos, and `B-PERMS` findings for exactly the three
consent-aware-web workflows whose banners were read, naming the same missing
scope (`actions: read`, grant `none`).

**Detector verification (the question this bucket existed to answer):** of the
24 Issue-#30 repos, 11 were re-run today; every default-branch `startup_failure`
run in them received an exact class with only one generic remainder (burble,
one aggregate row). Of the 13 formerly unclassified runs, 12 have a named cause
(8 B-PERMS, 3 allow-list usage gap, 1 B-LOCKFILE); 1 (pong-ping sonarqube)
awaits the live re-read.

## B. Re-measured 2026-09-30 with the upgraded detector *(fresh)*

| Repo | Findings | Classes |
|---|---|---|
| 688-attack-hub | 2 | B-LOCKFILE ×2 |
| IDApTIK | 0 | clean |
| burble | 5 | B-LOCKFILE ×4 + B-STARTUPFAIL generic aggregate ×1 |
| cadastra | 3 | B-LOCKFILE ×3 |
| chronicles-of-slavia | 2 | **B-PERMS ×1** (scorecard.yml job `scorecard` → scorecard-reusable@fcb86691… grants `actions: none`, needs `actions: read`) + B-ACTOR ×1 (3 workflows, latest `container-build.yml` by `arena-ai-coding-agent[bot]`) |
| cleave | 4 | B-LOCKFILE ×4 (codeql.yml `actions/checkout@3d3c42e5…`, oikosbot.yml `github/codeql-action@v4.38.1`, pages.yml `actions/deploy-pages@v5.0.1`, secret-scanner.yml `hyperpolymath/standards@092dedad…`) |
| common-signal | 11 | B-LOCKFILE ×11 |
| consent-aware-web | 9 | **B-PERMS ×3** (governance/hypatia-scan/mirror, all `actions: read` missing, see §A) + B-LOCKFILE ×6 |
| enaction-engine | 1 | B-ACTOR ×1 (2 workflows, latest `dependabot-automerge.yml` by `arena-ai-coding-agent[bot]`) |
| f19-stealth-glider | 2 | B-LOCKFILE ×2 |
| first-post | 1 | B-ACTOR ×1 (2 workflows, latest `codeql.yml` by `dependabot[bot]`) |

No `B-BADPIN` and no `B-OFFBRANCH` were emitted anywhere in the censused set.

## C. Carried from the 2026-09-28 census *(carried — recheck before action)*

### LOCKFILE (40 runs) — Invalid lockfile annotation — lock-only candidates, subject to gate and diff

| Repo | Run ID | Workflow | Branch | Actor |
|---|---:|---|---|---|
| 688-attack-hub | 35848520709 | pages.yml | main | hyperpolymath |
| burble | 35914939287 | oikosbot.yml | chore/apply-foundation-ci-fixes-20260911 | hyperpolymath |
| burble | 35914937978 | codeql.yml | chore/apply-foundation-ci-fixes-20260911 | hyperpolymath |
| burble | 35914936682 | elixir-ci.yml | chore/apply-foundation-ci-fixes-20260911 | hyperpolymath |
| cadastra | 36055119389 | sonarqube.yml | main | hyperpolymath |
| cadastra | 36055118381 | codeql.yml | main | hyperpolymath |
| cadastra | 36055117193 | oikosbot.yml | main | hyperpolymath |
| cleave | 35861079809 | oikosbot.yml | main | hyperpolymath |
| consent-aware-web | 36070677624 | sonarqube.yml | main | hyperpolymath |
| f19-stealth-glider | 35848427658 | pages.yml | main | hyperpolymath |
| first-post | 35846816785 | sonarqube.yml | dependabot/github_actions/actions-c83b7ed659 | dependabot[bot] |
| first-post | 35846815809 | codeql.yml | dependabot/github_actions/actions-c83b7ed659 | dependabot[bot] |
| groove | 35861730064 | codeql.yml | main | hyperpolymath |
| groove | 35861729042 | oikosbot.yml | main | hyperpolymath |
| harvard-dehallucinator | 35853565123 | codeql.yml | main | hyperpolymath |
| insolvency-tycoon | 35849597960 | quality.yml | main | hyperpolymath |
| marid | 36191576145 | pages.yml | main | hyperpolymath |
| marid | 36191575397 | codeql.yml | main | hyperpolymath |
| metadatastician-governance | 36358429436 | zz-probe-lockmismatch.yml | arena/01a0e520-metadatastician-governance | arena-ai-coding-agent[bot] |
| metadatastician-governance | 36295476367 | ci-health-sweep.yml | main | hyperpolymath |
| paint-type | 36163988135 | coverage.yml | main | hyperpolymath |
| paint-type | 36163987263 | oikosbot.yml | main | hyperpolymath |
| pong-ping | 36350352711 | pages.yml | main | hyperpolymath |
| pong-ping | 36350352154 | codeql.yml | main | hyperpolymath |
| pong-ping | 36350351572 | push-email-notify.yml | main | hyperpolymath |
| progblocks | 35861788162 | codeql.yml | main | hyperpolymath |
| sim-public-relations | 36070112852 | sonarqube.yml | main | hyperpolymath |
| sim-public-relations | 36070111910 | codeql.yml | main | hyperpolymath |
| spline | 35861703423 | oikosbot.yml | main | hyperpolymath |
| spline | 35861702426 | codeql.yml | main | hyperpolymath |
| stapeln | 35862012288 | codeql.yml | main | hyperpolymath |
| stapeln | 35862011397 | oikosbot.yml | main | hyperpolymath |
| svalinn | 36250198448 | casket-pages.yml | main | hyperpolymath |
| svalinn | 36250197691 | codeql.yml | main | hyperpolymath |
| svalinn | 36250197127 | oikosbot.yml | main | hyperpolymath |
| universal-modding-studio | 36283963613 | codeql.yml | main | hyperpolymath |
| _pathroot | 36350196173 | sonarqube.yml | main | hyperpolymath |
| _pathroot | 36350195516 | pages.yml | main | hyperpolymath |
| _pathroot | 36350194964 | codeql.yml | main | hyperpolymath |
| _pathroot | 36350194352 | jekyll.yml | main | hyperpolymath |

### ACTOR (9 runs) — Actor not allowed — owner Settings → Actions; no repo change applies

| Repo | Run ID | Workflow | Branch | Actor |
|---|---:|---|---|---|
| berrywiki | 36319802651 | label-triage.yml | main | arena-ai-coding-agent[bot] |
| chronicles-of-slavia | 36310000400 | dependabot-automerge.yml | arena/01a0e227-chronicles-of-slavia | arena-ai-coding-agent[bot] |
| enaction-engine | 36287580979 | sonarcloud-queue-gate.yml | arena/01a0df62-enaction-engine | arena-ai-coding-agent[bot] |
| enaction-engine | 36287579144 | dependabot-automerge.yml | arena/01a0df62-enaction-engine | arena-ai-coding-agent[bot] |
| metadatastician-governance | 36359814257 | labels.yml | arena/01a0e520-metadatastician-governance | arena-ai-coding-agent[bot] |
| metadatastician-governance | 36358898360 | zz-probe-verify.yml | arena/01a0e520-metadatastician-governance | arena-ai-coding-agent[bot] |
| metadatastician-governance | 36358428865 | zz-probe-nolock.yml | arena/01a0e520-metadatastician-governance | arena-ai-coding-agent[bot] |
| metadatastician-governance | 36358428225 | zz-probe-lockmatch.yml | arena/01a0e520-metadatastician-governance | arena-ai-coding-agent[bot] |
| metadatastician-governance | 36358427666 | zz-probe-noactions.yml | arena/01a0e520-metadatastician-governance | arena-ai-coding-agent[bot] |

## D. Actionable buckets

1. **B-LOCKFIX-ready** (regenerate `actions.lock` via the dry-run-first pipeline; live PRs only under `ENABLE_LOCKFIX_PRS=true`): all LOCKFILE rows in §B and §C where the workflow and branch are current — refresh carried rows first. The `standards#981` restore-then-verify path in `lockfix.sh` now makes banner-churn regenerations safe (original YAML is restored and gates re-verified before any PR text is emitted).
2. **B-BADPIN-blocked**: none measured anywhere in the censused set (both days). Nothing to re-point.
3. **standards#451-blocked** (add `actions: read` to the caller's permissions; pin is an ancestor, no re-point): consent-aware-web `hypatia-scan.yml` (job `scan`), `governance.yml` (job `governance`), `mirror.yml` (job `mirror`); chronicles-of-slavia `scorecard.yml` (job `scorecard`, callee `scorecard-reusable.yml@fcb8669169b4e9f5d9848608df880ae5fae812b4`); *(carried, banner-verified)* project-ovine `governance.yml` + `hypatia-scan.yml`; sr71-blackglider `governance.yml`, `mirror.yml`, `hypatia-scan.yml`. Grant it on the workflow-level `permissions:` map — job-level grants would shadow the workflow map wholesale.
4. **Off-branch-pin-blocked**: none measured today (`B-OFFBRANCH` 0/11 repos; the Scorecard/#44 case in this repository remains the only confirmed instance and was fixed by re-pointing at `2ccc38ea`).
5. **Allow-list usage gap** — *estate decision needed*: knot-knot `julia-docs.yml` needs `julia-actions/julia-buildpkg` in the effective patterns (the documented route is `scripts/ci-health/action-superset.txt`; currently absent). marid-relationship-explorer `ci.yml`/`codeql.yml` fail on tag refs (`actions/checkout@v4`, `@v7.0.1`, `julia-actions/setup-julia@v2`) that the estate's pinning policy refuses at run time; the in-repo cure is SHA-pinned refs + lock regeneration (B-LOCKFILE rows for `marid` in §C point the same direction). This class is deliberately REPORT-only in the detector: it sits outside the two scoped Phase-2 classes, and widening the org allow-list from a sweep is exactly the trust decision T-1 reserves for humans.
6. **B-ACTOR-only** (owner Settings → Actions): §B `chronicles-of-slavia` (3 workflows), `enaction-engine` (2), `first-post` (2); §C table as listed. No repository change can fix these.
7. **Still open**: pong-ping `sonarqube.yml` run 36350353285 (no banner; re-detect once the token is restored), burble's one generic B-STARTUPFAIL aggregate row, and the 13 carried repos' live re-verification. The organization allow-list/policy read also could not be re-run today (token lacks `admin:org` on this session's credentials; the sweep's PAT owns that check as before).
