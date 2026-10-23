# Dual identity, presence, and simultaneous companion access

Status: implemented in `0004-raumata-add-usb-companion-serial-mux.patch` and `0007-raumata-add-dual-identity-link-and-presence-schedule.patch`.

The current six-patch series already runs Meshtastic and MeshCore on one
SX1262 with a shared PHY, gives the MeshCore side its own ed25519 identity,
adverts, channels and text messaging, and multiplexes Meshtastic and MeshCore
framing on USB serial. It does **not** yet link the two identities explicitly,
schedule their presence, or support two companion apps at the same time. This
document specifies how to add those pieces.

> The PHY is a first-class, selectable profile rather than “MeshCore mirrors
> Meshtastic.” See
> [shared-phy-profiles.md](./shared-phy-profiles.md). The current series still
> mirrors Meshtastic's PHY; the next PHY series replaces that with a profile
> that can be a Meshtastic preset, a MeshCore preset, a dual preset, or custom
> values.

## 1. Goals

- One physical node appears as a normal Meshtastic node **and** a normal
  MeshCore node.
- The node can be a companion for a Meshtastic app and a MeshCore app at the
  same time.
- Standard Meshtastic and MeshCore apps keep working without custom builds.
- The shared radio remains within one airtime budget.

## 2. Non-goals for the first identity/companion series

- Transparent bridging of every packet between the two meshes.
- MeshCore BLE companion in the first step.
- Proving to a remote node that the two identities are the same device.
- Changing Meshtastic's or MeshCore's on-air formats beyond the existing
  `RAUM` transport tag.

Cross-protocol node visibility (MeshCore contacts appearing in the Meshtastic
app, and vice versa) is a separate optional bridge described in section 6.

## 3. Current identity state

### Meshtastic

- `myNodeNum`: 32-bit node number, persisted in the Meshtastic device state.
- `owner`: `meshtastic_User` with `long_name`, `short_name`, `hw_model`,
  `role`, and `public_key`.
- `config.security.private_key` / `public_key`: Curve25519 keypair used for
  Meshtastic PKI and direct messages.
- Presence is sent by `NodeInfoModule` (NodeInfo/User), `PositionModule`
  (position), and the telemetry modules.

### MeshCore

- ed25519 keypair stored in NVS as `raumata/mc_id` (64-byte private key, or
  64-byte private + 32-byte public key).
- Node name in `raumata/mc_name` (falls back to Meshtastic `owner`).
- Up to eight channels in `raumata/mc_ch`.
- `MeshCoreNode` sends an `ADV_TYPE_CHAT` advert on boot and every 15 minutes.
- MeshCore contacts learn the node from that advert.

## 4. Identity model

### 4.1 Mode A: independent keys plus a link record (recommended for v1)

Keep the existing Meshtastic Curve25519 key and the MeshCore ed25519 key
separate. Give both the same human-readable name and persist an explicit
mapping:

```c
struct RaumataLinkRecord {
    uint8_t version;        // 1
    uint8_t mode;           // INDEPENDENT, DERIVED, CROSS_SIGNED
    uint32_t msh_node_num;
    uint8_t  mc_pubkey[32];
    uint8_t  msh_pubkey_fp[8]; // SHA-256(Meshtastic public key), truncated
    uint32_t updated;
};
```

NVS key: `raumata/link`.

Advantages:

- No crypto coupling; a Meshtastic key reset does not silently change the
  MeshCore identity.
- Works with unmodified Meshtastic and MeshCore apps.
- The mapping is available to custom clients and to a future bridge.

Disadvantage:

- The two identities are not cryptographically bound. A malicious node could
  advertise the same display name; the link record is local/trusted.

### 4.2 Mode B: deterministic derivation (optional)

Derive the MeshCore ed25519 seed from the Meshtastic private key:

```
seed = HKDF-SHA256(
    ikm  = Meshtastic private key (32 bytes),
    salt = "raumata",
    info = "meshcore-identity-v1",
    len  = 32)
```

Then create the MeshCore keypair from that seed. Store only a fingerprint of
the source key, e.g. `mc_derived_fp = SHA256(Meshtastic public key)[0..7]`.
On boot:

- If the fingerprint matches, reuse the derived MeshCore identity.
- If it does not match, derive a new one, save the new fingerprint, and
  re-advertise.

Advantages:

- One secret; the two identities are cryptographically derived from the same
  root.
- No extra long-term MeshCore secret to back up.

Disadvantages:

- Meshtastic key regeneration/factory reset changes the MeshCore identity.
- Compromise of the Meshtastic private key compromises both identities.
- Requires a reviewed HKDF implementation and a `LocalIdentity::fromSeed()`
  helper in the vendored MeshCore core.

Make this a build option (`RAUMATA_IDENTITY_DERIVED`), not the default.

