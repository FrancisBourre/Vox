#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Vox"
BUNDLE_ID="com.francisbourre.Vox"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${VOX_DIST_DIR:-$ROOT_DIR/dist}"
INPUT_DIR="$DIST_DIR/input"
SPARKLE_DIR="$DIST_DIR/sparkle"
DOTENV_FILE="$DIST_DIR/release.env"
SPARKLE_GENERATE_APPCAST="${VOX_SPARKLE_GENERATE_APPCAST:-$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast}"
DMG_PATH="${VOX_DMG_PATH:-}"
DMG_URL="${VOX_DMG_URL:-}"
APPCAST_FILENAME="${VOX_SPARKLE_APPCAST_FILENAME:-appcast.xml}"
REQUIRED_ARCH="${VOX_REQUIRED_ARCH:-arm64}"
EXPECTED_FEED_URL="${VOX_EXPECTED_FEED_URL:-}"
EXPECTED_PUBLIC_ED_KEY="${VOX_EXPECTED_PUBLIC_ED_KEY:-}"
GITHUB_REPOSITORY_NAME="${VOX_GITHUB_REPOSITORY:-${GITHUB_REPOSITORY:-FrancisBourre/Vox}}"
SKIP_GATEKEEPER_VALIDATION="${VOX_SKIP_GATEKEEPER_VALIDATION:-0}"
SKIP_NOTARIZATION_VALIDATION="${VOX_SKIP_NOTARIZATION_VALIDATION:-0}"
ALLOW_UNSIGNED_APPCAST="${VOX_ALLOW_UNSIGNED_APPCAST:-0}"
MOUNT_DIR=""

log() {
  printf '==> %s\n' "$*" >&2
}

