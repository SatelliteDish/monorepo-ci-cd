#!/usr/bin/env bash
#
# Report which pnpm workspace packages need were changed between two commits.
#
# Output: a JSON array with one object per CHANGED workspace package:
#     [{"name":"@ns/web","path":"apps/web","changed":true}, ...]
# printed (pretty) to stdout. When running inside GitHub Actions it is also
# appended to $GITHUB_OUTPUT as a single-line value:
#     changed=<only the changed ones>
#
# Division of labour:
#   - pnpm lists the workspace packages and says who depends on whom. Nothing
#     here names a package or an area; new packages are picked up automatically.
#   - git decides WHAT CHANGED (merge-base diff, renames expanded). pnpm's own
#     "changed since <ref>" filter is not used: it diffs against the ref's tip
#     rather than the merge-base, and it relies on git rename detection, so a
#     file moved out of a package goes unnoticed.
#   - "changed" means: a file inside the package changed, or something it
#     depends on (directly or transitively) changed.
#
# What is still described by hand (one small table below):
#   classify_outside   files that live outside every package
#
# Dependencies between packages are never listed here. If a package is built
# from or deployed with another one, it declares that in its own package.json
# (e.g. infra depends on backend and web with "workspace:*"), and the change
# propagates through that edge automatically.
#
# Usage:
#   scripts/ci/changed.sh <base-sha> <head-sha>   # diff-based (PRs, pushes)
#   scripts/ci/changed.sh --all                   # mark every package changed
#
# Requirements: git, jq, pnpm (no `pnpm install` needed), full git history
# (fetch-depth: 0). The dependency graph is read from the checked-out tree, so
# in CI check out <head-sha>.
#
# Design rules:
#   1. Unknown or unsure => mark everything changed. A wasted CI run is cheap;
#      a missed one is not.
#   2. Every changed file must be inside a package or claimed by
#      classify_outside. Anything else marks everything changed, which makes
#      forgotten directories loud.
#   3. If the package list itself cannot be produced there is nothing to
#      output, so the script exits 1 (the CI step fails visibly).

set -euo pipefail

ZERO_SHA="0000000000000000000000000000000000000000"

# --- state ---------------------------------------------------------------------
all=0            # 1 => every package is marked changed
TOP=""           # repo root (physical path)
MEMBERS="[]"     # JSON: [{name, path}] for every workspace package
PKG_DIRS=""      # the same paths, one per line
FILES=""         # every file changed since the merge-base
TOUCHED=""       # package dirs with a directly changed file, one per line
AFFECTED=""      # TOUCHED plus everything that depends on them, one per line

log() { echo "changed.sh: $*" >&2; }
die() { log "$*"; exit 1; }

# has_line <needle> <newline-separated haystack>
has_line() { grep -qxF -- "$1" <<<"$2"; }

# Mark a workspace package as directly changed.
claim() {
  if has_line "$1" "$PKG_DIRS"; then
    TOUCHED+="$1"$'\n'
  else
    all=1
    log "'$1' is claimed by a rule but is not a workspace package"
  fi
}