### 4.3 Mode C: cross-signed link (optional, later)

Keep independent keys and publish a proof:

- MeshCore advert carries a compact link tag (for example a 4-byte
  `msh_node_num` hash in the advert feature slots).
- A companion command or MeshCore `RAW_CUSTOM` packet carries a signature,
  made with the MeshCore key, over `msh_node_num || msh_pubkey_fp`.
- Meshtastic publishes the reciprocal signature via a `ClientNotification`
  or a custom `PortNum` message.

Custom apps can verify the link; standard apps ignore the extra data. This
adds code and airtime, so it should only be implemented if a verifiable link
is a requirement.

### 4.4 Name and lifecycle

- Default MeshCore name = Meshtastic `owner.long_name` (falling back to
  `short_name`, then `"Raumata"`).
- `raumata/mc_name` is an explicit override. The MeshCore companion
  `CMD_SET_ADVERT_NAME` writes this override; it does not rewrite the
  Meshtastic owner.
- Observe Meshtastic owner changes (the `NodeDB` status observer) and, when
  no MeshCore override exists, update the MeshCore name and schedule an
  advert.
- On Meshtastic factory reset/key regeneration:
  - Mode A: keep `mc_id`; update `msh_node_num` and `msh_pubkey_fp` in the
    link record.
  - Mode B: invalidate the derived identity and derive a new one.
- On MeshCore identity reset: generate `mc_id`, update the link record, and
  send an advert.

### 4.5 Publishing the link to apps

The device itself already appears in both node lists. The link record makes it
possible for a custom app to correlate the two entries:

- MeshCore companion: implement `CMD_GET_CUSTOM_VARS` /
  `CMD_SET_CUSTOM_VAR` (the upstream companion protocol already defines
  them) with read-only keys:
  - `msh.node` — decimal or hex Meshtastic node number.
  - `msh.pubkey` — Meshtastic public-key fingerprint.
  - `mc.pubkey` — MeshCore public key hex.
- Meshtastic: send a `ClientNotification` with a `raumata.link` string, or a
  custom `PortNum` message with a compact binary record. Standard Meshtastic
  apps ignore unknown notifications.
- Optional advert hint: use one of MeshCore's two feature slots
  (`ADV_FEAT1`/`ADV_FEAT2`, 2 bytes each) for a NodeNum hash. This is advisory
  only and must not be used for trust decisions.

## 5. Presence in both meshes

### 5.1 Meshtastic presence

No new protocol is needed:

- Keep `NodeInfoModule` enabled. It sends our `User` on boot and at the
  configured interval (default 3 hours).
- Keep position/telemetry broadcasts as configured.
- The node is a normal Meshtastic node; the app sees it in the node list.

### 5.2 MeshCore presence

- `MeshCoreNode` sends `ADV_TYPE_CHAT` adverts on boot and every 15 minutes.
- Include latitude/longitude when Meshtastic has a local position. Add a
  small accessor from the Meshtastic NodeDB/position state to the MeshCore
  node.
- Use the shared display name from section 4.4.
- If the device is configured as a repeater/room server rather than a
  companion, use the corresponding MeshCore advert type. This is a separate
  role/config decision.

### 5.3 Scheduling and shared airtime

Two independent protocol stacks on one radio must not burst at the same time.

Add a `PresenceScheduler`:

- Boot: MeshCore advert at T+15 s, Meshtastic NodeInfo at T+20 s.
- Periodic: MeshCore advert every 15 minutes; Meshtastic NodeInfo at its
  configured interval. Offset the two by 30 s plus a deterministic jitter
  derived from the node identity to avoid synchronized bursts.
- Position/telemetry: keep Meshtastic's existing schedules; MeshCore adverts
  carry location only (no separate telemetry stream initially).

Add a shared airtime budget:

- Track transmitted milliseconds per rolling hour across both stacks.
- Reserve a configurable share for each protocol. A simple default is 75%
  Meshtastic / 25% MeshCore.
- Classify traffic: control/ACK > text > position > telemetry > adverts.
  Defer or drop adverts/telemetry first when the budget is exhausted.
- MeshCore's `Dispatcher` already has a tx budget; set its
  `getAirtimeBudgetFactor()` so its share matches the reservation, and make
  the radio arbiter account for the actual airtime of both stacks.
- Region-aware: EU 868 has a 1% duty-cycle limit; AU 915–928 MHz does not
  have the same limit but still needs fair airtime. The budget must use the
  same region configuration Meshtastic uses.
- Profile-aware: the selected PHY profile determines time-on-air. Recompute
  the budget when the profile changes, and re-advertise both stacks after the
  change.

### 5.4 What “appear in both” means

- **Device appears in both node lists (in scope):** the Meshtastic app sees
  the device's Meshtastic NodeInfo; the MeshCore app sees the device's
  MeshCore advert. Same name, optional link record.
