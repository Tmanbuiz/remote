# Room Remote

A local Wi-Fi TV remote for Android and iPhone, built with Flutter. No account or subscription is required. Your phone and TV must be on the same home network.

**Work status:** [JOB_LOG.md](JOB_LOG.md). **Phone/TV checks:** [DEVICE_TEST_CHECKLIST.md](DEVICE_TEST_CHECKLIST.md).

## Features

- Room names, saved TVs, automatic discovery and manual IP entry.
- Button remote and swipe navigation, with supported buttons shown for each adapter.
- Voice-to-text search with language selection and editable words before sending. Microphone access starts only when you tap **Start voice input**. Keyboard entry remains available.
- Live app/input lists, favourites and friendly labels where supported. Optional on-device launch counts suggest favourites; switching the option off deletes those counts.
- Activities: up to 20 explicit wake, wait, button and app steps across saved TVs. Edit, reorder, run and stop activities; each step reports its delivery result.
- Quiet moment on LG: read mute/volume, mute, and explicitly restore only when the observed state has not changed.
- Wake-on-LAN with a saved TV MAC address. Actual wake depends on the TV's network-standby settings.
- Foreground sleep timer using a power-off command. Leaving the app cancels it; use the TV's own timer for unattended sleep.
- Simple mode, left-handed volume/channel layout, optional vibration and spoken button names, and practice controls that never contact a TV.
- Connection diagnostics and a reviewable compatibility report you can copy. No automatic uploads.
- Protected pairing credentials, private-address validation and first-pairing trust for self-signed TV certificates.

## Adapter support

| Feature | Roku | Samsung Tizen (2016+) | LG webOS |
|---|---|---|---|
| Buttons | ECP-2 | WebSocket | SSAP and pointer socket |
| Pairing | Connect to TV | Accept TV prompt | Accept TV prompt |
| Keyboard/voice text | Yes | Focused text field | Focused text field |
| Open search automatically | Search button | Open the field yourself | Open the field yourself |
| Live apps/inputs | Channels and inputs | Use Home navigation | Installed apps |
| Verified quiet/restore | Unavailable | Unavailable | Audio-state readback |
| Wake packet | Requires MAC and TV support | Requires MAC and TV support | Requires MAC and TV support |

An implemented adapter is not a guarantee for every model or firmware. The original Roku transport has a captured real-hardware authentication regression test. Current end-to-end device testing is still required, particularly Samsung and LG. Sony, Vizio, Android/Google TV and Apple TV control adapters are **not implemented**. This app cannot add infrared hardware to a phone.

Discovery combines SSDP with a private IPv4 /24 unicast sweep. The sweep identifies Roku and Samsung endpoints. LG discovery relies on SSDP; use manual setup if multicast is unavailable, including on iOS without the multicast entitlement. Guest networks, VPNs and client isolation can block discovery/control.

## Install a development build

1. Open **Actions → Verify Room Remote** on GitHub and choose a successful run for the latest commit.
2. Download **room-remote-debug-apk**, extract the ZIP and install `app-debug.apk` on Android. This is a development build, not a store release.
3. Put the phone and TV on the same Wi-Fi. Open Room Remote, scan or enter the TV's private IP, and accept any TV pairing prompt.
4. Follow [the device checklist](DEVICE_TEST_CHECKLIST.md), starting with one harmless button.

The iOS CI job compiles for a simulator, without Apple account credentials. Installing on a real iPhone requires signing through Xcode or your configured Codemagic workflow. Store distribution also requires the owner's signing credentials and account setup.

## Develop and verify

The GitHub workflow pins Flutter **3.47.5**, the SDK used by the existing build runs.

```sh
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --debug
# On a Mac:
flutter build ios --simulator --debug --no-codesign
```

Android release builds require `android/key.properties` and your keystore. Never commit them. Release signing does not fall back to the debug key. Codemagic includes development APK and iOS workflows; signed distribution requires your own account configuration.

## Reliability and privacy

Commands are serialized. A command captured for one TV is discarded if another TV becomes active before dispatch. Queued taps are invalidated when the app backgrounds or an activity begins. Failed or uncertain commands are not automatically replayed: a power toggle or partially typed text may already have reached the TV.

Delivery labels distinguish **sent**, **acknowledged**, **verified**, **uncertain** and **failed**. Even a TV acknowledgement does not prove the on-screen result. Only state that the adapter reads back is labelled verified.

Pairing tokens migrate from old preferences to platform secure storage before the plaintext copy is removed. Failed migration leaves the old credential available for a retry. Android backup is disabled. Self-signed certificates are trusted on explicit initial pairing, then their recorded fingerprints are checked on subsequent self-signed connections. Re-pairing resets that trust.

Voice recognition and spoken labels use the phone's services, which may process audio online. Room Remote does not save recordings, transcripts or search text. Optional app-launch counts stay on the phone. Compatibility reports omit network addresses, device IDs and credentials by default; review any text you add before sharing.

## Project layout

- `lib/core/`: controller, capabilities, device model and protocol interface.
- `lib/protocols/`: Roku ECP-2, Samsung and LG implementations.
- `lib/discovery/`: SSDP and local subnet discovery.
- `lib/storage/`: credentials, rooms, favourites and activities.
- `lib/ui/`: device picker, remote, voice input, activities and tools.
- `test/`: protocol and controller regression coverage.
- `.github/workflows/verify.yml`: analysis, tests and platform builds.
