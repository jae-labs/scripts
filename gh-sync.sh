#!/bin/bash

# Description: Clones and pulls all repositories from your GitHub organizations
#              and personal account to local folders. Useful for batch updating
#              or keeping a local mirror of all your repos.
# Usage: ./gh-sync.sh [--include-archived] [--remove-inexistent]
#
# Requirements:
# - Git
# - gh (GitHub CLI, authenticated via `gh auth login`)
# - jq

# Note: Not using set -e to allow parallel operations to continue even if some fail

show_help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Clones and pulls all repositories from your GitHub organizations and personal
account to local folders. Useful for batch updating or keeping a local mirror.

Options:
  --include-archived            Include archived repositories (skipped by default)
  --remove-inexistent           Delete local folders whose remote repo no longer exists
                                Without this flag, a dry-run is always performed showing
                                what would be removed.
  -h, --help                    Show this help message and exit

Requirements:
  git   Git CLI
  gh    GitHub CLI, authenticated via \`gh auth login\`
  jq    JSON processor

Examples:
  $(basename "$0")
  $(basename "$0") --include-archived
  $(basename "$0") --remove-inexistent
  $(basename "$0") --include-archived --remove-inexistent
EOF
}

# Function to fetch all paginated results from GitHub API
fetch_github_repos() {
  local base_url=$1
  # Strip the base API URL prefix for gh api (it expects a path, not a full URL)
  local api_path="${base_url#https://api.github.com/}"

  # gh api --paginate fetches all pages automatically
  gh api --paginate -H "Accept: application/vnd.github.inertia-preview+json" \
    "$api_path" \
    --jq '.[] | [.ssh_url, (.archived|tostring)] | @tsv' 2>/dev/null
}

# Function to clone repos from an API endpoint into a target directory
clone_repos() {
  local api_url=$1
  local target_dir=$2
  local include_archived=$3  # pass "--include-archived" to include archived repos
  local remove_inexistent=$4  # pass "--remove-inexistent" to delete; omit for dry-run

  echo "Cloning repos from $api_url to $target_dir"
  mkdir -p "$target_dir"
  cd "$target_dir"

  local -a repo_urls=()
  local -a remote_names=()
  while IFS=$'\t' read -r url archived; do
    if [[ "$include_archived" == "--include-archived" || "$archived" == "false" ]]; then
      repo_urls+=("$url")
      local name
      name=$(echo "$url" | awk -F ":" '{ print $2}' | awk -F "/" '{ print $2 }' | sed 's/.git$//g')
      remote_names+=("$name")
    fi
  done < <(fetch_github_repos "$api_url")
  for repo_url in "${repo_urls[@]}"; do
    local folder
    folder=$(echo "$repo_url" | awk -F ":" '{ print $2}' | awk -F "/" '{ print $2 }' | sed 's/.git$//g')
    mkdir -p "$folder"
    echo "$repo_url"
    if ! git clone "$repo_url" "$folder" 2>&1 | grep -v "already exists and is not an empty directory"; then
      :
    fi
  done

  for local_dir in "$target_dir"/*/; do
    [[ -d "$local_dir" ]] || continue
    local dir_name
    dir_name=$(basename "$local_dir")
    local found=0
    for remote_name in "${remote_names[@]}"; do
      if [[ "$dir_name" == "$remote_name" ]]; then
        found=1
        break
      fi
    done
    if [[ $found -eq 0 ]]; then
      if [[ "$remove_inexistent" == "--remove-inexistent" ]]; then
        echo "Removing local folder not found on remote: $local_dir"
        rm -rf "$local_dir"
      else
        echo "[dry-run] Would remove local folder not found on remote: $local_dir"
      fi
    fi
  done
}

# Parse arguments
INCLUDE_ARCHIVED=""
REMOVE_INEXISTENT=""
for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    show_help
    exit 0
  fi
  if [[ "$arg" == "--include-archived" ]]; then
    INCLUDE_ARCHIVED="--include-archived"
  fi
  if [[ "$arg" == "--remove-inexistent" ]]; then
    REMOVE_INEXISTENT="--remove-inexistent"
  fi
done

# Fetch all organizations the user is part of
echo "Discovering GitHub organizations..."
ORGS=$(gh api --paginate user/orgs --jq '.[].login')

# Clone org repositories
declare -a ORG_FOLDERS=()

for org in $ORGS; do
  echo "Found organization: $org"
  clone_repos "https://api.github.com/orgs/$org/repos" "${HOME}/gh_${org}" "$INCLUDE_ARCHIVED" "$REMOVE_INEXISTENT"
  ORG_FOLDERS+=("${HOME}/gh_${org}")
done

# Use authenticated /user/repos so private personal repos are included; limit to repos you own
clone_repos "https://api.github.com/user/repos?visibility=all&affiliation=owner" "${HOME}/gh_personal" "$INCLUDE_ARCHIVED" "$REMOVE_INEXISTENT"

echo ""
echo ">>> GIT Pulling..."
echo ""

# Folders to pull - combine org folders with personal folder
FOLDERS=("${ORG_FOLDERS[@]}" "${HOME}/gh_personal")

# Collect all git directories first
declare -a GIT_DIRS=()
for i in "${FOLDERS[@]}"; do
  echo "Scanning folder: $i"
  local_count=0
  while IFS= read -r dir; do
    GIT_DIRS+=("$dir")
    ((local_count++))
  done < <(find -L "$i" -name .git -type d 2>/dev/null | sed 's/.git$//g')
  echo "Found $local_count repos in $i"
done

echo "Total repos to pull: ${#GIT_DIRS[@]}"
echo ""

# Run git operations in parallel on all directories
printf '%s\n' "${GIT_DIRS[@]}" | parallel --will-cite --halt never -j 32 "echo \"Pulling: {}\" && cd {} && git remote prune origin >/dev/null 2>&1; (git checkout main >/dev/null 2>&1 || git checkout master >/dev/null 2>&1 || git checkout latest >/dev/null 2>&1 || git checkout dev >/dev/null 2>&1 || true); git pull >/dev/null 2>&1 || echo \">>> FAILED: {}\""

# Remove all branches other than main locally, garbage collection, display git ignored files
#git branch | grep -v \"main\" | xargs git branch -D | git gc | git clean -xdn
