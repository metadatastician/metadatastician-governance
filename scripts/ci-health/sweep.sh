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
#      remediate.sh), MAX_ISSUE_BODY_BYTES (default 60000; GitHub refuses an
#      issue body over 65,536 characters).
#
# Exit 2 means the sweep REFUSED to publish: detection was incomplete, or a live
# repair check failed. It always says which target failed and why -- in the log,
# as workflow annotations (the REST API serves those even when it will not serve
# the log) and in the run summary -- because a refusal that does not name its
# cause cost five daily runs (2026-09-21..29) to diagnose.
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
failures=$(mktemp)   # <target><TAB><reason>, one per incomplete detection / failed live repair
advisories=$(mktemp) # <target><TAB><reason>, dry-run proposal failures that do not withhold the report
pub=""
[ -n "${GH_TOKEN:-}" ] || { echo "E-INSTRUMENT: GH_TOKEN absent; sweep cannot run" >&2; exit 2; }
if ! gh api "users/$O" >/dev/null; then echo "E-INSTRUMENT: owner API unavailable" >&2; exit 2; fi
trap 'rm -f "$findings" "$errors" "$failures" "$advisories" "$rep" "$pub" "$lock_report" "$lock_report.repos"' EXIT

# ── Evidence helpers ─────────────────────────────────────────────────────────
# Workflow-command escaping (GitHub: %, CR and LF in data; also : and , in properties).
esc_data() {
  local s=$1
  s=${s//'%'/%25}
  s=${s//$'\r'/%0D}
  s=${s//$'\n'/%0A}
  printf '%s' "$s"
}
esc_prop() {
  local s
  s=$(esc_data "$1")
  s=${s//:/%3A}
  s=${s//,/%2C}
  printf '%s' "$s"
}
annotate() { printf '::%s title=%s::%s\n' "$1" "$(esc_prop "$2")" "$(esc_data "$3")"; }

# failure_reason STDOUT_FILE STDERR_FILE -- why one detect.sh call failed: the
# E-INSTRUMENT text it emitted plus the last `gh:` line it printed (the HTTP status).
failure_reason() {
  local detail ghline
  detail=$(awk -F '\t' '$2=="E-INSTRUMENT" {print $4; exit}' "$1")
  ghline=$(grep -E '^gh: ' "$2" | tail -n 1 || true)
  printf '%s%s' "${detail:-detect.sh exited non-zero without an E-INSTRUMENT finding}" "${ghline:+ [$ghline]}"
}

# run_detect TARGET [VAR=value ...] -- one detect.sh call. Findings and stderr reach
# $findings and the log exactly as before; a failure is additionally recorded with its
# reason so the refusal below can name it. Never fails itself: failures are recorded.
run_detect() {
  local target=$1 out err rc=0
  shift
  out=$(mktemp)
  err=$(mktemp)
  env OWNER="$O" "$@" "$HERE/detect.sh" "$target" >"$out" 2>"$err" || rc=$?
  cat "$err" >&2
  cat "$out" >>"$findings"
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$target" >>"$errors"
    printf '%s\t%s\n' "$target" "$(failure_reason "$out" "$err")" >>"$failures"
  fi
  rm -f "$out" "$err"
}

# lockfix_reason OUTPUT -- first line naming the E-INSTRUMENT, else the last line.
lockfix_reason() {
  local r
  r=$(printf '%s\n' "$1" | grep -m1 'E-INSTRUMENT' || true)
  [ -n "$r" ] || r=$(printf '%s\n' "$1" | tail -n 1)
  printf '%s' "${r:0:300}"
}

# annotate_each LEVEL TITLE FILE -- one annotation per <target><TAB><reason> row. GitHub
# keeps 10 annotations of a level per step and the runner adds its own "exit code 2"
# error, so at most 7 rows are annotated individually and the rest are counted.
annotate_each() {
  local level=$1 title=$2 file=$3 n=0 total target reason
  total=$(wc -l <"$file")
  while IFS=$'\t' read -r target reason; do
    n=$((n + 1))
    [ "$n" -le 7 ] || break
    annotate "$level" "$title" "$target — $reason"
  done <"$file"
  [ "$total" -le 7 ] || annotate "$level" "$title" "…and $((total - 7)) more; see the job log"
}

# refuse_with_evidence TITLE -- name every failed target, then let the caller exit 2.
refuse_with_evidence() {
  local title=$1 target reason
  while IFS=$'\t' read -r target reason; do
    echo "  incomplete: $target — $reason" >&2
  done <"$failures"
  annotate_each error "$title" "$failures"
  annotate error "CI-Health sweep refused to publish" "The tracking issue was NOT updated: a report built on incomplete results would be a false health report."
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "## 🩺 CI-health sweep — report NOT published"
      echo ""
      echo "**$title.** The rolling tracking issue was left untouched: a report built on incomplete results would be a false health report."
      echo ""
      while IFS=$'\t' read -r target reason; do
        printf -- '- **%s** — %s\n' "$target" "$reason"
      done <"$failures"
    } >>"$GITHUB_STEP_SUMMARY"
  fi
}

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
run_detect @organization

# Zero-job startup failures cannot be retried through GitHub's API. Compare
# latest workflow runs only after the most recent organization-policy update;
# otherwise a rare workflow's pre-fix record would remain "current" forever.
if ! policy_epoch=$(gh variable get CI_HEALTH_POLICY_EPOCH --org "$O"); then
  policy_epoch=$(date -u -d '25 hours ago' +%Y-%m-%dT%H:%M:%SZ)
  echo "CI_HEALTH_POLICY_EPOCH unavailable; using 25-hour observation horizon ($policy_epoch)" >&2
fi

for r in "${REPOS[@]}"; do
  run_detect "$r" CHECK_ALLOWLIST=false STARTUP_FAILURE_SINCE="$policy_epoch"
done

if [ -s "$errors" ]; then
  echo "Detection was incomplete for $(wc -l <"$errors") repo(s); refusing remediation and a false health report" >&2
  refuse_with_evidence "CI-Health detection incomplete"
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
    # One repair per repository, however many of its workflows drifted: the first
    # finding does the work and the rest are the same job. (This used to print
    # "CAP ... deferred" for every repeat, which reads as the cap being reached.)
    if grep -qx "$repo" "$lock_report.repos" 2>/dev/null; then
      :
    elif [ "$lockfixed" -lt "${MAX_LOCKFIX_PRS:-15}" ]; then
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
        if [ "$lock_dry" = true ]; then
          # A DRY proposal that could not be produced does not make the health
          # report false: the B-LOCKFILE finding itself is already in $findings,
          # and the failed proposal is listed in the report's B-LOCKFIX section
          # and as a warning annotation. Withholding the whole estate report for
          # it would let an advisory step outrank the report it decorates -- and
          # this step had never run on a runner when that was written.
          printf '%s\t%s\n' "$repo" "$(lockfix_reason "$out")" >>"$advisories"
        else
          # LIVE (ENABLE_LOCKFIX_PRS=true) can open PRs in other repositories, so
          # a failed repair check still fails closed.
          printf '%s\n' "$repo" >>"$errors"
          printf '%s\t%s\n' "$repo" "B-LOCKFIX: $(lockfix_reason "$out")" >>"$failures"
        fi
      fi
    else
      echo "$repo" >>"$lock_report.repos"
      echo "CAP $repo/B-LOCKFIX deferred (MAX_LOCKFIX_PRS=${MAX_LOCKFIX_PRS:-15} reached)" >>"$lock_report"
    fi
    ;;
  B-BADPIN)
    # Diagnosed, not auto-applied: the cure is to regenerate actions.lock (or
    # re-point a dead pin) in the same commit as the ref change. Doing that
    # blind from a sweep would guess which side is stale - the estate has been
    # burned by that already (hyperpolymath/standards#981) - so the finding
    # carries the exact refs and the file stays with the repo's owners.
    echo "REPORT $repo/$cls: see the finding text (regenerate actions.lock with gh actions-lock; review the diff)"
    ;;
  B-OFFBRANCH | B-PERMS)
    # Diagnosed from the caller/callee files, not auto-applied: re-pointing a
    # caller at a different commit or widening its permissions are human
    # judgements about trust (T-1). The finding carries the exact pinned ref,
    # the compare verdict, and the missing scope(s), so no banner needs
    # reading; no file is mutated from a sweep.
    echo "REPORT $repo/$cls: cross-repo reusable-workflow fault identified; see the finding text (re-point the caller / grant the missing scope)"
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

if [ -s "$errors" ]; then
  echo "E-INSTRUMENT: repair check failed; no complete report" >&2
  refuse_with_evidence "CI-Health repair check failed"
  exit 2
fi

# Build report
{
  echo "## $TITLE"
  echo "_Generated $(date -u +%Y-%m-%dT%H:%MZ) · owner: $O · dry_run: $DRY · scanned ${#REPOS[@]} repos_"
  echo ""
  echo "### 🔴 A-BILLING — OWNER action required (account spending-limit/payment wall)"
  grep -P '\tA-BILLING\t' "$findings" | awk -F'\t' '{print "- **"$1"** — "$4}' || true
  grep -qP '\tA-BILLING\t' "$findings" || echo "- _none_"
  echo ""
  echo "### 🟠 B — allow-list / lock & pin drift / reusable-pin & permission faults / actor refusal / startup_failure"
  grep -P '\tB-(ALLOWLIST|LOCKFILE|BADPIN|OFFBRANCH|PERMS|ACTOR|STARTUPFAIL)\t' "$findings" | awk -F'\t' '{print "- "$1" ("$2"): "$4}' || true
  grep -qP '\tB-' "$findings" || echo "- _none_"
  echo ""
  echo "### B-LOCKFIX proposals and decisions"
  echo "B-LOCKFIX is dry-run unless ENABLE_LOCKFIX_PRS=true is explicitly set. B-BADPIN, B-OFFBRANCH and B-PERMS are report-only (re-pointing a caller or widening a grant is a human trust decision; the finding names the ref and scope). B-ACTOR requires owner settings (Settings → Actions); no repository change applies."
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
if [ -s "$advisories" ]; then
  annotate_each warning "CI-Health B-LOCKFIX proposal failed (report still published)" "$advisories"
fi

if [ "$DRY" = true ]; then
  echo "dry-run complete: tracking issue unchanged"
  exit 0
fi

# GitHub refuses an issue body over 65,536 characters (HTTP 422). Unhandled, that
# refusal would be the sweep's LAST act -- after live remediation, with the report
# unpublished and the run red -- and a report that lists one line per finding
# across ~70 repos plus lock diffs gets there fast (the B section alone measured
# 32 KB for the public repos on 2026-09-29). Publish a whole-line prefix, say so,
# and leave the complete report in the run summary written above.
pub="$rep"
max_body="${MAX_ISSUE_BODY_BYTES:-60000}"
if [ "$(wc -c <"$rep")" -gt "$max_body" ]; then
  pub=$(mktemp)
  awk -v max="$max_body" '{ n += length($0) + 1; if (n > max) exit; print }' "$rep" >"$pub"
  # A cut inside the ```text block would leave the fence open.
  [ $(($(grep -c '^```' "$pub" || true) % 2)) -eq 0 ] || echo '```' >>"$pub"
  printf '\n> ⚠ Truncated to fit GitHub'"'"'s 65,536-character issue limit (%s of %s bytes shown). The complete report is in this run'"'"'s step summary.\n' \
    "$(wc -c <"$pub")" "$(wc -c <"$rep")" >>"$pub"
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
  gh issue edit "$num" --repo "$O/$IREPO" --body-file "$pub" >/dev/null && echo "updated issue #$num"
else
  gh issue create --repo "$O/$IREPO" --title "$TITLE" --body-file "$pub" >/dev/null && echo "opened tracking issue"
fi
