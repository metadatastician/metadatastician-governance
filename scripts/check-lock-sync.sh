#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# check-lock-sync.sh — is .github/workflows/actions.lock in sync with the YAML?
#
# ── The fault this detects ─────────────────────────────────────────────────
#
# GitHub's locked-dependencies feature makes `.github/workflows/actions.lock`
# the manifest: the lock, not the YAML, is what gets resolved at run creation.
# A `uses:` ref that the lock does not record *under that workflow's own path*
# makes the whole repository unstartable — the run is refused with
# `startup_failure`, ZERO jobs, no log and no annotation in REST or GraphQL.
#
# It is self-reinflicting. Dependabot rewrites `uses:` refs in the YAML and
# cannot write lockfiles, so every action bump re-acquires the fault. Measured
# 2026-08-25 across the estate: 60 of 60 sampled repos carried both a lockfile
# and a Dependabot config. Repos do not "go bad again" — nobody breaks them,
# the clock does.
#
# It happened here. Commit 5d9e8b8 pinned this repo's sweep checkout to a SHA
# while the lock still recorded `@v7.0.1`, and the daily CI-Health Sweep was
# refused at startup for four days (runs 35957324128, 36096095736,
# 36218967182, 36295476367). The sweep is this estate's only detector for the
# infrastructure failure classes, so the detector was switched off by the class
# it detects, and issue #30 kept showing a stale report that looked current.
#
# ── How this reads the files (upstream rule Y-1, IN FORCE) ─────────────────
#
# Both files are YAML and both are read only through `scripts/lib/yaml.sh`,
# which resolves the document with a real parser (`yq` first) and hands
# canonical JSON to `jq`. No grep, no sed, no awk over YAML — see Y-1 and the
# `yaml.sh` header for why that is not a style preference.
#
# This matters here specifically: `actions.lock` records each workflow's pins
# as a *flow sequence under a quoted path key*, and records reusable-workflow
# calls as `owner/repo@sha` with the sub-path stripped, and records transitive
# pins reached through a callee in `dependencies[*].uses`. A line-oriented
# reader gets all three wrong and says so confidently.
#
# ── Calibration: which differences are fatal, and which are not ─────────────
#
# Measured in this repository, 2026-09-28:
#
#   LISTED workflow, refs disagree with the lock  -> run REFUSED at creation.
#       This is the incident: ci-health-sweep.yml was listed as
#       `actions/checkout@v7.0.1` while the workflow asked for a SHA, and the
#       run was refused daily for four days.
#
#   UNLISTED workflow, uses external actions     -> run STARTS.
#       The oikosbot and scorecard reusable calls and the secret scanner plus
#       (until its 2026-09-29 retirement) the local codeql.yml all ran on the
#       default branch while absent from the lock. So "not onboarded" is a real
#       gap in coverage, but it is NOT the failure mode, and calling it drift
#       would be a false alarm of exactly the kind that gets a detector ignored.
#
# So: a listed path that disagrees with the workflow is a FAIL (exit 1). An
# unlisted path is reported as a NOTE and does not fail the run. Reporting them
# the other way round is how a gate earns a reputation for crying wolf —
# `standards/scripts/check-lockfile-drift.sh` records the same lesson: "treat
# output as 'reconcile this', not 'this is why CI is down'".
#
# ── Exit contract (never two outcomes where three are needed) ──────────────
#   0 = every workflow and the lock agree
#   1 = drift found (the finding is on stdout, one `FAIL <path>` block each)
#   2 = NO CHECK WAS PERFORMED — no parser, or a document that would not load.
#       Never reported as a pass; a check that did not run has no verdict.
#
# Usage: check-lock-sync.sh [REPO_ROOT]        (default: repository root)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/yaml.sh
. "$SCRIPT_DIR/lib/yaml.sh"

ROOT="${1:-$(cd "$SCRIPT_DIR/.." && pwd)}"
WFDIR="$ROOT/.github/workflows"
LOCK="$WFDIR/actions.lock"

if [ ! -d "$WFDIR" ]; then
  printf 'E-INSTRUMENT: no .github/workflows under %s — NO CHECK WAS PERFORMED\n' "$ROOT" >&2
  exit 2
fi

if [ ! -f "$LOCK" ]; then
  # Absence is not drift: a repo outside the enforcement cohort is legitimately
  # lockfile-free. Report the population and pass, so the output never implies
  # a check that did not happen.
  printf 'lock-sync: no actions.lock in %s — not in the enforcement cohort, nothing to compare\n' "$WFDIR"
  exit 0
