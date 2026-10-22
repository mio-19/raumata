# Raumata

Raumata is a patch series on top of [Meshtastic firmware](https://github.com/meshtastic/firmware).

The patches in [`patches/`](./patches) are the real history of this project.
Commits in this repository are bookkeeping: they may be squashed, reordered or
rewritten whenever the series is regenerated. The tooling is adapted from
[cheetah-1.16's patch-series scripts](https://github.com/gommehdnet/cheetah-1.16/tree/master/scripts).

## Current series: Meshtastic + MeshCore

The first series turns the Heltec V3 firmware into a shared-PHY dual-protocol
node:

- Meshtastic and [MeshCore](https://github.com/ripplebiz/MeshCore) both run on
  the same SX1262 and the same LoRa PHY.
- MeshCore frames carry the four-byte `RAUM` transport tag so they can be
  demultiplexed from Meshtastic frames on receive.
- MeshCore's identity and channels persist in NVS; the node advertises and
  supports direct/group text.
- A USB-serial mux serves both Meshtastic's PhoneAPI and the MeshCore companion
  protocol, so MeshCore apps can connect to the same port.

Because one radio has one demodulator, the MeshCore side uses Meshtastic's
frequency/BW/SF/CR/sync-word settings. It reaches MeshCore peers configured to
the same PHY, **not** the standard MeshCore 916.575 MHz/SF7 preset. Both stacks
also share one airtime budget. The patched tree contains
`docs/raumata-dual-protocol.md` with the design and limitations.

Build the dual-protocol image from the working tree:

```sh
cd work/firmware
pio run -e heltec-v3-dual
```

`heltec-v3-dual` is the only build target verified by this series.

## Design notes

- [Dual identity, presence, and simultaneous companion access](./docs/dual-identity-and-companion.md)
  covers linking the Meshtastic and MeshCore identities, advertising the node
  in both meshes, and running a Meshtastic app and a MeshCore app at the same
  time.

## Layout

| Path              | Purpose                                                        |
| ----------------- | -------------------------------------------------------------- |
| `patches/`        | The patch series, applied in filename order.                   |
| `upstream.conf`   | Pinned Meshtastic firmware tag and commit.                     |
| `scripts/`        | Apply, export, verify and rebase the series.                   |
| `work/firmware/`  | Scratch clone of upstream (ignored by git).                    |

## Requirements

- `git`
- Network access the first time `work/firmware` is cloned
- For firmware builds: the toolchain Meshtastic expects (PlatformIO).
  `scripts/apply.sh` initializes submodules by default; pass `--no-submodules`
  while only editing source.

## Workflow

### 1. Set up the working tree

```sh
scripts/apply.sh
```

This clones `work/firmware` if needed, resets it to the pinned upstream commit,
applies every patch in order with `git am --3way --ignore-whitespace`, and
initializes submodules. Add `--no-submodules` to skip submodules when you only
need to edit source.

> `scripts/apply.sh` resets the working tree. It refuses to discard uncommitted
> changes unless you pass `--force`.

### 2. Develop in `work/firmware`

```sh
cd work/firmware
# edit files
git commit -am "subsystem: do the thing"
cd ../..
```

Commit on the `raumata` branch. Split work into logical commits: one commit
becomes one patch in the series.

### 3. Export the series

```sh
scripts/rebuildpatches.sh
```

Every commit between the pinned upstream commit and `HEAD` is written to
`patches/` with `git format-patch`, replacing the previous series. Review the
result and commit it in this repository.

### 4. Verify the series

```sh
scripts/verify.sh
```

This applies the committed series to the pinned upstream commit in a throwaway
git worktree, so it catches patches that were hand-edited or that depend on
uncommitted state.

### 5. Move to a newer upstream release

```sh
scripts/upstream.sh --latest          # latest stable GitHub release
scripts/upstream.sh v2.7.27.abcdef0   # or an explicit tag/commit
```

`--latest` follows GitHub's "latest release", which skips prereleases (the
`v2.8.x` tags are currently prereleases, so they are not picked automatically).
Pass the tag explicitly if you want a prerelease.

The script rebases the `raumata` branch onto the new base, updates
`upstream.conf`, and regenerates `patches/`. If the rebase conflicts, resolve it
in `work/firmware`, then:

```sh
git -C work/firmware rebase --continue
scripts/upstream.sh --continue
```

To update only the base without exporting patches, add `--no-rebuild`.

## Scripts

| Script                     | Purpose                                              |
| -------------------------- | ---------------------------------------------------- |
| `scripts/init.sh`          | Shared config and helpers (sourced, not executed).   |
| `scripts/apply.sh`         | Reset `work/firmware` to the base and apply patches. |
| `scripts/rebuildpatches.sh`| Export commits from `work/firmware` to `patches/`.   |
| `scripts/verify.sh`        | Check the series applies cleanly in a temp worktree. |
| `scripts/upstream.sh`      | Rebase the series onto a newer upstream release.     |

The upstream base is pinned by both tag and commit in `upstream.conf`; changing
it by hand works too, but `scripts/upstream.sh` also rebases the series.
