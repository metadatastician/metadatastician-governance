#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Regression tests for the compliance badges in README.adoc.
#
# This was `scripts/tests/test_readme_badges.py`, run through a wrapper. It is
# now plain Bash with the same three checks, so the canonical shell test
# discovery (`tests/*.sh`) runs it directly. Set README to test another file.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="${README:-$ROOT/README.adoc}"

if [ ! -f "$README" ]; then
  echo "readme-badges-test: README not found at $README" >&2
  exit 1
fi

failures=0
pass() { printf 'ok: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

# The compliance block: the lines after "// Compliance" up to the first blank
# line. The line after that blank line is the "status" line.
if ! grep -qx -- '// Compliance' "$README"; then
  echo "readme-badges-test: no '// Compliance' marker in $README" >&2
  exit 1
fi
block=$(awk '/^\/\/ Compliance$/ { on = 1; next } on && /^$/ { exit } on { print }' "$README")
after=$(awk '/^\/\/ Compliance$/ { on = 1; next } on && seen { print; exit } on && /^$/ { seen = 1 }' "$README")

# 1. The unrelated Best Practices badge is absent (case-insensitive, whole file).
if grep -qiF -e 'bestpractices.dev' -e 'openssf best practices' -e '/projects/8509' "$README"; then
  fail 'unrelated OpenSSF Best Practices badge is present'
else
  pass 'unrelated Best Practices badge is absent'
fi

# 2. The repository Scorecard badge is kept exactly once, and is the only
#    OpenSSF mention in the block.
expected='image:https://api.scorecard.dev/projects/github.com/metadatastician/metadatastician-governance/badge[OpenSSF Scorecard,link="https://scorecard.dev/viewer/?uri=github.com/metadatastician/metadatastician-governance"]'
badges=$(printf '%s\n' "$block" | grep -oF -- "$expected" | wc -l)
openssf=$(printf '%s\n' "$block" | grep -oi 'openssf' | wc -l)
if [ "$badges" -eq 1 ] && [ "$openssf" -eq 1 ]; then
  pass 'repository Scorecard badge is kept exactly once'
else
  fail "Scorecard badge count $badges (want 1), openssf mentions $openssf (want 1)"
fi

# 3. The badges stay separated from the status line.
case "$after" in
  'Status: '*) pass 'compliance badges stay separated from status' ;;
  *) fail 'compliance badges must be followed by a blank line, then "Status: "' ;;
esac

if [ "$failures" -ne 0 ]; then
  printf '%d README badge test(s) failed\n' "$failures" >&2
  exit 1
fi
echo "OK"
