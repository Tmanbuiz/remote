# Google TV, Android TV and VIDAA

These adapters run inside Universal Remote. They connect directly to your TV on
the home network; Home Assistant, an external MQTT broker and developer/ADB mode
are not needed. VIDAA uses the MQTT broker built into the TV.

## Connect your TV

1. Turn the TV on and connect the phone to the same home network. Allow Local
   Network access on iPhone. Avoid guest networks that isolate devices.
2. Tap **Scan again**. If the TV is absent, choose **Add TV by address**, enter
   the current IPv4 address and select **Google TV / Android TV** or **VIDAA OS**.
   Enter the address alone, without `http://` or a port.
3. You may enter the **Firmware / build** value from the TV About screen. This
   helps identify compatibility but does not override the TV's control protocol.
4. Pair with the code shown on the TV. Google/Android TV uses six hexadecimal
   characters, including A–F; VIDAA uses four digits. Cancel stops pairing.
5. Try navigation and volume. In the saved-TV menu, **TV details** shows reported
   model, firmware, Remote Service version and control-protocol version. Fields
   the TV does not supply remain marked **Not reported**.
6. Use **Pair again** if a factory reset, expired authorization or certificate
   change requires a fresh pairing. Forgetting a TV removes its saved platform
   authorization from encrypted storage.

## Google TV and Android TV

Most Google TV and Android TV televisions and streaming devices expose Android
TV Remote Service v2. The app discovers `_androidtvremote2._tcp` and
`_androidtvremote._tcp`, with unicast probes/manual addresses as a fallback.
Pairing uses TLS on 6467; control uses TLS on 6466. A six-character code binds
the client and server certificates. Reconnection requires the same TV certificate.
Client private keys are generated on the phone and kept in platform secure storage.

Navigation, digits, media keys, power, volume and text entry are implemented.
Volume/power controls are disabled when the service does not advertise those
features. Text requires an active TV text field and the negotiated IME feature.
Manufacturers and streaming boxes can handle some keys differently, particularly
TV volume/power through CEC. Devices without Android TV Remote Service are not
covered by this adapter; Android-based firmware alone does not imply compatibility.
If pairing fails, update/enable Android TV Remote Service in the TV's apps settings.

## VIDAA firmware families

The app probes the TV's TLS/MQTT service on 36669 and reads its UPnP descriptor
on 38400 when available. Manufacturer names alone are not enough: a Hisense TV
can run Roku, Android/Google TV or VIDAA.

| Reported transport version | Credential profile |
| --- | --- |
| Below 3000 | Legacy |
| 3000–3289 | Middle |
| 3290 or later | Modern |
| Not supplied | Try modern, middle, then legacy broker credential formats |

Every new app identity must complete the TV's PIN authorization. MQTT connection
alone is not treated as pairing. Modern firmware requires access-token issuance;
older firmware without tokens must send a fresh state response after PIN approval.
Stored access/refresh tokens have expiry dates and are kept outside ordinary
preferences. Commands use non-retained QoS 0 publications and are not queued for
later replay. Retained authorization/state messages are ignored.

The bundled mobile-client certificate is the public interoperability fixture
distributed by the upstream MIT-licensed vidaa-control project. It is not a user
credential and does not replace PIN authorization. Firmware can reject this
client identity or change its protocol. This implementation is not an official
VIDAA SDK or a manufacturer-approved integration. If the TV rejects pairing,
use **Support → Mobile App** to check the official app supported by that firmware.
TV text/voice entry and private listening are not provided by this VIDAA adapter.

## Validation and practical limits

Protocol vectors are checked against independent Python/cryptography results.
Tests exercise fragmented/coalesced Android frames, certificate/PIN binding,
handshake order, capabilities, live-session ownership, cancellation, VIDAA
authorization, retained-message rejection, token persistence and reconnect.
CI analyzes the Flutter code, runs tests and builds an Android ARM64 preview.

Physical Google/Android/VIDAA TVs were not available in the development workspace.
The adapters need testing on each target TV and firmware; passing fixture tests
does not prove a particular model works. The software/build string in a photo
cannot establish protocol compatibility by itself. This feature does not flash,
replace or update TV firmware. Smart Volume sound detection is a separate feature
and is not implemented by these adapters.

Preview APKs use the repository's existing debug-signing fallback. Production
updates must use the owner's existing upload/signing key. CI artifacts expire
after one day to limit storage usage.

## Sources

- [Android TV Remote v2 reference](https://github.com/tronikos/androidtvremote2)
- [Android pairing protocol](https://android.googlesource.com/platform/external/google-tv-pairing-protocol/)
- [VIDAA protocol reference](https://github.com/tombabolewski/vidaa-control)
- [Official VIDAA connection guide](https://www.vidaa.com/customer_support/how-can-i-connect-the-vidaa-app-to-my-tv/)
