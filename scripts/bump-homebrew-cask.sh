#!/usr/bin/env bash
#
# Bumps the `version` and `sha256` lines of a Homebrew cask file to match a
# newly published stable release of this app. Refuses to run on anything
# that looks wrong: a malformed version/sha256, a missing cask file, a cask
# missing the lines it expects to rewrite, a same-version checksum mismatch,
# or a version that would go backwards.
#
# Usage: scripts/bump-homebrew-cask.sh <cask-file> <version> <sha256>
#
# Must run on both macOS's bash 3.2 and Linux's bash: no associative arrays,
# no `${var,,}`.

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: scripts/bump-homebrew-cask.sh <cask-file> <version> <sha256>" >&2
  exit 2
fi

cask_file="$1"
new_version="$2"
new_sha256="$3"

if [ ! -f "$cask_file" ]; then
  echo "error: cask file '$cask_file' does not exist" >&2
  exit 2
fi

# No leading zeros: 0.09.0 would compare equal to 0.9.0 numerically but not
# as a string, and slip past the same-version check below.
if ! [[ "$new_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "error: version must look like X.Y.Z, got '$new_version'" >&2
  exit 2
fi

if ! [[ "$new_sha256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "error: sha256 must be 64 lowercase hex characters, got '$new_sha256'" >&2
  exit 2
fi

# Compares two dotted X.Y.Z versions numerically per component. Echoes the
# result on stdout: -1 if v1 < v2, 0 if equal, 1 if v1 > v2. `sort -V` is not
# reliably available on macOS's older sort, so this is done by hand.
compare_versions() {
  local v1="$1" v2="$2"
  local v1_major v1_minor v1_patch v2_major v2_minor v2_patch rest

  v1_major="${v1%%.*}"
  rest="${v1#*.}"
  v1_minor="${rest%%.*}"
  v1_patch="${rest#*.}"

  v2_major="${v2%%.*}"
  rest="${v2#*.}"
  v2_minor="${rest%%.*}"
  v2_patch="${rest#*.}"

  if [ "$v1_major" -lt "$v2_major" ]; then echo -1; return; fi
  if [ "$v1_major" -gt "$v2_major" ]; then echo 1; return; fi
  if [ "$v1_minor" -lt "$v2_minor" ]; then echo -1; return; fi
  if [ "$v1_minor" -gt "$v2_minor" ]; then echo 1; return; fi
  if [ "$v1_patch" -lt "$v2_patch" ]; then echo -1; return; fi
  if [ "$v1_patch" -gt "$v2_patch" ]; then echo 1; return; fi
  echo 0
}

current_version="$(sed -n 's/^  version "\(.*\)"$/\1/p' "$cask_file" | head -n1)"
if [ -z "$current_version" ]; then
  echo "error: no '  version \"...\"' line found in $cask_file" >&2
  exit 1
fi

current_sha256="$(sed -n 's/^  sha256 "\(.*\)"$/\1/p' "$cask_file" | head -n1)"
if [ -z "$current_sha256" ]; then
  echo "error: no '  sha256 \"...\"' line found in $cask_file" >&2
  exit 1
fi

if [ "$current_version" = "$new_version" ]; then
  if [ "$current_sha256" = "$new_sha256" ]; then
    echo "already at $new_version" >&2
    exit 0
  fi
  echo "error: $cask_file is already at version $new_version but with a different sha256 (current: $current_sha256, new: $new_sha256) — refusing to overwrite" >&2
  exit 1
fi

if [ "$(compare_versions "$new_version" "$current_version")" -lt 0 ]; then
  echo "error: new version $new_version is older than the current version $current_version in $cask_file" >&2
  exit 1
fi

tmp_file="$cask_file.tmp.$$"
trap 'rm -f "$tmp_file"' EXIT

sed \
  -e "s/^  version \".*\"\$/  version \"$new_version\"/" \
  -e "s/^  sha256 \".*\"\$/  sha256 \"$new_sha256\"/" \
  "$cask_file" > "$tmp_file"
mv "$tmp_file" "$cask_file"
trap - EXIT

if ! grep -qF "  version \"$new_version\"" "$cask_file"; then
  echo "error: failed to write the new version line into $cask_file" >&2
  exit 1
fi
if ! grep -qF "  sha256 \"$new_sha256\"" "$cask_file"; then
  echo "error: failed to write the new sha256 line into $cask_file" >&2
  exit 1
fi

echo "bumped $cask_file from $current_version to $new_version" >&2
