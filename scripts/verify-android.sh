#!/usr/bin/env bash
# Verify that the committed Android patch series applies cleanly to the pinned
# upstream base in a throwaway git worktree.
set -euo pipefail

_source="${BASH_SOURCE[0]}"
while [ -h "$_source" ]; do
    _dir="$(cd -P "$(dirname "$_source")" && pwd)"
    _source="$(readlink "$_source")"
    [[ "$_source" != /* ]] && _source="$_dir/$_source"
done
# shellcheck source=init-android.sh
. "$(dirname "$_source")/init-android.sh"

require_worktree
verify_pin

mapfile -t patches < <(patch_list)
if [ "${#patches[@]}" -eq 0 ]; then
    warn "No patches in $PATCHES_DIR; nothing to verify."
    exit 0
fi

verify_dir="$(mktemp -d "${TMPDIR:-/tmp}/raumata-android-verify.XXXXXX")"
cleanup() {
    git -C "$WORK_DIR" worktree remove --force "$verify_dir" >/dev/null 2>&1 ||
        rm -rf "$verify_dir"
}
trap cleanup EXIT

info "Checking out $UPSTREAM_TAG ($UPSTREAM_COMMIT) into $verify_dir..."
git -C "$WORK_DIR" worktree add --detach --quiet "$verify_dir" "$UPSTREAM_COMMIT"

for patch in "${patches[@]}"; do
    info "Checking $(basename "$patch")..."
    if ! git -C "$verify_dir" am --3way --ignore-whitespace --quiet "$patch"; then
        error "Patch $(basename "$patch") does not apply cleanly to $UPSTREAM_TAG."
        exit 1
    fi
done

success "All ${#patches[@]} Android patch(es) apply cleanly to $UPSTREAM_TAG."
