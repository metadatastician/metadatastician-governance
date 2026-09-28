#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Regression cover for scripts/check-lock-sync.sh.
#
# The interesting property is not "does it find drift". It is that each way the
# check can be *fooled* is red, and that the three-outcome contract holds:
#
#   0 = the check ran and the documents agree
#   1 = the check ran and drift was found
#   2 = NO CHECK WAS PERFORMED (no parser, or a document that will not load)
#
# Exit 2 must never be reachable by callers as "looks fine": a workflow whose
# YAML will not resolve must not read as "requests nothing", and must not
# receive a partial verdict either. Every case below is either a silence fixture
# (clean input, must not fire) or a firing fixture (a named member of a declared
# drift class, must fire).
#
# Fixtures are built in a temporary directory and passed as the optional
# REPO_ROOT argument; nothing here touches the real repository.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-lock-sync.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

if [ "$(bash -c ". '$ROOT/scripts/lib/yaml.sh'; yaml_parser_kind")" = "none" ]; then
  echo "SKIP: no YAML parser available in this environment"
  exit 0
fi

SHA=3d3c42e5aac5ba805825da76410c181273ba90b1
OTHER=1c5b675653bb5c22dbe9b12b556ec555138e09fd

# ── fixture builders ───────────────────────────────────────────────────────
# new_root <name> — a repo root holding a consistent alpha.yml / beta.yml pair
new_root() {
  local d="$TMP/$1"
  mkdir -p "$d/.github/workflows"
  cat > "$d/.github/workflows/alpha.yml" <<YAML
name: alpha
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@$SHA
YAML
  cat > "$d/.github/workflows/beta.yml" <<'YAML'
name: beta
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo nothing external here
YAML
  write_lock "$d"
  printf '%s' "$d"
}

# write_lock <dir> [beta-list-items] [extra-workflow-keys] [extra-dependencies]
# Every argument is inserted verbatim, so a fixture states its own drift.
write_lock() {
  local d="$1" beta="${2:-}" extrawf="${3:-}" extradep="${4:-}" indent
  {
    printf "version: 'v0.0.2'\n"
    printf 'workflows:\n'
    printf "    '.github/workflows/alpha.yml':\n"
    printf "        - 'actions/checkout@%s'\n" "$SHA"
    if [ -n "$beta" ]; then
      printf "    '.github/workflows/beta.yml':\n"
      printf '%s\n' "$beta"
    else
      printf "    '.github/workflows/beta.yml': []\n"
    fi
    [ -n "$extrawf" ] && printf '%s\n' "$extrawf"
    printf 'dependencies:\n'
    printf "    'actions/checkout@%s':\n" "$SHA"
    printf "        ref: '%s'\n" "$SHA"
    printf "        commit: 'sha1-%s'\n" "$SHA"
    printf '        owner_id: 44036562\n'
    printf '        repo_id: 197814629\n'
    [ -n "$extradep" ] && printf '%s\n' "$extradep"
  } > "$d/.github/workflows/actions.lock"
}

run_check() { # run_check <dir> [env assignments...]
  local d="$1"; shift
  env "$@" bash "$CHECK" "$d" > "$TMP/out" 2> "$TMP/err"
  return $?
}

# ── Silence fixture: consistent input must not fire ────────────────────────
d="$(new_root clean)"
run_check "$d"; rc=$?
if [ "$rc" -eq 0 ]; then ok "clean fixture: exit 0"; else bad "clean fixture fired: rc=$rc"; cat "$TMP/out" "$TMP/err"; fi
if grep -q 'every workflow agrees' "$TMP/out"; then ok "clean fixture: states the verdict"; else bad "clean fixture: no verdict line"; fi

# ── Firing fixture: a ref the lock does not record under its path ──────────
# This is the class that kills a run at startup.
d="$(new_root missing_ref)"
printf '      - uses: actions/setup-node@%s\n' "$OTHER" >> "$d/.github/workflows/alpha.yml"
run_check "$d"; rc=$?
if [ "$rc" -eq 1 ]; then ok "missing ref: exit 1"; else bad "missing ref: rc=$rc (want 1)"; fi
if grep -q "refs missing from the lockfile: actions/setup-node@$OTHER" "$TMP/out"; then
  ok "missing ref: names the exact ref"
else
  bad "missing ref: did not name the ref"; cat "$TMP/out"
fi

# ── Firing fixture: a lock entry the workflow no longer requests ───────────
d="$(new_root stale_entry)"
write_lock "$d" "        - 'actions/setup-node@$OTHER'"
run_check "$d"; rc=$?
if [ "$rc" -eq 1 ] && grep -q "stale lockfile entries: actions/setup-node@$OTHER" "$TMP/out"; then
  ok "stale entry: exit 1 and named"
else
  bad "stale entry: rc=$rc"; cat "$TMP/out"
fi

# ── Coverage gap: a workflow with no lock entry — reported, NOT a failure ──
# Measured 2026-09-28: GitHub starts an unlisted workflow (codeql.yml and the
# Scorecard reusable call both run while absent from this repository's lock).
# Calling this drift would be a false alarm, and a detector that cries wolf is
# ignored. It must still be *reported*, so the gap stays visible.
d="$(new_root not_onboarded)"
cat > "$d/.github/workflows/gamma.yml" <<YAML
name: gamma
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@$SHA
YAML
run_check "$d"; rc=$?
if [ "$rc" -eq 0 ]; then ok "not onboarded: exit 0 (coverage gap, not the fault)"; else bad "not onboarded: rc=$rc"; cat "$TMP/out" "$TMP/err"; fi
if grep -q 'NOTE:   not onboarded: .github/workflows/gamma.yml' "$TMP/out"; then
  ok "not onboarded: named in the notes"
