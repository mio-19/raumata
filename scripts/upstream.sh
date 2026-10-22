#!/usr/bin/env bash
# Move the patch series onto a newer Meshtastic firmware release.
set -euo pipefail

_source="${BASH_SOURCE[0]}"
while [ -h "$_source" ]; do
    _dir="$(cd -P "$(dirname "$_source")" && pwd)"
    _source="$(readlink "$_source")"
    [[ "$_source" != /* ]] && _source="$_dir/$_source"
done
# shellcheck source=init.sh
. "$(dirname "$_source")/init.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") <tag|commit> [--no-rebuild]
       $(basename "$0") --latest [--no-rebuild]
       $(basename "$0") --continue

Rebase the commits in work/firmware onto a newer upstream release, update
upstream.conf, and export the result to patches/.

Options:
  --latest      Pick the latest non-prerelease GitHub release.
  --continue    Finish an update whose rebase was interrupted by conflicts.
  --no-rebuild  Update the base and work/firmware only; do not export patches.
  -h, --help    Show this help.
EOF
}

state_file="$WORK_DIR/.git/raumata-upstream-target"

# Resolve the latest stable (non-prerelease) upstream release through the
# GitHub API. Tags alone cannot distinguish stable releases from prereleases:
# Meshtastic tags prerelease builds without an "-rc" suffix.
latest_stable_tag() {
    local repo json
    command -v curl >/dev/null 2>&1 ||
        die "curl is required for --latest; pass an explicit tag instead."

    case "$UPSTREAM_URL" in
        *github.com[:/]*)
            repo="${UPSTREAM_URL#*github.com}"
            repo="${repo#[:/]}"
            repo="${repo%.git}"
            ;;
        *)
            die "Cannot derive a GitHub repository from UPSTREAM_URL=$UPSTREAM_URL; pass an explicit tag instead."
            ;;
    esac

    json="$(curl -fsSL --max-time 30 \
        -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$repo/releases/latest")" ||
        die "Could not query the latest release for $repo; pass an explicit tag instead."

    printf '%s\n' "$json" |
        sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' |
        sed -n '1p'
}

update_upstream_conf() {
    local tag="$1" commit="$2" tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/raumata-upstream-conf.XXXXXX")"
    sed -e "s|^UPSTREAM_TAG=.*|UPSTREAM_TAG=\"$tag\"|" \
        -e "s|^UPSTREAM_COMMIT=.*|UPSTREAM_COMMIT=\"$commit\"|" \
        "$BASEDIR/upstream.conf" >"$tmp"
    mv "$tmp" "$BASEDIR/upstream.conf"
    UPSTREAM_TAG="$tag"
    UPSTREAM_COMMIT="$commit"
}

finish_update() {
    if [ "$no_rebuild" -eq 1 ]; then
        info "Skipping patch export (--no-rebuild). Run scripts/rebuildpatches.sh when ready."
        return 0
    fi
    exec "$BASEDIR/scripts/rebuildpatches.sh"
}

mode="update"
target=""
no_rebuild=0
for arg in "$@"; do
    case "$arg" in
        --latest)
            [ "$mode" = "continue" ] && die "--latest cannot be combined with --continue."
            target="--latest"
            ;;
        --continue)
            [ "$mode" = "continue" ] && die "--continue specified twice."
            mode="continue"
            ;;
        --no-rebuild) no_rebuild=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        -*)
            die "Unknown option: $arg (try --help)"
            ;;
        *)
            [ -n "$target" ] && die "Only one upstream target can be given."
            target="$arg"
            ;;
    esac
done

if [ "$mode" = "continue" ]; then
    [ -f "$state_file" ] || die "No interrupted upstream update recorded in $WORK_DIR."
    rebase_in_progress && die "The rebase is still in progress. Finish it with 'git -C \"$WORK_DIR\" rebase --continue' first."

    {
        IFS= read -r target
        IFS= read -r new_commit
    } <"$state_file"

    git -C "$WORK_DIR" merge-base --is-ancestor "$new_commit" HEAD ||
        die "$BRANCH_NAME is not based on $target ($new_commit); was the rebase aborted? Remove $state_file and re-run the update."

    rm -f "$state_file"
    update_upstream_conf "$target" "$new_commit"
    success "Updated upstream base to $target ($new_commit)."
    finish_update
    exit 0
fi

[ -n "$target" ] || {
    usage
    exit 1
}

mkdir -p "$BASEDIR/work" "$PATCHES_DIR"

if [ ! -d "$WORK_DIR/.git" ]; then
    info "Cloning upstream $UPSTREAM_URL into $WORK_DIR..."
    git clone "$UPSTREAM_URL" "$WORK_DIR"
fi

info "Fetching tags from $UPSTREAM_URL..."
git -C "$WORK_DIR" fetch --tags --prune origin

if [ "$target" = "--latest" ]; then
    target="$(latest_stable_tag)"
    [ -n "$target" ] ||
        die "Could not determine the latest stable upstream release; pass an explicit tag."
    info "Latest stable upstream release: $target"
fi

new_commit="$(git -C "$WORK_DIR" rev-parse --verify --quiet "$target^{commit}")" ||
    die "Unknown upstream ref: $target"
old_commit="$UPSTREAM_COMMIT"

if [ "$new_commit" = "$old_commit" ]; then
    success "Already based on $target ($new_commit); nothing to do."
    exit 0
fi

require_clean_worktree
rebase_in_progress && die "A rebase is already in progress in $WORK_DIR. Finish or abort it first."

if git -C "$WORK_DIR" show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
    git -C "$WORK_DIR" checkout "$BRANCH_NAME"
else
    git -C "$WORK_DIR" checkout -B "$BRANCH_NAME" "$old_commit"
fi

commit_count="$(git -C "$WORK_DIR" rev-list --count "$old_commit"..HEAD)"

if [ "$commit_count" -eq 0 ]; then
    info "No local commits to rebase; moving the branch to $target."
    git -C "$WORK_DIR" reset --hard "$new_commit"
    update_upstream_conf "$target" "$new_commit"
    success "Updated upstream base to $target ($new_commit)."
    exit 0
fi

printf '%s\n%s\n' "$target" "$new_commit" >"$state_file"

info "Rebasing $commit_count commit(s) from $UPSTREAM_TAG onto $target..."
if ! git -C "$WORK_DIR" rebase --onto "$new_commit" "$old_commit" "$BRANCH_NAME"; then
    error "Rebase stopped due to conflicts."
    error "Resolve them in $WORK_DIR, then run:"
    error "  git -C \"$WORK_DIR\" rebase --continue"
    error "  scripts/upstream.sh --continue"
    error "Or abandon the update with:"
    error "  git -C \"$WORK_DIR\" rebase --abort && rm -f \"$state_file\""
    exit 1
fi

rm -f "$state_file"
update_upstream_conf "$target" "$new_commit"
success "Updated upstream base to $target ($new_commit)."
finish_update
