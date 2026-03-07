#!/usr/bin/env bash
# apply-pane-patches.sh
# Applies Kytos-local patches to Pane and SwiftTerm submodules.
# Safe to run repeatedly — already-applied patches are skipped.
#
# Usage:
#   Scripts/apply-pane-patches.sh            # apply all patches
#   Scripts/apply-pane-patches.sh --reverse  # revert all patches

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REVERSE="${1:-}"

apply_patches() {
  local submodule_dir="$1"
  local patch_dir="$2"
  local name="$(basename "$submodule_dir")"

  if [ ! -d "$submodule_dir/.git" ] && [ ! -f "$submodule_dir/.git" ]; then
    echo "warning: $name submodule not initialised, skipping" >&2
    return
  fi

  local patches=( $(ls "$patch_dir"/*.patch 2>/dev/null | sort) )
  if [ ${#patches[@]} -eq 0 ]; then
    return
  fi

  cd "$submodule_dir"
  echo "[$name]"

  if [ "$REVERSE" = "--reverse" ]; then
    for (( i=${#patches[@]}-1; i>=0; i-- )); do
      local patch="${patches[$i]}"
      local pname="$(basename "$patch")"
      if git apply --reverse --check "$patch" 2>/dev/null; then
        git apply --reverse "$patch"
        echo "  reverted  $pname"
      else
        echo "  skipped   $pname (not applied)"
      fi
    done
  else
    for patch in "${patches[@]}"; do
      local pname="$(basename "$patch")"
      if git apply --check "$patch" 2>/dev/null; then
        git apply "$patch"
        echo "  applied   $pname"
      elif git apply --reverse --check "$patch" 2>/dev/null; then
        echo "  skipped   $pname (already applied)"
      else
        echo "  resetting $pname (partial apply detected)"
        git checkout -- .
        git apply "$patch"
        echo "  applied   $pname (after reset)"
      fi
    done
  fi
}

apply_patches "$REPO_ROOT/Submodules/SwiftTerm" "$REPO_ROOT/Patches/SwiftTerm"
apply_patches "$REPO_ROOT/Submodules/Pane" "$REPO_ROOT/Patches/Pane"
