#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${VOX_DIST_DIR:-$ROOT_DIR/dist}"
DOTENV_FILE="${VOX_RELEASE_DOTENV:-$DIST_DIR/release.env}"
DRY_RUN=0

usage() {
  cat <<'EOF'
usage: ./ci/publish-github-release.sh [--dry-run]

Uploads prepared Vox Sparkle update assets to a GitHub Release.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
  shift
done

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

source_dotenv() {
  [ -f "$DOTENV_FILE" ] || fail "release dotenv is missing: $DOTENV_FILE"
  set -a
  # shellcheck disable=SC1090
  . "$DOTENV_FILE"
  set +a
}

repo_asset_url() {
  local file_name="$1"
  printf 'https://github.com/%s/releases/download/%s/%s\n' "$VOX_GITHUB_REPOSITORY" "$VOX_GITHUB_RELEASE_TAG" "$file_name"
}

latest_appcast_url() {
  printf 'https://github.com/%s/releases/latest/download/%s\n' "$VOX_GITHUB_REPOSITORY" "$VOX_APPCAST_FILENAME"
}

verify_public_url() {
  local url="$1"
  local output
  local status

  output="$(mktemp)"
  status="$(curl --silent --location --output "$output" --write-out '%{http_code}' "$url" || true)"
  if [ "$status" != "200" ]; then
    cat "$output" >&2 || true
    rm -f "$output"
    fail "public URL is not reachable without credentials: $url ($status)"
  fi
  rm -f "$output"
}

release_notes_file() {
  local generated_notes="${VOX_UPDATE_ZIP%.*}.md"

  if [ -n "${VOX_RELEASE_NOTES_FILE:-}" ]; then
    printf '%s\n' "$VOX_RELEASE_NOTES_FILE"
  elif [ -f "$generated_notes" ]; then
    printf '%s\n' "$generated_notes"
  else
    printf '%s\n' ""
  fi
}

validate_inputs() {
  VOX_DMG_PATH="$ROOT_DIR/${VOX_DMG_PATH#"$ROOT_DIR/"}"
  VOX_UPDATE_ZIP="$ROOT_DIR/${VOX_UPDATE_ZIP#"$ROOT_DIR/"}"
  VOX_APPCAST="$ROOT_DIR/${VOX_APPCAST#"$ROOT_DIR/"}"

  [ -n "${VOX_GITHUB_REPOSITORY:-}" ] || fail "VOX_GITHUB_REPOSITORY is missing"
  [ -n "${VOX_GITHUB_RELEASE_TAG:-}" ] || fail "VOX_GITHUB_RELEASE_TAG is missing"
  [ -n "${VOX_RELEASE_VERSION:-}" ] || fail "VOX_RELEASE_VERSION is missing"
  [ -f "$VOX_DMG_PATH" ] || fail "DMG is missing: $VOX_DMG_PATH"
  [ -f "$VOX_UPDATE_ZIP" ] || fail "Sparkle ZIP is missing: $VOX_UPDATE_ZIP"
  [ -f "$VOX_APPCAST" ] || fail "appcast is missing: $VOX_APPCAST"
}

publish_release() {
  local title="Vox $VOX_RELEASE_VERSION"
  local notes_file
  local assets=("$VOX_UPDATE_ZIP" "$VOX_APPCAST" "$VOX_DMG_PATH")

  notes_file="$(release_notes_file)"

  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'dry-run release: %s %s\n' "$VOX_GITHUB_REPOSITORY" "$VOX_GITHUB_RELEASE_TAG"
    printf 'dry-run upload: %s -> %s\n' "$VOX_UPDATE_ZIP" "$(repo_asset_url "$(basename "$VOX_UPDATE_ZIP")")"
    printf 'dry-run upload: %s -> %s\n' "$VOX_APPCAST" "$(repo_asset_url "$(basename "$VOX_APPCAST")")"
    printf 'dry-run upload: %s -> %s\n' "$VOX_DMG_PATH" "$(repo_asset_url "$(basename "$VOX_DMG_PATH")")"
    return 0
  fi

  if gh release view "$VOX_GITHUB_RELEASE_TAG" --repo "$VOX_GITHUB_REPOSITORY" >/dev/null 2>&1; then
    gh release upload "$VOX_GITHUB_RELEASE_TAG" "${assets[@]}" --repo "$VOX_GITHUB_REPOSITORY" --clobber
  else
    if [ -n "$notes_file" ]; then
      gh release create "$VOX_GITHUB_RELEASE_TAG" "${assets[@]}" \
        --repo "$VOX_GITHUB_REPOSITORY" \
        --title "$title" \
        --notes-file "$notes_file"
    else
      gh release create "$VOX_GITHUB_RELEASE_TAG" "${assets[@]}" \
        --repo "$VOX_GITHUB_REPOSITORY" \
        --title "$title" \
        --notes "Internal Vox update."
    fi
  fi
}

main() {
  require_tool curl
  require_tool gh
  source_dotenv
  validate_inputs

  log "Publishing $VOX_GITHUB_RELEASE_TAG to $VOX_GITHUB_REPOSITORY"
  publish_release

  if truthy "${VOX_VERIFY_PUBLIC_ACCESS:-0}"; then
    verify_public_url "$(latest_appcast_url)"
    verify_public_url "$(repo_asset_url "$(basename "$VOX_UPDATE_ZIP")")"
  fi

  ok "GitHub release assets are ready"
}

main "$@"
