# Universal Remote

A Wi-Fi TV remote for iPhone and Android, built in Flutter. No Mac needed to
ship it — see [Building without a Mac](#building-without-a-mac).

## What works today

| Brand | Protocol | Pairing | Status |
|---|---|---|---|
| **Roku** | ECP, HTTP on 8060 | none needed | Working, unit-tested |
| **Samsung** (2016+, Tizen) | WebSocket on 8002 | on-screen accept, token stored | Working, untested against hardware |
| **LG** (webOS) | SSAP on 3000 + pointer socket | on-screen accept, client-key stored | Working, untested against hardware |
| Sony Bravia | IRCC-IP, HTTP | PSK or PIN | Not written yet |
| Vizio | HTTPS on 7345 | PIN shown on TV | Not written yet |
| Android TV / Google TV | protobuf on 6466/6467 | 6-digit code, TLS client cert | Not written yet |
| Apple TV | Companion (SRP + ChaCha20) | PIN | Not written yet — see below |

Discovered sets whose brand has no adapter appear in the list marked
"Not yet supported" rather than being hidden, so it is obvious what the app saw.

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
    roku_protocol.dart     Reference implementation — simplest of the three
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

You need three things, and only one of them costs money:

1. **A cloud macOS builder.** `codemagic.yaml` in this repo is ready to go —
   push the repo to Codemagic and the `ios-debug` workflow produces a signed
   `.ipa`. Free tier covers roughly 500 build-minutes a month, which is ample.
   GitHub Actions `macos-latest` runners work too if you prefer.
2. **An Apple Developer account — $99/yr.** This is unavoidable for installing
   on a real iPhone for more than 7 days. A free Apple ID can sideload, but the
   app stops working after a week and must be re-installed.
3. **Your iPhone's UDID** registered in the developer portal, for ad-hoc builds.

Nothing else about this project requires macOS. Development, analysis and tests
all run on Windows:

```bash
flutter analyze
flutter test
flutter run   # on an Android device or emulator
```

## Testing status — read this before trusting it

The Roku adapter is unit-tested against a mocked ECP server: key names, the
`Lit_` text encoding, error handling and device-info parsing are all verified.

**The Samsung and LG adapters have never been run against a real TV.** They are
written from the published protocol behaviour and follow the same shape as the
mature open-source implementations, but pairing handshakes are exactly the kind
of thing that differs by firmware year. Expect to iterate on first contact with
real hardware, particularly:

- Samsung sets older than 2016 use a completely different (unencrypted, port
  55000) protocol that this adapter does not speak.
- LG's pointer-socket path is the most likely thing to need adjustment.

## Permissions

- **iOS** — `NSLocalNetworkUsageDescription` and `NSBonjourServices` are set in
  `ios/Runner/Info.plist`. The system prompt appears on first scan; if the user
  declines it, discovery returns nothing and there is no way to re-prompt except
  through Settings.
- **Android** — `INTERNET`, `ACCESS_WIFI_STATE` and
  `CHANGE_WIFI_MULTICAST_STATE`, plus a network security config permitting
  cleartext, since Roku's ECP is plain HTTP.
