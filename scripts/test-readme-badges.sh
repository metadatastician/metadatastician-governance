#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readme="$repo_root/README.adoc"
failures=0

if [[ ! -f $readme ]]; then
  printf 'FAIL: README not found at %s\n' "$readme" >&2
  exit 1
fi

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_absent() {
  local needle=$1
  local description=$2

  if grep -Fq -- "$needle" "$readme"; then
    fail "$description"
  else
    printf 'PASS: %s\n' "$description"
  fi
}

assert_exactly_once() {
  local needle=$1
  local description=$2
  local count

  count=$(grep -Fc -- "$needle" "$readme" || true)
  if [[ $count -ne 1 ]]; then
    fail "$description (found $count occurrences)"
  else
    printf 'PASS: %s\n' "$description"
  fi
}

false_badge_target='bestpractices.dev/projects/8509'
scorecard_badge='image:https://api.scorecard.dev/projects/github.com/metadatastician/metadatastician-governance/badge[OpenSSF Scorecard,link="https://scorecard.dev/viewer/?uri=github.com/metadatastician/metadatastician-governance"]'

assert_absent "$false_badge_target" \
  'README does not claim OpenSSF Best Practices project 8509'
assert_absent 'badge[OpenSSF Best Practices' \
  'README does not display an unverified OpenSSF Best Practices badge'
assert_absent 'nimage:' \
  'README contains no malformed nimage badge directive'
assert_exactly_once "$scorecard_badge" \
  'README retains the repository-specific OpenSSF Scorecard badge exactly once'

if awk '
  /^Status: / {
    found = 1
    if (previous != "") {
      exit 1
    }
  }
  { previous = $0 }
  END {
    if (!found) {
      exit 1
    }
  }
' "$readme"; then
  printf 'PASS: README keeps a blank-line boundary before its status\n'
else
  fail 'README must keep a blank-line boundary before its status'
fi

if [[ $failures -ne 0 ]]; then
  printf '%d README badge regression test(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'All README badge regression tests passed\n'
