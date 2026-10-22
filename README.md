# pwa-shell-ios

An iOS app that shows one web app (a PWA) full screen in a `WKWebView`, for sites behind
**Cloudflare Access**. Nothing about the site is in this repository: its URL, the app's name, bundle id,
language and icon are build inputs, set as GitHub secrets and written into the project at build time by
`scripts/configure.sh`.

## What the app does

- **Sign-in through Cloudflare Access.** Google (and other identity providers) refuse to sign in inside an
  embedded web view, so the login runs in the system sign-in sheet (`ASWebAuthenticationSession`), using the
  same token transfer as `cloudflared access login`: the app opens `https://<site>/cdn-cgi/access/cli?…`
  with an ephemeral X25519 public key, the person signs in and taps **Approve**, and the app collects the app
  token and the org token from `login.cloudflareaccess.org/transfer/<key>` (sealed to its key with NaCl box,
  opened with [swift-sodium](https://github.com/jedisct1/swift-sodium)). Both go into the web view's cookie
  store as `CF_Authorization`: the app token on the site, the org token on the team domain, so Access
  renews the app token silently inside the web view until the org session ends. When Access shows its login
  page again, the app shows its sign-in screen instead. See `App/AccessSignIn.swift`.
- Links to other sites, `mailto:` and `tel:` open outside the app (Safari, Mail, Phone).
- Downloads (`<a download>`, blob URLs, `Content-Disposition: attachment`) open in the share sheet.
- File inputs offer the photo library, the camera and Files (usage strings in English and zh-HK).
- Pull to refresh; a native "Can't connect / Try again" screen when the page does not load; a reload after
  the web content process dies or when the app returns with an expired session cookie.
- Pages the site opens in a new window open in a sheet that shares the session.
- The page owns the safe areas (`viewport-fit=cover` + `env(safe-area-inset-*)`).
- No push notifications, no analytics.

## Build inputs (repository secrets)

| Secret | What |
| --- | --- |
| `PWA_SITE_URL` | the web app, `https://…` |
| `PWA_APP_NAME` | home-screen name |
| `PWA_BUNDLE_ID` | bundle id (registered in the Apple developer account, with an App Store Connect record) |
| `PWA_LANGUAGE` | the app's own UI language: `en` or `zh-HK` (one per build; the web app picks its own) |
| `PWA_ICON_PNG_BASE64` | the app icon: an opaque 1024×1024 PNG, base64 (optional; a placeholder otherwise) |
| `APPLE_TEAM_ID` | Apple developer team id |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY` | App Store Connect API key (Admin: cloud signing), `.p8` text |

## Shipping a build

Every push to `main` (or **Actions → iOS → Run workflow**) runs `.github/workflows/ios.yml`:

1. **simulator**: generates the project (XcodeGen), runs the UI tests on an iPhone simulator
   (`scripts/simulator-test.sh`): the shell renders a page, the configured site brings up the sign-in screen,
   and its button opens the Access login sheet. Screenshots are the `simulator-screenshots` artifact.
2. **testflight** (after the simulator job passes): archives unsigned, then `xcodebuild -exportArchive`
   cloud-signs with the API key and uploads to App Store Connect. The build number is
   `<run number>.<run attempt>`. TestFlight processing takes a few minutes after the upload.

Locally (macOS with Xcode 26 and `brew install xcodegen`):

```bash
PWA_SITE_URL=https://app.example.com PWA_APP_NAME="Example" scripts/configure.sh
open PWAShell.xcodeproj
```

The archive is unsigned on purpose: signing during `archive` on a fresh CI runner makes automatic signing
create a new development certificate every run, until the team reaches Apple's certificate limit.

## License

MIT
