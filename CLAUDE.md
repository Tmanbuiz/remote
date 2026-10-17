# Universal Remote

TV remote app by WianTribe Inc., built with Flutter.

- Repo: github.com/Tmanbuiz/remote (GitHub account Tmanbuiz)
- Goal: list it on the Apple App Store
- Apple Developer Program: subscribed; signed in to App Store Connect
- App Store preparation PR was merged into main on 2026-10-16
- Support page: wiantribe.com/remote
- Privacy policy: wiantribe.com/remote/privacy
- Owner has limited coding background. Claude writes the code; the owner builds and submits.

## How to work here

- The next milestone is getting the app through App Store review. Before adding features, check what could cause a rejection: missing or inaccurate privacy answers, permission prompts without clear purpose strings, broken links, crashes on first launch, features that don't work without a real TV.
- Keep the privacy policy and App Store privacy answers in step with what the code does. If a change adds a permission (local network, Bluetooth, camera, microphone) or a new data use, say so and list the policy and Info.plist changes it needs.
- Review will test without the owner's TV. Make sure the app opens, explains itself, and handles "no TV found" cleanly instead of failing silently.
- Do not claim support for a TV brand or model that has not been tested. Say which brands the code actually talks to.
- Keep Dart code in small files, and run `flutter analyze` and the tests before saying a change is done.
- Say plainly what the owner must do by hand (Xcode signing, App Store Connect field, screenshot upload, version/build number bump).
- Deliver complete files and name the path of each.

## Agents and skills to use

- Agents: planner (before big features), code-reviewer (before each build), build-error-resolver (Flutter and Xcode build errors), doc-updater (keep the support page and privacy policy text in step)
- Commands: /plan, /code-review, /verify
- Not useful here: the React and Next.js skills. Nothing in the toolkit covers Dart or Flutter, so rely on `flutter analyze` and the app's own tests.

## Keep sessions cheap

- Work on one task per session. When a task is finished, tell the owner to run `/clear` before starting the next.
- If the conversation has gone long (many file edits, repeated debugging), tell the owner to run `/compact` before continuing.
- Read only the files the task needs. Ask which file to change if unsure; do not scan the whole repo.
- Do not start a subagent for small jobs. Use one only for a planning or review pass, and only when asked.
- Do not paste whole files or long logs back into the chat. Show only the changed lines and the result.
