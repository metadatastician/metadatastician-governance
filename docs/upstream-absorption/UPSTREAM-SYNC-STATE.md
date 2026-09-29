<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->

# Upstream sync state — MetaManifold-WebUI

Measured 2026-09-29. Every number here is re-derivable with
`MAKE-UNITS.sh`; nothing is carried over from a previous reading.

| Repo | Role | Default branch |
|---|---|---|
| `JoshuaJewell/MetaManifold-WebUI` | upstream — his | `main` |
| `hyperpolymath/MetaManifold-WebUI` | fork — ours | `main` |

## 1. The measured divergence

```
upstream/main  HEAD   6b2693d7dd2ccf9959d9ca170b3716a6e02e88ab
                      "Move the server into the package and build the
                       frontend at install"            2026-09-28
fork/main      HEAD   9f3ec0293a9b859c4f2464ea2fffb473be96ba8f
PR #13 head           0d1fd6830c268f411acc147aac2700f58c5aaceb
merge base            78845531c48ab188ceffcaf24703df34dc508181
                      ("Initial commit" — the only shared commit)
```

* `fork/main` vs `upstream/main`: **98 ahead, 253 behind**, merge base = the
  initial commit. The fork was history-rewritten (blob strip) which renamed
  every commit, so the two sides have no usable three-way base.
* `PR #13 head` vs **current** `upstream/main`: **397 added, 154 modified,
  102 deleted**.

## 2. The 102 deletions are the serious finding

The PR #13 branch was cut from upstream's July state. Re-diffed against
current `main`, it *deletes* 102 paths that exist upstream today — including
his most recent work:

```
README.md                                   codecov.yml
.github/screenshots/*.png  (9 files)        frontend/src/figure/*  (10 files)
frontend/src/components/PublicationTables*  frontend/src/components/PlacementPanel.tsx
frontend/src/components/TreesPanel.tsx      frontend/src/components/ReportPanel.tsx
frontend/src/components/AnalysisWorkspace*  frontend/src/components/dataTable/* (6)
```

Those deletions are an artefact of a stale base, **not** an intention. Any
unit that still carries them would silently remove his publication-table
builder, figure builder and phylogenetic-placement panels. Every unit in the
catalogue is therefore built by *re-applying* file sets onto current
`upstream/main`, never by replaying the branch.

## 3. Upstream progress since the fork's base (what he has done "there")

| Date | Commit | What moved |
|---|---|---|
| 2026-09-28 | `6b2693d7d` | Move the server into the package; build the frontend at install |
| 2026-09-28 | `547b20404` | Publication table builder; remove chart customisation |
| 2026-09-18 | `e817ed76b` | Phylogenetic placement: MAFFT, trimAl, IQ-TREE, RAxML, gappa; reference tree library |
| 2026-09-15 | `ac099a20f` | Figure builder, reports, study analysis workspace |
| 2026-09-12 | `5e95e5c7f` | Classifier-specific taxonomy columns, heatmaps, read funnel, tree viewer |
| 2026-09-04 | `b3bcc0d81` | Offload DADA2 stages to the bioserver; serialise jobs per run |
| 2026-08-29 | `46229d5e1` | Hash primers and reference databases into run configs; verify downloads |

Two of these collide with units in the catalogue and are flagged
`ask-first` there: the DOI/publication work (his `PublicationTables*`), and
anything touching `frontend/src/figure/`.

## 4. The six merge conditions, in his words

Posted on PR #13, 2026-09-28 (abridged only by removing repetition; the
wording is his):

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

> **3. Delete `ui/` and all of Genie.** `ui/Project.toml` still depends on
> Genie 6, Stipple 1 and StippleUI 1 … Remove the directory and every
> reference to it.

> **4. Leave the licence metadata alone.** Do not touch `LICENSE`,
> `CITATION.cff`, the licence and acknowledgement sections of `README.md`, or
> the headers on files you did not write. Do not add a `NOTICE`, and do not
> add a `LICENSES/` directory. …

> **5. CI must run and pass on the PR.** The branch hasn't got a single
> workflow run. A PR with no CI will not be reviewed.

> **6. The description must exist.** What it does, which issues it closes,
> how to run the tests, and the Julia, R and bun versions you tested
> against.

Note that `ecefb1c` was `main` when he wrote that; `main` is now
`6b2693d7d`. Condition 1 is satisfied against whichever commit is `main` at
the moment the branch is cut.

## 5. Who can push what

The agent token used to prepare these units is scoped to
`metadatastician/metadatastician-governance` only. Pushing a branch to
`hyperpolymath/MetaManifold-WebUI` returns `403 Permission denied`, and it
cannot open or comment on anything in the upstream repo either. Consequence:
**unit branches and PRs are pushed with your own credentials**; the agent's
contribution is the patch, the PR body and the measurement that the patch is
clean against current `main`. `RUNBOOK.md` has the commands.

This also means the register is the durable artefact. It lives here, in git,
where the token can write.

## 6. Consequence for the menu

Condition 2 is a *whitelist*. Six of the ~30 units in the catalogue are on
it (statistics ×6, ci ×2, bench ×1, tests, minimum docs). Everything else is
offered on the understanding that it needs an issue and a yes before it is
sent — which is exactly what the menu is for: it turns "open an issue first
and ask" into a list he can tick.
