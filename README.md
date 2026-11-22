# XSign

An on-device signer and update dashboard for iOS. XSign keeps your own
sideloaded apps up to date: it watches each app's GitHub repo (public or
private) for new releases, then downloads, signs and installs the build when
you tap **Update**.

```
GitHub Release (MyApp.ipa)
        │  api.github.com + your token
        ▼
XSign ── download ─► unzip ─► zsign (your .p12 + profile) ─► zip
        │
        └─► HTTPS server on 127.0.0.1 ─► itms-services:// ─► iOS installs the app
```

## Features

- **Repos**: add as many sources as you like. A source is a GitHub repo
  (paste `github.com/owner/repo` or `owner/repo`) whose releases carry an
  `.ipa`. It can also be any AltStore / Feather-style source URL, or a
  single-app XSign feed on your NAS. XSign shows a preview before you add one.
  Private repos work with a fine-grained token kept in the keychain.
- **Apps**: browse what your sources offer, Feather-style. Each source shows
  its newest few apps with **See All**; search covers every source and loads
  results a page at a time, so sources with tens of thousands of apps stay
  smooth. Get / Update / Reinstall buttons with live progress. Each app has a
  page with What's New, recent versions, and info. Pre-releases are listed as
  **beta**.
- **Home**: what you have. Pending updates with **Update All**, setup steps,
  certificate status, and **Your apps** with their installed version and
  whether each is up to date. Source catalogs are not listed here.
- **Library**: signed apps with **Install** (reuses the signed copy),
  **Re-sign** (signs the original again with the current certificate) and
  **Share** (exports the signed `.ipa`). You can also import any `.ipa` from
  Files.
- **On-device signing** with [zsign](https://github.com/zhlynn/zsign) (MIT).
  Every app keeps its own bundle ID, as in Feather, so an update installs over
  the existing app and its data. This works with profiles that have one fixed
  App ID, as most sideloading certificates do.
  Downloads are checked against GitHub's SHA-256 digest when one is available.
- **Local install**: a loopback-only HTTPS server (Vapor) serves the manifest
  and IPA, then iOS's own installer takes over.
- **Updates**: optional betas, background refresh, and notifications with an
  **Update** action. Deep links: `xsign://add?url=<source>` and
  `xsign://update?bundle=<bundle id>`.
- **Settings › GitHub**: shows your API quota (requests left, reset time),
  manages the token, and explains how to create one.

## Repository layout

| Path | What |
| --- | --- |
| `project.yml` | XcodeGen spec (the `.xcodeproj` is generated, not committed) |
| `XSign/App` | App entry, `AppModel` (state + update pipeline), background tasks |
| `XSign/Services` | Downloader, IPA unpack/repack, zsign wrapper, install server, keychain/storage, notifications |
| `XSign/Views` | SwiftUI screens: Repos, Apps, Home, Library, Settings |
| `Packages/XSignCore` | Platform-independent logic + unit tests: source parsing, GitHub/feed catalogs, rate limits, versions, provisioning profiles, install manifest, trust profile |
| `docs/release-ipa.yml` | Workflow to drop into an app's repo so version tags publish an IPA |
| `.github/workflows/build.yml` | CI: core tests + unsigned `XSign-unsigned.ipa` (main, tags, manual runs) |
| `THIRD-PARTY-NOTICES.md` | Licenses of the open-source packages XSign includes |

## Getting started

### 1. Get XSign onto the phone

1. On the iPhone, open this repository's **Releases** page in Safari and tap
   `XSign-unsigned.ipa` under the newest release to download it.
2. Sign and install it once with your current signer (FlareStore, Feather,
   Sideloadly or AltStore), using the same certificate you'll import into
   XSign.
3. Optional: add this repository as a source in XSign itself. XSign then
   offers its own updates like any other app.

Every push to `main` rebuilds the `.ipa` and publishes it as release
`v<MARKETING_VERSION>` (from `project.yml`). Bump that version for a new
release; otherwise the same release's file is replaced.

To build it yourself on a Mac:

```sh
brew install xcodegen
xcodegen generate
open XSign.xcodeproj
```

### 2. Publish builds

Any repo whose GitHub Releases include an `.ipa` works. For a native Xcode
app, [`docs/release-ipa.yml`](docs/release-ipa.yml) is a starting point: it
builds an unsigned `.ipa` on every `v<version>` tag and attaches it to the
release.

### 3. Set up XSign on the phone

1. **Repos › +**: paste `github.com/<owner>/<repo>` for each of your apps
   (or any source URL).
2. **Settings › GitHub**: add a fine-grained token with **Contents:
   Read-only** on your private repos.
3. **Settings › Certificates**: import your `.p12`, its password, and a
   `.mobileprovision` that includes your device.
4. **Settings › Installer**: download the profile, install it in the Settings
   app, and turn it on under General › About › Certificate Trust Settings.
5. **Apps**: tap **Get** on an app, then confirm the iOS prompt. New releases
   show up on **Home** as updates.

## How "installed version" works

iOS doesn't let one app read another app's version. XSign records what it
installed: the release tag and the bundle's version and build. It compares that
record against the newest release. If you installed a build some other way,
open the app's page and use **Versions › ⋯ › Mark as Installed**.

## Notes and limits

- The signing certificate decides everything else. With a free Apple ID,
  profiles expire after 7 days and allow 3 apps. A paid developer account gets
  a year and wildcard profiles.
- iOS only installs from HTTPS addresses it trusts. XSign makes its own root
  certificate on the device, signs a server certificate for `localhost` and
  `local.backloop.dev` with it, and discards the root's private key, so the
  root can't vouch for anything else. You trust it once (Settings ›
  Installer). backloop.dev's shared certificate was revoked and the service
  discontinued in September 2026.
- Background checks run when iOS allows them. Opening XSign always checks.
- Icons are taken from loose PNGs in the bundle. Apps whose icons exist only in
  `Assets.car` get a coloured monogram instead.

## Roadmap

- Homelab / NAS dashboard tiles: a build server publishes to a feed and
  triggers updates. Optionally, signing moves to the homelab.
- Self-update for XSign itself (track this repository's releases).
- Certificate revocation check (zsign's OCSP helper) and expiry reminders.
- Pairing-file based installs (no HTTPS server) for iOS versions that need it.
