#!/usr/bin/env bash
#
# Decide which parts of the monorepo need CI/deploy work for a given change.
#
# pnpm-aware version. Division of labour:
#   - git decides WHAT CHANGED (merge-base diff, renames expanded), exactly as
#     before. pnpm's own "changed since <ref>" filter is not used: it diffs
#     against the ref's tip rather than the merge-base, and it relies on git
#     rename detection, so a file moved out of a package goes unnoticed.
#   - pnpm answers WHO DEPENDS ON IT (the real workspace dependency graph).
#   - Three small hand-written tables remain:
#       package_area      which area a workspace package belongs to
#       classify_outside  paths outside any package (docs, non-JS code, globals)
#       propagate         edges no package.json declares
#
# Usage:
#   scripts/ci/changed.sh <base-sha> <head-sha>   # diff-based (PRs, pushes)
#   scripts/ci/changed.sh --all                   # force everything on
#
# Requirements: git, jq, pnpm (no `pnpm install` needed), and full git history
# (fetch-depth: 0).
#
# Output: one "name=true|false" line per area, printed to stdout and appended
# to $GITHUB_OUTPUT when running inside GitHub Actions. Reasons go to stderr.
#
# Design rules (unchanged from the original):
#   1. Unknown or unsure => run everything. A wasted CI run is cheap; a missed
#      one is not.
#   2. Every changed path must be claimed by a package or by classify_outside.
#      Anything else falls through to "all", which makes forgotten directories
#      (and unmapped packages) loud.
#   3. Dependency edges pnpm cannot see live in ONE place: propagate().

set -euo pipefail

ZERO_SHA="0000000000000000000000000000000000000000"

# --- area flags (0/1) ---------------------------------------------------------
infra=0 backend=0 web=0 mobile=0 packages=0 docs=0 all=0

log() { echo "changed.sh: $*" >&2; }