- **MeshCore nodes appear in the Meshtastic app, and vice versa (optional
  bridge):** this requires identity shadowing and message translation; see
  section 6. It is not a side effect of running both stacks.

## 6. Optional bridge mode: cross-protocol node visibility

### 6.1 MeshCore to Meshtastic

- Allocate a synthetic Meshtastic NodeNum for each MeshCore contact:
  `0x80000000 | (first 31 bits of SHA256("raumata-msh-shadow" || mc_pubkey))`.
- Store the mapping in a bounded table.
- Inject a synthetic `NodeInfo`/`User` into the Meshtastic NodeDB and
  PhoneAPI so the app shows the contact. Prefer local injection only; do not
  flood synthetic NodeInfo over the Meshtastic air unless a dedicated channel
  and airtime budget are configured.
- For text, create a Meshtastic text packet with `from` = synthetic NodeNum
  on a dedicated channel, or expose a custom `PortNum` and let a custom app
  render it. Standard Meshtastic apps may treat injected packets as normal
  channel traffic; this needs careful testing and loop prevention.

### 6.2 Meshtastic to MeshCore

MeshCore direct messages require an ed25519 keypair and a shared secret. A
bridge cannot sign as an arbitrary Meshtastic node. Two options:

1. **Single bridge contact:** all Meshtastic traffic appears from the bridge's
   MeshCore identity, with a `[MSH:<node>]` prefix in the text. Simple and
   honest, but Meshtastic nodes are not separate MeshCore contacts.
2. **Shadow MeshCore identities:** derive a deterministic ed25519 seed per
   Meshtastic NodeNum from a bridge secret:
   `seed = SHA256("raumata-mc-shadow" || bridge_secret || node_num)`.
   Advertise each shadow identity as `ADV_TYPE_CHAT` and sign messages with it.
   MeshCore apps then see one contact per Meshtastic node. The shadow identity
   is controlled by the bridge; it is not cryptographic proof of the original
   Meshtastic node.

### 6.3 Loop prevention and security

- Tag bridged messages with a compact bridge ID and maintain a recent
  message-hash cache.
- Never bridge a packet that already carries a bridge tag.
- Do not bridge ACKs, routing control, PKI/direct messages, or telemetry in
  the first version; text only.
- Treat the bridge as a trusted translator. Document that shadow identities
  are bridge-asserted.
- Rate-limit bridged traffic and include it in the shared airtime budget;
  bridging doubles transmissions.

## 7. Simultaneous companion access

### 7.1 Transport matrix

| Stack | Transport | Status |
| --- | --- | --- |
| Meshtastic | BLE (NimBLE service) | Existing |
| Meshtastic | USB CDC PhoneAPI | Existing |
| Meshtastic | TCP 4403 (`ServerAPI`) | Existing |
| MeshCore | USB CDC companion | Implemented in the current series |
| MeshCore | BLE Nordic UART service | Upstream MeshCore; not integrated here |
| MeshCore | TCP 5000 (`SerialWifiInterface`) | Upstream MeshCore; not integrated here |

### 7.2 Why one USB port cannot serve two apps

USB CDC is one character device. Two mobile/desktop apps cannot both open the
same CDC port at the same time. A host-side proxy could open the port once and
expose two virtual serial ports, but that is a desktop-only workaround and not
a firmware feature. For two apps, use two transports.

### 7.3 Recommended v1: Meshtastic BLE + MeshCore USB

- Meshtastic app connects over BLE using the existing NimBLE service.
- MeshCore app connects over USB using the MeshCore companion framing.
- The two paths have independent state:
  - Meshtastic `PhoneAPI`/`BluetoothPhoneAPI` queues and BLE callbacks.
  - `MeshCoreNode` queue and `CompanionSerial` USB reader/writer.
- In this mode, do not run the Meshtastic USB PhoneAPI concurrently with the
  MeshCore USB companion. Keep Meshtastic USB for debug or make it a build
  option; USB is owned by `CompanionSerial`.
- This is the smallest change that satisfies “both apps at once” and is the
  recommended first implementation.

Build flags:

- `RAUMATA_COMPANION_MODE_BLE_USB` (default for the dual build)
- `RAUMATA_MESHCORE_USB` (USB companion enabled)

### 7.4 v2: dual-service BLE

To run both apps over BLE:

