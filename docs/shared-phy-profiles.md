# Shared PHY profiles and preset selection

Status: profiles are implemented in `0002-radio-add-raw-frame-hook-and-shared-ownership.patch` and `0006-raumata-add-shared-phy-profiles-and-preset-selection.patch`. Operating modes are implemented in `0011-raumata-choose-a-native-profile-and-which-protocol-o.patch`. The companion is MeshCore's `MyMesh` as of `0013-raumata-run-MeshCore-s-companion-on-the-shared-radio.patch`.

The radio stays in **one physical configuration** continuously. There is no
per-protocol retuning and no time slicing. That one configuration is a
complete LoRa PHY profile, and both Meshtastic and MeshCore use it.

The operating mode chooses which family supplies that configuration:

| Mode | Wire name | Physical configuration | Background traffic |
| --- | --- | --- | --- |
| Mainly Meshtastic | `mainly-meshtastic` | A Meshtastic preset (sync `0x2B`, preamble 16) | Meshtastic. MeshCore does not advertise. Companion sends still go out. About 90% / 10% airtime. |
| Mainly MeshCore | `mainly-meshcore` | A MeshCore preset (sync `0x12`, preamble 32) | MeshCore. Meshtastic nodeinfo, position, and telemetry stay off. Phone-originated Meshtastic messages still go out. About 10% / 90% airtime. |
| Both on a Meshtastic profile | `shared-meshtastic` | A Meshtastic preset | Both stacks advertise. About 50% / 50% airtime. |
| Both on a MeshCore profile | `shared-meshcore` | A MeshCore preset | Both stacks advertise. About 50% / 50% airtime. |

Each stack's share is a portion of the regional duty cycle, measured over the
last hour. Background traffic is dropped once that share is used. Text,
routing, and admin messages are still sent. A MeshCore companion can set the
advert position with `CMD_SET_ADVERT_COORDS` (latitude and longitude in
millionths of a degree); otherwise the advert uses the Meshtastic local
position.

The mode is stored in NVS (`raumata/mode`) with the last preset chosen for each
family, so switching back restores it. A profile from the other family is
rejected. Stock peers of the selected family hear the node; stock peers of the
other family do not, because one radio has one sync word.

Set the mode from the MeshCore companion with custom var `mode`, or
`mode set <name>` over `CMD_RUN_CLI_COMMAND`. Set the preset with custom var
`phy.id` or `phy set <id>`. `CMD_GET_CUSTOM_VARS` reports `mode`, `phy.id`,
`phy.name`, and `phy.sync`. The Android MeshCore tab exposes the same choices.

A node that already had a saved profile and no mode record keeps both stacks
active. A MeshCore preset (or an older dual/custom profile whose sync word is
`0x12`) becomes `shared-meshcore`. Anything else becomes `shared-meshtastic`,
and a profile that is not a native preset of that family is replaced by the
regional default.

## 1. What a “physical configuration” includes

A LoRa profile is more than frequency and spreading factor. The shared
profile must define all of these:

| Field | Why it matters |
| --- | --- |
| Frequency | Must match on both sides. |
| Bandwidth | A receiver configured for 250 kHz cannot demodulate 62.5 kHz. |
| Spreading factor | Part of the demodulator configuration. |
| Coding rate | Part of the frame format; must match. |
| Sync word | Hardware-level filter; a mismatched sync word is discarded. |
| Preamble length | Transmitter and receiver should agree; MeshCore uses 32 symbols for SF ≤ 8, Meshtastic uses 16. |
| CRC | Both currently use CRC on. |
| LDRO | Derived from SF/BW; must be consistent. |
| TX power | Region/hardware limit, not a protocol parameter but part of the profile. |
| Region/regulatory hint | Power/duty-cycle limits and channel calculation. |

The hardware must stay on exactly one set of these values. Changing any field
means reconfiguring the radio for both stacks at the same time.

## 2. Preset model

Define a `PhyProfile`:

```c
enum PhyProfileKind : uint8_t {
    PHY_MESHTASTIC_PRESET,
    PHY_MESHCORE_PRESET,
    PHY_DUAL_PRESET,
    PHY_CUSTOM,
};

struct PhyProfile {
    uint8_t id;
    const char *name;
    PhyProfileKind kind;

    // Meshtastic-preset fields
    uint8_t  msh_modem_preset;
    uint16_t msh_channel_num;
    uint8_t  msh_region;       // hint/validation

    // Explicit PHY fields. MeshCore presets fill these in.
    // PHY_DUAL_PRESET and PHY_CUSTOM remain so an old NVS record can be migrated.
    float    freq_mhz;
    float    bw_khz;
    uint8_t  sf;
    uint8_t  cr;
    uint8_t  sync_word;
    uint16_t preamble;
    bool     crc;
    int8_t   tx_power;
};
```

For a Meshtastic preset, the frequency is computed by Meshtastic from the
region and channel, so `freq_mhz` can be zero and the active frequency is read
back from the radio. For a MeshCore preset, `freq_mhz` is explicit
and Meshtastic is configured with `use_preset=false`, manual BW/SF/CR, and
`override_frequency`.

