#!/usr/bin/env bash
# apply-pane-patches.sh
# Applies Kytos-local patches to the Pane submodule.
# Safe to run repeatedly — already-applied patches are skipped via git apply --check.
#
# Usage:
#   Scripts/apply-pane-patches.sh            # apply all Patches/Pane/*.patch
#   Scripts/apply-pane-patches.sh --reverse  # revert all patches (clean submodule)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUBMODULE_DIR="$REPO_ROOT/Submodules/Pane"
PATCH_DIR="$REPO_ROOT/Patches/Pane"
REVERSE="${1:-}"

if [ ! -d "$SUBMODULE_DIR/.git" ] && [ ! -f "$SUBMODULE_DIR/.git" ]; then
  echo "error: Pane submodule not initialised. Run: git submodule update --init" >&2
  exit 1
fi

cd "$SUBMODULE_DIR"

PATCHES=( $(ls "$PATCH_DIR"/*.patch 2>/dev/null | sort) )
if [ ${#PATCHES[@]} -eq 0 ]; then
  echo "No patches found in $PATCH_DIR"
  exit 0
fi

if [ "$REVERSE" = "--reverse" ]; then
  # Revert in reverse order
  for (( i=${#PATCHES[@]}-1; i>=0; i-- )); do
    PATCH="${PATCHES[$i]}"
    NAME="$(basename "$PATCH")"
    if git apply --reverse --check "$PATCH" 2>/dev/null; then
      git apply --reverse "$PATCH"
      echo "  reverted  $NAME"
    else
      echo "  skipped   $NAME (not applied)"
    fi
  done
else
  for PATCH in "${PATCHES[@]}"; do
    NAME="$(basename "$PATCH")"
    if git apply --check "$PATCH" 2>/dev/null; then
      git apply "$PATCH"
      echo "  applied   $NAME"
    else
      echo "  skipped   $NAME (already applied or conflicts)"
    fi
  done
fi
