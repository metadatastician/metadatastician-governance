#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Regression cover for scripts/ci-health/sweep.sh — the driver, not the detector.
#
# Three properties, each of which a real outage taught:
#
# 1. A REFUSAL NAMES ITS CAUSE. sweep.sh exits 2 rather than publish a report
#    built on incomplete detection. That is right, but until 2026-09-29 the
#    refusal said only "incomplete for N repo(s)": not which, not why. The cause
#    (one empty repository) was in a job log that most readers cannot fetch, and
#    it did not name the repository either, so five daily runs failed before
#    anyone could say what was wrong. The refusal now names every failed target
#    and reason in the log, in the run summary and as workflow ANNOTATIONS,
#    which the REST API serves whether or not it serves the log.
#
# 2. A DRY PROPOSAL MAY NOT OUTRANK THE REPORT. B-LOCKFIX on a scheduled run is
#    a dry-run proposal generator. A failure there does not make the health
#    report false, so it is a warning and the report is still published. A LIVE
#    repair (ENABLE_LOCKFIX_PRS=true) can open PRs elsewhere and still fails
#    closed.
#
# 3. THE PUBLISH STEP CANNOT BE THE SWEEP'S LAST, FAILING ACT. GitHub refuses an
#    issue body over 65,536 characters. The body is cut on a line boundary with a
#    stated notice; the full report stays in the run summary.
#
# 4. ONE REPAIR PER REPOSITORY. A repository with six drifted workflows produces
#    six B-LOCKFILE findings; only the first does the work. The other five used
#    to print "CAP ... deferred", which reads as the cap being reached and put
#    dozens of misleading lines into the first report after nine silent days.
#
# Detection completeness itself is NOT weakened by any of this: a failed detect.sh
# call still refuses the sweep with exit 2 and never touches the tracking issue.
#
# detect.sh, remediate.sh and lockfix.sh are stubbed and `gh` is a shim, so every
# branch is reachable offline. Mutants of sweep.sh at the end prove the
# assertions are able to fail.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP="$ROOT/scripts/ci-health/sweep.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is required by sweep.sh itself"
  exit 0
fi

# ── the gh shim ──────────────────────────────────────────────────────────────
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  api) exit 0 ;;                                   # gh api users/$OWNER
  repo) printf '%s' "$REPO_JSON" ;;                # gh repo list ... --json name
  variable) exit 1 ;;                              # epoch unreadable -> documented fallback
  issue)
    echo "gh $*" >>"$CALLS"
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      [ "${args[$i]}" = "--body-file" ] && cp "${args[$((i + 1))]}" "$CASE_DIR/published-body.md"
    done
    [ "${2:-}" = list ] && printf '30\n'
    exit 0 ;;
  *) echo "unexpected gh: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/gh"

# ── the stubbed siblings sweep.sh calls by path ──────────────────────────────
make_case() { # make_case <name> <sweep.sh to install>  -> prints the case dir
  local d="$TMP/$1" h
  h="$d/scripts/ci-health"
  mkdir -p "$h"
  cp "$2" "$h/sweep.sh"
  cat >"$h/detect.sh" <<'STUB'
#!/usr/bin/env bash
t="$1"
for f in ${FAIL_TARGETS:-}; do
  if [ "$f" = "$t" ]; then
    printf '%s\tE-INSTRUMENT\tCRITICAL\t%s\n' "$t" "${FAIL_DETAIL:-repository-tree query failed; workflow trigger health is unknown}"
    printf '%s\n' "${FAIL_GHLINE:-gh: Git Repository is empty. (HTTP 409)}" >&2
    exit 2
  fi
done
case " ${LOCKDRIFT:-} " in
  *" $t "*)
    for i in $(seq 1 "${LOCKROWS:-1}"); do
      printf '%s\tB-LOCKFILE\tHIGH\tERR-SEC-004: .github/workflows/w%s.yml refs missing from the lockfile: actions/checkout@v9\n' "$t" "$i"
    done ;;
esac
if [ -n "${MANY_FINDINGS:-}" ] && [ "$t" != @organization ]; then
  filler="$(head -c 200 /dev/zero | tr '\0' x)"
  for i in $(seq 1 "$MANY_FINDINGS"); do printf '%s\tB-BADPIN\tHIGH\tERR-SEC-005: %s %s\n' "$t" "$i" "$filler"; done
fi
if [ -n "${NEWCLASSES:-}" ] && [ "$t" != @organization ]; then
  printf '%s\tB-OFFBRANCH\tHIGH\tERR-SEC-007: .github/workflows/audit.yml calls hyperpolymath/standards/.github/workflows/audit-reusable.yml@c0ffee — diverged\n' "$t"
  printf '%s\tB-PERMS\tHIGH\tERR-SEC-008: .github/workflows/audit.yml job audit grants contents:none, reusable requires contents:read\n' "$t"
