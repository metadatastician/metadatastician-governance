#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Seam regression cover for scripts/ci-health/sweep.sh -> scripts/ci-health/detect.sh.
#
# Why this file exists alongside ci-health-detect-test.sh and ci-health-sweep-test.sh
# (cherry-picked from PR #52 and reconciled against PR #51):
#
# * ci-health-detect-test.sh drives detect.sh on a single repository in isolation
#   and never exercises `detect.sh @organization` or feeds detect.sh output into
#   sweep.sh.
# * ci-health-sweep-test.sh replaces detect.sh with a synthetic stub, so it tests
#   sweep.sh against assumed TSV/stderr shapes rather than the ones detect.sh
#   actually emits.
#
# This suite runs the REAL sweep.sh invoking the REAL detect.sh (with only `gh`
# stubbed, and with `gh api --jq` filters executed by the real `jq`) across:
#
#   1. Silence: @organization healthy + an empty repository (HTTP 409 "Git
#      Repository is empty.") + a clean repository -> exit 0, zero annotations,
#      healthy tracking issue closed.
#   2. Firing (@organization 403): org Actions-permissions query fails with HTTP
#      403 -> detect.sh emits @organization E-INSTRUMENT and exits 2 -> sweep.sh
#      exits 2, names @organization, the E-INSTRUMENT detail, and the gh HTTP 403
#      line in stderr, ::error annotations, and step summary, leaving the
#      tracking issue untouched.
#   3. Firing (repository 403): @organization passes and an empty repository is
#      skipped, but a non-empty repository's tree query fails with HTTP 403 ->
#      sweep.sh exits 2 and names that repository and its HTTP 403 status without
#      publishing a partial report.
#   4. Seam mutants: mutations in detect.sh's TSV column order or stderr
#      forwarding that a stubbed-detector test cannot see are killed here.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP="$ROOT/scripts/ci-health/sweep.sh"
DETECT="$ROOT/scripts/ci-health/detect.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is required by sweep.sh and detect.sh"
  exit 0
fi

mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  repo)
    printf '%s' "$REPO_JSON"
    exit 0
    ;;
  variable)
    exit 1
    ;;
  issue)
    echo "gh $*" >>"$CALLS"
    [ "${2:-}" = list ] && printf '30\n'
    exit 0
    ;;
  api)
    shift
    endpoint="" jqexpr=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --jq) jqexpr="$2"; shift 2 ;;
        -*) shift ;;
        *) [ -n "$endpoint" ] || endpoint="$1"; shift ;;
      esac
    done
    emit_json() {
      if [ -n "$jqexpr" ]; then
        printf '%s' "$1" | jq -r "$jqexpr"
      else
        printf '%s' "$1"
      fi
    }
    case "$endpoint" in
      users/metadatastician)
        emit_json '{"login":"metadatastician"}'
        ;;
      orgs/metadatastician/actions/permissions)
        if [ "${ORG_MODE:-ok}" = "forbidden" ]; then
          echo "gh: Resource not accessible by integration (HTTP 403)" >&2
          exit 1
        fi
        emit_json '{"allowed_actions":"all"}'
        ;;
      repos/metadatastician/empty-priv)
        emit_json '{"archived":false,"fork":false,"default_branch":"main"}'
        ;;
      repos/metadatastician/empty-priv/actions/workflows*)
        emit_json '{"total_count":0,"workflows":[]}'
        ;;
      repos/metadatastician/empty-priv/git/trees/main*)
        echo "gh: Git Repository is empty. (HTTP 409)" >&2
        exit 1
        ;;
      repos/metadatastician/sample)
        emit_json '{"archived":false,"fork":false,"default_branch":"main"}'
        ;;
      repos/metadatastician/sample/actions/workflows*)
        emit_json '{"total_count":0,"workflows":[]}'
        ;;
      repos/metadatastician/sample/git/trees/main*)
        if [ "${SAMPLE_TREE:-ok}" = "forbidden" ]; then
          echo "gh: Resource not accessible by personal access token (HTTP 403)" >&2
          exit 1
        fi
        emit_json '{"tree":[{"path":"README.adoc","type":"blob"}],"truncated":false}'
        ;;
      *)
        echo "unexpected gh api endpoint: $endpoint" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "unexpected gh invocation: $*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$TMP/bin/gh"

make_seam_case() { # make_seam_case <name> <sweep.sh> <detect.sh>
  local d="$TMP/$1" h
  h="$d/scripts/ci-health"
  mkdir -p "$h"
  cp "$2" "$h/sweep.sh"
  cp "$3" "$h/detect.sh"
  cp "$ROOT/scripts/ci-health/action-superset.txt" "$h/action-superset.txt"
  chmod +x "$h/sweep.sh" "$h/detect.sh"
  printf '%s' "$d"
}

