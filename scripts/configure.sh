#!/usr/bin/env bash
# Writes the build inputs into Generated/ and generates PWAShell.xcodeproj (XcodeGen).
# Inputs (environment; in CI they come from the repository's secrets, see README):
#   PWA_SITE_URL         the web app (https://…)                default https://example.com/
#   PWA_APP_NAME         home-screen name                        default "Web App"
#   PWA_BUNDLE_ID        bundle id                               default dev.example.pwashell
#   PWA_LANGUAGE         the app's one UI language (en | zh-HK)  default en
#   PWA_ICON_PNG_BASE64  1024x1024 opaque PNG, base64            default branding/placeholder-icon.png
#   APPLE_TEAM_ID        Apple developer team                    default empty
#   BUILD_NUMBER         CFBundleVersion                         default 1
# Prints no input values.
set -euo pipefail
cd "$(dirname "$0")/.."
SITE=${PWA_SITE_URL:-https://example.com/}
NAME=${PWA_APP_NAME:-Web App}
BUNDLE=${PWA_BUNDLE_ID:-dev.example.pwashell}
export PWA_LANGUAGE=${PWA_LANGUAGE:-en}
TEAM=${APPLE_TEAM_ID:-}
BUILD=${BUILD_NUMBER:-1}
[[ -d "App/Localizations/$PWA_LANGUAGE.lproj" ]] || { echo "no App/Localizations/$PWA_LANGUAGE.lproj" >&2; exit 1; }
[[ "$SITE" == https://* ]] || { echo "PWA_SITE_URL must be https://" >&2; exit 1; }

rm -rf Generated && mkdir -p Generated/Resources
# xcconfig treats // as a comment: write it as /$()/
xc() { printf '%s = %s\n' "$1" "${2//\/\//\/\$()\/}"; }
{
  xc PWA_SITE_URL "$SITE"
  xc PWA_APP_NAME "$NAME"
  xc PWA_BUNDLE_ID "$BUNDLE"
  xc PWA_LANGUAGE "$PWA_LANGUAGE"
  xc PWA_TEAM_ID "$TEAM"
  xc PWA_BUILD_NUMBER "$BUILD"
} > Generated/Config.xcconfig

# One language only: iOS then uses it whatever the device language is (the web app decides its own).
cp -R "App/Localizations/$PWA_LANGUAGE.lproj" Generated/Resources/

A=Generated/Resources/Assets.xcassets
mkdir -p "$A/AppIcon.appiconset" "$A/ShellIcon.imageset"
printf '{"info":{"author":"xcode","version":1}}\n' > "$A/Contents.json"
if [[ -n "${PWA_ICON_PNG_BASE64:-}" ]]; then
  printf '%s' "$PWA_ICON_PNG_BASE64" | base64 --decode > "$A/AppIcon.appiconset/icon-1024.png"
else
  cp branding/placeholder-icon.png "$A/AppIcon.appiconset/icon-1024.png"
fi
cp "$A/AppIcon.appiconset/icon-1024.png" "$A/ShellIcon.imageset/icon.png"
cat > "$A/AppIcon.appiconset/Contents.json" <<'J'
{"images":[{"filename":"icon-1024.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
J
cat > "$A/ShellIcon.imageset/Contents.json" <<'J'
{"images":[{"filename":"icon.png","idiom":"universal"}],"info":{"author":"xcode","version":1}}
J

sed "s/TEAM_ID_PLACEHOLDER/$TEAM/" ExportOptions.plist > Generated/ExportOptions.plist

if command -v xcodegen >/dev/null; then
  xcodegen generate --quiet
else
  echo "xcodegen not installed: Generated/ written, project not generated" >&2
fi