ok() {
  printf 'OK: %s\n' "$*" >&2
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

require_tool() {
  local tool="$1"
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
}

plist_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

download_dmg() {
  local output="$INPUT_DIR/Vox.dmg"
  local curl_args=()

  if [ -n "$DMG_PATH" ]; then
    [ -f "$DMG_PATH" ] || fail "VOX_DMG_PATH does not exist: $DMG_PATH"
    cp "$DMG_PATH" "$output"
    printf '%s\n' "$output"
    return 0
  fi

  [ -n "$DMG_URL" ] || fail "set VOX_DMG_PATH or VOX_DMG_URL"

  if [ -n "${VOX_DMG_AUTH_HEADER:-}" ]; then
    curl_args+=(--header "$VOX_DMG_AUTH_HEADER")
  elif [ -n "${VOX_DMG_BEARER_TOKEN:-}" ]; then
    curl_args+=(--header "Authorization: Bearer $VOX_DMG_BEARER_TOKEN")
  elif [ -n "${VOX_DMG_GITHUB_TOKEN:-}" ]; then
    curl_args+=(--header "Authorization: Bearer $VOX_DMG_GITHUB_TOKEN")
  fi

  curl --fail --location "${curl_args[@]}" --output "$output" "$DMG_URL"
  printf '%s\n' "$output"
}

require_generate_appcast() {
  if [ -x "$SPARKLE_GENERATE_APPCAST" ]; then
    return 0
  fi

  log "Resolving Sparkle artifact tools"
  swift package resolve >/dev/null

  [ -x "$SPARKLE_GENERATE_APPCAST" ] || fail "Sparkle generate_appcast not found at $SPARKLE_GENERATE_APPCAST"
}

mount_dmg() {
  local dmg="$1"
  local mount_dir="$2"

  hdiutil attach "$dmg" \
    -nobrowse \
    -readonly \
    -mountpoint "$mount_dir" \
    >/dev/null
}

cleanup_mount() {
  if [ -n "$MOUNT_DIR" ]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
    rm -rf "$MOUNT_DIR"
  fi
}

find_vox_app() {
  local mount_dir="$1"
  local app_path

  app_path="$(find "$mount_dir" -maxdepth 2 -type d -name "$APP_NAME.app" -print -quit)"
  [ -n "$app_path" ] || fail "$APP_NAME.app was not found in mounted DMG"
  printf '%s\n' "$app_path"
}

validate_info_plist() {
  local app_path="$1"
  local info_plist="$app_path/Contents/Info.plist"
  local bundle_id
  local short_version
  local bundle_version
  local feed_url
  local public_key

  [ -f "$info_plist" ] || fail "Info.plist is missing at $info_plist"

  bundle_id="$(plist_value "$info_plist" "CFBundleIdentifier")"
  short_version="$(plist_value "$info_plist" "CFBundleShortVersionString")"
  bundle_version="$(plist_value "$info_plist" "CFBundleVersion")"
  feed_url="$(plist_value "$info_plist" "SUFeedURL")"
  public_key="$(plist_value "$info_plist" "SUPublicEDKey")"

  [ "$bundle_id" = "$BUNDLE_ID" ] || fail "unexpected bundle id: $bundle_id"
  [ -n "$short_version" ] || fail "CFBundleShortVersionString is missing"
  [ -n "$bundle_version" ] || fail "CFBundleVersion is missing"
  [ -n "$feed_url" ] || fail "SUFeedURL is missing"
  [ -n "$public_key" ] || fail "SUPublicEDKey is missing"

  if [ -n "$EXPECTED_FEED_URL" ] && [ "$feed_url" != "$EXPECTED_FEED_URL" ]; then
    fail "unexpected SUFeedURL: $feed_url"
  fi

  if [ -n "$EXPECTED_PUBLIC_ED_KEY" ] && [ "$public_key" != "$EXPECTED_PUBLIC_ED_KEY" ]; then
    fail "unexpected SUPublicEDKey"
  fi

  VOX_RELEASE_VERSION="$short_version"
  VOX_BUNDLE_VERSION="$bundle_version"
  VOX_FEED_URL="$feed_url"
  VOX_GITHUB_RELEASE_TAG="${VOX_GITHUB_RELEASE_TAG:-v$short_version}"

  ok "Info.plist metadata validated for $short_version ($bundle_version)"
}

validate_frameworks_and_rpaths() {
  local app_path="$1"
  local executable="$app_path/Contents/MacOS/$APP_NAME"
  local sparkle_framework="$app_path/Contents/Frameworks/Sparkle.framework"
  local archs

  [ -x "$executable" ] || fail "Vox executable is missing or not executable"
  [ -d "$sparkle_framework" ] || fail "Sparkle.framework is missing from Contents/Frameworks"

  if ! otool -l "$executable" | grep -Fq "@executable_path/../Frameworks"; then
    fail "Vox executable is missing @executable_path/../Frameworks rpath"
  fi

  archs="$(lipo -archs "$executable")"
  if ! printf '%s\n' "$archs" | grep -Eq "(^|[[:space:]])$REQUIRED_ARCH($|[[:space:]])"; then
    fail "Vox executable does not contain required architecture $REQUIRED_ARCH: $archs"
  fi

  ok "Sparkle framework, rpath, and architecture validated"
}

validate_signing_and_notarization() {
  local app_path="$1"
  local dmg="$2"
  local signing_output

  codesign --verify --deep --strict --verbose=2 "$app_path" >/dev/null
  signing_output="$(codesign -dv --verbose=2 "$app_path" 2>&1 || true)"

  if [[ "$signing_output" != *"Authority=Developer ID Application:"* ]]; then
    printf '%s\n' "$signing_output" >&2
    fail "$APP_NAME.app is not signed with Developer ID Application"
  fi

  if [[ "$signing_output" == *$'\nTeamIdentifier=not set'* ]] || [[ "$signing_output" == "TeamIdentifier=not set"* ]]; then
    printf '%s\n' "$signing_output" >&2
    fail "$APP_NAME.app resolved to an ad-hoc signature"
  fi

  if ! truthy "$SKIP_GATEKEEPER_VALIDATION"; then
    spctl -a -vvv -t execute "$app_path" >/dev/null
  fi

  if ! truthy "$SKIP_NOTARIZATION_VALIDATION"; then
    xcrun stapler validate "$app_path" >/dev/null
    xcrun stapler validate "$dmg" >/dev/null
  fi

  ok "Developer ID signing validated"
}

copy_release_notes() {
  local archive_basename="$1"
  local release_notes_file="${VOX_RELEASE_NOTES_FILE:-}"
  local extension

  if [ -z "$release_notes_file" ]; then
    cat >"$SPARKLE_DIR/${archive_basename%.*}.md" <<NOTES
# Vox $VOX_RELEASE_VERSION

Internal Vox update.
NOTES
    return 0
  fi

  [ -f "$release_notes_file" ] || fail "release notes file is missing: $release_notes_file"
  extension="${release_notes_file##*.}"

  case "$extension" in
    html|md|txt)
      cp "$release_notes_file" "$SPARKLE_DIR/${archive_basename%.*}.$extension"
      ;;
    *)
      fail "release notes must be .html, .md, or .txt: $release_notes_file"
      ;;
  esac
}

create_update_zip() {
  local app_path="$1"
  local arch="$2"
  local output_zip="$SPARKLE_DIR/$APP_NAME-$VOX_RELEASE_VERSION-$arch.zip"
  local archive_basename

  rm -f "$output_zip"
  ditto -c -k --sequesterRsrc --keepParent "$app_path" "$output_zip"
  archive_basename="$(basename "$output_zip")"
  copy_release_notes "$archive_basename"
  printf '%s\n' "$output_zip"
}

