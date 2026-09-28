#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Regression cover for scripts/lib/yaml.sh.
#
# ── Why this test is load-bearing ──────────────────────────────────────────
#
# The estate's actions-lockfile failure class has one cause: a line-oriented
# reader gave a confident, well-formed answer about a structure it could not
# see. `gh actions-lock`'s extractor saw step-level `uses:` only, so every
# job-level reusable-workflow call was classified as an orphan pin; 71 refs were
# "fixed" across 14 branches on the strength of that reading, turning green
# repositories red.
#
# The payload of this test is therefore not "does it find refs". It is:
#
#   1. a JOB-LEVEL `uses:` is seen at all                     (firing fixture)
#   2. a COMMENTED-OUT `uses:` is not seen                    (silence fixture)
#   3. an unparseable document produces exit 2, never an empty ref list
#   4. no parser at all produces exit 2, never a pass
#
# (3) and (4) are the two ways a gate can fake a verdict. Both must be red.
#
# Per the estate Test Doctrine (`proven-tests-and-benches` docs/TEST-DOCTRINE):
# the harness must never fire on clean input, the payload must always fire on a
# member of its declared class, and a crash is exit 2 — "no check performed" —
# never a pass.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

# ── Firing fixture (gate-faking shape 3): forced parser kind, binary absent ─
# Selecting a parser that is not installed must be an instrument failure —
# exit 2, with a message — never an empty parse. nickel is the realistic
# case: it sits mid-chain, so an environment that selects or forces it
# without the binary must refuse rather than read the document as empty.
# This block needs no ambient parser, so it runs BEFORE the no-parser SKIP.
printf 'name: force\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n' > "$TMP/force.yml"
if ! command -v nickel >/dev/null 2>&1; then
  out="$(bash -c "YAML_PARSER_KIND=nickel; . '$ROOT/scripts/lib/yaml.sh'; yaml_to_json '$TMP/force.yml'" 2>&1)"
  rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'nickel was selected but is not installed'; then
    ok "forced nickel kind without the binary is exit 2 and says so"
  else
    bad "forced nickel kind without the binary: rc=$rc out=[$out]"
  fi
fi
if [ "$fail" -ne 0 ]; then
  # A failure here must not be erased by the SKIP that follows it.
  echo "FAIL: pre-skip fixtures failed; not skipping"
  exit 1
fi

if [ "$(bash -c ". '$ROOT/scripts/lib/yaml.sh'; yaml_parser_kind")" = "none" ]; then
  echo "SKIP: no YAML parser available in this environment"
  exit 0
fi

mkdir -p "$TMP/wf"

# ── Firing fixture: the exact shape the estate's extractor went blind on ───
cat > "$TMP/wf/job-level.yml" <<'YAML'
name: caller
on: [push]
jobs:
  reusable:
    uses: hyperpolymath/standards/.github/workflows/scorecard-reusable.yml@892497fe373744874316710966b81ae6f0ea9e66
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
      - name: composite with a sub-path
        uses: github/codeql-action/init@1c5b675653bb5c22dbe9b12b556ec555138e09fd
      - name: a comment is not a ref
        uses: actions/setup-node@1111111111111111111111111111111111111111
      # - uses: actions/never-runs@2222222222222222222222222222222222222222
      - name: local refs are not lockable
        uses: ./.github/actions/local
YAML

echo "yaml_uses_in — firing fixture (job-level, sub-path, comment, local)"
out="$(bash -c ". '$ROOT/scripts/lib/yaml.sh'; yaml_uses_in '$TMP/wf/job-level.yml'")"
rc=$?
if [ "$rc" -eq 0 ]; then ok "exit 0 on a parseable workflow"; else bad "expected exit 0, got $rc"; fi

expect_present() {
  if printf '%s\n' "$out" | grep -qxF "$1"; then ok "sees $1"; else bad "missing ref: $1"; fi
}
expect_absent() {
  if printf '%s\n' "$out" | grep -qxF "$1"; then bad "must not see $1"; else ok "correctly ignores $1"; fi
}

expect_present "hyperpolymath/standards@892497fe373744874316710966b81ae6f0ea9e66"
expect_present "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
expect_present "github/codeql-action@1c5b675653bb5c22dbe9b12b556ec555138e09fd"
expect_present "actions/setup-node@1111111111111111111111111111111111111111"
expect_absent  "actions/never-runs@2222222222222222222222222222222222222222"
expect_absent  "actions/local@3d3c42e5aac5ba805825da76410c181273ba90b1"

# ── Silence fixture: a file with no external refs must yield nothing, not fire
cat > "$TMP/wf/none.yml" <<'YAML'
name: no external actions
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo hello
YAML
out="$(bash -c ". '$ROOT/scripts/lib/yaml.sh'; yaml_uses_in '$TMP/wf/none.yml'")"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  ok "silence fixture: no refs, no fire"
else
  bad "silence fixture fired or failed: rc=$rc out=[$out]"
fi

# ── Firing fixture (gate-faking shape 1): unparseable document ─────────────
# An unparseable workflow must not read as "requests nothing". Reading it that
# way would silently pass a workflow whose refs were never examined.
printf 'jobs:\n  build:\n    steps:\n      - uses: actions/checkout@abc\n   bad_indent: [\n' > "$TMP/wf/broken.yml"
out="$(bash -c ". '$ROOT/scripts/lib/yaml.sh'; yaml_uses_in '$TMP/wf/broken.yml'" 2>/dev/null)"
rc=$?
if [ "$rc" -eq 2 ]; then
  ok "unparseable workflow is exit 2 (NO CHECK), not an empty ref list"
else
  bad "unparseable workflow returned rc=$rc (must be 2); output=[$out]"
fi

# ── Firing fixture (gate-faking shape 2): no parser at all ─────────────────
out="$(bash -c "YAML_PARSER_KIND=none; . '$ROOT/scripts/lib/yaml.sh'; yaml_to_json '$TMP/wf/none.yml'" 2>&1)"
rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'NO CHECK WAS PERFORMED'; then
  ok "no parser is exit 2 and says so"
else
  bad "no parser returned rc=$rc without the no-check notice"
fi

# A missing file is an instrument failure too, not an empty document.
bash -c ". '$ROOT/scripts/lib/yaml.sh'; yaml_to_json '$TMP/wf/does-not-exist.yml'" >/dev/null 2>&1
if [ $? -eq 2 ]; then ok "missing file is exit 2"; else bad "missing file did not return 2"; fi

echo
if [ "$fail" -ne 0 ]; then
  echo "yaml-reader-test: $fail failure(s), $pass pass(es)" >&2
  exit 1
fi
echo "yaml-reader-test: all $pass check(s) passed"
