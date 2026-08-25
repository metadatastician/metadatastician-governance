#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath)
# Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# detect-wipe.sh — detect repos where allow-list was cleared (empty patterns_allowed)
# This is the companion to the heal-then-wipe oscillation investigation (Issue #638).
#
# Scans all repos for the wipe signature: allowed_actions=selected with
# patterns_allowed=[] or missing. These are the repos that will cause startup_failure.
#
# Usage: detect-wipe.sh [owner]
#        OWNER env var can override default (hyperpolymath)
#
# Exit codes: 0 = no wipes found, >0 = number of wiped repos found
set -euo pipefail

O="${OWNER:-${1:-hyperpolymath}}"
echo "==> Scanning $O for wiped allow-lists (allowed_actions=selected, patterns_allowed=[])..."

wiped=0
for r in $(gh repo list "$O" --source --no-archived --limit 1000 --json name --jq '.[].name' | sort); do
  # Skip denylisted repos (same as sweep.sh)
  DENYLIST="${CI_HEALTH_DENYLIST:-007}"
  for d in $DENYLIST; do [ "$r" = "$d" ] && continue 2; done
  
  aa=$(gh api "repos/$O/$r/actions/permissions" --jq '.allowed_actions // empty' 2>/dev/null || true)
  if [ "$aa" = "selected" ]; then
    patterns_count=$(gh api "repos/$O/$r/actions/permissions/selected-actions" --jq '.patterns_allowed | length // 0' 2>/dev/null || echo 0)
    if [ "$patterns_count" = "0" ] || [ -z "$patterns_count" ]; then
      echo "WIPED: $O/$r has allowed_actions=selected with 0 patterns"
      wiped=$((wiped+1))
    fi
  fi
done

echo "==> Total wiped repos in $O: $wiped"

if [ "$wiped" -gt 0 ]; then
  echo "!! WIPE DETECTED: $wiped repos have empty allow-lists (B-ALLOWLIST state)" >&2
  echo "!! This is the heal-then-wipe oscillation - something is resetting patterns_allowed to []" >&2
fi

exit $wiped