fi

lock_json="$(yaml_to_json "$LOCK")" || {
  printf 'E-INSTRUMENT: actions.lock did not resolve as YAML — NO CHECK WAS PERFORMED\n' >&2
  exit 2
}

fail=0
unlisted=()
fail_block() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }
reason()     { printf '    %s\n' "$1"; }

# ── Population. State it: a gate that does not say what it examined cannot
#    report that it examined the wrong thing.
mapfile -t files < <(
  for f in "$WFDIR"/*.yml "$WFDIR"/*.yaml; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in actions.lock) continue ;; esac
    printf '%s\n' "$f"
  done | sort
)

if [ "${#files[@]}" -eq 0 ]; then
  printf 'E-INSTRUMENT: no workflow files found under %s — NO CHECK WAS PERFORMED\n' "$WFDIR" >&2
  exit 2
fi
printf 'lock-sync: examining %d workflow file(s) against %s\n' "${#files[@]}" "${LOCK#"$ROOT"/}"

# ── Pre-pass: resolve every workflow before judging any of them ────────────
# A workflow that will not parse must not receive a partial verdict. Reporting
# "not onboarded" for a file whose refs were never read is a confident answer
# about a structure the gate could not see — the exact defect class this whole
# design exists to stop. So: no verdict at all (exit 2) until every document has
# resolved.
declare -A WF_REFS=()
for f in "${files[@]}"; do
  rel="$(basename "$f")"
  if ! refs="$(yaml_uses_in "$f")"; then
    printf 'E-INSTRUMENT: .github/workflows/%s did not resolve as YAML — NO CHECK WAS PERFORMED\n' "$rel" >&2
    exit 2
  fi
  WF_REFS["$rel"]="$(printf '%s\n' "$refs" | sed '/^$/d' | sort -u)"
done

lock_keys="$(jq_read "$lock_json" -r '.workflows // {} | keys[]')" || {
  printf 'E-INSTRUMENT: actions.lock has no readable .workflows map — NO CHECK WAS PERFORMED\n' >&2
  exit 2
}
lock_paths=()
[ -n "$lock_keys" ] && mapfile -t lock_paths <<< "$lock_keys"

# ── Check 1: lockfile entries that point at nothing (dead keys) ────────────
# A key for a deleted workflow is not harmful to startup, but it is a stale
# manifest entry and it hides a rename: the renamed file then reads as "not
# onboarded" and the operator sees two mysteries instead of one.
for lp in "${lock_paths[@]}"; do
  case "$lp" in
    .github/workflows/*) : ;;
    *) fail_block "$lp"; reason "lockfile key is not a path under .github/workflows/"; continue ;;
  esac
  rel="${lp#*/workflows/}"
  if [ ! -f "$WFDIR/$rel" ]; then
    fail_block "$lp"
    reason "stale lockfile entry: no such workflow file (${rel}) — a rename here hides the real fault"
  fi
done

# ── Per-workflow comparison, both directions ───────────────────────────────
checked=0
for f in "${files[@]}"; do
  rel="$(basename "$f")"
  key=".github/workflows/$rel"
  checked=$((checked + 1))

  have_lock_entry=0
  for lp in "${lock_paths[@]}"; do
    [ "$lp" = "$key" ] && { have_lock_entry=1; break; }
  done
  if [ "$have_lock_entry" -eq 0 ]; then
    # Not fatal today (see the calibration note in the header), but it is
    # unverifiable: nothing ties this workflow's refs to resolved commits.
    unlisted+=("$key")
    continue
  fi

  # `uses:` refs the workflow actually requests, from the parse pre-pass.
  want_sorted="${WF_REFS[$rel]}"
  have_sorted="$(jq_read "$lock_json" -r --arg p "$key" '.workflows[$p] // [] | .[]' | sort -u)"

  # These two sets are compared as *text*, which is safe: both sides are
  # already parser output, not YAML being searched.
  missing="$(comm -23 <(printf '%s\n' "$want_sorted") <(printf '%s\n' "$have_sorted"))"
  stale="$(comm -13 <(printf '%s\n' "$want_sorted") <(printf '%s\n' "$have_sorted"))"

  if [ -n "$missing" ] || [ -n "$stale" ]; then
    fail_block "$key"
    if [ -n "$missing" ]; then
      while IFS= read -r r; do
        [ -n "$r" ] || continue
        reason "refs missing from the lockfile: $r"
      done <<< "$missing"
    fi
    if [ -n "$stale" ]; then
      while IFS= read -r r; do
        [ -n "$r" ] || continue
        reason "stale lockfile entries: $r"
      done <<< "$stale"
    fi
    reason "fix: gh actions-lock .github/workflows/<file> --no-migrate-local-actions, then review the diff"
  fi
