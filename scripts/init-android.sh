#!/usr/bin/env bash
# Shared configuration and helpers for the Raumata Android patch series.
# Sourced by the Android scripts; do not execute directly.

set -euo pipefail

_script="${BASH_SOURCE[0]}"
while [ -h "$_script" ]; do
    _dir="$(cd -P "$(dirname "$_script")" && pwd)"
    _script="$(readlink "$_script")"
    [[ "$_script" != /* ]] && _script="$_dir/$_script"
done

BASEDIR="$(cd -P "$(dirname "$_script")/.." && pwd)"
PATCHES_DIR="$BASEDIR/patches/android"
WORK_DIR="$BASEDIR/work/android"
BRANCH_NAME="raumata-android"

# shellcheck source=../upstream-android.conf
. "$BASEDIR/upstream-android.conf"

if [ -t 1 ]; then
    C_INFO=$'\033[1;34m'
    C_SUCCESS=$'\033[1;32m'
    C_WARN=$'\033[1;33m'
    C_ERROR=$'\033[1;31m'
    C_RESET=$'\033[0m'
else
    C_INFO=""
    C_SUCCESS=""
    C_WARN=""
    C_ERROR=""
    C_RESET=""
fi

info() { printf '%s[INFO]%s %s\n' "$C_INFO" "$C_RESET" "$*"; }
success() { printf '%s[SUCCESS]%s %s\n' "$C_SUCCESS" "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
error() { printf '%s[ERROR]%s %s\n' "$C_ERROR" "$C_RESET" "$*" >&2; }
die() {
    error "$*"
    exit 1
}

patch_list() {
    find "$PATCHES_DIR" -maxdepth 1 -type f -name '*.patch' 2>/dev/null | LC_ALL=C sort
}

require_worktree() {
    [ -d "$WORK_DIR/.git" ] ||
        die "Working tree not found at $WORK_DIR. Run scripts/apply-android.sh first."
}

require_clean_worktree() {
    require_worktree
    if [ -n "$(git -C "$WORK_DIR" status --porcelain)" ]; then
        die "Working tree $WORK_DIR has uncommitted changes. Commit or discard them first."
    fi
}

rebase_in_progress() {
    [ -d "$WORK_DIR/.git/rebase-merge" ] || [ -d "$WORK_DIR/.git/rebase-apply" ]
}

ensure_upstream_commit() {
    if git -C "$WORK_DIR" cat-file -e "$UPSTREAM_COMMIT^{commit}" 2>/dev/null; then
        return 0
    fi

    info "Fetching tags from $UPSTREAM_URL..."
    git -C "$WORK_DIR" fetch --tags --prune origin
    git -C "$WORK_DIR" cat-file -e "$UPSTREAM_COMMIT^{commit}" 2>/dev/null ||
        die "Pinned upstream commit $UPSTREAM_COMMIT ($UPSTREAM_TAG) not found in $WORK_DIR."
}

verify_pin() {
    local tag_commit
    tag_commit="$(git -C "$WORK_DIR" rev-parse --verify --quiet "$UPSTREAM_TAG^{commit}" || true)"
    if [ -n "$tag_commit" ] && [ "$tag_commit" != "$UPSTREAM_COMMIT" ]; then
        die "upstream-android.conf is inconsistent: $UPSTREAM_TAG is $tag_commit, but UPSTREAM_COMMIT is $UPSTREAM_COMMIT."
    fi
}
