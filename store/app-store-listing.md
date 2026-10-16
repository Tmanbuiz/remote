# App Store listing — Universal Remote by WianTribe

Bundle ID: `com.wiantribe.universalRemote` (camel case matters; it must match
`ios/Runner.xcodeproj` and `codemagic.yaml`). Version `1.0.0`, minimum iOS 15.0.

## App Information

| Field | Value | Limit |
|---|---|---|
| Name | Universal Remote by WianTribe | 30 |
| Subtitle | Private Wi-Fi remote for TVs | 30 |
| Primary category | Utilities | |
| Secondary category | Entertainment | |
| Age rating | 4+ (no objectionable content; answer "None" to every question) | |
| Price | Free | |
| Support URL | https://wiantribe.com | |
| Privacy Policy URL | https://wiantribe.com/privacy | |
| Copyright | 2026 WianTribe Inc. | |

## Promotional text (170, editable without a new review)

Control your Roku TV from your phone over Wi-Fi. No account, no ads, no tracking.
Type, speak, wake your TV and listen privately.

## Description (4000)

Universal Remote turns your iPhone into a fast, private remote control for the
TVs on your home Wi-Fi. No account, no sign-up, no ads.

WHAT IT DOES
• Control Roku TVs and players: D-pad, OK, back, home, volume and power.
• Launch channels and switch HDMI inputs straight from your phone.
• Type with your iPhone keyboard instead of pecking letters on the TV.
• Voice search: hold the microphone button and say what you are looking for.
• Private listening: send the TV's audio to your headphones through the phone,
  so you can watch without disturbing anyone. It keeps playing with the screen off.
• Wake a TV that supports Wi-Fi wake-up without getting up.
• Add a TV by typing its IP address when automatic discovery cannot see it.
• Rename a TV to something you will actually say, like "Living room TV".

PRIVATE BY DESIGN
There is no account and no cloud. The app talks directly to your TVs on your own
network. It collects no personal information, has no analytics and shows no ads.

GOOD TO KNOW
• Your iPhone and TV must be on the same Wi-Fi network, and the TV must be a
  networked smart TV. iPhones have no infrared blaster, so IR-only TVs cannot
  be controlled.
• On a Roku TV, set Settings > System > Advanced system settings > Control by
  mobile apps to a permissive option.
• Samsung (2016 and newer) and LG webOS support is experimental and may need
  adjustments on some models.
• Universal Remote is an independent app and is not affiliated with or endorsed
  by Roku, Samsung or LG. All product names are trademarks of their owners.

## Keywords (100 characters, comma-separated, no spaces after commas)

tv remote,smart tv,wifi remote,television,controller,voice search,clicker,channel,hdmi

(86 characters. Brand names are left out on purpose, because Apple rejects
keyword lists that contain other companies' trademarks.)

## What's New (version 1.0.0)

First release.

## App Privacy ("nutrition label")

Answer **Data Not Collected**. This matches `store/privacy-policy.md` and the
`PrivacyInfo.xcprivacy` shipped in the app: no tracking, no collected data
types. Paired TV names and tokens are stored on the device only.

The microphone is used for voice search and recognition is performed by iOS's
speech service. If App Store Connect asks whether Apple's speech recognition
counts, the app itself does not receive or store the audio.

## App Review Information

**Sign-in required:** No.

**Notes for the reviewer (paste into the Notes field):**

> Universal Remote controls a TV on the local Wi-Fi network. It needs a Roku TV
> or Roku player on the same network to show live control, which a review device
> may not have. A screen recording of the app controlling a real Roku TV is
> attached to this submission and shows pairing, navigation, text entry, voice
> search and private listening.
>
> Permissions: Local Network (to find and control TVs; no data leaves the
> network), Microphone and Speech Recognition (voice search, only while the
> microphone button is held). Background audio is used only for the Private
> Listening feature, which plays the TV's audio to the phone's headphones and
> keeps playing with the screen locked. No account, tracking or ads.

**Contact:** Tolulope Atoyeje, atoyejet@gmail.com, phone on file in the App Store
Connect form.

## Screenshots (you must capture these)

Required: **6.9-inch iPhone**, 1320 x 2868 px (6.5-inch is only needed if you
skip 6.9). Provide 3 to 10 images, PNG or JPEG, no transparency. Suggested
screens: device list, the remote, text entry, voice search, private listening.
The app icon (1024 x 1024, no alpha) is already in
`ios/Runner/Assets.xcassets/AppIcon.appiconset`. `store/play-icon-512.png` is
for Google Play only.

Also record the 30-second screen video for App Review described above.

## Steps only you can do

1. **Join the Apple Developer Program** (https://developer.apple.com/programs/,
   US$99 per year, billed annually; enrolment can take a day or more).
2. **Create the app record** in App Store Connect: New App, iOS, name
   "Universal Remote by WianTribe", bundle ID `com.wiantribe.universalRemote`,
   an SKU of your choice. Copy its numeric **Apple ID** from App Information and
   put it in `codemagic.yaml` as `APP_APPLE_ID`.
3. **Connect Codemagic**: add this repo, connect your Apple Developer account
   under Teams > Code signing identities, and create an App Store Connect API
   key saved as the `codemagic` integration (see the header of `codemagic.yaml`).
4. **Host the privacy policy** at the Privacy Policy URL above, using
   `store/privacy.html`. The URL must load before you submit.
5. **Run the `ios-testflight` workflow.** It analyzes, tests, signs and uploads
   the build. Install it from TestFlight on a real iPhone, with a real Roku TV,
   and check pairing, keys, text entry, voice search and private listening.
6. **Fill in the listing** with the text above, upload screenshots and the
   review video, pick the processed build, and answer the export-compliance
   question if asked (the app sets `ITSAppUsesNonExemptEncryption` to false
   because it uses only standard TLS and the TV vendors' own authentication;
   confirm that is true for you).
7. **Submit for review.**

## Things most likely to cause a rejection

- **Guideline 2.1 (needs hardware to test):** reviewers without a Roku TV cannot
  see the app work. The review video and notes above are the mitigation; do not
  skip them.
- **Guideline 5.2 (other companies' IP):** the description uses "Roku" only to
  say what the app controls, with an independence disclaimer. Do not use their
  logos or icons.
- **Guideline 2.3 (accurate metadata):** Samsung and LG have never been tested on
  real TVs, so the listing calls them experimental. Do not describe them as fully
  supported until they have been verified.
- **Privacy policy URL:** a dead link is an automatic rejection.