### 2.1 Example preset table

| ID | Kind | Name | Frequency | BW | SF | CR | Sync | Preamble |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Meshtastic | ANZ LongFast | region/channel computed (e.g. ~915.125 MHz) | 250 | 11 | 5 | 0x2B | 16 |
| 2 | Meshtastic | ANZ MediumSlow | region/channel computed | 250 | 10 | 5 | 0x2B | 16 |
| 3 | Meshtastic | ANZ ShortFast | region/channel computed | 250 | 7 | 5 | 0x2B | 16 |
| 10 | MeshCore | Australia (Narrow) | 916.575 MHz | 62.5 | 7 | 7 | 0x12 | 32 |
| 11 | MeshCore | New Zealand (Narrow) | 917.375 MHz | 62.5 | 7 | 5 | 0x12 | 32 |
| 12 | MeshCore | US/Canada (Narrow) | 910.525 MHz | 62.5 | 7 | 5 | 0x12 | 32 |
| 13 | MeshCore | Portugal 868 | 869.618 MHz | 62.5 | 7 | 6 | 0x12 | 32 |

Older dual presets (ids 20 and 21) and free-form custom PHY values are not
selectable. Shared operation is the operating mode above, and the physical
configuration is always one of these native presets. `CMD_SET_RADIO_PARAMS`
selects a MeshCore preset only when the active mode uses the MeshCore family
and the frequency, bandwidth, spreading factor, and coding rate match.

The table is data, not hard-coded control flow. Adding a preset should not
require changes to the radio or companion code.

## 3. The sync-word problem

One radio has one sync word. This is the unavoidable interoperability
trade-off:

| Selected profile | Sync word | Standard Meshtastic peers | Standard MeshCore peers |
| --- | --- | --- | --- |
| Meshtastic preset, including both-on-Meshtastic-profile | 0x2B | Hear it | Need a Raumata/patched MeshCore using 0x2B |
| MeshCore preset, including both-on-MeshCore-profile | 0x12 | Need a Raumata/patched Meshtastic using 0x12 | Hear it |

There is no single sync word that makes *standard* Meshtastic and *standard*
MeshCore peers both hear the same transmission. The choices are:

1. **Native preset:** use the preset family's native sync word (0x2B for
   Meshtastic, 0x12 for MeshCore). The selected protocol is standard; the
   other side needs matching firmware/configuration.
2. **Shared mode on one native profile:** both stacks use that profile's sync
   word. Stock peers of the other family do not hear the node.
3. **Two radios:** the only way to be standard on both networks at once.

The companion lists only the presets the active mode allows, and it reports
the sync word. Do not silently rewrite a MeshCore preset's sync word to 0x2B,
or a Meshtastic preset's sync word to 0x12.

Preamble has the same issue, though it is less brittle: MeshCore presets use
32 symbols, Meshtastic presets use 16. Make preamble part of the profile and
report it.

## 4. Applying a profile

### 4.1 Boot

`raumata::phyInit()` runs after config/NodeDB are loaded and before
`initLoRa()`:

1. Load the selected profile from NVS (`raumata/phy`).
2. If it is a Meshtastic preset:
   - `config.lora.use_preset = true`
   - `config.lora.modem_preset = profile.msh_modem_preset`
   - `config.lora.channel_num = profile.msh_channel_num`
   - `config.lora.override_frequency = 0`
3. If it is a MeshCore preset:
   - `config.lora.use_preset = false`
   - `config.lora.bandwidth = bwKHzToCode(profile.bw_khz)`
   - `config.lora.spread_factor = profile.sf`
   - `config.lora.coding_rate = profile.cr`
   - `config.lora.override_frequency = profile.freq_mhz`
   - `config.lora.channel_num = 0`
4. Set `config.lora.tx_power` from the profile.
5. Publish the profile's sync word and preamble to the radio layer.
6. `initLoRa()` creates the SX126x interface and calls `applyModemConfig()`;
   both stacks then share the resulting radio.

Meshtastic's config does not have sync-word or preamble fields. Store those
in the profile and make `RadioLibInterface` read them:
- change `syncWord` from `const` to a member initialized from the profile;
- initialize `preambleLength` from the profile before `SX126xInterface::init()`;
- use the same values in `reconfigure()`.

### 4.2 Runtime profile change

`raumata::applyPhyProfile(id)` rejects a preset from the other family.

1. Validate the profile against the region and hardware limits.
2. Update `config.lora` as in 4.1.
3. Save the config (`nodeDB->saveToDisk(SEGMENT_CONFIG)` or
   `service->reloadConfig(SEGMENT_CONFIG)`).
4. Update the radio's sync word/preamble and call `RadioInterface::reconfigure()`.
5. Persist the profile in NVS.
6. Schedule a re-advertisement for the stacks the active mode allows to announce.

The radio reconfigures once. Both stacks continue on the new configuration;
there is no per-protocol switching.

### 4.3 Meshtastic app changes

