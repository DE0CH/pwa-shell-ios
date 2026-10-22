# pwa-shell-ios

A native SwiftUI iPhone/iPad client for a **Jarvis** server (the staff build of
[DE0CH/claudecodeui](https://github.com/DE0CH/claudecodeui): Claude Code in a sandbox per conversation) behind
**Cloudflare Access**. All logic stays on the server; the app draws it natively with the same REST API and chat
WebSocket the web UI uses. (The repository started as a web-view shell, hence its name.)

Nothing about any particular instance is in this repository: its URL, the app's name, bundle id, language, icon and
logo are build inputs, set as GitHub secrets and written into the project at build time by `scripts/configure.sh`.

## What the app does

- **Sign-in.** The app opens `https://<site>/api/jarvis/app-signin?state=<random>` in `ASWebAuthenticationSession`.
  The person sees only Cloudflare Access's own login (Google or an emailed code; Google allows it in the system
  sheet, not in a web view). The server then redirects to `<bundle id>://signed-in?state=…#token=<the caller's
  Access token>` (the router's `JARVIS_APP_SCHEME` must be the bundle id); the app checks the state, keeps the token
  in the Keychain and sends it as the `CF_Authorization` cookie on every API and WebSocket call. When it expires
  (the Access app's session duration), the app asks to sign in again.
- **Conversations**: the list (kept current by the server's `session_upserted` / `session_removed` pushes, pull to
  refresh), rename, delete (to *Recently deleted*, with restore and delete permanently), a running indicator.
- **Chat**: user bubbles with photos and files; Claude's replies as Markdown
  ([swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui): tables, code); tool steps collapsed,
  runs of the same tool grouped (as the web UI's `toolGrouping.ts`); `SendUserFile` results as file cards that open
  in Quick Look (share, save to Files); the *preparing the workspace* and working indicators with Stop; errors and
  reconnecting.
- **Composer**: multi-line input, attachments from Photos, the camera or Files (removable thumbnails), send / stop,
  the server's warm call while typing.
- **Empty chat**: the logo and the greeting in Hong Kong time (the web UI's `jarvisGreeting.ts` phrases and rules).
- **Files** (the conversation's sent files) and **Share** (read-only links; they open in the browser).
- zh-HK and English (`App/Localizations`; wording from the web UI's locale files), Dynamic Type, dark mode.
- No web view anywhere: sign-in uses the system sign-in sheet, files use Quick Look.

## Build inputs (repository secrets)

| Secret | What |
| --- | --- |
| `PWA_SITE_URL` | the server, `https://…` |
| `PWA_APP_NAME` | home-screen name (also the `{product}` in texts) |
| `PWA_BUNDLE_ID` | bundle id; also the sign-in callback scheme (the server's `JARVIS_APP_SCHEME`) |
| `PWA_LANGUAGE` | development region / fallback language: `zh-HK` or `en` |
| `PWA_ICON_PNG_BASE64` | app icon: an opaque 1024×1024 PNG, base64 (optional; a placeholder otherwise) |
| `PWA_LOGO_PNG_BASE64` | logo on a transparent background for the sign-in and empty chat, base64 (optional) |
| `APPLE_TEAM_ID` | Apple developer team id |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY` | App Store Connect API key (Admin: cloud signing), `.p8` text |
| `PWA_ARTIFACT_AGE_RECIPIENT` | an [age](https://age-encryption.org) public key: CI's screenshots show the site, and this repository's artifacts are public, so they are uploaded encrypted to it |

## Tests and shipping

Every push to `main` runs `.github/workflows/ios.yml`:

1. **simulator** (`scripts/simulator-test.sh`): UI tests on an iPhone Pro simulator (Dynamic Island):
   - the real server's sign-in path up to Access's Google button;
   - against `StubServer/` (a recorded stand-in for the server's REST API and WebSocket frames): the empty chat,
     the conversation list and a history, sending a message with a streamed Markdown reply (table, code) and a file
     card opening in Quick Look, attaching a photo; light and dark.
   Screenshots, UI snapshots, the app's and the stub's logs are the `simulator-results-encrypted` artifact
   (`age -d -i KEY simulator-results.tar.age | tar -xz`). The public log names no host.
2. **testflight** (after the tests pass): archives unsigned, then `xcodebuild -exportArchive` cloud-signs with the
   API key and uploads. Build number `<run number>.<run attempt>`.

Locally (macOS, Xcode 26, `brew install xcodegen`, Node 22):

```bash
PWA_SITE_URL=https://app.example.com PWA_APP_NAME="Example" scripts/configure.sh && open PWAShell.xcodeproj
node StubServer/server.mjs 8787   # then run with -PWASiteURLOverride http://127.0.0.1:8787 -PWATestToken stub-token
```

The archive is unsigned on purpose: signing during `archive` on a fresh CI runner makes automatic signing create a
new development certificate every run, until the team reaches Apple's certificate limit.

## License

MIT
