# Protocol interoperability notices

Android TV message layouts and pairing behavior were implemented using
[androidtvremote2](https://github.com/tronikos/androidtvremote2), revision
`e664a8e1f14ee458b14c646bfb3ea46f10367051`, under Apache License 2.0.
The upstream license is included at `third_party/androidtvremote2-LICENSE`.
The pairing schema originated in Google's Android Open Source Project.

VIDAA topic layouts, credential derivation, firmware-profile boundaries and the
public mobile-client certificate fixture were implemented using
[vidaa-control](https://github.com/tombabolewski/vidaa-control), revision
`1a25834469c8e7af51be8b50fe71b69c0546b1d3`, copyright 2025 Tom Babolewski,
under the MIT license at `third_party/vidaa-control-LICENSE`.
The fixture certificate/private key are included at `assets/vidaa/client.pem`
and `assets/vidaa/client.key`, as published by that upstream project. No owner's
TV PIN, access token or private Android pairing identity is included.

These are interoperability adapters, not official Google/Roku/VIDAA products.
Manufacturer behavior and protocol availability vary by firmware.
