#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# MAKE-UNITS.sh — re-measure the MetaManifold-WebUI absorption register.
#
# Nothing in this directory is believed; it is measured. Run this after any
# upstream move and commit the new numbers.
#
#   cd <a clone of hyperpolymath/MetaManifold-WebUI>
#   git remote add upstream https://github.com/JoshuaJewell/MetaManifold-WebUI.git
#   git fetch upstream main
#   UPSTREAM_REF=upstream/main BRANCH_REF=origin/main \
#     path/to/MAKE-UNITS.sh
#
# It reports, then fails loudly if:
#   * any unit would delete a path that still exists upstream
#     (the stale-base artefact that would silently revert his newest work);
#   * any unit touches a forbidden path (ui/, Genie, licence metadata,
#     README, screenshots, frontend/src — see EXCLUSIONS-AND-PARKED.md);
#   * a declared unit matches no file at all (the paths went stale).
#
# Re-measured 2026-10-15: the unit list below is the LIVE set only.
# Units whose paths resolve nowhere any more (01–09, 13, 17–22, 24, 26,
# 27, 30, 31, 33, 34 of the original catalogue) are recorded with their
# measured statuses — absorbed, superseded, spun out, parked, refused —
# in UNIT-CATALOGUE.adoc, and are deliberately not listed here: the
# register measures what exists, the catalogue remembers what went.
# Unit 38 (charts-fixpoint) is record-only in the catalogue: its paths
# are under frontend/src/, which this register forbids for units, and it
# was sent as a security exception and closed — the script cannot measure
# what it must refuse to carry.
# The default BRANCH_REF is the fork.s main (the old arena default went
# with its branch).
#
# bash + git only.

set -uo pipefail

UPSTREAM_REF="${UPSTREAM_REF:-upstream/main}"
BRANCH_REF="${BRANCH_REF:-origin/main}"

die() { printf 'make-units: %s\n' "$*" >&2; exit 1; }

git rev-parse -q --verify "$UPSTREAM_REF^{commit}" >/dev/null 2>&1 \
  || die "upstream ref not found: $UPSTREAM_REF (git remote add upstream …; git fetch upstream main)"
git rev-parse -q --verify "$BRANCH_REF^{commit}" >/dev/null 2>&1 \
  || die "branch ref not found: $BRANCH_REF"

# id|name|pathspecs
UNITS=$(cat <<'EOF'
10|stats-diversity-1x1|src/analysis/diversity.jl src/analysis/analysis.jl
11|stats-wiring|src/MetaManifold.jl
12|stats-tests|test/unit/test_analysis.jl test/unit/test_analysis_config.jl test/unit/test_dispersion.jl test/unit/test_diversity.jl test/unit/test_estimation.jl test/unit/test_exact_summaries.jl test/unit/test_ilr_basis.jl test/unit/test_numeric_boundaries.jl test/unit/test_numeric_policy.jl test/unit/test_scaling.jl test/unit/test_zero_replacement.jl test/unit/test_read_conservation.jl
14|ci-julia-tests-rename|.github/workflows/ci.yml
15|ci-fastqc-multiqc|.github/workflows/ci.yml
16|ci-retry-pinned-downloads|scripts/ci/fetch_pinned.sh
23|proofs-agda-core|proofs/agda
25|proofs-harness|proofs/tests
28|backend-core-tests|test/unit/test_categories.jl test/unit/test_composition.jl test/unit/test_composition_library.jl test/unit/test_config.jl test/unit/test_dada2_commands.jl test/unit/test_databases.jl test/unit/test_databases_library.jl test/unit/test_duckdb_store.jl test/unit/test_funcdb.jl test/unit/test_install_pins.jl test/unit/test_jobs.jl test/unit/test_log.jl test/unit/test_merge_taxa.jl test/unit/test_merge_taxa_mappings.jl test/unit/test_migrate_composition.jl test/unit/test_primers_library.jl test/unit/test_project.jl test/unit/test_provenance.jl test/unit/test_r_runtime.jl test/unit/test_tools.jl test/unit/test_validation.jl
29|bench-julia|bench
32|repo-tooling|Justfile .editorconfig launcher.sh
35|dada2-base-r|src/pipeline/dada2/dada2_functions.r renv.lock R/_renv_dependencies.R
36|permanova-proofs|proofs/agda/MetaManifold/Permanova.agda proofs/agda/MetaManifold/All.agda proofs/agda/README.md
39|wildcard-origin|src/server/server.jl test/unit/test_server_security.jl
40|canonical-jcs|src/canonical.jl test/unit/test_canonical.jl test/fixtures/jcs_oracle.jsonl
42|kyaml-config-defaults|config/defaults/pipeline.yml config/defaults/tools.yml config/defaults/tool_versions.yml
EOF
)

