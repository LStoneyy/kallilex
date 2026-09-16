#!/usr/bin/env bash
#
# Assembles the Tauri updater manifest (latest.json) for a release from the
# minisign .sig files produced by the release workflow's build jobs.
#
# Usage: scripts/build-update-manifest.sh <tag> <sig-dir> > latest.json
#
# Must run on both macOS's bash 3.2 and Linux's bash: no associative arrays,
# no `${var,,}`.

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: scripts/build-update-manifest.sh <tag> <sig-dir> > latest.json" >&2
  exit 2
fi

tag="$1"
sig_dir="$2"
repo_url="https://github.com/LStoneyy/kallilex"
version="${tag#v}"

macos_asset="Kallilex-${tag}-macos-universal.app.tar.gz"
linux_asset="Kallilex-${tag}-linux-x86_64.AppImage"
windows_asset="Kallilex-${tag}-windows-x86_64-setup.exe"

macos_sig_file="$sig_dir/$macos_asset.sig"
linux_sig_file="$sig_dir/$linux_asset.sig"
windows_sig_file="$sig_dir/$windows_asset.sig"

# Check every required signature exists and is non-empty before producing any
# output. A partial manifest would leave one platform "available but not
# installable" forever, since the app only re-checks on its own schedule.
missing=0
for f in "$macos_sig_file" "$linux_sig_file" "$windows_sig_file"; do
  if [ ! -s "$f" ]; then
    echo "error: missing signature file $f" >&2
    missing=1
  fi
done
[ "$missing" -eq 0 ] || exit 1

# Command substitution strips the trailing newline; each .sig file holds a
# single base64 line, which is exactly what the manifest's signature field
# must contain.
macos_sig="$(cat "$macos_sig_file")"
linux_sig="$(cat "$linux_sig_file")"
windows_sig="$(cat "$windows_sig_file")"

pub_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

macos_url="$repo_url/releases/download/$tag/$macos_asset"
linux_url="$repo_url/releases/download/$tag/$linux_asset"
windows_url="$repo_url/releases/download/$tag/$windows_asset"

# deb/rpm are notify-only for the updater (it installs the AppImage on
# Linux), so they are intentionally absent from the manifest.
jq -n \
  --arg version "$version" \
  --arg notes "$repo_url/releases/tag/$tag" \
  --arg pub_date "$pub_date" \
  --arg macos_url "$macos_url" \
  --arg macos_sig "$macos_sig" \
  --arg linux_url "$linux_url" \
  --arg linux_sig "$linux_sig" \
  --arg windows_url "$windows_url" \
  --arg windows_sig "$windows_sig" \
  '{
    version: $version,
    notes: $notes,
    pub_date: $pub_date,
    platforms: {
      "darwin-aarch64": { url: $macos_url, signature: $macos_sig },
      "darwin-x86_64": { url: $macos_url, signature: $macos_sig },
      "linux-x86_64": { url: $linux_url, signature: $linux_sig },
      "windows-x86_64": { url: $windows_url, signature: $windows_sig }
    }
  }'
