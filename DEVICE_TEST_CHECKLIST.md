# Phone and TV acceptance checks

Record the phone OS, TV brand/model/firmware, app commit and result. Do not include pairing tokens or private network details in a shared report.

## First connection

- [ ] Phone and TV are on the same Wi-Fi; scan identifies the TV or manual IP pairing succeeds.
- [ ] Samsung/LG: accept the prompt on the intended TV.
- [ ] Home, arrows, OK and Back affect only that TV.
- [ ] Restart the app; pairing survives and reconnect works.
- [ ] Turn the TV off or disable Wi-Fi; the app gives recovery guidance without repeating a power toggle.
- [ ] Re-enable the network; a new explicit command reconnects.

## Voice and text

- [ ] Microphone permission is requested after Start voice input, not at startup.
- [ ] Denied microphone/speech permissions leave keyboard entry usable.
- [ ] Speak, stop, edit the recognised words and send to a focused text field.
- [ ] Roku: test automatic search separately; verify that the screen is ready for text.
- [ ] Switch recognition languages and test accented/non-Latin text supported by the TV.
- [ ] Background or close the voice sheet; microphone capture stops.

## Everyday controls

- [ ] Volume repeat stops when the finger lifts and when the app backgrounds.
- [ ] A queued command from one TV never affects another selected TV.
- [ ] Apps, inputs, favourites, aliases and room names persist after restart.
- [ ] Simple mode, left-handed layout and system dark mode are usable.
- [ ] TalkBack/VoiceOver announces buttons and can activate them.
- [ ] At large text size and on a small screen, all controls remain reachable.
- [ ] Practice mode has no effect on a TV.

## Activities and timers

- [ ] Create, edit and reorder an activity across two saved TVs.
- [ ] Stop during a wait: no following step runs and no completed-wait result appears.
- [ ] A failed step stops the activity; manual controls are available afterward.
- [ ] LG Quiet moment verifies mute, then restores only on explicit request.
- [ ] Change LG volume using another remote during Quiet moment; restoration leaves the changed state alone.
- [ ] Wake works only with the correct MAC and network standby enabled.
- [ ] Foreground sleep powers off the selected target; leaving the app cancels the timer.

## Release gates

- [ ] Latest CI passes analysis, tests, Android build and iOS simulator compilation.
- [ ] Physical Android and iPhone checks above pass on each advertised TV model.
- [ ] Owner configures Android/iOS signing before production distribution.

A simulator build cannot verify microphone behaviour, TV networking, certificate changes or physical-device keychain persistence. Do not advertise a model as tested until these checks have been observed.