# Classify a changed file that is NOT inside any workspace package.
# NOTE: order matters; first match wins.
classify_outside() {
  case "$1" in
    # Non-JS code that ships with a package (Rust, C, ...). Giving native/ its
    # own package.json makes it a package and removes the need for this rule.
    native/*)                claim infra ;;
    # Nothing is deployed from these.
    docs/*)                  ;;
    README.md|CONTRIBUTING.md|LICENSE|.gitignore) ;;
    # Global inputs: a change here can affect everything.
    pnpm-lock.yaml|pnpm-workspace.yaml|package.json|tsconfig*.json|.nvmrc|.npmrc) all=1 ;;
    .github/*|scripts/ci/*)  all=1 ;;
    # Rule 1 + 2: anything unclaimed marks everything changed.
    *)                       all=1; log "unclaimed path '$1'" ;;
  esac
}

# jq: repo-relative paths of the listed packages, without the workspace root.
PKG_PATHS='.[].path | select(. != $top) | ltrimstr($top + "/")'

# --- obtain the workspace layout and the changed files -------------------------
# Sets the globals above. Sets all=1 when it cannot be sure which files changed.
# Deliberately NOT called inside $(...): a subshell would lose the all=1 flag.
read_changes() {
  local base="${1:-}" head="${2:-}" mb pkgs_json

  TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
  TOP="$(cd "$TOP" && pwd -P)"
  cd "$TOP"

  # The package list is needed for the output, so failing here is fatal.
  pkgs_json="$(pnpm ls -r --depth -1 --json 2>/dev/null)" || die "pnpm could not list the workspace"
  jq -e 'type == "array"' <<<"$pkgs_json" >/dev/null 2>&1 || die "unexpected output from 'pnpm ls'"
  MEMBERS="$(jq -c --arg top "$TOP" \
    '[.[] | select(.path != $top) | {name, path: (.path | ltrimstr($top + "/"))}] | sort_by(.path)' \
    <<<"$pkgs_json")" || die "could not parse the package list"
  PKG_DIRS="$(jq -r '.[].path' <<<"$MEMBERS")" || die "could not parse the package list"

  if [ "$base" = "--all" ]; then all=1; return; fi

  # Missing/zero base happens on new branches and some force-pushes.
  if [ -z "$base" ] || [ -z "$head" ] || [ "$base" = "$ZERO_SHA" ]; then
    log "no usable base; marking everything changed"; all=1; return
  fi
  # Both commits must exist locally (needs fetch-depth: 0 in checkout).
  if ! git cat-file -e "${base}^{commit}" 2>/dev/null || \
     ! git cat-file -e "${head}^{commit}" 2>/dev/null; then
    log "commit(s) not available locally; marking everything changed"; all=1; return
  fi
  # Merge-base = only what THIS side changed (same as a three-dot diff).
  # NOTE: base must be the EARLIER commit. Reversed, the merge-base is the head
  # itself and the diff is empty.
  if ! mb="$(git merge-base "$base" "$head" 2>/dev/null)"; then
    log "no merge-base; marking everything changed"; all=1; return
  fi
  # --no-renames lists both the old and new path of a moved file, so a move
  # out of a package is still seen as a change to that package.
  if ! FILES="$(git diff --name-only --no-renames "$mb" "$head" 2>/dev/null)"; then
    log "git diff failed; marking everything changed"; all=1; FILES=""
  fi
}

# TOUCHED -> AFFECTED: ask pnpm for the touched packages plus all their
# dependents, transitively. Sets all=1 if pnpm cannot answer.
expand_dependents() {
  local d json
  local -a args=()
  while IFS= read -r d; do
    if [ -n "$d" ]; then args+=(--filter "...{$d}"); fi
  done < <(printf '%s' "$TOUCHED" | sort -u)
  if [ "${#args[@]}" -eq 0 ]; then AFFECTED=""; return; fi

  if ! json="$(pnpm ls "${args[@]}" --depth -1 --json 2>/dev/null)" || \
     ! jq -e 'type == "array"' <<<"$json" >/dev/null 2>&1 || \
     ! AFFECTED="$(jq -r --arg top "$TOP" "$PKG_PATHS" <<<"$json")"; then
    log "pnpm could not compute dependents; marking everything changed"; all=1
  fi
}

emit() {
  local affected_json out changed
  affected_json="$(printf '%s' "$AFFECTED" | jq -Rn '[inputs | select(length > 0)]')"
  out="$(jq -c --argjson all "$all" --argjson affected "$affected_json" \
    'map(.changed = ($all == 1 or (.path as $p | $affected | any(. == $p))))' <<<"$MEMBERS")"
  changed="$(jq -c 'map(select(.changed))' <<<"$out")"

  jq . <<<"$changed"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "changed=$changed" >> "$GITHUB_OUTPUT"
  fi
}

main() {
  local f d inpkg
  read_changes "$@"

  if [ "$all" -eq 0 ]; then
    # 1. Sort every changed file into "inside package X" or "outside".
    while IFS= read -r f; do
      if [ -z "$f" ]; then continue; fi
      inpkg=0
      while IFS= read -r d; do
        if [ -n "$d" ]; then
          case "$f" in "$d"/*) inpkg=1; TOUCHED+="$d"$'\n' ;; esac
        fi
      done <<< "$PKG_DIRS"
      if [ "$inpkg" -eq 0 ]; then classify_outside "$f"; fi
    done <<< "$FILES"

    # 2. Add everything that depends on the touched packages.
    if [ "$all" -eq 0 ] && [ -n "$TOUCHED" ]; then
      expand_dependents
    fi
  fi

  emit
}

main "$@"
