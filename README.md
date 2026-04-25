# Vox

Source-free Sparkle update publication for Vox.

This repository intentionally does not contain Vox application source code. It receives a signed and notarized Vox DMG, validates the app bundle on a macOS runner, creates the ZIP payload Sparkle should install, generates a signed `appcast.xml`, and uploads the update assets to GitHub Releases.

## Repository Roles

- `/Users/francisbourre/vox`: source repository, builds the Sparkle-ready signed and notarized app/DMG.
- `FrancisBourre/Vox`: public update repository, publishes Sparkle update metadata and archives.

The app must already contain Sparkle, `SUFeedURL`, and `SUPublicEDKey` before it reaches this repository. This repository must not mutate, re-sign, or re-notarize `Vox.app`.

## Required Secret

Add this GitHub Actions secret:

| Secret | Required | Notes |
| --- | --- | --- |
| `VOX_SPARKLE_PRIVATE_ED_KEY` | Yes | Sparkle private EdDSA key used by `generate_appcast`. Do not commit it. |

The app-side release build must embed:

```text
SUFeedURL = https://github.com/FrancisBourre/Vox/releases/latest/download/appcast.xml
SUPublicEDKey = S45U2pv76YeCkCHHKTaZjLyDMa0soVvDyMRhJOo9JCc=
```

## Publish Flow

Run the `Publish Sparkle Update` workflow manually with:

| Input | Required | Notes |
| --- | --- | --- |
| `dmg_url` | Yes | Public or authenticated HTTPS URL to the signed and notarized Vox DMG. |
| `release_notes_file` | Optional | Path to committed `.md`, `.html`, or `.txt` release notes in this repository. |
| `release_notes_url` | Optional | HTTPS URL to `.md`, `.html`, or `.txt` release notes. Used by the private Vox source wrapper. |
| `verify_public_access` | Yes | Keep enabled for production. It verifies appcast and ZIP access without credentials. |

The workflow publishes:

- `Vox-<version>-<arch>.zip`
- `Vox-<version>-<arch>.dmg`
- `appcast.xml`

The installed app fetches:

```text
https://github.com/FrancisBourre/Vox/releases/latest/download/appcast.xml
```

The appcast points at the versioned ZIP on the matching release tag:

```text
https://github.com/FrancisBourre/Vox/releases/download/v<version>/Vox-<version>-<arch>.zip
```

## Local Dry Run

From this repository:

```sh
VOX_DMG_PATH=/path/to/Vox.dmg \
VOX_SPARKLE_PRIVATE_ED_KEY_FILE=/path/to/private-key.txt \
VOX_EXPECTED_FEED_URL=https://github.com/FrancisBourre/Vox/releases/latest/download/appcast.xml \
VOX_EXPECTED_PUBLIC_ED_KEY=S45U2pv76YeCkCHHKTaZjLyDMa0soVvDyMRhJOo9JCc= \
VOX_GITHUB_REPOSITORY=FrancisBourre/Vox \
VOX_RELEASE_NOTES_URL=https://example.com/Vox-0.2.0.md \
./ci/prepare-sparkle-update.sh
```

Publication dry run:

```sh
./ci/publish-github-release.sh --dry-run
```

## Notes

Sparkle signatures protect update integrity. GitHub is only the public transport for `appcast.xml`, ZIP, and optional manual-install DMG.
