#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath)
# Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# sweep.sh — estate driver: detect + auto-remediate (B,D) + report (A).
# Enumerates the owner's own (non-fork, non-archived) repos, classifies each
# with detect.sh, applies remediate.sh for the safe classes (unless dry-run),
# and upserts a single rolling tracking issue with the findings.
#
# Env: OWNER (default metadatastician), DRY_RUN (true|false), MAX_BURN_PRS
#      (default 15), ISSUE_REPO (where the tracking issue lives, default
#      metadatastician-governance), CI_HEALTH_DENYLIST (passed through to
#      remediate.sh).
set -euo pipefail
O="${OWNER:-metadatastician}"
DRY="${DRY_RUN:-true}"
MAXPR="${MAX_BURN_PRS:-15}"
IREPO="${ISSUE_REPO:-metadatastician-governance}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TITLE="🩺 CI-health: estate failure-class report"
findings=$(mktemp)
errors=$(mktemp)
rep=$(mktemp)
burned=0
trap 'rm -f "$findings" "$errors" "$rep"' EXIT

echo "::group::Enumerate owner repos (own, non-archived)"
mapfile -t REPOS < <(gh repo list "$O" --source --no-archived --limit 1000 --json name --jq '.[].name' | sort)
echo "repos to scan: ${#REPOS[@]}  (dry_run=$DRY)"
echo "::endgroup::"

# Organization Actions policy is centrally enforced for this estate. Detect it
# once at its authoritative scope; do not report the same inherited gap 34 times.
if ! OWNER="$O" "$HERE/detect.sh" @organization >>"$findings"; then
  printf '%s\n' @organization >>"$errors"
fi

# Zero-job startup failures cannot be retried through GitHub's API. Compare
# latest workflow runs only after the most recent organization-policy update;
# otherwise a rare workflow's pre-fix record would remain "current" forever.
if ! policy_epoch=$(gh variable get CI_HEALTH_POLICY_EPOCH --org "$O"); then
  policy_epoch=$(date -u -d '25 hours ago' +%Y-%m-%dT%H:%M:%SZ)
  echo "CI_HEALTH_POLICY_EPOCH unavailable; using 25-hour observation horizon ($policy_epoch)" >&2
fi

for r in "${REPOS[@]}"; do
  if ! OWNER="$O" CHECK_ALLOWLIST=false STARTUP_FAILURE_SINCE="$policy_epoch" "$HERE/detect.sh" "$r" >>"$findings"; then
    printf '%s\n' "$r" >>"$errors"
  fi
done

if [ -s "$errors" ]; then
  echo "Detection was incomplete for $(wc -l <"$errors") repo(s); refusing remediation and a false health report" >&2
  exit 2
fi

# Remediate
while IFS=$'\t' read -r repo cls _sev _detail; do
  case "$cls" in
  B-ALLOWLIST) OWNER="$O" "$HERE/remediate.sh" "$repo" "$cls" "$DRY" || true ;;
  D-BURN)
    if [ "$burned" -lt "$MAXPR" ]; then
      out=$(OWNER="$O" "$HERE/remediate.sh" "$repo" "$cls" "$DRY" || true)
      echo "$out"
      echo "$out" | grep -q '^FIXED' && burned=$((burned + 1))
    else echo "CAP $repo/D-BURN max-burn-prs($MAXPR) reached — deferred"; fi
    ;;
  esac
done < <(sort -u "$findings")

# Build report
{
  echo "## $TITLE"
  echo "_Generated $(date -u +%Y-%m-%dT%H:%MZ) · owner: $O · dry_run: $DRY · scanned ${#REPOS[@]} repos_"
  echo ""
  echo "### 🔴 A-BILLING — OWNER action required (account spending-limit/payment wall)"
  grep -P '\tA-BILLING\t' "$findings" | awk -F'\t' '{print "- **"$1"** — "$4}' || true
  grep -qP '\tA-BILLING\t' "$findings" || echo "- _none_"
  echo ""
  echo "### 🟠 B — allow-list / startup_failure"
  grep -P '\tB-(ALLOWLIST|STARTUPFAIL)\t' "$findings" | awk -F'\t' '{print "- "$1" ("$2"): "$4}' || true
  grep -qP '\tB-' "$findings" || echo "- _none_"
  echo ""
  echo "### 🟡 D-BURN — push/PR double-trigger"
  grep -P '\tD-BURN\t' "$findings" | awk -F'\t' '{print "- "$1": "$4}' || true
  grep -qP '\tD-BURN\t' "$findings" || echo "- _none_"
  echo ""
  if [ "$DRY" = true ]; then
    echo "> Dry-run: no settings or repository changes were applied. See \`scripts/ci-health/README.adoc\`."
  else
    echo "> Auto-remediation attempted: B-ALLOWLIST in place; D-BURN via PRs (cap $MAXPR/run); A-BILLING is owner-only. See \`scripts/ci-health/README.adoc\`."
  fi
} >"$rep"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$rep" >>"$GITHUB_STEP_SUMMARY"

if [ "$DRY" = true ]; then
  echo "dry-run complete: tracking issue unchanged"
  exit 0
fi

# Upsert the rolling tracking issue when unhealthy. A complete, finding-free
# sweep closes the existing issue instead of perpetually rewriting/reopening it.
num=$(gh issue list --repo "$O/$IREPO" --state open --search "$TITLE in:title" --json number --jq '.[0].number // empty' 2>/dev/null || true)
if [ ! -s "$findings" ]; then
  if [ -n "${num:-}" ]; then
    gh issue comment "$num" --repo "$O/$IREPO" --body "Closing automatically: a complete sweep of ${#REPOS[@]} in-scope repositories returned no active CI-health findings." >/dev/null
    gh issue close "$num" --repo "$O/$IREPO" --reason completed >/dev/null
    echo "closed healthy tracking issue #$num"
  else
    echo "healthy: no tracking issue required"
  fi
elif [ -n "${num:-}" ]; then
  gh issue edit "$num" --repo "$O/$IREPO" --body-file "$rep" >/dev/null && echo "updated issue #$num"
else
  gh issue create --repo "$O/$IREPO" --title "$TITLE" --body-file "$rep" >/dev/null && echo "opened tracking issue"
fi
