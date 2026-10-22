#!/usr/bin/env bash
# Apply the Raumata Android patch series on top of the pinned Meshtastic
# Android release. Clones work/android on first use.
set -euo pipefail

_source="${BASH_SOURCE[0]}"
while [ -h "$_source" ]; do
    _dir="$(cd -P "$(dirname "$_source")" && pwd)"
    _source="$(readlink "$_source")"
    [[ "$_source" != /* ]] && _source="$_dir/$_source"
done
# shellcheck source=init-android.sh
. "$(dirname "$_source")/init-android.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--force]

Reset work/android to the pinned upstream base and apply every patch in
patches/android in order.

Options:
  --force  Discard uncommitted changes / an in-progress git am or rebase.
  -h, --help
EOF
}

force=0
for arg in "$@"; do
    case "$arg" in
        --force) force=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "Unknown argument: $arg (try --help)" ;;
    esac
done

mkdir -p "$BASEDIR/work" "$PATCHES_DIR"

if [ ! -d "$WORK_DIR/.git" ]; then
    info "Cloning upstream $UPSTREAM_URL into $WORK_DIR..."
    git clone "$UPSTREAM_URL" "$WORK_DIR"
fi

if [ "$force" -eq 1 ]; then
    git -C "$WORK_DIR" am --abort >/dev/null 2>&1 || true
    git -C "$WORK_DIR" rebase --abort >/dev/null 2>&1 || true
elif [ -n "$(git -C "$WORK_DIR" status --porcelain)" ]; then
    die "Working tree $WORK_DIR has uncommitted changes (or a failed apply). Re-run with --force to discard them."
fi

ensure_upstream_commit
verify_pin

info "Resetting $WORK_DIR to $UPSTREAM_TAG ($UPSTREAM_COMMIT)..."
git -C "$WORK_DIR" checkout -f -B "$BRANCH_NAME" "$UPSTREAM_COMMIT"
git -C "$WORK_DIR" reset --hard "$UPSTREAM_COMMIT"
git -C "$WORK_DIR" clean -fdxq

mapfile -t patches < <(patch_list)
if [ "${#patches[@]}" -eq 0 ]; then
    warn "No patches found in $PATCHES_DIR; work/android is at the upstream base."
else
    for patch in "${patches[@]}"; do
        info "Applying $(basename "$patch")..."
        if ! git -C "$WORK_DIR" am --3way --ignore-whitespace "$patch"; then
            error "Failed to apply $(basename "$patch")."
            error "Resolve the conflict in $WORK_DIR, then run:"
            error "  git -C \"$WORK_DIR\" am --continue"
            error "or discard everything and start over with:"
            error "  scripts/apply-android.sh --force"
            exit 1
        fi
    done
    success "Applied ${#patches[@]} Android patch(es) on top of $UPSTREAM_TAG."
fi

info "Working tree ready: $WORK_DIR (branch $BRANCH_NAME)"
info "Edit and commit there, then run scripts/rebuild-android-patches.sh."