run_seam() { # run_seam <sweep.sh> <detect.sh> [VAR=value ...]
  local sweep="$1" detect="$2"
  shift 2
  case_dir="$(make_seam_case "s$RANDOM$RANDOM" "$sweep" "$detect")"
  : >"$case_dir/calls.log"
  : >"$case_dir/summary.md"
  rc=0
  out="$(env PATH="$TMP/bin:$PATH" GH_TOKEN=fixture OWNER=metadatastician DRY_RUN=false LIMIT=0 \
    REPO_JSON='[{"name":"empty-priv"},{"name":"sample"}]' \
    CALLS="$case_dir/calls.log" GITHUB_STEP_SUMMARY="$case_dir/summary.md" \
    "$@" bash "$case_dir/scripts/ci-health/sweep.sh" 2>"$case_dir/err")" || rc=$?
  err="$(cat "$case_dir/err")"
  calls="$(cat "$case_dir/calls.log")"
  summary="$(cat "$case_dir/summary.md")"
}

check_seam_silence() {
  run_seam "$1" "$2"
  [ "$rc" -eq 0 ] \
    && ! printf '%s' "$out" | grep -q '^::error' \
    && printf '%s' "$err" | grep -q '^SKIP empty-priv empty repository' \
    && printf '%s' "$calls" | grep -q 'issue close'
}

check_seam_org_403() {
  run_seam "$1" "$2" ORG_MODE=forbidden REPO_JSON='[]'
  [ "$rc" -eq 2 ] \
    && printf '%s' "$err" | grep -q 'Detection was incomplete for 1 repo(s); refusing remediation and a false health report' \
    && printf '%s' "$err" | grep -qF 'incomplete: @organization — Actions-permissions query failed; allow-list health is unknown [gh: Resource not accessible by integration (HTTP 403)]' \
    && printf '%s' "$out" | grep -qF '::error title=CI-Health detection incomplete::@organization — Actions-permissions query failed; allow-list health is unknown [gh: Resource not accessible by integration (HTTP 403)]' \
    && printf '%s' "$summary" | grep -qF '**@organization** — Actions-permissions query failed; allow-list health is unknown [gh: Resource not accessible by integration (HTTP 403)]' \
    && [ -z "$calls" ]
}

check_seam_repo_403() {
  run_seam "$1" "$2" SAMPLE_TREE=forbidden
  [ "$rc" -eq 2 ] \
    && printf '%s' "$err" | grep -q 'Detection was incomplete for 1 repo(s); refusing remediation and a false health report' \
    && printf '%s' "$err" | grep -q '^SKIP empty-priv empty repository' \
    && printf '%s' "$err" | grep -qF 'incomplete: sample — repository-tree query failed; workflow trigger health is unknown [gh: Resource not accessible by personal access token (HTTP 403)]' \
    && printf '%s' "$out" | grep -qF '::error title=CI-Health detection incomplete::sample — repository-tree query failed; workflow trigger health is unknown [gh: Resource not accessible by personal access token (HTTP 403)]' \
    && [ -z "$calls" ]
}

echo "sweep.sh -> detect.sh seam — unstubbed detector integration"

check_seam_silence "$SWEEP" "$DETECT" \
  && ok "silence: real sweep.sh + real detect.sh excuses 409 empty repo, emits zero errors, closes healthy issue" \
  || bad "seam silence (rc=$rc out=[$out] err=[$err])"

check_seam_org_403 "$SWEEP" "$DETECT" \
  && ok "firing (@organization 403): real detect.sh E-INSTRUMENT + gh 403 surfaces in sweep stderr, annotation, and summary" \
  || bad "seam @organization 403 (rc=$rc out=[$out] err=[$err])"

check_seam_repo_403 "$SWEEP" "$DETECT" \
  && ok "firing (repo tree 403): empty sibling still skipped while failing repo is named with its HTTP 403 status" \
  || bad "seam repo 403 (rc=$rc out=[$out] err=[$err])"

# ── Seam mutants: break the contract between detect.sh and sweep.sh ──────────
mutant_detect() {
  local name="$1" expr="$2" copy="$TMP/mutant-detect-$1.sh"
  sed "$expr" "$DETECT" >"$copy"
  if cmp -s "$copy" "$DETECT"; then bad "mutant $name: expression did not change detect.sh (stale test)"; return 1; fi
  printf '%s' "$copy"
}

m_col="$(mutant_detect column-order 's/emit E-INSTRUMENT CRITICAL "\$1"/emit CRITICAL E-INSTRUMENT "\$1"/')" && {
  if check_seam_org_403 "$SWEEP" "$m_col"; then
    bad "mutant column-order SURVIVED check_seam_org_403"
  else
    ok "mutant column-order killed by check_seam_org_403 (detect.sh/sweep.sh TSV column drift caught)"
  fi
}

m_err="$(mutant_detect drop-tree-stderr 's/cat "\$tree_err" >&2/:/')" && {
  if check_seam_repo_403 "$SWEEP" "$m_err"; then
    bad "mutant drop-tree-stderr SURVIVED check_seam_repo_403"
  else
    ok "mutant drop-tree-stderr killed by check_seam_repo_403 (dropped gh stderr on tree failure caught)"
  fi
}

echo
if [ "$fail" -ne 0 ]; then
  echo "ci-health-sweep-errors-test: $fail failure(s), $pass passed"
  exit 1
fi
echo "ci-health-sweep-errors-test: all $pass check(s) passed"
