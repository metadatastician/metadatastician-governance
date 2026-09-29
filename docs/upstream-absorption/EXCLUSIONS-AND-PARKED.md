<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->

# Excluded and parked

Things deliberately kept out of the menu, with the reason, so that nobody has
to rediscover it and nothing sneaks back in inside a "small" PR.

## 1. Genie / Stipple — thrown out, not deferred

`ui/**` (11 files) and `.github/workflows/ui.yml`.

Rejected by the maintainer on PR #7 ("The Genie direction is rejected") and
again on PR #13. The HTTP layer in the project is **Oxygen.jl**
(`Project.toml`, `src/server/server.jl`); `ui/Project.toml` is the only thing
that depends on Genie 6 / Stipple 1 / StippleUI 1.

The directory is removed from the working set. Any unit that reintroduces a
Genie, Stipple or StippleUI reference is wrong on arrival.

## 2. Marid + Vue replacing TypeScript and React — parked

The frontend's typed shell, views and components (`frontend/src/**`, 81 files)
belong to a separate piece of work: replacing TypeScript and React with Marid
and Vue. That work is **in progress elsewhere and excluded from this menu
entirely** until it is ready to be offered on its own terms.

Consequence: `frontend/src/**` is out of scope for every unit in the
catalogue. The only frontend units offered are test-only
(`frontend/tests/**`, unit 30) and `frontend/bench/**` (unit 31) — neither
touches application source.

## 3. His licence metadata — hands off, permanently

Per his condition 4: `LICENSE`, `CITATION.cff`, the licence and
acknowledgement sections of `README.md`, the headers on files he wrote, no
`NOTICE`, no `LICENSES/` directory. Credit, if wanted, is asked for in a PR
description — never taken by editing `CITATION.cff`.

The fork carries a `LICENSES/` directory (4 files) and a `NOTICE`. Both stay
on the fork.

## 4. The 102 stale deletions — an artefact, never an intention

The branch was cut from upstream's July state. Diffed against today's
`upstream/main` it deletes 102 paths, including his publication-table builder,
figure builder, phylogenetic-placement panels and all nine README
screenshots. Those deletions mean "our branch is old", not "these files
should go".

Every unit is built by **re-applying a file set onto current `main`**. No
unit may delete a path that exists upstream unless that deletion is the
unit's stated purpose. `MAKE-UNITS.sh` fails loudly if one does.

## 5. Documentation bulk — parked

`docs/**` on the fork is 121 files: 33 wiki pages, 21 triage records, 13
milestone logs, 8 migration notes, 7 issue specs, 5 integration notes, 4
compliance, 3 audit, and so on. His condition allows *"the minimum
 documentation for those changes"* — which is unit 13 (`docs/statistics/**`)
and nothing else.

The rest stays on the fork. It is our working record, not his reading list.

## 6. Estate-governance overlay — parked

`EXPLAINME.adoc`, `ROADMAP.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`,
`CONTRIBUTING.md`, `CHANGELOG.md`, `packaging/**`, `.githooks/**`,
`stapeln.toml`, `guix.scm`, `channels.scm` and the `Justfile` are the
estate's own conventions applied to a repository that is not ours. They are
offered as one ask-first unit (32, `repo-tooling`) rather than smuggled in
under a statistics PR — and should not be sent at all unless he asks.