# Map a workspace package directory (repo-relative) to an area.
package_area() {
  case "$1" in
    infra|infra/*)     infra=1 ;;
    backend|backend/*) backend=1 ;;
    apps/web)          web=1 ;;
    apps/mobile)       mobile=1 ;;
    packages/*)        packages=1 ;;
    # Rule 2: a package that no area claims runs everything.
    *)                 all=1; log "package '$1' is not mapped to an area" ;;
  esac
}

# Classify a changed file that is NOT inside any workspace package.
# NOTE: order matters; first match wins.
classify_outside() {
  case "$1" in
    # Non-JS code that ships with the infrastructure (Rust, C, ...). Inside the
    # infra package directory it is already covered by package_area; this
    # handles it living next to the package.
    infra/*|native/*)        infra=1 ;;
    docs/*)                  docs=1 ;;
    README.md|CONTRIBUTING.md|LICENSE|.gitignore) docs=1 ;;
    # Global inputs: a change here can affect everything.
    pnpm-lock.yaml|pnpm-workspace.yaml|package.json|tsconfig*.json|.nvmrc|.npmrc) all=1 ;;
    .github/*|scripts/ci/*)  all=1 ;;
    # Rule 1 + 2: anything unclaimed runs everything.
    *)                       all=1; log "unclaimed path '$1'" ;;
  esac
}

# Edges pnpm cannot see because no package.json links the two sides.
# (Alternative: declare them, e.g. infra depends on backend and web with
# "workspace:*", and delete this block.)
propagate() {
  if [ "$all" -eq 1 ]; then
    infra=1 backend=1 web=1 mobile=1 packages=1
  fi
  # CDK builds the site image and bundles lambdas as assets, so a change to
  # either one means the stack must be re-synthesised / re-deployed.
  if [ "$backend" -eq 1 ] || [ "$web" -eq 1 ]; then
    infra=1
  fi
  # mobile ships through app stores / EAS, not through CDK.
  # Shared packages need no rule here: pnpm already reports their dependents.
}

emit() {
  local b
  for pair in "infra:$infra" "backend:$backend" "web:$web" "mobile:$mobile" \
              "packages:$packages" "docs:$docs"; do
    b=$([ "${pair#*:}" -eq 1 ] && echo true || echo false)
    echo "${pair%%:*}=$b"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "${pair%%:*}=$b" >> "$GITHUB_OUTPUT"; fi
  done
}

# --- obtain changed files and the workspace layout ----------------------------
# Sets the globals below. Sets all=1 when it cannot be sure.
# Deliberately NOT called inside $(...): a subshell would lose the all=1 flag.
TOP=""           # repo root
PKG_DIRS=""      # every workspace package dir, repo-relative, one per line
FILES=""         # every file changed since the merge-base
# jq: paths of the listed packages, repo-relative, without the workspace root.
PKG_PATHS='.[].path | select(. != $top) | ltrimstr($top + "/")'

read_changes() {
  if [ "${1:-}" = "--all" ]; then all=1; return; fi

  local base="${1:-}" head="${2:-}" mb all_json
  # Missing/zero base happens on new branches and some force-pushes.
  if [ -z "$base" ] || [ -z "$head" ] || [ "$base" = "$ZERO_SHA" ]; then
    log "no usable base; running everything"; all=1; return
  fi
  # Both commits must exist locally (needs fetch-depth: 0 in checkout).
  if ! git cat-file -e "${base}^{commit}" 2>/dev/null || \
     ! git cat-file -e "${head}^{commit}" 2>/dev/null; then
    log "commit(s) not available locally; running everything"; all=1; return
  fi
  # Merge-base = only what THIS side changed (same as the old three-dot diff).
  if ! mb="$(git merge-base "$base" "$head" 2>/dev/null)"; then
    log "no merge-base; running everything"; all=1; return
  fi

  TOP="$(git rev-parse --show-toplevel)"
  cd "$TOP"

  # --no-renames lists both the old and new path of a moved file, so a move
  # out of a package is still seen as a change to that package.
  if ! FILES="$(git diff --name-only --no-renames "$mb" "$head" 2>/dev/null)"; then
    log "git diff failed; running everything"; all=1; FILES=""; return
  fi

  if ! all_json="$(pnpm ls -r --depth -1 --json 2>/dev/null)" || \
     ! jq -e 'type == "array"' <<<"$all_json" >/dev/null 2>&1 || \
     ! PKG_DIRS="$(jq -r --arg top "$TOP" "$PKG_PATHS" <<<"$all_json")"; then
    log "pnpm could not list the workspace; running everything"; all=1; return
  fi
}

# Given package dirs (newline-separated), print them plus all their dependents,
# transitively, as repo-relative dirs. Sets all=1 if pnpm cannot answer.
# Called as a plain function (not in $(...)) so all=1 survives; result in $AFFECTED.
AFFECTED=""
expand_dependents() {
  local d json
  local -a args=()
  while IFS= read -r d; do
    if [ -n "$d" ]; then args+=(--filter "...{$d}"); fi
  done < <(printf '%s\n' "$1" | sort -u)
  if [ "${#args[@]}" -eq 0 ]; then return; fi

  if ! json="$(pnpm ls "${args[@]}" --depth -1 --json 2>/dev/null)" || \
     ! jq -e 'type == "array"' <<<"$json" >/dev/null 2>&1 || \
     ! AFFECTED="$(jq -r --arg top "$TOP" "$PKG_PATHS" <<<"$json")"; then
    log "pnpm could not compute dependents; running everything"; all=1; return
  fi
}

main() {
  local f d p inpkg touched=""
  read_changes "$@"

  if [ "$all" -eq 0 ]; then
    # 1. Sort every changed file into "inside package X" or "outside".
    while IFS= read -r f; do
      if [ -z "$f" ]; then continue; fi
      inpkg=0
      while IFS= read -r d; do
        if [ -n "$d" ]; then
          case "$f" in "$d"/*) inpkg=1; touched+="$d"$'\n' ;; esac
        fi
      done <<< "$PKG_DIRS"
      if [ "$inpkg" -eq 0 ]; then classify_outside "$f"; fi
    done <<< "$FILES"

    # 2. Let pnpm add everything that depends on the touched packages.
    if [ "$all" -eq 0 ] && [ -n "$touched" ]; then
      expand_dependents "$touched"
    fi

    # 3. Map affected packages to areas.
    if [ "$all" -eq 0 ]; then
      while IFS= read -r p; do
        if [ -n "$p" ]; then package_area "$p"; fi
      done <<< "$AFFECTED"
    fi
  fi

  propagate
  emit
}

main "$@"
