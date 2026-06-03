#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

function error() {
  echo -e "${RED}[ERROR] $* ${NC}" >&2
}

fetch_github_path() {
  local user="$1"
  local repo="$2"
  local branch="$3"
  local path="$4"
  local current_dir="${5:-.}"

  local api_url="https://api.github.com/repos/$user/$repo/contents/$path?ref=$branch"

  local response=$(curl -s -w "\n%{http_code}" "$api_url")
  local http_code=$(echo "$response" | tail -n1)
  local json_body=$(echo "$response" | sed '$d')

  if [ "$http_code" -ne 200 ]; then
    error "API Error: Received status code $http_code"
    return 1
  fi

  local type=$(echo "$json_body" | jq -r 'type')
  if [ "$type" == "object" ]; then
    local file_name=$(echo "$json_body" | jq -r '.name')
    local download_url=$(echo "$json_body" | jq -r '.download_url')

    echo "Downloading file: $current_dir/$file_name"
    mkdir -p "$current_dir"
    curl -s -L "$download_url" -o "$current_dir/$file_name"
  elif [ "$type" == "array" ]; then
    echo "$json_body" | jq -c '.[]' | while read -r item; do
      local item_type=$(echo "$item" | jq -r '.type')
      local item_name=$(echo "$item" | jq -r '.name')
      local item_path=$(echo "$item" | jq -r '.path')

      if [ "$item_type" == "file" ]; then
        local download_url=$(echo "$item" | jq -r '.download_url')
        echo "Downloading file: $current_dir/$item_name"
        mkdir -p "$current_dir"
        curl -s -L "$download_url" -o "$current_dir/$item_name"
      elif [ "$item_type" == "dir" ]; then
        echo "Entering directory: $current_dir/$item_name"
        fetch_github_path "$user" "$repo" "$branch" "$item_path" "$current_dir/$item_name"
        if [ $? -ne 0 ]; then
            return 1
        fi
      fi
    done
  else
    error "Unknown object type in API response."
    return 1
  fi
}

if [ "$#" -lt 4 ]; then
  echo -e "${YELLOW}Usage:${NC} $0 <user> <repo> <branch> <path> [target_dir]"
  echo -e "Example: $0 GFW4Fun randomfakehtml master path/to/folder"
  exit 1
fi

USER_ARG="$1"
REPO_ARG="$2"
BRANCH_ARG="$3"
PATH_ARG="$4"
DEST_ARG="${5:-./$PATH_ARG}"

fetch_github_path "$USER_ARG" "$REPO_ARG" "$BRANCH_ARG" "$PATH_ARG" "$DEST_ARG"
