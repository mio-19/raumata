# Raumata

Raumata manages two downstream patch series:

- [`patches/`](./patches) on top of [Meshtastic firmware](https://github.com/meshtastic/firmware).
- [`patches/android/`](./patches/android) on top of the
  [Meshtastic Android client](https://github.com/meshtastic/Meshtastic-Android).

The patches are the real history of each project. Commits in this repository are
bookkeeping: they may be squashed, reordered or rewritten whenever a series is
regenerated. The tooling is adapted from
[cheetah-1.16's patch-series scripts](https://github.com/gommehdnet/cheetah-1.16/tree/master/scripts).

## Current series: Meshtastic + MeshCore

The first series turns the Heltec V3 firmware into a shared-PHY dual-protocol
node:

- Meshtastic and [MeshCore](https://github.com/ripplebiz/MeshCore) both run on
  the same SX1262 and the same selectable LoRa PHY profile (Meshtastic preset,
  MeshCore preset, dual preset, or custom PHY).
- MeshCore frames carry the four-byte `RAUM` transport tag so they can be
  demultiplexed from Meshtastic frames on receive.
- MeshCore's identity, contacts, channels, and identity-link record persist in
  NVS; the node staggers presence adverts across both meshes and supports
  direct/group text, contact import/export, custom variables, and telemetry stats.
- A USB-serial mux serves both Meshtastic's PhoneAPI and the MeshCore companion
  protocol (or dedicates USB to MeshCore when Meshtastic uses BLE in
  `RAUMATA_COMPANION_MODE_BLE_USB`).

Because one radio has one demodulator, both stacks share the active `PhyProfile`
(frequency, bandwidth, spreading factor, coding rate, sync word, preamble, and
TX power) as well as one airtime budget. The patched tree contains
`docs/raumata-dual-protocol.md` with the design and limitations.

Build the dual-protocol image from the working tree:

```sh
cd work/firmware
pio run -e heltec-v3-dual      # Heltec V3
pio run -e t-deck-plus-dual    # LILYGO T-Deck Plus (with built-in L76K GPS)
pio run -e t-deck-dual         # LILYGO T-Deck (BaseUI)
pio run -e t-deck-tft-dual     # LILYGO T-Deck / T-Deck Plus (Meshtastic UI / LVGL)
```

`heltec-v3-dual` and `t-deck-plus-dual` (`t-deck-dual`, `t-deck-tft-dual`) are
the supported dual-protocol build targets in this series.

## Current series: Android MeshCore companion

The Android series adds a dedicated **MeshCore** tab to the Meshtastic Android
client, built on
[MeshCoreKmp](https://github.com/Wavesonics/MeshCoreKmp):

- USB and BLE transports. USB uses the app's existing `UsbRepository` and adds
  MeshCore's `<`/`>` CDC framing; BLE uses MeshCoreKmp's BlueFalcon adapter.
- A separate MeshCore repository and chat surface, so MeshCore identities,
  channels and contacts do not pollute the Meshtastic node/message database.
- Connect, scan, channel/contact lists, and direct/group text.

The Android series is pinned to `v2.8.3`. Patch application is verified; the
Android build is not run in this workspace.

```sh
scripts/apply-android.sh
scripts/rebuild-android-patches.sh
scripts/verify-android.sh
```

## Design notes

- [Dual identity, presence, and simultaneous companion access](./docs/dual-identity-and-companion.md)
  covers linking the Meshtastic and MeshCore identities, advertising the node
  in both meshes, and running a Meshtastic app and a MeshCore app at the same
  time.
- [Shared PHY profiles and preset selection](./docs/shared-phy-profiles.md)
  covers keeping the radio in one selectable physical configuration that can
  be a Meshtastic preset, a MeshCore preset, a dual preset, or custom values.

## Layout

| Path                  | Purpose                                                        |
| --------------------- | -------------------------------------------------------------- |
| `patches/`            | Firmware patch series, applied in filename order.              |
| `patches/android/`    | Android client patch series.                                   |
| `upstream.conf`       | Pinned Meshtastic firmware tag and commit.                     |
| `upstream-android.conf` | Pinned Meshtastic Android tag and commit.                    |
| `scripts/`            | Firmware apply/export/verify/rebase tooling.                   |
| `scripts/*-android.sh`| Android apply/export/verify tooling.                           |
| `work/firmware/`      | Scratch firmware clone (ignored by git).                       |
| `work/android/`       | Scratch Android clone (ignored by git).                        |

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
| `scripts/init-android.sh`  | Shared Android config and helpers (sourced).         |
| `scripts/apply-android.sh` | Reset `work/android` to the base and apply patches.  |
| `scripts/rebuild-android-patches.sh` | Export Android commits to `patches/android/`. |
| `scripts/verify-android.sh`| Check the Android series applies cleanly.            |
| `scripts/upstream-android.sh` | Rebase the Android series onto a newer release.   |

The upstream base is pinned by both tag and commit in `upstream.conf`; changing
it by hand works too, but `scripts/upstream.sh` also rebases the series.
