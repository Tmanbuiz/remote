# App Store submission draft — Universal Remote

Status: prepared locally; nothing has been entered or submitted in App Store Connect.
The uploaded build and live listing have not been inspected.

## App identity

| Field | Value |
| --- | --- |
| App Store Connect app ID | 6822749631 (from the supplied URL; verify the bundle ID matches) |
| Bundle ID | com.wiantribe.universalRemote |
| Source version | 1.1.0 (build 2 minimum; CI increments past the latest TestFlight build) |
| Suggested name | Universal Remote by WianTribe |
| Suggested subtitle | Wi-Fi remote for your TV |
| Suggested primary category | Utilities |
| Language | English |

Keep the existing app name if it has already been chosen in App Store Connect.

## Promotional text

Control your Roku TV over Wi-Fi, type with your phone's keyboard, and use voice search. No account or ads. Your phone and TV must share a network.

## Description

Turn your iPhone or iPad into a remote for your Roku TV or streaming player on your home Wi-Fi.

EVERYDAY TV CONTROLS
Navigate with a familiar directional pad and use home, back, playback, volume, and power controls where supported by your TV.

LESS TYPING ON YOUR TV
Enter text using your phone's keyboard. Use voice search to dictate text, check the result, and tap Send to TV.

CHANNELS AND INPUTS
See the channels installed on your Roku and open them from your phone. Switch supported TV inputs without searching for the physical remote.

PRIVATE LISTENING
Listen through headphones connected to your phone on compatible Roku devices. Availability depends on the TV, content, and network.

FIND AND SAVE YOUR TVS
Scan your network or add a TV by IP address. Save and rename your TVs to switch between rooms.

NO ACCOUNT OR ADS
Start using the remote without signing up. Saved TV details and pairing settings stay on your device. Optional voice search uses your device's speech-recognition service.

REQUIREMENTS
Your phone and TV must be on the same network and able to reach each other. Allow Local Network access when prompted. Power-on requires a compatible network standby or wake-on-LAN setup. Features vary by model.

Roku is the primary tested platform. Samsung Tizen and LG webOS adapters are included but have not yet been validated on physical TVs; compatibility is not guaranteed. Infrared-only TVs, Apple TV, Android TV, Google TV, Sony, and Vizio are not supported by this release.

Universal Remote is made by WianTribe and is not affiliated with, endorsed by, or sponsored by Roku, Samsung, or LG.

## Keywords

tv,remote,wifi,roku,controller,keyboard,smart,television,home,channels

## URLs and contact

- Marketing URL candidate: https://wiantribe.com
- Privacy policy URL candidate: https://wiantribe.com/privacy
- Support email from the existing store materials: atoyejet@gmail.com
- Support URL: still needed; supply a public page with app support and contact details.
- Review contact name and phone: still needed from the account owner.
- Copyright holder: confirm the legal rights holder before entering.

Both candidate URLs returned HTTP 403 from this execution environment. This does
not establish their accessibility in a normal browser. Verify the privacy URL
actually serves this app's policy; the repository contains policy source files
but does not establish that they have been published there.

## App Review notes draft

No app account or sign-in is required. Main functionality requires a compatible
TV on the same local network as the review device. A Roku TV or streaming player
is recommended for review.

1. Connect the iPhone or iPad and Roku to the same Wi-Fi network.
2. Open Universal Remote and allow Local Network access.
3. Tap Scan and choose the Roku. If discovery is blocked by the router, add the
   Roku's IP address manually.
4. Use the directional pad, Home, and Back to navigate. Open Channels to launch
   an installed channel. Volume and input controls depend on the connected TV.
5. Open a text field on the TV, then use the keyboard or voice-search sheet.
   Voice search requests microphone and speech-recognition permission and sends
   the recognized text only after tapping Send to TV.
6. Test private listening only with compatible Roku hardware and content.

Background audio is used for private listening with the phone screen locked.
Provide an actual demonstration recording if requested; none is included here.

## Items to complete before submission

- Inspect the existing app record and choose the intended processed build.
  Verify its version, bundle ID, and behavior against these draft claims.
- Upload genuine screenshots from the shipping app for required device sizes.
  No iOS screenshots are currently included in this repository.
- Complete App Privacy for the actual shipping build and its dependencies.
  Source inspection found local device storage and no app analytics/account
  service; it is not a completed SDK privacy audit. Speech recognition is not
  forced to run on-device. Do not claim all recognition happens offline.
- Check the existing policy against current behavior: voice capture runs while
  the voice sheet listens, and saved data includes pairing details and relay
  settings as well as TV names. Update and publish the policy as needed.
- Answer Apple's age-rating, content-rights, and export-compliance questions
  based on the actual app. Do not guess account or legal declarations.
- Confirm price, storefront availability, and release timing with the owner.
- Supply the public support URL and review contact details.

## Build route if no suitable build exists

The existing `ios-testflight` workflow in `codemagic.yaml` signs and uploads an
IPA using the Codemagic App Store Connect integration named `codemagic`.
It does not submit the App Store version for review. Ensure the integration has
access to the matching app. `APP_APPLE_ID` is configured as `6822749631` from
the supplied URL; verify that record has the bundle ID above before running.
No build was triggered in this session.

## Submission route

In the existing app record, select the App Store/Distribution version rather
than the TestFlight group. Complete the version information, select its build,
resolve required fields, and save. Add the app version for review, then submit
the submission to App Review. Apple review precedes public availability.

References:

- https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app
- https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/
