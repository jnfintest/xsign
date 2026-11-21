# Homelab / NAS feeds

Besides GitHub repos, the Repos tab accepts any HTTP(S) JSON source. This lets your NAS, a CI runner in the homelab, or a build agent publish builds that XSign picks up.

## XSign feed format

```json
{
  "name": "MyApp",
  "bundleIdentifier": "com.example.myapp",
  "releases": [
    {
      "version": "1.4.0",
      "build": "42",
      "date": "2026-11-19T10:00:00Z",
      "notes": "Faster sync, new budget view",
      "url": "builds/MyApp-1.4.0.ipa",
      "size": 18350080,
      "sha256": "9f2c…",
      "prerelease": false
    }
  ]
}
```

* `url` may be absolute or relative to the feed URL.
* `build` must be a string.
* `sha256` is optional; when present XSign verifies the download.
* Order doesn't matter; XSign sorts by version, then build.

## AltStore-style sources

A standard AltStore / Feather source (`apps[].versions[]` with `downloadURL`)
also works, and every app in it shows up under Apps. Apps with `"beta": true`
are marked as betas.

## Auth

Turn on **Send homelab token** when adding the source, and enter the token
under *Settings › Homelab*. XSign sends it as `Authorization: Bearer <token>`
for both the feed and the IPA download.

## Minimal setup on a NAS

```
/srv/apps/myapp.json
/srv/apps/builds/MyApp-1.4.0.ipa
```

Serve `/srv/apps` with any static web server (Caddy, nginx, Synology Web
Station) and point XSign at `https://nas.example.lan/apps/myapp.json`.
Use HTTPS with a certificate your iPhone trusts, or plain HTTP on the local
network. XSign allows local networking.

## Roadmap: build server

Planned direction (not built yet):

1. A build server or agent builds or collects an IPA and writes the feed entry, then pings XSign
   through a push notification or the `xsign://update?app=MyApp` deep link.
2. Optional: sign on the homelab (zsign on Linux) and serve a ready-to-install
   manifest, so the phone only downloads and installs.
3. A status endpoint so the XSign dashboard can show homelab services next to
   your apps.
