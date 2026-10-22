#!/usr/bin/env bash
# Export commits on work/android into patches/android.
set -euo pipefail

_source="${BASH_SOURCE[0]}"
while [ -h "$_source" ]; do
    _dir="$(cd -P "$(dirname "$_source")" && pwd)"
    _source="$(readlink "$_source")"
    [[ "$_source" != /* ]] && _source="$_dir/$_source"
done
# shellcheck source=init-android.sh
. "$(dirname "$_source")/init-android.sh"

if rebase_in_progress; then
    die "A rebase is in progress in $WORK_DIR. Finish it or abort it first."
fi

require_clean_worktree
verify_pin

if ! git -C "$WORK_DIR" merge-base --is-ancestor "$UPSTREAM_COMMIT" HEAD; then
    die "Pinned upstream commit $UPSTREAM_COMMIT is not an ancestor of HEAD in $WORK_DIR."
fi

commit_count="$(git -C "$WORK_DIR" rev-list --count "$UPSTREAM_COMMIT"..HEAD)"
if [ "$commit_count" -eq 0 ]; then
    die "No commits on top of $UPSTREAM_TAG in $WORK_DIR; there is nothing to export."
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/raumata-android-patches.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

info "Exporting $commit_count commit(s) from $WORK_DIR..."
git -C "$WORK_DIR" format-patch \
    --zero-commit \
    --full-index \
    --no-signature \
    --no-stat \
    --no-numbered \
    --quiet \
    -o "$tmp_dir" \
    "$UPSTREAM_COMMIT"..HEAD

find "$PATCHES_DIR" -maxdepth 1 -type f -name '*.patch' -delete
mkdir -p "$PATCHES_DIR"
cp "$tmp_dir"/*.patch "$PATCHES_DIR"/

success "Wrote $commit_count Android patch(es) to $PATCHES_DIR:"
for patch in "$PATCHES_DIR"/*.patch; do
    printf '  - %s\n' "$(basename "$patch")"
done