fi
exit 0
STUB
  cat >"$h/remediate.sh" <<'STUB'
#!/usr/bin/env bash
echo "SKIP $1/$2 stub"
STUB
  cat >"$h/lockfix.sh" <<'STUB'
#!/usr/bin/env bash
case "${LOCKFIX_MODE:-ok}" in
  ok) echo "PROPOSED $1/B-LOCKFIX lock-only diff (workflow YAML unchanged):"; echo "DRYRUN $1/B-LOCKFIX no branch or PR" ;;
  fail) echo "E-INSTRUMENT $1/B-LOCKFIX: generated lock did not pass lock-sync: still drifted" >&2; exit 2 ;;
esac
STUB
  chmod +x "$h"/*.sh
  printf '%s' "$d"
}

# run_sweep <sweep.sh> [VAR=value ...]  -> sets rc out err calls body summary case_dir
run_sweep() {
  local sweep="$1"
  shift
  case_dir="$(make_case "c$RANDOM$RANDOM" "$sweep")"
  : >"$case_dir/calls.log"
  : >"$case_dir/summary.md"
  rc=0
  out="$(env PATH="$TMP/bin:$PATH" GH_TOKEN=fixture OWNER=metadatastician DRY_RUN=false LIMIT=0 \
    REPO_JSON='[{"name":"alpha"},{"name":"beta"},{"name":"gamma"}]' \
    CASE_DIR="$case_dir" CALLS="$case_dir/calls.log" GITHUB_STEP_SUMMARY="$case_dir/summary.md" \
    "$@" bash "$case_dir/scripts/ci-health/sweep.sh" 2>"$case_dir/err")" || rc=$?
  err="$(cat "$case_dir/err")"
  calls="$(cat "$case_dir/calls.log")"
  body=""
  [ -f "$case_dir/published-body.md" ] && body="$(cat "$case_dir/published-body.md")"
  summary="$(cat "$case_dir/summary.md")"
}

count() { printf '%s\n' "$1" | grep -c -- "$2" || true; }

# ── Scenario checks: each returns 0 when its property holds, 1 otherwise ─────
# They print nothing themselves, so the same check can be run against a mutant
# and its failure counted as a kill.

check_silence() { # healthy estate: nothing failed, nothing found -> closes the issue, no noise
  run_sweep "$1"
  [ "$rc" -eq 0 ] && [ "$(count "$out" '^::error')" -eq 0 ] && [ "$(count "$out" '^::warning')" -eq 0 ] \
    && printf '%s' "$calls" | grep -q 'issue close' && [ -z "$body" ]
}

check_names_repo() { # one failed detection -> exit 2, named with reason, tracking issue untouched
  run_sweep "$1" FAIL_TARGETS=beta
  [ "$rc" -eq 2 ] \
    && printf '%s' "$err" | grep -q 'Detection was incomplete for 1 repo(s); refusing remediation and a false health report' \
    && printf '%s' "$err" | grep -q 'incomplete: beta — repository-tree query failed' \
    && printf '%s' "$out" | grep -qF '::error title=CI-Health detection incomplete::beta — repository-tree query failed; workflow trigger health is unknown [gh: Git Repository is empty. (HTTP 409)]' \
    && printf '%s' "$out" | grep -q '^::error title=CI-Health sweep refused to publish::' \
    && printf '%s' "$summary" | grep -q '\*\*beta\*\*' \
    && [ -z "$calls" ]
}

check_org_named() { # the organisation-policy check is a target like any other
  run_sweep "$1" FAIL_TARGETS=@organization FAIL_DETAIL='Actions-permissions query failed; allow-list health is unknown' \
    FAIL_GHLINE='gh: Resource not accessible by personal access token (HTTP 403)'
  [ "$rc" -eq 2 ] \
    && printf '%s' "$out" | grep -qF '::error title=CI-Health detection incomplete::@organization — Actions-permissions query failed; allow-list health is unknown [gh: Resource not accessible by personal access token (HTTP 403)]' \
    && [ -z "$calls" ]
}

check_cap() { # more failures than GitHub will display: 7 named, the rest counted
  run_sweep "$1" REPO_JSON='[{"name":"r1"},{"name":"r2"},{"name":"r3"},{"name":"r4"},{"name":"r5"},{"name":"r6"},{"name":"r7"},{"name":"r8"},{"name":"r9"}]' \
    FAIL_TARGETS="r1 r2 r3 r4 r5 r6 r7 r8 r9"
  [ "$rc" -eq 2 ] \
    && [ "$(count "$out" '^::error title=CI-Health detection incomplete::r[0-9] —')" -eq 7 ] \
    && [ "$(count "$out" '^::error title=CI-Health detection incomplete::…and 2 more')" -eq 1 ] \
    && [ "$(count "$err" 'incomplete: r[0-9] —')" -eq 9 ]
}

check_escape() { # workflow-command escaping: a % in a reason cannot corrupt the annotation
  run_sweep "$1" FAIL_TARGETS=beta FAIL_DETAIL='rate limit at 100% of quota, retry: later'
  [ "$rc" -eq 2 ] \
    && printf '%s' "$out" | grep -qF '::error title=CI-Health detection incomplete::beta — rate limit at 100%25 of quota, retry: later' \
    && [ "$(printf '%s\n' "$out" | grep -c '^::error')" -eq "$(printf '%s\n' "$out" | grep -c '^::error title=[^:]*::')" ]
}

check_dry_advisory() { # a failed DRY proposal is a warning; the report is still published
  run_sweep "$1" LOCKDRIFT=beta LOCKFIX_MODE=fail
  [ "$rc" -eq 0 ] \
    && printf '%s' "$out" | grep -qF '::warning title=CI-Health B-LOCKFIX proposal failed (report still published)::beta — E-INSTRUMENT beta/B-LOCKFIX: generated lock did not pass lock-sync: still drifted' \
    && [ "$(count "$out" '^::error')" -eq 0 ] \
    && printf '%s' "$calls" | grep -q 'issue edit' \
    && printf '%s' "$body" | grep -q 'E-INSTRUMENT beta/B-LOCKFIX' \
    && printf '%s' "$body" | grep -q 'B-LOCKFILE'
}

check_live_fatal() { # a failed LIVE repair still fails closed and publishes nothing
  run_sweep "$1" LOCKDRIFT=beta LOCKFIX_MODE=fail ENABLE_LOCKFIX_PRS=true
  [ "$rc" -eq 2 ] \
    && printf '%s' "$out" | grep -qF '::error title=CI-Health repair check failed::beta — B-LOCKFIX: E-INSTRUMENT beta/B-LOCKFIX' \
    && [ -z "$calls" ] && [ -z "$body" ]
}

check_body_cap() { # oversize body: whole-line prefix, stated, fences balanced, full text in the summary
  run_sweep "$1" MANY_FINDINGS=40 MAX_ISSUE_BODY_BYTES=6000
  local size fences
  size="$(wc -c <"$case_dir/published-body.md" 2>/dev/null || echo 0)"
  fences="$(grep -c '^```' "$case_dir/published-body.md" 2>/dev/null || true)"
  [ "$rc" -eq 0 ] && [ "$size" -gt 0 ] && [ "$size" -le 6400 ] \
    && printf '%s' "$body" | grep -q "Truncated to fit GitHub's 65,536-character issue limit" \
    && [ $((fences % 2)) -eq 0 ] \
    && [ "$(wc -c <"$case_dir/summary.md")" -gt 20000 ]
}

check_body_whole() { # under the limit nothing is cut and no notice is added
  run_sweep "$1" LOCKDRIFT=beta
  [ "$rc" -eq 0 ] && ! printf '%s' "$body" | grep -q 'Truncated to fit' && [ -n "$body" ]
}

check_one_repair() { # six findings for one repo -> exactly one repair, and no false "CAP" lines
  run_sweep "$1" LOCKDRIFT=beta LOCKROWS=6
  [ "$rc" -eq 0 ] \
    && [ "$(count "$body" '^PROPOSED beta/B-LOCKFIX')" -eq 1 ] \
    && [ "$(count "$body" '^CAP ')" -eq 0 ]
}

check_real_cap() { # a real cap is still stated, once per repository, and does no repair
  run_sweep "$1" LOCKDRIFT="beta gamma" LOCKROWS=3 MAX_LOCKFIX_PRS=0
  [ "$rc" -eq 0 ] \
    && [ "$(count "$body" '^CAP beta/B-LOCKFIX deferred (MAX_LOCKFIX_PRS=0 reached)')" -eq 1 ] \
    && [ "$(count "$body" '^CAP gamma/B-LOCKFIX deferred (MAX_LOCKFIX_PRS=0 reached)')" -eq 1 ] \
    && [ "$(count "$body" '^PROPOSED')" -eq 0 ]
}

echo "sweep.sh — refusal evidence, advisory proposals, body cap"

check_silence "$SWEEP" && ok "silence: healthy estate closes the issue, zero annotations" || bad "silence"
check_names_repo "$SWEEP" && ok "firing: a failed detection exits 2, names the repo and the gh error, touches no issue" || { bad "names the repo"; printf '%s\n--- err\n%s\n' "$out" "$err" | sed 's/^/       /' | head -20; }
check_org_named "$SWEEP" && ok "firing: the organisation-policy check is named with its HTTP status" || bad "organisation check named"
check_cap "$SWEEP" && ok "cap: 9 failures -> 7 annotations + '…and 2 more', all 9 in the log" || bad "annotation cap"
check_escape "$SWEEP" && ok "escaping: '%' and ':' in a reason cannot corrupt the annotation" || bad "escaping"
check_dry_advisory "$SWEEP" && ok "dry: a failed B-LOCKFIX proposal is a warning; the report is still published" || bad "dry advisory"
check_live_fatal "$SWEEP" && ok "live: a failed B-LOCKFIX repair still fails closed and publishes nothing" || bad "live fatal"
check_body_cap "$SWEEP" && ok "cap: an oversize body is cut on a line, says so, keeps its fences, and the summary keeps the rest" || bad "body cap"
check_body_whole "$SWEEP" && ok "cap: a report under the limit is published whole" || bad "body whole"
check_one_repair "$SWEEP" && ok "dedupe: six findings for one repository -> one repair, no false CAP lines" || bad "one repair per repository"
check_real_cap "$SWEEP" && ok "cap: MAX_LOCKFIX_PRS reached is still stated, once per repository, with no repair" || bad "real cap"

# ── Report-only startup classes reach the published report ─────────────────
# B-OFFBRANCH and B-PERMS are diagnosed by detect.sh from the mirrored files;
# the sweep must carry them into the issue body, REPORT them (never mutate
# another repository for them), and not mistake them for the B-LOCKFIX seam.
check_new_classes() { # B-OFFBRANCH/B-PERMS: published, REPORTed, no lockfix
  local body_s
  run_sweep "$1" NEWCLASSES=one
  body_s="$(cat "$case_dir/published-body.md" 2>/dev/null)"
  [ "$rc" -eq 0 ] \
    && printf '%s' "$body_s" | grep -q 'alpha (B-OFFBRANCH)' \
    && printf '%s' "$body_s" | grep -q 'alpha (B-PERMS)' \
    && [ "$(count "$out" '^REPORT alpha/B-OFFBRANCH')" -eq 1 ] \
    && [ "$(count "$out" '^REPORT alpha/B-PERMS')" -eq 1 ] \
    && [ "$(count "$out" '^PROPOSED alpha/B-LOCKFIX')" -eq 0 ]
}
check_new_classes "$SWEEP" && ok "report-only: B-OFFBRANCH and B-PERMS are published and REPORTed, never repaired" || { bad "new classes reach the report"; printf '%s\n' "$out" | head; }

# ── Mutants: each must make its check fail ───────────────────────────────────
mutant() { # mutant <name> <sed expression>  -> prints path of the mutated copy
  local copy="$TMP/mutant-$1.sh"
  sed "$2" "$SWEEP" >"$copy"
  if cmp -s "$copy" "$SWEEP"; then echo "STALE" >&2; return 1; fi
  printf '%s' "$copy"
}
kill_with() { # kill_with <mutant name> <check function> <sed expression>
  local name="$1" check="$2" expr="$3" m
  if ! m="$(mutant "$name" "$expr")"; then bad "mutant $name: expression no longer changes sweep.sh (stale test)"; return; fi
  if "$check" "$m"; then bad "mutant $name SURVIVED $check"; else ok "mutant $name killed by $check"; fi
}

kill_with no-evidence check_names_repo 's/^  refuse_with_evidence "CI-Health detection incomplete"$/  :/'
kill_with guard-disabled check_names_repo '0,/if \[ -s "\$errors" \]; then/s//if false; then/'
kill_with dry-fatal check_dry_advisory 's/if \[ "\$lock_dry" = true \]; then$/if false; then/'
kill_with live-lenient check_live_fatal 's/if \[ "\$lock_dry" = true \]; then$/if true; then/'
kill_with no-body-cap check_body_cap 's/-gt "\$max_body" \]/-gt 999999999 ]/'
kill_with no-annotation-cap check_cap 's/\[ "\$n" -le 7 \] || break/:/'
kill_with no-dedupe check_one_repair 's/if grep -qx "\$repo" "\$lock_report.repos" 2>\/dev\/null; then/if false; then/'
kill_with no-escaping check_escape 's/s=\${s\/\/'"'"'%'"'"'\/%25}/:/'

echo
if [ "$fail" -ne 0 ]; then
  echo "ci-health-sweep-test: $fail failure(s), $pass passed"
  exit 1
fi
echo "ci-health-sweep-test: all $pass check(s) passed"