else
  bad "not onboarded: gap was not reported"; cat "$TMP/out"
fi
if grep -q 'every workflow agrees' "$TMP/out"; then ok "not onboarded: verdict stated"; else bad "not onboarded: no verdict"; fi

# ── Firing fixture: a lock entry pointing at a workflow that is gone ───────
d="$(new_root dead_path)"
write_lock "$d" "" "    '.github/workflows/deleted.yml': []"
run_check "$d"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'stale lockfile entry: no such workflow file' "$TMP/out"; then
  ok "dead lock path: exit 1 and named"
else
  bad "dead lock path: rc=$rc"; cat "$TMP/out"
fi

# ── Firing fixture: a recorded ref with no dependencies record ─────────────
d="$(new_root no_dependency)"
write_lock "$d" "        - 'actions/setup-node@$OTHER'"
printf '      - uses: actions/setup-node@%s\n' "$OTHER" >> "$d/.github/workflows/alpha.yml"
run_check "$d"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'no dependencies record' "$TMP/out"; then
  ok "missing dependency record: exit 1 and named"
else
  bad "missing dependency record: rc=$rc"; cat "$TMP/out"
fi

# ── Firing fixture: a SHA ref whose recorded commit disagrees ──────────────
d="$(new_root commit_disagrees)"
write_lock "$d" "" "" "    'actions/setup-node@$OTHER':
        ref: '$OTHER'
        commit: 'sha1-1111111111111111111111111111111111111111'
        owner_id: 44036562
        repo_id: 194000000"
printf '      - uses: actions/setup-node@%s\n' "$OTHER" >> "$d/.github/workflows/alpha.yml"
run_check "$d"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'the recorded commit disagrees' "$TMP/out"; then
  ok "commit disagreement: exit 1 and named"
else
  bad "commit disagreement: rc=$rc"; cat "$TMP/out"
fi

# ── Firing fixture: the gate-faking shape. Unparseable workflow. ───────────
# Must be exit 2 even though the same file is also "not onboarded". Judging the
# missing entry before reading the file would be a verdict on unread evidence.
d="$(new_root unparseable)"
printf 'jobs:\n  build:\n    steps:\n      - uses: actions/checkout@abc\n  bad: [\n' > "$d/.github/workflows/broken.yml"
run_check "$d"; rc=$?
if [ "$rc" -eq 2 ]; then ok "unparseable workflow: exit 2 (NO CHECK)"; else bad "unparseable workflow: rc=$rc (want 2)"; cat "$TMP/out" "$TMP/err"; fi
if grep -q 'NO CHECK WAS PERFORMED' "$TMP/err"; then ok "unparseable workflow: says no check was performed"; else bad "unparseable workflow: silent"; fi

# An unparseable workflow that IS onboarded must also be exit 2, not a pass.
d="$(new_root unparseable_onboarded)"
printf 'jobs:\n  build:\n    steps:\n      - uses: actions/checkout@abc\n  bad: [\n' > "$d/.github/workflows/beta.yml"
run_check "$d"; rc=$?
if [ "$rc" -eq 2 ]; then ok "unparseable but onboarded: exit 2"; else bad "unparseable but onboarded: rc=$rc (want 2)"; fi

# ── Firing fixture: no YAML parser available anywhere ──────────────────────
d="$(new_root no_parser)"
run_check "$d" YAML_PARSER_KIND=none; rc=$?
if [ "$rc" -eq 2 ]; then ok "no parser: exit 2 (NO CHECK)"; else bad "no parser: rc=$rc (want 2)"; cat "$TMP/out" "$TMP/err"; fi

# ── Silence fixture: no lockfile at all is not drift ───────────────────────
d="$(new_root no_lockfile)"
rm "$d/.github/workflows/actions.lock"
run_check "$d"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'not in the enforcement cohort' "$TMP/out"; then
  ok "no lockfile: exit 0 and says why"
else
  bad "no lockfile: rc=$rc"; cat "$TMP/out"
fi

# ── Guard against a regression to the text readers (rule Y-1) ──────────────
# The gate must reach its verdict through the parser. A line-oriented reader
# gets a flow-style document wrong, so this fixture is what notices if one is
# ever put back in front of the YAML.
d="$(new_root flow_style)"
cat > "$d/.github/workflows/alpha.yml" <<YAML
name: alpha
on: [push]
jobs: {build: {runs-on: ubuntu-latest, steps: [{uses: 'actions/checkout@$SHA'}]}}
YAML
run_check "$d"; rc=$?
if [ "$rc" -eq 0 ]; then ok "flow-style YAML parses (line readers get this wrong)"; else bad "flow-style YAML: rc=$rc"; cat "$TMP/out" "$TMP/err"; fi

echo
if [ "$fail" -ne 0 ]; then
  echo "lock-sync-test: $fail failure(s), $pass pass(es)" >&2
  exit 1
fi
echo "lock-sync-test: all $pass check(s) passed"