If the Meshtastic app changes the radio settings:

- If the mode uses a Meshtastic profile and the app selects a Meshtastic
  preset, map it to that preset. Sync and preamble stay 0x2B and 16.
- Manual BW/SF/CR/frequency is put back to the active Meshtastic preset.
  A MeshCore-profile mode puts the radio back to the active MeshCore preset.
- Use an `applyingProfile` guard to avoid a config-change feedback loop.

The MeshCore companion's self-info (`CMD_APP_START`) should report the
effective frequency/BW/SF/CR read from the radio, so a MeshCore app sees the
same values the hardware is using.

## 5. Selecting presets from companion apps

### MeshCore companion

Add custom commands (IDs outside MeshCore's assigned range, or use
`CMD_RUN_CLI_COMMAND`):

- `CMD_GET_PHY_PROFILES` — list IDs, names, kinds, and PHY fields.
- `CMD_SET_PHY_PROFILE` — select by ID.
- `CMD_GET_PHY_PROFILE` — report the active profile and effective
  frequency/BW/SF/CR/sync/preamble.
- `CMD_SET_RADIO_PARAMS` (existing MeshCore command) — select a MeshCore
  preset when the mode uses the MeshCore family and frequency, bandwidth,
  spreading factor, and coding rate match. Otherwise reject it.
- `CMD_RUN_CLI_COMMAND` text aliases: `mode get|list|set <name>`,
  `phy list`, `phy get`, `phy set <id>`. `phy list` shows only presets the
  active mode allows.

The MeshCore companion app will only expose the commands it knows; a custom
app or the CLI can use the rest. The existing `CMD_APP_START` response already
carries frequency/BW/SF/CR, so standard apps show the effective PHY.

### Meshtastic app / API

- The existing radio configuration screen can select Meshtastic presets and
  manual BW/SF/CR/frequency; that is enough for Meshtastic-native profiles.
- Sync word and preamble are not in Meshtastic's protobuf. Select a MeshCore
  profile from the MeshCore companion or CLI.
- On any profile change, emit a `ClientNotification` (or a custom port
  message) so custom clients can refresh the displayed PHY.

## 6. Airtime and regulatory implications

- The selected profile changes time-on-air. The shared airtime budget from
  `dual-identity-and-companion.md` must use the active profile.
- MeshCore-native presets may be outside the Meshtastic region's channel
  calculation. Use `override_frequency` and keep a region hint for power and
  duty-cycle limits; do not bypass regulatory limits silently.
- AU 915–928 MHz, NZ, and EU 868 MeshCore presets fit existing Meshtastic
  regions (ANZ / EU_868) for power limits. A preset outside the device's
  regulatory region is the user's responsibility.
- Re-advertising after a profile change consumes airtime; rate-limit it.

## 7. Implementation patch breakdown

After the current dual-protocol series:

1. `raumata: add shared PHY profile and preset table`
   - `PhyProfile` data, static table, NVS load/save, lookup.
2. `radio: make sync word and preamble profile-driven`
   - `RadioLibInterface` fields initialized from the profile; `reconfigure()`
     uses them; no behavior change for non-dual builds.
3. `raumata: apply the profile before radio init`
   - `phyInit()` in `main.cpp`; map the selected family's profile into
     `config.lora`; build check.
4. `raumata: expose preset selection through the companion API`
   - custom commands + CLI. `CMD_SET_RADIO_PARAMS` selects a matching MeshCore
     preset when that family is active.
5. `raumata: persist runtime radio changes and re-advertise`
   - config observer, `applyPhyProfile()`, re-advertise both stacks.
6. `docs: document shared PHY profiles`
   - README/main design links and the sync-word trade-off.

Each patch should build for `heltec-v3-dual`.

## 8. Verification plan

- Build `heltec-v3-dual`.
- Apply each preset and read back the effective frequency/BW/SF/CR/sync/
  preamble from the radio.
- Two-node tests:
  - Meshtastic preset: a standard Meshtastic node hears the Meshtastic side;
    a Raumata MeshCore node with the same sync hears the MeshCore side.
  - MeshCore preset: a standard MeshCore node hears the MeshCore side; a
    Raumata Meshtastic node with the same sync hears the Meshtastic side.
  - Shared mode: both Raumata stacks hear each other on the selected family's
    sync word. Stock peers of the other family do not.
- Verify no retuning occurs during normal operation; only explicit profile
  changes reconfigure the radio.
- Measure airtime for each preset and verify the shared budget/region limits.
- Verify Meshtastic app radio settings and MeshCore companion self-info agree
  with each other after a profile change.

## 9. Recommendation

- Make the operating mode and the profile first-class NVS records.
- Keep each family's native sync word. Do not rewrite a MeshCore preset to
  `0x2B` or a Meshtastic preset to `0x12`.
- Default a node with no saved mode to both stacks on a Meshtastic profile,
  unless the saved profile is already MeshCore.
- Document that standard Meshtastic and standard MeshCore cannot both be
  reached by one radio with one sync word.