done

# ── Check 2: every recorded ref has a dependencies record ──────────────────
# A ref listed under a workflow but absent from `dependencies` has no resolved
# commit, and GitHub cannot resolve it at run creation.
dep_key_list="$(jq_read "$lock_json" -r '.dependencies // {} | keys[]')" || {
  printf 'E-INSTRUMENT: actions.lock has no readable .dependencies map — NO CHECK WAS PERFORMED\n' >&2
  exit 2
}
dep_keys=()
[ -n "$dep_key_list" ] && mapfile -t dep_keys <<< "$dep_key_list"
for lp in "${lock_paths[@]}"; do
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    found=0
    for dk in "${dep_keys[@]}"; do
      [ "$dk" = "$ref" ] && { found=1; break; }
    done
    if [ "$found" -eq 0 ]; then
      fail_block "$lp"
      reason "ref has no dependencies record, so it cannot resolve at run creation: $ref"
    fi
  done < <(jq_read "$lock_json" -r --arg p "$lp" '.workflows[$p] // [] | .[]')
done

# ── Check 3: dependency records are well formed ────────────────────────────
for dk in "${dep_keys[@]}"; do
  case "$dk" in
    *\$* | *//* | *@@*)
      fail_block "$dk"
      reason "malformed dependency key (templating or duplicate @ leaked into the lock)"
      continue
      ;;
  esac
  slug="${dk%@*}"
  ref="${dk##*@}"
  if ! printf '%s' "$slug" | grep -qE '^[^/@:]+/[^/@:]+$'; then
    fail_block "$dk"
    reason "malformed dependency key: expected OWNER/REPO@REF"
    continue
  fi
  if [ -z "$ref" ]; then
    fail_block "$dk"
    reason "malformed dependency key: empty ref"
    continue
  fi

  commit="$(jq_read "$lock_json" -r --arg k "$dk" '.dependencies[$k].commit // ""')"
  case "$commit" in
    sha1-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) : ;;
    *)
      fail_block "$dk"
      reason "dependency has no resolvable commit (schema requires commit: sha1-<40 hex>), got: ${commit:-<absent>}"
      continue
      ;;
  esac
  if printf '%s' "$ref" | grep -qE '^[0-9a-f]{40}$'; then
    if [ "$commit" != "sha1-$ref" ]; then
      fail_block "$dk"
      reason "ref is a commit SHA but the recorded commit disagrees: $commit"
    fi
  fi

  # Transitive pins reached through a callee (reusable workflow or composite
  # action). Each must also be a first-class dependency, or it cannot resolve.
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    found=0
    for dk2 in "${dep_keys[@]}"; do
      [ "$dk2" = "$t" ] && { found=1; break; }
    done
    if [ "$found" -eq 0 ]; then
      fail_block "$dk"
      reason "transitive pin is not recorded as a dependency: $t"
    fi
  done < <(jq_read "$lock_json" -r --arg k "$dk" '.dependencies[$k].uses // [] | .[]')
done

# ── Verdict ────────────────────────────────────────────────────────────────
printf 'lock-sync: examined %d workflow file(s), %d lockfile workflow key(s), %d dependencies record(s)\n' \
  "$checked" "${#lock_paths[@]}" "${#dep_keys[@]}"

if [ "${#unlisted[@]}" -ne 0 ]; then
  printf 'NOTE: %d workflow(s) have no actions.lock entry, so their refs are not pinned to resolved commits.\n' "${#unlisted[@]}"
  printf 'NOTE: GitHub does not currently refuse these (measured 2026-09-28), so this is a coverage gap, not the fault.\n'
  for u in "${unlisted[@]}"; do
    printf 'NOTE:   not onboarded: %s\n' "$u"
  done
  printf 'NOTE: close the gap by regenerating the lock with `gh actions-lock`; do not hand-write entries.\n'
fi

if [ "$fail" -ne 0 ]; then
  printf 'lock-sync: %d drift finding(s) — see the FAIL blocks above\n' "$fail" >&2
  exit 1
fi
printf 'lock-sync: every workflow agrees with actions.lock\n'
exit 0