- Extend the existing NimBLE server with MeshCore's service:
  - Service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
  - RX (app → firmware) `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
  - TX (firmware → app) `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`
- Implement `MeshCoreBleSerial : BaseSerialInterface` with RX/TX queues and
  `NimBLECharacteristic` notification handles.
- Track connection handles. Notify the MeshCore subscriber on its
  characteristic; keep the Meshtastic service on its existing characteristics.
- Allow at least two BLE connections (`NIMBLE_MAX_CONNECTIONS >= 2`). Keep
  Meshtastic at one active client because `bluetoothPhoneAPI` is a
  single-client state machine; MeshCore can also be limited to one companion
  client.
- Security: decide whether the MeshCore service uses a PIN/bond separate from
  the Meshtastic BLE security. Sharing one bond is simpler but couples the two
  apps; separate bonds are cleaner but need per-service security handling.
- Advertising: include both service UUIDs in the advertisement so each app can
  filter by its service.
- This is the best mobile UX but requires the most NimBLE work and testing.

### 7.5 v3: dual TCP servers

- Meshtastic `ServerAPI` already listens on TCP 4403.
- Add a MeshCore TCP companion server on port 5000 using
  `SerialWifiInterface` (upstream MeshCore) and a `MultiSerialInterface`.
- Independent sockets allow multiple clients; no BLE/USB contention.
- Useful for desktop/hosted nodes; mobile app support for TCP varies and WiFi
  increases power consumption.

### 7.6 Shared-transport mux (only if one transport is unavoidable)

The current USB mux parses both framings and routes complete frames. It can
support both protocols on one byte stream, but only one host application can
own the port. If this mode is retained:

- Maintain independent Meshtastic and MeshCore TX queues.
- Write complete frames atomically with a mutex; never interleave bytes.
- Do not suppress one protocol when the other is active.
- Keep the Meshtastic `PhoneAPI` and MeshCore companion each single-client.

### 7.7 State and queues

| Component | State owner | Concurrency |
| --- | --- | --- |
| Meshtastic PhoneAPI | `BluetoothPhoneAPI` / `SerialConsole` / `ServerAPI` | Existing per-transport queues and mutexes |
| MeshCore companion | `MeshCoreNode` + `CompanionSerial` | Main loop; add mutex if BLE callbacks are added |
| Radio | `RadioLibInterface` | `rawRadioMutex` and owner flags |
| Identity/link | `NodeDB` + NVS | Read at boot; update on owner/key changes |
| Message queues | Per stack | No shared protocol queue |

## 8. Patch breakdown

Recommended next series (after the current six patches):

1. `raumata: add identity link record and name synchronization`
   - NVS link record, owner observer, MeshCore name fallback/override.
2. `raumata: publish the link through companion APIs`
   - MeshCore custom vars, Meshtastic ClientNotification/custom port.
3. `raumata: schedule presence adverts`
   - Staggered boot/periodic adverts, MeshCore location from Meshtastic.
4. `raumata: share the airtime budget`
   - Token bucket, traffic classes, MeshCore budget factor.
5. `transport: dedicate USB to MeshCore in BLE+USB mode`
   - Build flag, SerialConsole behavior, docs.
6. `transport: add MeshCore BLE NUS` (optional v2)
   - Dual-service NimBLE, per-connection router, security.
7. `transport: add MeshCore TCP companion` (optional v3)
   - TCP server on 5000, `MultiSerialInterface`.

Optional bridge series (separate scope):

8. `bridge: synthesize Meshtastic nodes for MeshCore contacts`
9. `bridge: translate text and prevent loops`
10. `bridge: synthesize MeshCore shadow identities for Meshtastic nodes`

Each patch should build and be testable independently.

## 9. Verification plan

- Build `heltec-v3-dual` with and without each optional transport.
- Host-side tests for the link record, name sync, and companion frame
  encode/decode.
- Two-node radio test: one dual node, one Meshtastic node, one MeshCore node
  configured to the shared PHY.
  - Confirm the dual node appears in both apps.
  - Confirm text in both directions.
  - Confirm no Meshtastic frame is parsed by MeshCore and vice versa.
- Simultaneous companion test:
  - Meshtastic app over BLE + MeshCore app over USB, both connected.
  - Send/receive on both concurrently; measure loss and latency.
- Dual BLE test (v2): two centrals, one per service; check notifications,
  disconnects, and bonding.
- Airtime test: measure per-hour TX time for both stacks; verify the shared
  budget and region limits.
- Regression: standard Meshtastic nodes and standard MeshCore peers still see
  the node; no unexpected synthetic nodes unless bridge mode is enabled.

## 10. Recommendation

- **Identity:** Mode A (independent keys + shared name + link record) for the
  first series. Keep Mode B (deterministic derivation) behind a build flag.
- **Presence:** Meshtastic NodeInfo + MeshCore adverts, with staggered
  scheduling and a shared airtime budget.
- **Simultaneous apps:** Meshtastic BLE + MeshCore USB first. Add dual-service
  BLE only if both apps must be wireless; add TCP servers for desktop/hosted
  use.
- **Cross-protocol node lists:** treat as an optional bridge, not part of the
  basic “node appears in both” requirement.
