#!/bin/bash
# shellcheck disable=SC2059,SC2155
set -euo pipefail

# The script intends to cleanup a specified repo, but unlike v1 it actually recovers from the previous change pre force push
# Given the malware always changes the signatures and involved obfuscated code, one thing is clear, it always force pushes the changes to the repo
# Therefore, we'll
# 1. Look into a prompted repo, or the current one.
# 2. Get the actor to look for who committed the force push
# 3. Get an optional date, by default it will use the latest force push
# 4. Look into the repo's activity for the force push with this behaviour
# 5. Once we have it, get the sha of the commit right before the force push
# 6. Check if there was any activity post the force push, say a merge, if so we prompt for confirmation
# 7. Finally if its ok, we force reset the branch to the sha before the force push, and force push the branch
# 8. Rinse and repeat🏀
#
# Parameters
# -b <branches>, --branches=<branches>: A comma separated list of branches to fix (Defaults to all affected branches)
# -a <actor>, --actor=<actor>: The github username to look out for (Defaults to current logged in user)
# -t <time-period>, --time-period=<time-period>: The ***optional*** time-period of the force pushes in the branches to filter. Can be day, week, month, quarter, year. It filters the actual API call to be within this period.
# -r <repo>, --repo=<repo>: The repo to work on (Defaults to current repo's origin). Must be either a http url or in the format owner/repo
# -h, --help: Show this guide
#
# It shows
# `help and prompts` in white text
# `error` in red text
# `success messages` in green

## Declaring global values

# Colors and bold pattern (disabled if not a terminal)
RED=""
GREEN=""
YELLOW=""
BOLD=""
RESET=""

if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BOLD='\033[1m'
  RESET='\033[0m'
fi

## Declaring internal functions
VERSION="2.0"
GIT_BRANCHES=""
ACTOR=""
TIME_PERIOD=""
CURRENT_REPO=""

# A function to log errors in the right format, inside stderr
log_error() { printf "${RED}${BOLD}$*${RESET}" >&2; }
# A function to log success messages
log_success() { printf "${GREEN}$*${RESET}"; }
# A function to log a warning
log_warning() { printf "${YELLOW}$*${RESET}"; }

# A function to prompt for a confirmation after printing a warning message
# Parameters:
# 1. The prompt message, defaults to "Continue? [y/N]"
# Returns a boolean to use to check if the prompt is confirmed
confirm() {
  local prompt="${1:-Continue? }"
  local reply=""

  while [[ ! "$reply" =~ ^[yY](es)?$|^[Nn]o?$ ]]; do
    read -r -p "$prompt" reply
  done

  [[ "$reply" =~ ^[yY](es)?$ ]]
}

