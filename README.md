# Universal Remote

A Wi-Fi TV remote for iPhone and Android, built in Flutter. No Mac needed to
ship it — see [Building without a Mac](#building-without-a-mac).

## What works today

| Brand | Protocol | Pairing | Status |
|---|---|---|---|
| **Roku** | **ECP-2**, WebSocket on 8060 | none needed | Working, unit-tested; protocol proven on real hardware |
| **Samsung** (2016+, Tizen) | WebSocket on 8002 | on-screen accept, token stored | Working, untested against hardware |
| **LG** (webOS) | SSAP on 3000 + pointer socket | on-screen accept, client-key stored | Working, untested against hardware |
| Sony Bravia | IRCC-IP, HTTP | PSK or PIN | Not written yet |
| Vizio | HTTPS on 7345 | PIN shown on TV | Not written yet |
| Android TV / Google TV | protobuf on 6466/6467 | 6-digit code, TLS client cert | Not written yet |
| Apple TV | Companion (SRP + ChaCha20) | PIN | Not written yet — see below |

Discovered sets whose brand has no adapter appear in the list marked
"Not yet supported" rather than being hidden, so it is obvious what the app saw.

### Also in the app

- **Wake on LAN** — turn a TV on over Wi-Fi when it supports it (`lib/core/wake_on_lan.dart`)
- **Private listening** — Roku TV audio streamed to the phone's headphones,
  decoded from Opus and kept playing with the screen off
  (`lib/protocols/private_listening.dart`)
- **Voice search** — on-device speech recognition typed into the TV's search box
- **Text entry** — type on the phone keyboard instead of the on-screen one
- **Manual add** — enter a TV's IP address when discovery cannot see it

Wake on LAN and private listening have unit tests; none of these extras has been
checked against a range of real TVs yet.

### Why Roku uses ECP-2 and not plain HTTP

Roku's documented HTTP interface — `POST /keypress/Home` on port 8060 — only
works when the TV's **Control by mobile apps** setting is permissive. In the
default Limited mode the TV answers **403** to `/keypress/...` and
`/query/apps`, while still serving `/query/device-info`.

That failure mode is nasty: an HTTP-only remote passes every mocked test and
then does nothing on real hardware, with discovery still appearing to work.

So commands go over **ECP-2** instead — a WebSocket to
`ws://host:8060/ecp-session` using the `ecp-2` subprotocol, authenticated by a
SHA-1 challenge/response. This is the channel Roku's own app uses, and the TV
honours it in Limited mode. Discovery stays on HTTP, since `device-info`
remains readable.

**TV inputs are not launchable over ECP-2.** The TV answers `launch` with 403
Forbidden for any `tvinput.*` id, while accepting the same id over plain HTTP.
Inputs have to go through `key-press InputHDMI2` instead, even though
`query-apps` lists them alongside real channels with nothing to mark the
difference. Verified on a TCL Roku TV; see `inputKeyFor`.

The authentication is pinned by a test against a challenge/response pair
captured from a real handshake, so a mistake in the port fails loudly in CI
rather than silently on the sofa.

### The infrared problem

**No iPhone has an IR blaster, and no app can add one.** If a TV only accepts
infrared, it cannot be driven from an iPhone at all — the hardware is not there.
Every brand above is controlled over Wi-Fi instead, which is why the TV must be
a networked smart TV. For an IR-only set the only route is a Wi-Fi→IR bridge
(Broadlink RM4 and similar), which is a separate piece of hardware.

### Apple TV is the expensive one

Apple TV's Companion protocol needs SRP-6a authentication, HKDF key derivation,
Ed25519 signatures and ChaCha20-Poly1305 encryption, over Apple's OPACK binary
encoding. There is no shortcut and no Dart library for it. Budget weeks, not
days — it is a larger job than the other five remaining brands combined.

## Architecture

```
lib/
  core/
    remote_key.dart        Brand-neutral key vocabulary — the UI speaks only this
    tv_device.dart         Device model; carries the pairing token
    tv_protocol.dart       The adapter interface every brand implements
    protocol_factory.dart  Brand -> adapter. One line per new brand.
    remote_controller.dart Owns the session; handles reconnect-and-retry
  protocols/
    roku_ecp2_session.dart ECP-2 transport: the channel Roku's own app uses
    roku_protocol.dart     Roku adapter — ECP-2 for commands, HTTP for discovery
    samsung_protocol.dart  Self-signed TLS, one-shot token
    lg_protocol.dart       Two sockets, two wire formats
  discovery/
    ssdp_discovery.dart    Multicast M-SEARCH (works on Android, usually not iOS)
    subnet_scanner.dart    Unicast /24 sweep (the path that works on iOS)
  storage/
    device_store.dart      Persists paired devices and their tokens
  ui/
    device_list_page.dart  Discovery and pairing
    remote_page.dart       The remote itself
```

Adding a brand means writing one `TvProtocol` subclass and adding one case to
`ProtocolFactory`. Nothing in the UI changes.

### Why there are two discovery mechanisms

SSDP is the normal way to find a TV: one multicast M-SEARCH, every set answers.
It works fine on Android.

**It does not work on iOS.** Since iOS 14, sending to a multicast group requires
the `com.apple.developer.networking.multicast` entitlement, which Apple grants
only on special application — and routinely declines for consumer apps. Without
it the datagrams are dropped silently: no error, no results, just an app that
never finds anything.

So `SubnetScanner` probes all 254 addresses on the local /24 directly over
unicast TCP, which needs only the ordinary Local Network permission. Both run in
parallel and the results are merged by host.

## Building without a Mac

Compiling for iOS genuinely requires macOS — that part cannot be worked around.
Everything else can. `codemagic.yaml` runs the compile on Codemagic's Macs;
its free tier covers roughly 500 build-minutes a month, which is ample.

There are two routes, and the free one is worth exhausting first.

### Free route — no Apple membership

Run the **`ios-unsigned`** workflow. It compiles on a Mac and hands back an
unsigned `.ipa`, never touching your Apple account. You then sign and install
it from Windows with **AltStore** or **Sideloadly** using an ordinary Apple ID.

What it costs instead of money:

- the app stops opening after **7 days** and must be refreshed — AltStore can
  do this automatically whenever the phone and PC share a Wi-Fi network
- at most **3** sideloaded apps on the device at once
- no push notifications or other paid-only entitlements

**None of those restrictions affect this app.** All it needs is Local Network
access, which free provisioning grants.

### Paid route — $99/yr

Worth it once the app is something you rely on, or you want it on someone
else's phone. Run **`ios-debug`** for an ad-hoc build that installs over the
air and lasts a year rather than a week, or **`ios-testflight`** to distribute
to other people.

Be clear that the **$99 is annual, not a one-off**. If the membership lapses,
signed builds stop working and App Store listings are removed; already-installed
ad-hoc builds keep running only until their profile expires. Ad-hoc also needs
your iPhone's UDID registered, and is capped at 100 devices per year.

### Everything else runs on Windows

Development, analysis and tests need no Mac at all:

```bash
flutter analyze
flutter test
flutter run   # on an Android device or emulator
```

## Testing status — read this before trusting it

The Roku adapter's ECP-2 layer is ported from a native Android implementation
that was built and tested against a real TCL/Hisense Roku TV, and its
authentication is pinned to a captured handshake vector. The channel-list
parser, 2xx status handling, channel-id validation and HTTP device-info
parsing are all unit-tested.

What is **not** covered by tests is the live socket itself — opening the
WebSocket, the two-message handshake ordering and reconnect behaviour need a
real TV on the network.

**The Samsung and LG adapters have never been run against a real TV.** They are
written from the published protocol behaviour and follow the same shape as the
mature open-source implementations, but pairing handshakes are exactly the kind
of thing that differs by firmware year. Expect to iterate on first contact with
real hardware, particularly:

- Samsung sets older than 2016 use a completely different (unencrypted, port
  55000) protocol that this adapter does not speak.
- LG's pointer-socket path is the most likely thing to need adjustment.

## Shipping to the App Store

The listing text, review notes and privacy answers are in
[`store/app-store-listing.md`](store/app-store-listing.md), with the exact steps
that need an Apple account. The iOS target already carries a privacy manifest
(`ios/Runner/PrivacyInfo.xcprivacy`) and the export-compliance flag.

## Permissions

- **iOS** — `NSLocalNetworkUsageDescription` and `NSBonjourServices` are set in
  `ios/Runner/Info.plist`. The system prompt appears on first scan; if the user
  declines it, discovery returns nothing and there is no way to re-prompt except
  through Settings.
- **Android** — `INTERNET`, `ACCESS_WIFI_STATE` and
  `CHANGE_WIFI_MULTICAST_STATE`, plus a network security config permitting
  cleartext, since Roku's ECP is plain HTTP.