# Paths a unit may never carry. See EXCLUSIONS-AND-PARKED.md.
FORBIDDEN='^(ui/|\.github/workflows/ui\.yml$|LICENSE$|LICENSES/|CITATION\.cff$|NOTICE$|README\.md$|\.github/screenshots/|frontend/src/)'

echo "=== Divergence ==="
printf 'upstream  %s  %s\n' "$(git rev-parse --short "$UPSTREAM_REF")" \
  "$(git log -1 --format=%s "$UPSTREAM_REF")"
printf 'branch    %s  %s\n' "$(git rev-parse --short "$BRANCH_REF")" \
  "$(git log -1 --format=%s "$BRANCH_REF")"
printf 'merge base %s  %s\n' "$(git rev-parse --short "$(git merge-base "$UPSTREAM_REF" "$BRANCH_REF")")" \
  "$(git log -1 --format=%s "$(git merge-base "$UPSTREAM_REF" "$BRANCH_REF")")"
printf 'ahead/behind: %s / %s\n' \
  "$(git rev-list --count "$(git merge-base "$UPSTREAM_REF" "$BRANCH_REF")..$BRANCH_REF")" \
  "$(git rev-list --count "$(git merge-base "$UPSTREAM_REF" "$BRANCH_REF")..$UPSTREAM_REF")"
echo

mapfile -t ADDED   < <(git diff --diff-filter=A --name-only "$UPSTREAM_REF" "$BRANCH_REF")
mapfile -t MODDED  < <(git diff --diff-filter=M --name-only "$UPSTREAM_REF" "$BRANCH_REF")
mapfile -t DELETED < <(git diff --diff-filter=D --name-only "$UPSTREAM_REF" "$BRANCH_REF")
printf 'branch vs current upstream: %s added / %s modified / %s deleted\n\n' \
  "${#ADDED[@]}" "${#MODDED[@]}" "${#DELETED[@]}"

if [ "${#DELETED[@]}" -gt 0 ]; then
  echo "=== Deletions of paths that exist upstream today (stale-base artefact) ==="
  printf '  %s\n' "${DELETED[@]}" | head -20
  [ "${#DELETED[@]}" -gt 20 ] && printf '  … and %s more\n' "$(( ${#DELETED[@]} - 20 ))"
  echo
fi

echo "=== Units ==="
printf '%-4s %-28s %6s %6s %6s  %s\n' ID NAME FILES NEW OVERWR ' '
fail=0
while IFS='|' read -r id name paths; do
  [ -n "$id" ] || continue
  # shellcheck disable=SC2086
  files=$(git ls-tree -r --name-only "$BRANCH_REF" -- $paths 2>/dev/null | sort -u)
  n=$(printf '%s' "$files" | grep -c . || true)
  new=0; overw=0; bad=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if git rev-parse -q --verify "$UPSTREAM_REF:$f" >/dev/null 2>&1; then overw=$((overw+1)); else new=$((new+1)); fi
    printf '%s\n' "$f" | grep -Eq "$FORBIDDEN" && { printf '  FORBIDDEN in %s: %s\n' "$name" "$f"; bad=1; }
  done <<< "$files"
  [ "$n" -eq 0 ] && { printf '  STALE unit %s (%s): no files match\n' "$id" "$name"; fail=1; }
  [ "$bad" -eq 1 ] && fail=1
  printf '%-4s %-28s %6s %6s %6s\n' "$id" "$name" "$n" "$new" "$overw"
done <<< "$UNITS"
echo

# Would any unit delete an upstream path? Compare per-unit pathspecs.
echo "=== Stale-deletion guard (per unit) ==="
while IFS='|' read -r id name paths; do
  [ -n "$id" ] || continue
  # shellcheck disable=SC2086
  upstream_paths=$(git ls-tree -r --name-only "$UPSTREAM_REF" -- $paths 2>/dev/null | sort -u)
  gone=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    git rev-parse -q --verify "$BRANCH_REF:$f" >/dev/null 2>&1 || {
      printf '  %-28s would delete %s\n' "$name" "$f"; gone=$((gone+1)); }
  done <<< "$upstream_paths"
  [ "$gone" -gt 0 ] && fail=1
done <<< "$UNITS"
[ "$fail" -eq 0 ] && echo "  clean: no unit deletes an upstream path"

echo
if [ "$fail" -ne 0 ]; then
  echo "FAIL — see the findings above. Do not push until this is clean." >&2
  exit 1
fi
echo "OK — units resolve, none is forbidden, none deletes upstream work."
