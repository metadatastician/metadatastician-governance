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
lockfixed=0
lock_report=$(mktemp)
[ -n "${GH_TOKEN:-}" ] || { echo "E-INSTRUMENT: GH_TOKEN absent; sweep cannot run" >&2; exit 2; }
if ! gh api "users/$O" >/dev/null; then echo "E-INSTRUMENT: owner API unavailable" >&2; exit 2; fi
trap 'rm -f "$findings" "$errors" "$rep" "$lock_report" "$lock_report.repos"' EXIT

echo "::group::Enumerate owner repos (own, non-archived)"
repo_json=$(gh repo list "$O" --source --no-archived --limit 1000 --json name) || { echo "E-INSTRUMENT: repo enumeration failed" >&2; exit 2; }
mapfile -t REPOS < <(printf '%s' "$repo_json" | jq -r '.[].name' | sort)
if [[ "${LIMIT:-0}" =~ ^[0-9]+$ ]] && [ "${LIMIT:-0}" -gt 0 ]; then
  REPOS=("${REPOS[@]:0:$LIMIT}")
fi
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
  # Findings are normally consumed to build the report below. On the fail-closed
  # path they used to be discarded, leaving Actions logs with only an exit code
  # and the number of failed repositories. Surface the exact E-INSTRUMENT rows
  # so operators can distinguish (for example) an org-policy 403/token-scope
  # problem from a transient API failure without publishing partial health data.
  while IFS= read -r failed_scope; do
    [ -z "$failed_scope" ] && continue
    awk -F '\t' -v scope="$failed_scope" \
      '$1 == scope && $2 == "E-INSTRUMENT" { printf "  %s (%s): %s\n", $1, $3, $4 }' \
      "$findings" >&2
  done <"$errors"
  echo "No remediation or tracking-issue update was performed. Check the GitHub API error above and verify the sweep PAT has classic repo, workflow, and admin:org scopes." >&2
  exit 2
fi

# Remediate
while IFS=$'\t' read -r repo cls _sev _detail; do
  case "$cls" in
  B-ALLOWLIST) OWNER="$O" "$HERE/remediate.sh" "$repo" "$cls" "$DRY" || true ;;
  B-ACTOR)
    # Decided before any workflow file is read, and settled by an org/repo
    # Actions policy rather than by a change in the repository. Verified
    # 2026-09-28: the run-page annotation reads "Actor is not allowed to
    # trigger Actions workflows", and the affected workflow carried no `uses:`
    # at all -- so there is nothing here for a bot to repair. Report it to the
    # owner with the exact settings route; do not attempt a code fix.
    echo "REPORT $repo/$cls: GitHub refuses this actor; owner must permit it in the org/repo Actions policy (no repo change applies)"
    ;;
  B-LOCKFILE)
    if [ "$lockfixed" -lt "${MAX_LOCKFIX_PRS:-15}" ] && ! grep -qx "$repo" "$lock_report.repos" 2>/dev/null; then
      echo "$repo" >>"$lock_report.repos"
      details=$(awk -F '\t' -v r="$repo" '$1==r && $2=="B-LOCKFILE" {print $4}' "$findings")
      # Independent safety switch: scheduled runs stay DRY even when D-BURN is live.
      lock_dry=true
      [ "$DRY" = false ] && [ "${ENABLE_LOCKFIX_PRS:-false}" = true ] && lock_dry=false
      if out=$(OWNER="$O" "$HERE/lockfix.sh" "$repo" "$lock_dry" "$details" 2>&1); then
        printf '%s\n' "$out" >>"$lock_report"
        echo "$out"
        [[ "$out" != *"FIXED $repo/B-LOCKFIX"* ]] || lockfixed=$((lockfixed+1))
      else
        printf 'E-INSTRUMENT %s/B-LOCKFIX: %s\n' "$repo" "$out" >>"$lock_report"
        echo "$out" >&2
        printf '%s\n' "$repo" >>"$errors"
      fi
    else echo "CAP $repo/B-LOCKFIX deferred" >>"$lock_report"; fi
    ;;
  B-BADPIN)
    # Diagnosed, not auto-applied: the cure is to regenerate actions.lock (or
    # re-point a dead pin) in the same commit as the ref change. Doing that
    # blind from a sweep would guess which side is stale - the estate has been
    # burned by that already (hyperpolymath/standards#981) - so the finding
    # carries the exact refs and the file stays with the repo's owners.
    echo "REPORT $repo/$cls: see the finding text (regenerate actions.lock with gh actions-lock; review the diff)"
    ;;
  D-BURN)
    if [ "$burned" -lt "$MAXPR" ]; then
      out=$(OWNER="$O" "$HERE/remediate.sh" "$repo" "$cls" "$DRY" || true)
      echo "$out"
      echo "$out" | grep -q '^FIXED' && burned=$((burned + 1))
    else echo "CAP $repo/D-BURN max-burn-prs($MAXPR) reached — deferred"; fi
    ;;
  esac
done < <(sort -u "$findings")

if [ -s "$errors" ]; then echo "E-INSTRUMENT: repair check failed; no complete report" >&2; exit 2; fi

# Build report
{
  echo "## $TITLE"
  echo "_Generated $(date -u +%Y-%m-%dT%H:%MZ) · owner: $O · dry_run: $DRY · scanned ${#REPOS[@]} repos_"
  echo ""
  echo "### 🔴 A-BILLING — OWNER action required (account spending-limit/payment wall)"
  grep -P '\tA-BILLING\t' "$findings" | awk -F'\t' '{print "- **"$1"** — "$4}' || true
  grep -qP '\tA-BILLING\t' "$findings" || echo "- _none_"
  echo ""
  echo "### 🟠 B — allow-list / lockfile drift / actor refusal / startup_failure"
  grep -P '\tB-(ALLOWLIST|LOCKFILE|BADPIN|ACTOR|STARTUPFAIL)\t' "$findings" | awk -F'\t' '{print "- "$1" ("$2"): "$4}' || true
  grep -qP '\tB-' "$findings" || echo "- _none_"
  echo ""
  echo "### B-LOCKFIX proposals and decisions"
  echo "B-LOCKFIX is dry-run unless ENABLE_LOCKFIX_PRS=true is explicitly set. B-BADPIN is report-only. B-ACTOR requires owner settings (Settings → Actions); no repository change applies."
  echo "\`\`\`text"
  cat "$lock_report"
  echo "\`\`\`"
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
