<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->

# Upstream sync state — MetaManifold-WebUI

Measured 2026-10-15. Every number here is re-derivable with
`MAKE-UNITS.sh`; nothing is carried over from a previous reading.

| Repo | Role | Default branch |
|---|---|---|
| `JoshuaJewell/MetaManifold-WebUI` | upstream — his | `main` |
| `hyperpolymath/MetaManifold-WebUI` | fork — ours | `main` |

## 1. The measured divergence

```
upstream/main  HEAD   52feb605176a4b140f4b40c2b74d2f18adec1f72
                      "test(pipeline): run the vsearch stage through the
                       server's entry points (#113)"         2026-10-15
fork/main      HEAD   35bd313
                      "chore(root): Justfile, CHANGELOG, .editorconfig,
                       launcher (+ --agent) …" (#157)         2026-10-15
merge base            257bcdec2db0d4231ed9d5b160b5caa623485681
                      ("Add a Differential Abundance tab to the
                       analysis workspace")
```

* `fork/main` vs `upstream/main`: **30 ahead, 31 behind**.
* `fork/main` vs **current** `upstream/main`: **35 added, 28 modified,
  0 deleted**.

### 1.1 The premise has changed: the one-shared-commit era is over

This register was founded on the measurement that *fork and upstream
share exactly one commit — the initial commit* — so the fork's work
arrived upstream as add/add conflicts and could only be offered as
re-applied units. **That is no longer true, and the change is his act:**