# A function to trim whitespaces off of names
# Takes the string to trim
# Returns the trimmed string
trim_string() {
  local string="${1:- }"
  string=${string#"${string%%[![:space:]]*}"} # trim leading whitespace
  string=${string%"${string##*[![:space:]]}"} # trim ending whitespaces
  echo "$string"
}

# A function that forms an array off of a string of names
# Parameters:
# 1. The string to separate its values
# 2. The array to populate, you pass an array value for the variable to be populated
csv_to_array() {
  # Ensure the string is valid
  if [[ ! "$1" =~ ^[^,]+(,[^,]+)?$ ]]; then
    log_error "The string to form an array from $1 is invalid"
    exit 1
  fi

  # Form an array of the values
  local -n array="$2"

  # trim every entry
  while IFS=, read -r line; do
    trimmed_line=$(trim_string "$line")
    array=("${array[@]}" "$trimmed_line")
  done <<<"$1"
}

# A function that calls the github cli with the appropriate headers and path, while handling error objects
# Parameters
# 1. The route at which to call the api
# 2. Any additional params to pass to the client
# Returns an object if the call to the api succeeded, or null if not
# Actually returns the following via the return keyword
# 0: If the call succeeded, and the object is valid. Object "returned" via echo
# 1: If the call succeeded, but the data retrieval failed from gh. The object is still "returned"
# 2: If the call failed, thus returning "null"
call_gh_api() {
  # Get local values
  local call_result
  local result
  local temp_error_log_file=$(mktemp)

  result=$(gh api \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2026-03-10" \
    "$1" "$2" 2>"$temp_error_log_file")

  # Ensure the call went well, this is done by checking the contents of the error file and the result
  call_result="$?"
  local error_logs=$(cat "$temp_error_log_file")

  # 1: If the call went well, its a success
  if (("$call_result" == 0)); then
    echo "$result"
    return 0
  fi

  # 2: At this point, we have an error, so display it
  log_error "An error occured from github cli: \n"
  log_error "$error_logs\n"

  # 3: If we have data, then its an error from github cli, otherwise its an error from our side
  if [[ -n "$result" ]]; then
    echo "$result"
    return 1
  else
    return 2
  fi
}

# A function to print the title of the script
print_banner() {
  printf "\n"
  printf "${BOLD}========================================${RESET}\n"
  printf "${BOLD}  PolinRider Malware Cleaner v%s${RESET}\n" "$VERSION"
  printf "${BOLD}  https://opensourcemalware.com${RESET}\n"
  printf "${BOLD}========================================${RESET}\n"
  printf "\n"
}

# A function to print the help menu of the user
print_help() {
  printf "Usage: %s [...options]\n" "$0"
  printf "Options:\n\n"
  printf "  -b <branches>, --branches=<branches>: A comma separated list of branches to fix (Defaults to all affected branches)\n"
  printf "  -a <actor>, --actor=<actor>: The github username to look out for (Defaults to current logged in user)\n"
  printf "  -t <time-period>, --time-period=<time-period>: The ***optional*** time-period of the force pushes in the branches to filter. Can be day, week, month, quarter, year. It filters the actual API call to be within this period.\n"
  printf "  -r <repo>, --repo=<repo>: The repo to work on (Defaults to current repo's origin). Must be either a format 'owner/repo'\n"
  printf "  -h, --help: Show this guide\n"
}

# A function to check if we have github-cli installed
check_dependencies() {
  printf "Checking if github-cli is installed...\n"

  if command -v gh >/dev/null; then
    log_success "All dependencies are present\n\n"
  else
    log_error "It appears you don't have github cli installed, kindly do so by visiting: https://github.com/cli/cli#installation\n\n"
    return 1
  fi
}

# The main function, accepts all params
main() {
  # Get the params
  while (($# > 0)); do
    case "$1" in
    -h | --help)
      print_help
      exit 0
      ;;
    -b)
      # If its a branch list, ensure we only get words that are comma separated
      if [[ "$2" =~ ^[^,]+(,[^,]+)?$ ]]; then
        GIT_BRANCHES="$2"
        shift 2
      else
        log_error "The branches provided need to be a list of comma separated values: $2\n\n"
        print_help
        exit 1
      fi
      ;;
    --branches=*)
      # If its a branch list, ensure we only get words that are comma separated
      if [[ "$1" =~ ^branches=[^,]+(,[^,]+)?$ ]]; then
        GIT_BRANCHES="${1#=}"
        shift
      else
        log_error "The branches provided need to be a list of comma separated values: ${1#=}\n\n"
        print_help
        exit 1
      fi
      ;;
    -a)
      ACTOR="$2"
      shift 2
      ;;
    --actor=*)
      ACTOR="${1#=}"
      shift
      ;;
    -t)
      # Ensure the period given is in the valid format
      if [[ "$2" =~ ^day|week|month|quarter|year$ ]]; then
        TIME_PERIOD=$(trim_string "$2")
        shift 2
      else
        log_error "The time period provided is invalid: $2\n\n"
        print_help
        exit 1
      fi
      ;;
    --time-period=*)
      # Ensure the period given is in the valid format
      if [[ "$1" =~ ^time-period=(day|week|month|quarter|year)$ ]]; then
        TIME_PERIOD=$(trim_string "${1#=}")
        exit 1
      else
        log_error "The time period provided is invalid: ${1#=}\n\n"
        print_help
      fi

      shift
      ;;
    -r)
      # Ensure repo is in the valid format
      if [[ "$2" =~ ^[^/]+/[^/]$ ]]; then
        CURRENT_REPO="$2"
        shift 2
      else
        log_error "The repo format provided is invalid: $2\n\n"
        print_help
        exit 1
      fi
      ;;
    --repo=*)
      # Ensure repo is in the valid format
      if [[ "$1" =~ ^repo=[^/]+/[^/]$ ]]; then
        CURRENT_REPO="${1#=}"
        shift
      else
        log_error "The repo format provided is invalid: ${1#=}\n\n"
        print_help
        exit 1
      fi
      ;;
    -*)
      log_error "Error: Unknown option '$1'\n\n"
      print_help
      exit 1
      ;;
    esac
  done

  # If no actor is provided, check from gh, otherwise trim it
  if [[ -n "$ACTOR" ]]; then
    ACTOR=$(trim_string "$ACTOR")
  else
    printf "Attempting to set current user...\n"
    ACTOR=$(call_gh_api "/user" "-q .login")
  fi

  printf "Current user set as ${GREEN}${BOLD}$ACTOR${RESET}\n\n"

  # If no repo is provided, we use the current one
  if [[ -n "$CURRENT_REPO" ]]; then
    CURRENT_REPO=$(trim_string "$CURRENT_REPO")
  else
    printf "Attempting to set current repo...\n"
    local remote_url=$(git remote get-url origin)
    local match="^https://github.com/([^/]+/[^/#?]+)"

    # Use matching to sort this out
    if [[ "$remote_url" =~ $match ]]; then
      CURRENT_REPO="${BASH_REMATCH[1]}"
    fi
  fi

  printf "Current repo set as ${GREEN}${BOLD}$CURRENT_REPO${RESET}\n\n"
}

## Calling the functions
print_banner
check_dependencies
main "$@"
