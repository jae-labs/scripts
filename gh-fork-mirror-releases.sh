#!/bin/bash

# Description:
#   Mirrors all releases (including assets and release notes)
#   from the upstream (parent) repository to the current fork.
#   Ensures all tags/releases are present in the fork, and
#   sets the correct 'latest' release tag.
#
# Usage:
#   ./gh-fork-mirror-releases.sh
#
# Requirements:
#   - GitHub CLI (gh) installed and authenticated
#   - jq
#   - Run inside a git repository that is a fork
#
# Notes:
#   - Only mirrors releases that do not already exist in the fork
#   - Does not overwrite existing releases in the fork
#   - The script will set the correct 'latest' tag at the end

echo "Detecting repository details..."

# Ensure gh is set to the current repository
gh repo set-default $(git remote get-url origin)

# 1. Get the current repository (The Fork)
# CHANGE: Use 'nameWithOwner' instead of 'full_name'
FORK=$(gh repo view --json nameWithOwner -q ".nameWithOwner")

# 2. Get the parent repository (The Upstream)
# CHANGE: Request 'parent', then extract 'nameWithOwner' from it
UPSTREAM=$(gh repo view $(git remote get-url origin) --json parent -q '.parent | "\(.owner.login)/\(.name)"')

# Verification
if [ -z "$FORK" ]; then
  echo "Error: Could not detect current repository. Are you inside a git repo?"
  exit 1
fi

if [ -z "$UPSTREAM" ]; then
  echo "Error: Repository '$FORK' is not a fork (no upstream found)."
  exit 1
fi

echo "Detected Fork:     $FORK"
echo "Detected Upstream: $UPSTREAM"

# 1. Identify the TRUE latest release from upstream
echo "Checking upstream for the real 'latest' release..."
TRUE_LATEST=$(gh release view -R "$UPSTREAM" --json tagName -q ".tagName")
echo "The correct latest tag is: $TRUE_LATEST"

# 2. Get list of ALL tags
TAGS=$(gh release list -R "$UPSTREAM" --limit 1000 --json tagName --jq '.[].tagName')

mkdir -p temp_mirror_assets

for TAG in $TAGS; do
  # Skip if exists
  if gh release view "$TAG" -R "$FORK" >/dev/null 2>&1; then
    echo "$TAG exists. Skipping."
    continue
  fi

  echo "Mirroring $TAG..."

  # Fetch metadata
  gh release view "$TAG" -R "$UPSTREAM" --json name,body,isPrerelease >release_meta.json
  TITLE=$(jq -r .name release_meta.json)
  IS_PRERELEASE=$(jq -r .isPrerelease release_meta.json)
  jq -r .body release_meta.json >release_notes.txt

  # Download assets
  rm -f temp_mirror_assets/*
  gh release download "$TAG" -R "$UPSTREAM" -D temp_mirror_assets || true

  # Prepare flags
  FLAGS="--latest=false" # <--- CRITICAL: Force this to NOT be latest
  if [ "$IS_PRERELEASE" = "true" ]; then
    FLAGS="$FLAGS --prerelease"
  fi

  # Create release
  if [ "$(ls -A temp_mirror_assets)" ]; then
    gh release create "$TAG" temp_mirror_assets/* \
      -R "$FORK" \
      --title "$TITLE" \
      --notes-file release_notes.txt \
      $FLAGS
  else
    gh release create "$TAG" \
      -R "$FORK" \
      --title "$TITLE" \
      --notes-file release_notes.txt \
      $FLAGS
  fi
done

# 3. Final Step: Restore the correct 'Latest' tag
echo "------------------------------------------------"
echo "Fixing 'Latest' tag to point to $TRUE_LATEST..."
gh release edit "$TRUE_LATEST" -R "$FORK" --latest

# Cleanup
rm -rf temp_mirror_assets release_meta.json release_notes.txt
echo "Done! All releases mirrored and 'latest' is set correctly."
