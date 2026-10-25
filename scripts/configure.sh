#!/usr/bin/env bash
# Writes the build inputs into Generated/ and generates PWAShell.xcodeproj (XcodeGen).
# Inputs (environment; in CI they come from the repository's secrets, see README):
#   PWA_SITE_URL         the web app (https://…)                default https://example.com/
#   PWA_APP_NAME         home-screen name                        default "Web App"
#   PWA_BUNDLE_ID        bundle id                               default dev.example.pwashell
#   PWA_LANGUAGE         the app's one UI language (en | zh-HK)  default en
#   PWA_BACKEND          the kind of server (server | jarvis4)   default server (App/Sources/Backend.swift)
#   PWA_ICON_PNG_BASE64  1024x1024 opaque PNG, base64            default branding/placeholder-icon.png
#   PWA_LOGO_PNG_BASE64  the logo on transparent background (sign-in, empty chat), base64; default: the icon
#   A secret holds at most 48 KB: a longer base64 value continues in PWA_ICON_PNG_BASE64_2 / PWA_LOGO_PNG_BASE64_2.
#   APPLE_TEAM_ID        Apple developer team                    default empty
#   BUILD_NUMBER         CFBundleVersion                         default 1
# Prints no input values.
set -euo pipefail
cd "$(dirname "$0")/.."
SITE=${PWA_SITE_URL:-https://example.com/}
NAME=${PWA_APP_NAME:-Web App}
BUNDLE=${PWA_BUNDLE_ID:-dev.example.pwashell}
export PWA_LANGUAGE=${PWA_LANGUAGE:-en}
BACKEND=${PWA_BACKEND:-server}
[[ "$BACKEND" == server || "$BACKEND" == jarvis4 ]] || { echo "PWA_BACKEND must be server or jarvis4" >&2; exit 1; }
TEAM=${APPLE_TEAM_ID:-}
BUILD=${BUILD_NUMBER:-1}
[[ -d "App/Localizations/$PWA_LANGUAGE.lproj" ]] || { echo "no App/Localizations/$PWA_LANGUAGE.lproj" >&2; exit 1; }
[[ "$SITE" == https://* ]] || { echo "PWA_SITE_URL must be https://" >&2; exit 1; }

rm -rf Generated && mkdir -p Generated/Resources
# xcconfig treats // as a comment: write it as /$()/
xc() { printf '%s = %s\n' "$1" "$(printf '%s' "$2" | sed 's#//#/$()/#g')"; }
{
  xc PWA_SITE_URL "$SITE"
  xc PWA_APP_NAME "$NAME"
  xc PWA_BUNDLE_ID "$BUNDLE"
  xc PWA_LANGUAGE "$PWA_LANGUAGE"
  xc PWA_BACKEND "$BACKEND"
  xc PWA_TEAM_ID "$TEAM"
  xc PWA_BUILD_NUMBER "$BUILD"
} > Generated/Config.xcconfig

# Both languages; PWA_LANGUAGE is the development region (the fallback).
cp -R App/Localizations/*.lproj Generated/Resources/

A=Generated/Resources/Assets.xcassets
mkdir -p "$A/AppIcon.appiconset" "$A/ShellIcon.imageset"
printf '{"info":{"author":"xcode","version":1}}\n' > "$A/Contents.json"
if [[ -n "${PWA_ICON_PNG_BASE64:-}" ]]; then
  printf '%s%s' "$PWA_ICON_PNG_BASE64" "${PWA_ICON_PNG_BASE64_2:-}" | base64 --decode > "$A/AppIcon.appiconset/icon-1024.png"
else
  cp branding/placeholder-icon.png "$A/AppIcon.appiconset/icon-1024.png"
fi
cp "$A/AppIcon.appiconset/icon-1024.png" "$A/ShellIcon.imageset/icon.png"
if [[ -n "${PWA_LOGO_PNG_BASE64:-}" ]]; then
  mkdir -p "$A/Logo.imageset"
  printf '%s%s' "$PWA_LOGO_PNG_BASE64" "${PWA_LOGO_PNG_BASE64_2:-}" | base64 --decode > "$A/Logo.imageset/logo.png"
  printf '{"images":[{"filename":"logo.png","idiom":"universal"}],"info":{"author":"xcode","version":1}}\n' > "$A/Logo.imageset/Contents.json"
fi
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
