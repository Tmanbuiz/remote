# Room Remote for Android

A personal Android remote prototype for Philips and Hisense TVs with Roku built in. Android 8.0 or later. Not affiliated with Roku, Philips, or Hisense.

## Use the app

1. Install `RoomRemote.apk` on your Android phone. If Android asks, allow installation from the file or browser app you used, then open the installer. You can turn that permission off afterward.
2. Turn your TV on and connect the phone and TV to the same home network.
3. On the TV, check **Settings → System → Advanced system settings → Control by mobile apps → Enabled**. Names may differ by Roku version.
4. Open **Room Remote**, tap **Find TVs**, and choose your TV. If discovery fails, use **Enter address**. The TV's address is under **Settings → Network → About**.
5. Allow notifications for a persistent remote shortcut and a **Disconnect** action.

The app includes navigation, Home, Back, Options, volume, mute, playback, replay, HDMI/antenna input selection, and power off. Input support varies by TV. Power-on, voice control, private listening, casting, and streaming-app shortcuts are not implemented. Use your physical remote to turn the TV on.

**Try demo remote** lets you try the interface without sending any commands. Demo mode does not start the background service.

## Keep-alive behavior

- A connected-device foreground service owns the TV session, separately from the screen.
- Switching apps, pressing Back, or locking the phone leaves the session running. Back moves the app to the background.
- A notification opens the remote and provides **Disconnect**.
- The app checks TV availability approximately every 30 seconds, retrying automatically after temporary network loss. Android can delay these checks while asleep.
- **Disconnect TV**, the notification's **Disconnect**, swiping the app out of recent apps, or force-stopping it stops the session. It does not start at phone boot.
- If Android reclaims the service process, the sticky service can restore the active session. This is best-effort; force-stop is respected.
- The screen is allowed to turn off. The app does not hold an indefinite wake lock.
- For phones with aggressive battery management, open Android's settings for Room Remote and allow unrestricted background battery use. No app can guarantee survival under every Android or manufacturer restriction.

Commands are not queued for later replay across network failure, session changes, or app restarts. After a control error, buttons temporarily disable until the next successful availability check. The app checks device identity on reconnect so a changed IP address does not silently select a different TV.

## Compatibility limitation

This app implements the local ECP protocol documented by Roku. Roku's current documentation states that ECP commands may not be sent from third-party platforms, including mobile applications. Personal use does not create a documented exception. This prototype is not an approved Roku integration; device firmware/settings may reject its commands. No access controls are bypassed.

Reference: https://developer.roku.com/dev/docs/external-control-api

## Privacy

No accounts, analytics, ads, cloud server, microphone, or location access. TV commands use unencrypted HTTP on the local network because that is how ECP works. The app accepts private/link-local IPv4 addresses only and does not follow HTTP redirects. It saves the last TV address locally. The active session address and device identifier support recovery after an operating-system process restart and are cleared when the service stops normally. Android backup is disabled.

## Build from source

Open this folder in Android Studio and let Gradle sync. Use JDK 17, Android SDK 35, and Build Tools 35.0.0. The included wrapper uses Gradle 8.11.1 with Android Gradle Plugin 8.9.1. There are no third-party runtime libraries.

On Windows, with the Android SDK available through `local.properties` or `ANDROID_HOME`:

```powershell
.\gradlew.bat testDebugUnitTest lintDebug assembleDebug
```

The debug APK is at `app/build/outputs/apk/debug/app-debug.apk`. A debug build is suitable for personal testing, not a Play Store release. Keep the same signing key if you later want to install updates over an existing installation.

## Phone verification checklist

1. Connect to the intended TV and try Home, directions, OK, Back, volume, and playback.
2. Switch to another app for several minutes; the notification should remain. Return and try a button.
3. Lock/unlock the phone and confirm the session remains. Repeat with your phone's battery-saving mode.
4. Temporarily turn Wi-Fi off/on. The session should remain active and recover without replaying old button presses.
5. Disconnect through the notification and confirm the app shows disconnected.
6. Reconnect, then swipe the app away. The notification should disappear; reopening must not reconnect until you choose a TV.
7. Repeat with Android's Force stop. Test each of your TVs independently.

Physical-device behavior cannot be verified without your phone and TV. See `VALIDATION.md` for checks performed during creation.