github_release_download_prefix() {
  [ -n "$GITHUB_REPOSITORY_NAME" ] || fail "VOX_GITHUB_REPOSITORY or GITHUB_REPOSITORY is required"
  [ -n "${VOX_GITHUB_RELEASE_TAG:-}" ] || fail "VOX_GITHUB_RELEASE_TAG is required"
  printf 'https://github.com/%s/releases/download/%s/\n' "$GITHUB_REPOSITORY_NAME" "$VOX_GITHUB_RELEASE_TAG"
}

generate_appcast() {
  local download_url_prefix="$1"
  local appcast_path="$SPARKLE_DIR/$APPCAST_FILENAME"
  local args

  require_generate_appcast

  args=(
    --download-url-prefix "$download_url_prefix"
    --maximum-versions 1
    --maximum-deltas 0
    --embed-release-notes
    -o "$appcast_path"
  )

  if [ -n "${VOX_SPARKLE_PRIVATE_ED_KEY_FILE:-}" ]; then
    [ -f "$VOX_SPARKLE_PRIVATE_ED_KEY_FILE" ] || fail "Sparkle private key file is missing: $VOX_SPARKLE_PRIVATE_ED_KEY_FILE"
    args+=(--ed-key-file "$VOX_SPARKLE_PRIVATE_ED_KEY_FILE")
    "$SPARKLE_GENERATE_APPCAST" "${args[@]}" "$SPARKLE_DIR" >&2
  elif [ -n "${VOX_SPARKLE_PRIVATE_ED_KEY:-}" ]; then
    printf '%s' "$VOX_SPARKLE_PRIVATE_ED_KEY" | "$SPARKLE_GENERATE_APPCAST" "${args[@]}" --ed-key-file - "$SPARKLE_DIR" >&2
  else
    fail "set VOX_SPARKLE_PRIVATE_ED_KEY_FILE or VOX_SPARKLE_PRIVATE_ED_KEY"
  fi

  [ -f "$appcast_path" ] || fail "Sparkle appcast was not generated at $appcast_path"

  if ! truthy "$ALLOW_UNSIGNED_APPCAST" && ! grep -Fq "sparkle:edSignature=" "$appcast_path"; then
    fail "Sparkle appcast is missing an EdDSA signature; verify the app SUPublicEDKey and private key match"
  fi

  printf '%s\n' "$appcast_path"
}

write_dotenv() {
  local dmg="$1"
  local zip="$2"
  local appcast="$3"
  local arch="$4"

  cat >"$DOTENV_FILE" <<ENV
VOX_RELEASE_VERSION=$VOX_RELEASE_VERSION
VOX_BUNDLE_VERSION=$VOX_BUNDLE_VERSION
VOX_ARCH=$arch
VOX_DMG_PATH=${dmg#"$ROOT_DIR/"}
VOX_UPDATE_ZIP=${zip#"$ROOT_DIR/"}
VOX_APPCAST=${appcast#"$ROOT_DIR/"}
VOX_APPCAST_FILENAME=$APPCAST_FILENAME
VOX_FEED_URL=$VOX_FEED_URL
VOX_GITHUB_REPOSITORY=$GITHUB_REPOSITORY_NAME
VOX_GITHUB_RELEASE_TAG=$VOX_GITHUB_RELEASE_TAG
ENV
}

main() {
  local dmg
  local app_path
  local archive_arch
  local zip_path
  local appcast_path
  local download_url_prefix

  require_tool curl
  require_tool hdiutil
  require_tool codesign
  require_tool spctl
  require_tool xcrun
  require_tool ditto
  require_tool otool
  require_tool lipo
  require_tool swift

  rm -rf "$DIST_DIR"
  mkdir -p "$INPUT_DIR" "$SPARKLE_DIR"

  dmg="$(download_dmg)"
  MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vox-updates-mount.XXXXXX")"
  trap cleanup_mount EXIT

  log "Mounting $dmg"
  mount_dmg "$dmg" "$MOUNT_DIR"
  app_path="$(find_vox_app "$MOUNT_DIR")"

  validate_info_plist "$app_path"
  validate_frameworks_and_rpaths "$app_path"
  validate_signing_and_notarization "$app_path" "$dmg"

  archive_arch="$REQUIRED_ARCH"
  zip_path="$(create_update_zip "$app_path" "$archive_arch")"
  download_url_prefix="$(github_release_download_prefix)"
  appcast_path="$(generate_appcast "$download_url_prefix")"
  cp "$dmg" "$SPARKLE_DIR/$APP_NAME-$VOX_RELEASE_VERSION-$archive_arch.dmg"
  write_dotenv "$SPARKLE_DIR/$APP_NAME-$VOX_RELEASE_VERSION-$archive_arch.dmg" "$zip_path" "$appcast_path" "$archive_arch"

  ok "Prepared Sparkle update assets in $SPARKLE_DIR"
  ok "Wrote $DOTENV_FILE"
}

main "$@"
