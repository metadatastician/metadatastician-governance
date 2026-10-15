<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->

# Runbook — landing a unit

## The one thing to know first

**The Arena bot cannot push to the fork or act on the upstream repo.** Its
token is scoped to this repository only; pushing to
`hyperpolymath/MetaManifold-WebUI` returns `403 Permission denied`. So every
branch push and every PR below is done with *your* credentials, from your
machine. The bot's job is to prepare the patch and prove it is clean.

## 0. Once

```sh
git clone https://github.com/hyperpolymath/MetaManifold-WebUI.git mm-fork
cd mm-fork
git remote add upstream https://github.com/JoshuaJewell/MetaManifold-WebUI.git
git fetch upstream main
```

## 1. Land a prepared patch (e.g. units 14 + 15)

```sh
cd mm-fork
git fetch upstream main
git checkout -b upstream/14-15-ci-rename-and-qc-tools upstream/main

git am /path/to/metadatastician-governance/docs/upstream-absorption/patches/14-15-ci-rename-and-qc-tools.patch
#   or, to review before committing:
#   git apply --index <patch>   && git commit

# Prove condition 1 before pushing:
gh api repos/JoshuaJewell/MetaManifold-WebUI/compare/main...hyperpolymath:HEAD \
  --jq '{behind_by, merge_base: .merge_base_commit.sha}'
#   want behind_by == 0 and merge_base == upstream/main's sha

git push -u origin upstream/14-15-ci-rename-and-qc-tools
gh pr create --repo JoshuaJewell/MetaManifold-WebUI --base main \
  --head hyperpolymath:upstream/14-15-ci-rename-and-qc-tools \
  --title "ci: rename the Julia check and install FastQC + MultiQC" \
  --body-file docs/upstream-absorption/pr-bodies/14-15.md
gh pr view 15 --repo JoshuaJewell/MetaManifold-WebUI --json mergeable --jq .mergeable
#   want MERGEABLE
```

## 2. Condition 1, restated as a command

Every unit branch is cut from **`upstream/main` as it is at that moment**, not
from a previous unit's branch and not from `fork/main`. Before pushing:

```sh
gh api repos/JoshuaJewell/MetaManifold-WebUI/compare/main...hyperpolymath:<branch> \
  --jq '{behind_by, ahead_by, merge_base: .merge_base_commit.sha}'
```

`behind_by: 0`. If upstream moved under you while you worked, re-cut: create a
fresh branch from the new `upstream/main` and re-apply. Do not merge `main`
into the branch.

## 3. What the bot leaves behind for each unit

* a patch under `patches/` that applies cleanly to `upstream/main`;
* a PR body under `pr-bodies/` containing what it does, the issues it closes,
  how to run the tests, and the versions it was written against;
* a row in `UNIT-CATALOGUE.adoc` with the file set and the dependency list.

If a unit has no patch yet, it is not ready — see `blocked` in the catalogue
and the dependency notes. Two units are blocked on real code dependencies
right now (01 needs the DOI bundles module and `Epistemic`; 30 is written
against the fork's frontend layout), and both are documented there.

---

## Update, 2026-10-15 — the era change, and what it alters

Measured in `UPSTREAM-SYNC-STATE.md` §1.1: upstream now absorbs fork
commits **with their history** (his HEAD is a fork commit), the merge base
is `257bcde`, and the fork deletes nothing upstream holds. The commands
above are unchanged where it matters — every unit branch is still cut
fresh from his current `main` with `behind_by: 0` — with these deltas:

1. **The default branch ref.** `BRANCH_REF` defaults to the fork's
   `origin/main`; the old `arena/01a0db23-*` default is gone with its
   branch.
2. **Condition 1 self-check, current form.** The compare runs against his
   live HEAD (`52feb605` today); the point is unchanged — a PR older than
   his HEAD needs a re-cut, and the fork holds its syncs so that does not
   happen to open PRs (his issue #58).
3. **Patches and PR bodies.** The one ready patch (14+15) is absorbed
   (his `d0b31f4`/`5b45d09`); `patches/` and `pr-bodies/` are historical
   now, kept because the register does not delete its own record. New
   units' PR bodies live on the PRs themselves; this register keeps the
   verdicts.
4. **What "land a unit" means now.** When he merges a fork PR, the fork
   commits land upstream with history — the next sync then picks them up
   as a three-way merge from `257bcde`, not an add/add resolution. The
   fork's squashed merges mean the fork still re-derives content; the
   sync resolves deliberately, as #120 (2026-10-15) demonstrated.
