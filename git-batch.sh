#!/usr/bin/env bash

# Description: This script processes multiple Git repositories by performing the following operations:
# 1. Pulls the latest changes on the default branch
# 2. Optionally creates directories
# 3. Copies source files/directories to specified destinations
# 4. Creates a new branch
# 5. Commits changes
# 6. Pushes the branch
# 7. Creates a pull request
#
# Usage:
# Initial run: ./git-batch.sh
# Rerun: ./git-batch.sh <state_file> (resumes non-interactively with saved inputs)
#
# Arguments:
# <state_file> (optional): Path to a JSON state file to resume processing from a previous run.
#   When provided, loads all inputs and resumes with remaining folders non-interactively.
#
# The script interactively prompts for inputs on initial run.
# On rerun with a state file, it loads all inputs and runs non-interactively.
# State is saved after inputs are collected and after each successful repository processing,
# allowing resumption in case of failures.
#
# Requirements:
# - Git
# - GitHub CLI (gh) installed and authenticated
# - jq

set -e

PR_LIST=()

STATE_FILE="git-batch-state.json"
IS_RERUN=0

if [ $# -eq 1 ]; then
  STATE_FILE="$1"
  if [ -f "$STATE_FILE" ]; then
    IS_RERUN=1
    # Load state from JSON
    FOLDERS=($(jq -r '.folders[]' "$STATE_FILE"))
    MKDIR_PATH=$(jq -r '.mkdir_path' "$STATE_FILE")
    COPY_SOURCES=($(jq -r '.copy_sources[]' "$STATE_FILE"))
    COPY_DEST=$(jq -r '.copy_dest' "$STATE_FILE")
    BRANCH_NAME=$(jq -r '.branch_name' "$STATE_FILE")
    COMMIT_MSG=$(jq -r '.commit_msg' "$STATE_FILE")
    PR_TITLE=$(jq -r '.pr_title' "$STATE_FILE")
    PR_BODY=$(jq -r '.pr_body' "$STATE_FILE")
    PROCESSED_REPOS=($(jq -r '.processed_repos[]' "$STATE_FILE"))
    FULL_SOURCES=()
    for SRC in "${COPY_SOURCES[@]}"; do
      if [[ "$SRC" != /* ]]; then
        SRC="$(pwd)/$SRC"
      fi
      FULL_SOURCES+=("$SRC")
    done
    # Filter FOLDERS to exclude processed repos
    NEW_FOLDERS=()
    for DIR in "${FOLDERS[@]}"; do
      if [[ ! " ${PROCESSED_REPOS[*]} " =~ " $DIR " ]]; then
        NEW_FOLDERS+=("$DIR")
      fi
    done
    FOLDERS=("${NEW_FOLDERS[@]}")

    # Re-validate folders on rerun
    INVALID=()
    for DIR in "${FOLDERS[@]}"; do
      if [ ! -d "$DIR" ] || [ ! -d "$DIR/.git" ]; then
        INVALID+=("$DIR")
        continue
      fi
      if [ -n "$(git -C "$DIR" status --porcelain)" ]; then
        INVALID+=("$DIR")
        continue
      fi
      # Detect default branch
      DEFAULT_BRANCH=$(git -C "$DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
      # Check for unpushed commits
      if [ -n "$(git -C "$DIR" log --oneline origin/"$DEFAULT_BRANCH"..HEAD 2>/dev/null)" ]; then
        INVALID+=("$DIR")
        continue
      fi
    done

    if [ ${#INVALID[@]} -gt 0 ]; then
      echo "The following folders are invalid on rerun (not directories, no .git, not clean, or have unpushed commits):"
      printf '%s\n' "${INVALID[@]}"
      exit 1
    fi

    if [ ${#FOLDERS[@]} -eq 0 ]; then
      echo "All target folders have already been processed."
      exit 0
    fi

    if [ ${#COPY_SOURCES[@]} -eq 0 ]; then
      echo "No source files in state."
      exit 1
    fi
  else
    echo "State file not found: $STATE_FILE"
    exit 1
  fi
fi

save_state() {
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  jq -n \
    --argjson folders "$(printf '%s\n' "${FOLDERS[@]}" | jq -R . | jq -s .)" \
    --arg mkdir_path "$MKDIR_PATH" \
    --argjson copy_sources "$(printf '%s\n' "${COPY_SOURCES[@]}" | jq -R . | jq -s .)" \
    --arg copy_dest "$COPY_DEST" \
    --arg branch_name "$BRANCH_NAME" \
    --arg commit_msg "$COMMIT_MSG" \
    --arg pr_title "$PR_TITLE" \
    --arg pr_body "$PR_BODY" \
    --argjson processed_repos "$(printf '%s\n' "${PROCESSED_REPOS[@]}" | jq -R . | jq -s .)" \
    '{folders: $folders, mkdir_path: $mkdir_path, copy_sources: $copy_sources, copy_dest: $copy_dest, branch_name: $branch_name, commit_msg: $commit_msg, pr_title: $pr_title, pr_body: $pr_body, processed_repos: $processed_repos}' >"$SCRIPT_DIR/$STATE_FILE"
}

echo "This script processes multiple Git repositories: it pulls the latest changes on the default branch,"
echo "optionally creates a directory, copies a source file/directory, creates a new branch, and commits the changes."
echo ""

if [ $# -eq 0 ]; then
  while true; do
    echo "Paste Git repository folder paths (one per line) to process as targets:"
    echo "When finished, press Ctrl+D (or Ctrl+C to cancel):"
    mapfile -t FOLDERS

    if [ ${#FOLDERS[@]} -eq 0 ]; then
      echo "No folders provided."
      exit 1
    fi

    declare -A seen_folders
    duplicates_folders=()
    for DIR in "${FOLDERS[@]}"; do
      if [ -n "${seen_folders[$DIR]}" ]; then
        duplicates_folders+=("$DIR")
      else
        seen_folders[$DIR]=1
      fi
    done
    if [ ${#duplicates_folders[@]} -gt 0 ]; then
      echo "Duplicate target folders found: ${duplicates_folders[*]}"
      exit 1
    fi

    INVALID=()
    for DIR in "${FOLDERS[@]}"; do
      if [ ! -d "$DIR" ] || [ ! -d "$DIR/.git" ]; then
        INVALID+=("$DIR")
        continue
      fi
      if [ -n "$(git -C "$DIR" status --porcelain)" ]; then
        INVALID+=("$DIR")
        continue
      fi
      # Detect default branch
      DEFAULT_BRANCH=$(git -C "$DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
      # Check for unpushed commits
      if [ -n "$(git -C "$DIR" log --oneline origin/"$DEFAULT_BRANCH"..HEAD 2>/dev/null)" ]; then
        INVALID+=("$DIR")
        continue
      fi
    done

    if [ ${#INVALID[@]} -eq 0 ]; then
      break
    else
      echo "The following are invalid (not directories, no .git, not clean, or have unpushed commits):"
      printf '%s\n' "${INVALID[@]}"
      echo "Please try again."
    fi
  done
fi

if [ $# -eq 0 ]; then
  read -p "Enter directory path to create on targets e.g. .github/workflows/ (leave empty to skip): " MKDIR_PATH

  while true; do
    echo "Paste source file/directory paths (one per line) to copy:"
    echo "When finished, press Ctrl+D (or Ctrl+C to cancel):"
    mapfile -t COPY_SOURCES

    FULL_SOURCES=()
    INVALID=()
    declare -A seen_sources
    duplicates_sources=()
    for SRC in "${COPY_SOURCES[@]}"; do
      if [[ "$SRC" != /* ]]; then
        SRC="$(pwd)/$SRC"
      fi
      if [ -e "$SRC" ]; then
        if [ -n "${seen_sources[$SRC]}" ]; then
          duplicates_sources+=("$SRC")
        else
          seen_sources[$SRC]=1
          FULL_SOURCES+=("$SRC")
        fi
      else
        INVALID+=("$SRC")
      fi
    done

    if [ ${#duplicates_sources[@]} -gt 0 ]; then
      echo "Duplicate source files/folders found: ${duplicates_sources[*]}"
      exit 1
    fi

    if [ ${#INVALID[@]} -eq 0 ]; then
      break
    else
      echo "The following sources do not exist:"
      printf '%s\n' "${INVALID[@]}"
      echo "Please try again."
    fi
  done

  if [ ${#FULL_SOURCES[@]} -eq 0 ]; then
    echo "No source files provided."
    exit 1
  fi

  read -p "Enter destination path (relative to target repo root, e.g. .github/workflows/): " COPY_DEST

  read -p "Enter a new unique branch name: " BRANCH_NAME
  read -p "Enter git commit message: " COMMIT_MSG
  read -p "Enter PR title: " PR_TITLE
  read -p "Enter PR description/body: " PR_BODY
fi

if [ -z "${PROCESSED_REPOS+x}" ]; then
  PROCESSED_REPOS=()
fi
save_state

for DIR in "${FOLDERS[@]}"; do
  echo "----------------------------------------"
  echo "Processing: $DIR"

  cd "$DIR"

  # Detect default branch (main or master)
  DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")

  echo "Checking out $DEFAULT_BRANCH..."
  git checkout "$DEFAULT_BRANCH"

  echo "Pulling latest changes..."
  git pull

  echo "Creating and switching to branch: $BRANCH_NAME"
  if [ $IS_RERUN -eq 1 ]; then
    git checkout "$BRANCH_NAME" || git checkout -b "$BRANCH_NAME"
  else
    git checkout -b "$BRANCH_NAME"
  fi

  if [ -n "$MKDIR_PATH" ]; then
    echo "Creating directory: $MKDIR_PATH"
    mkdir -p "$MKDIR_PATH"
  fi

  for SRC in "${FULL_SOURCES[@]}"; do
    echo "Copying $SRC to $COPY_DEST"
    cp -R "$SRC" "$COPY_DEST"
  done

  echo "Adding changes..."
  git add .

  echo "Committing..."
  git commit --allow-empty -m "$COMMIT_MSG"

  echo "Pushing branch $BRANCH_NAME..."
  git push origin "$BRANCH_NAME"

  echo "Creating PR..."
  PR_URL=$(gh pr create --title "$PR_TITLE" --body "$PR_BODY" --base "$DEFAULT_BRANCH" --head "$BRANCH_NAME")
  PR_JSON=$(gh pr view "$PR_URL" --json url,number,title)
  PR_LIST+=("$PR_JSON")

  PROCESSED_REPOS+=("$DIR")
  save_state

  cd - >/dev/null
done

if [ ${#PR_LIST[@]} -gt 0 ]; then
  echo "Created PRs:"
  for PR_JSON in "${PR_LIST[@]}"; do
    TITLE=$(echo "$PR_JSON" | jq -r '.title')
    URL=$(echo "$PR_JSON" | jq -r '.url')
    echo "PR Title: $TITLE"
    echo "$URL"
    echo ""
  done
fi

echo "All done."