* upstream `main` now contains fork commits **with their history**:
  `ef80481` (the occupancy flag base), `5f73b70` (the vsearch helper,
  fork PR #112), `52feb60` (the server entry-point tests, fork PR #113).
  `52feb60` *is* upstream's HEAD. His main carries our PR numbers in
  its commit messages.
* The merge base is no longer the initial commit but `257bcde`, his own
  "Differential Abundance tab" commit — a genuine three-way base both
  sides share.
* The old "102 stale deletions" finding is **gone**: the fork now deletes
  nothing that exists upstream (0 deleted, measured).

The consequence for this register: units are still the offer currency
(his conditions are unchanged), but a merged unit now lands *with
history*, and the fork can sync three-way from `257bcde` instead of
re-resolving everything add/add.

## 2. The five PRs he is holding, measured 2026-10-15

| His PR | Unit | State | Note |
|---|---|---|---|
| #40 | charts markup fixpoint (fork PR #119's work) | **closed, unmerged** | closed silently 2026-10-15; no review, no comment; the one-pass strip it fixes is still on his `main`; the owner has asked on the PR whether "not wanted" was meant |
| #54 | wildcard-bind origin fix (fork PR #121's work) | **closed, unmerged** | closed silently 2026-10-15; no review, no comment; the LAN-IP rejection it fixes is still on his `main`; the owner has asked there likewise |
| #55 | PERMANOVA Agda proofs (fork PR #127's work) | open | single commit on his HEAD, his CI green |
| #56 | docs + community files (fork PR #143's work, plus its review fixes) | open | single commit on his HEAD |
| #57 | dada2 base-R refactor (first slice of his #36) | open | single commit on his HEAD, his CI green |

Sequencing, stated to him in his issue #58 (2026-10-15): the fork is
**holding its next upstream sync until these verdicts land**, because a
sync moves his `main` and pushes every open PR past `behind_by: 0`
against his own condition 1 — each verdict would then cost a re-cut and
a re-review. One word per PR (merge / redo / close) settles each.

## 3. Upstream progress since the fork's base (what moved "there", measured)

His own commits on `upstream/main` since `257bcde`, including the
absorptions (content that first existed fork-side, now in his commits):

| Date | Commit | What moved |
|---|---|---|
| 2026-10-15 | `52feb605` | **fork PR #113's server entry-point tests, with history** |
| 2026-10-15 | `5f73b70` | **fork PR #112's vsearch helper, with history** |
| 2026-10-15 | `ef80481` | **fork's occupancy-flag base (PR #106 line), with history** |
| 2026-10-07 | `7799de8`..`b21d005` | the CLR (`clr_welch`) method chain — content first built fork-side |
| 2026-10-07 | `592ddd7` | PERMANOVA per-term testing, permutations, untestable terms (his #35) |
| 2026-10-07 | `d0b31f4`, `5b45d09` | the version-stable required-check name (fork's issue #38 finding, his #14) |
| 2026-10-07 | `a37a642`, `578915c`, `c4b2efc`, `144d0c1` | config value gating, remote staging_dir, config-at-warn |
| 2026-10-07 | `f71fa03`, `c860980`, `af75c8c` | the significance statuses (not-run ≠ null result), complete-separation refusal |
| 2026-10-07 | `b86d59f` | the zCompositions-absent CI test |

The Benjamini-Hochberg and scaling Agda proofs landed as **his PR #26,
merged 2026-10-07**.

## 4. The six merge conditions, in his words

Posted on PR #13, 2026-09-28 (abridged only by removing repetition; the
wording is his). **Unchanged and still in force**; condition 1 is
satisfied against whichever commit is `main` when the branch is cut —
today `52feb60`.

> **1. Rebase rather than merging.** This branch shares only one commit with
> `main`; the initial commit. … Concretely: create the branch from
> `ecefb1c72b3d2515e7086024b14227ef13329605` (current `main`); re-apply your
> work on top of it as your own commits; no merge commits from `main` into
> the branch. … I need `behind_by: 0` and `merge_base` equal to
> `ecefb1c72b3d2515e7086024b14227ef13329605`. The PR must also report
> `mergeable: MERGEABLE`.

> **2. Please include in your PR** — the statistics cluster:
> `src/analysis/AnalysisConfig.jl`, `analysis_config.jl`, `numeric_policy.jl`,
> `scaling.jl`, `estimation.jl`, `exact_summaries.jl`, plus the
> `src/MetaManifold.jl` includes they need; `src/analysis/Execution.jl`, only
> if the above requires it; `.github/workflows/ci.yml`: the `name: Julia
> tests` rename and the FastQC/MultiQC install steps to close issues #14 and
> #15; the `bench/` additions, and the tests covering exactly the above; the
> minimum documentation for those changes. **Everything not on this list
> stays on your fork. If you think something else belongs here, please open
> an issue first and ask.**

> **3. Delete `ui/` and all of Genie.** … Remove the directory and every
> reference to it.

> **4. Leave the licence metadata alone.** Do not touch `LICENSE`,
> `CITATION.cff`, … Do not add a `NOTICE`, and do not add a `LICENSES/`
> directory. …

> **5. CI must run and pass on the PR.** A PR with no CI will not be reviewed.

> **6. The description must exist.** What it does, which issues it closes,
> how to run the tests, and the Julia, R and bun versions you tested
> against.

*Measured note, 2026-10-15:* the statistics cluster his condition 2 names
(`AnalysisConfig.jl` and friends) no longer exists **on either side** —
not on the fork's `main`, not in the fork's archives, not upstream. The
work it described was superseded by the absorbed analyses and by fork
issue #1, which re-derives the layer against current `main`. Condition 2
therefore survives as a *whitelist principle* (send what is expected,
ask before anything else), while its specific file list is historical.

## 5. Who can push what

Measured 2026-10-15: pushes to `hyperpolymath/MetaManifold-WebUI` and PRs
against `JoshuaJewell/MetaManifold-WebUI` work with the owner's own
credentials — every unit PR above was pushed and opened that way, and
the fork's own merges likewise. The agent's contribution remains the
patch, the PR body and the measurement that the patch is clean against
current `main`. `RUNBOOK.md` has the commands.

The register remains the durable artefact. It lives here, in git.

## 6. Consequence for the menu

Condition 2 is a *whitelist*: send what he has asked for, and turn
everything else into "open an issue first and ask" — which is what the
catalogue is for. The re-measured menu (2026-10-15) lives in
`UNIT-CATALOGUE.adoc`: twenty-two of the original units are measured
stale — absorbed, superseded, spun out or parked — and the live offer
set is the four open/closed PRs above plus the new-era units appended
with IDs 35–42.
