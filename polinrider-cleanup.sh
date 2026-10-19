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
# Parameters, all prompted for unless one of them is present in the script call
# -b <branches>, --branches=<branches>: The specific comma-separated list of branches to perform the operation on (Defaults to all affected branches)
# -a <actor>, --actor=<actor>: The github username to look out for (Defaults to current logged in user)
# -r <repo>, --repo=<repo>: The repo to work on (Defaults to current repo's origin). Must be in the format owner/repo
# -t <time-period>, --time-period=<time-period>: The ***optional*** time-period of the force pushes in the branches to filter when calling the API. Can be day, week, month, quarter, year. This can be used when you're sure of when the force pushes occur, thus you want to get a subsect of them in that period from the API rather than calling for all force pushes, saving time and bandwidth.
# -s <date>, --since=<date>: Filter the response from the API to all force pushes beyond this date. It is ***optional***, ***inclusive*** and must be in YYYY-MM-DD format.
# -u <date>, --until=<date>: Filter the response from the API to all force pushes before this date. It is ***optional***, ***inclusive*** and must be in YYYY-MM-DD format.
# -h, --help: Show this guide
#
# It shows
# `help and prompts` in white text
# `error` in bold red text
# `success messages` in green
# `warnings` in yellow
# `emphasized words` in bold cyan

## Declaring global values

# Colors and bold pattern (disabled if not a terminal)
RED=""
GREEN=""
CYAN=""
YELLOW=""
BOLD=""
RESET=""

if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  CYAN='\033[0;36m'
  YELLOW='\033[1;33m'
  BOLD='\033[1m'
  RESET='\033[0m'
fi

# User set values
VERSION="2.0"
GIT_BRANCHES=()
FORCE_PUSH_ACTOR=""
TIME_PERIOD=""
CURRENT_REPO=""
FROM_DATE=""
TO_DATE=""

## Declaring internal functions

# A function to log errors in the right format, inside stderr
# Takes in any words to use in the error format
log_error() { printf "$RED$BOLD$*$RESET" >&2; }

# A function to log success messages
# Takes in any words to use in the success message
log_success() { printf "$GREEN$*$RESET"; }

# A function to log a warning
# Takes in any words to use in the warning
log_warning() { printf "$YELLOW$*$RESET" >&2; }

# A function to prompt for a confirmation after printing a warning message. It also loops till the right answer is given, either "y"|"n" or its uppercase and full term words "yes" and "no"
# Parameters:
# 1. The prompt message, defaults to "Continue? [y/N]"
# Returns a boolean to use to check if the prompt is confirmed
confirm() {
  local prompt="${1:-Continue? }"
  local reply=""

  while [[ ! "$reply" =~ ^([yY](es)?|[Nn]o?)$ ]]; do
    read -r -p "$prompt" reply
  done

  [[ "$reply" =~ ^[yY](es)?$ ]]
}

# A function to trim whitespaces off of names
# Takes the string to trim
# Returns the trimmed string
trim_string() {
  local string="${1:-}"
  string=${string#"${string%%[![:space:]]*}"} # trim leading whitespace
  string=${string%"${string##*[![:space:]]}"} # trim ending whitespaces
  echo "$string"
}

# A function that calls the github cli with the appropriate headers and path, while handling error objects
# Parameters
# 1. The route at which to call the api
# 2. Any additional params to pass to the client, as a space separated string
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
    "$1" "${2:-}" 2>"$temp_error_log_file")

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

# A function that calls the api and formats the results accordingly
# Takes in an ***optional*** branch to use in the query of the results
# Returns:
# 0: If the call succeeded
# 1/2: If the caller for gh api failed as documented
get_repo_activity() {
  # Get the right query string
  # 1. Must be a force push (activity_type=force_push)
  # 2. Must be of the set actor (actor setting)
  # 3. Must have as many results as possible in a given page (per_page=100)
  local query_string="/repos/$CURRENT_REPO/activity?activity_type=force_push&actor=$FORCE_PUSH_ACTOR&per_page=100"

  # 4. If there is a specific branch to query for, add it in
  if [[ -n "$1" ]]; then
    query_string="$query_string&ref=$1"
  fi

  # 5. If there was a timer, set it
  if [[ -n "$TIME_PERIOD" ]]; then
    query_string="$query_string&time_period=$TIME_PERIOD"
  fi

  # Get the right params to pass through
  # Here, we are only fetching what we need via the jq supported query string
  local jq_query="-q map({before, after, ref: (.ref | sub(\"^refs/heads/\"; \"\")), timestamp})"
  local result=$(call_gh_api "$query_string" "$jq_query")

  # Finally, perform the extensive filtering
  # We need to:
  # 1. ensure the timestamps are within range
  # 2. get the latest activity unique by branch
  # 3. format to get total with the result items
  result=$(echo "$result" | jq --arg from_date "$FROM_DATE" --arg to_date "$TO_DATE" '
  map(if $from_date != "" then select(.timestamp >= $from_date) end) |
  map(if $to_date != "" then select(.timestamp <= $to_date) end) |
  group_by(.ref) | map(.[0]) |
  {data: ., total: length}
')

  echo "$result"
}

# A function that works on a given branch and its props, essentially notifying the user if the force push is sensitive and whether to proceed
# Parameters:
# 1. The directory where the cloned repo is, to perform ops
# 2. The name of the branch in question
# 3. The branch's old commit prior to the force push
# 4. The branch's new commit hash after the force push
# Returns:
# 0: If all goes well
# 1/2: If the caller for gh api failed as documented
# 3: If the required params are absent
force_push_branch() {
  # Ensure params are valid
  if [[ ! -d "$1" ]]; then
    log_error "The git directory $1 is invalid\n"
    exit 3
  elif [[ -z "$2" ]]; then
    log_error "A git branch is needed for the operation\n"
    exit 3
  elif [[ -z "$3" || -z "$4" ]]; then
    log_error "The branch's both old and new SHAs are needed for the restoration\n"
    exit 3
  fi

  # Once that is done, check if we have any changes as per the current state of the remote branch
  local diff_state=$(call_gh_api "/repos/$CURRENT_REPO/compare/$4...$2" "-q .status")

  if [[ "$diff_state" == "identical" ]]; then
    log_success "Congratulations, branch $2 is up to date with remote. It can be easily reverted\n"
  else
    log_warning "It appears the branch has drifted since the force push, analysing changes...\n\n"

    git -C "$1" fetch origin "$2"
    git -C "$1" fetch origin "$4"
    git diff --stat "$4"..."$2"
  fi

  # Finally, ask for confirmation before proceeding
  if confirm "Are you sure you would like to proceed, force pushing is a dangerous attempt so only do so when you're sure? [y/N] "; then
    git -C "$1" checkout "origin/$2"
    git -C "$1" reset --hard "$3"
    git -C "$1" push -f

    log_success "Branch $2 restored successfully\n\n"
  fi
}

# A function to print the help menu of the user
print_help() {
  printf "Usage: %s [...options]\n" "$0"
  printf "Options:\n\n"
  printf "  -b <branches>, --branches=<branches>: The specific comma-separated list of branches to perform the operation on\n\t$CYAN${BOLD}Defaults to all affected branches$RESET\n"
  printf "  -a <actor>, --actor=<actor>: The github username to look out for\n\t$CYAN${BOLD}Defaults to current logged in user$RESET\n"
  printf "  -r <repo>, --repo=<repo>: The repo to work on. Must be in the $CYAN${BOLD}format owner/repo$RESET\n\t$CYAN${BOLD}Defaults to current repo's origin$RESET\n"
  printf "  -t <time-period>, --time-period=<time-period>: The $CYAN${BOLD}optional${RESET} time-period of the force pushes in the branches to filter when calling the API. Can be day, week, month, quarter, year. This can be used when you're sure of when the force pushes occur, thus you want to get a subsect of them in that period from the API rather than calling for all force pushes, saving time and bandwidth.\n"
  printf "  -s <date>, --since=<date>: Filter the response from the API to all force pushes beyond this date. It is $CYAN${BOLD}optional, inclusive and must be in YYYY-MM-DD format$RESET\n"
  printf "  -u <date>, --until=<date>: Filter the response from the API to all force pushes before this date. It is $CYAN${BOLD}optional, inclusive and must be in YYYY-MM-DD format$RESET\n"
  printf "  -h, --help: Show this guide\n\n"
}

# A function to set proper defaults of the passed options, if any, and format them accordingly
# Takes in the ***optional*** list of git branches to add
# Returns:
# 0: If the setup was ok
# 1/2: If the login setup failed via gh api
# 3: If the list of branches is invalid
set_option_defaults() {
  # If branches are set, format the string of commas to an actual list
  if [[ -z "$1" ]]; then
    printf "Using $CYAN${BOLD}default affected branches$RESET\n\n"
  else
    printf "Attempting to format passed branches...\n"

    # Ensure the list itself is valid
    if [[ ! "$1" =~ ^[^,]+(,[^,]+)*$ ]]; then
      log_error "The string provided is not a valid list of branches: $1"
      exit 3
    fi

    # If the list is valid, reset git branches to all values read from it while trimming them
    IFS=, read -r -a GIT_BRANCHES <<<"$1"

    for index in "${!GIT_BRANCHES[@]}"; do
      GIT_BRANCHES[index]=$(trim_string "${GIT_BRANCHES[index]}")
    done

    printf "Current branches set as $CYAN$BOLD$1$RESET\n\n"
  fi

  # If no actor is provided, check from gh, otherwise trim it
  if [[ -n "$FORCE_PUSH_ACTOR" ]]; then
    FORCE_PUSH_ACTOR=$(trim_string "$FORCE_PUSH_ACTOR")
  else
    printf "Attempting to set current user...\n"
    FORCE_PUSH_ACTOR=$(call_gh_api "/user" "-q .login")
  fi

  printf "Current user set as $CYAN$BOLD$FORCE_PUSH_ACTOR$RESET\n\n"

  # If no repo is provided, we use the current one
  if [[ -n "$CURRENT_REPO" ]]; then
    CURRENT_REPO=$(trim_string "$CURRENT_REPO")
  else
    printf "Attempting to set current repo...\n"
    local remote_url=$(git remote get-url origin)
    local match="^https://github.com/([^/]+/[^/#?.]+)"

    # Use matching to sort this out
    if [[ "$remote_url" =~ $match ]]; then
      CURRENT_REPO="${BASH_REMATCH[1]}"
    fi
  fi

  printf "Current repo set as $CYAN$BOLD$CURRENT_REPO$RESET\n\n"

  # If we had a timer, communicate it
  if [[ -n "$TIME_PERIOD" ]]; then
    TIME_PERIOD=$(trim_string "$TIME_PERIOD")
    printf "Current filter time set to $CYAN$BOLD$TIME_PERIOD$RESET\n\n"
  fi

  # If we had start and end dates, communicate them
  if [[ -n "$FROM_DATE" ]]; then
    FROM_DATE=$(trim_string "$FROM_DATE")                         # Trim the value
    FROM_DATE=$(date -d "$FROM_DATE" --iso-8601 seconds)          # Convert to iso-8601 format, with our timezone appended
    FROM_DATE=$(TZ="UTC" date -d "$FROM_DATE" --iso-8601 seconds) # Convert from local to UTC timezone

    printf "Getting all force push events from $CYAN$BOLD$FROM_DATE$RESET\n\n"
  fi

  if [[ -n "$TO_DATE" ]]; then
    TO_DATE=$(trim_string "$TO_DATE")                         # Trim the value
    TO_DATE=$(date -d "$TO_DATE" --iso-8601 seconds)          # Convert to iso-8601 format, with our timezone appended
    TO_DATE=$(TZ="UTC" date -d "$TO_DATE" --iso-8601 seconds) # Convert to local to UTC timezone

    printf "Getting all force push events from $CYAN$BOLD$TO_DATE$RESET\n\n"
  fi
}

# A function that fixes a given branch, holding the core of the script. It:
# 1. Uses the configured settings plus the passed branch to get branch details
# 2. Formats activity to the most recent within the given limits
# 3. Uses the data to reset for the given branch, or the current branch
# Parameters:
# 1. The temp dir to clone the repo in
# 2. ***optional*** branch to work with
# Returns:
# 0: If all goes well
# 1/2: If the caller for getting repo activity fails for some reason as documented
# 3: If the passed directory is invalid
fix_affected_branch() {
  # Ensure required params are valid
  if [[ ! -d "$1" ]]; then
    log_error "The directory passed to initialise the repo restoration doesn't exist"
    exit 3
  fi

  # 1: Get the valid repo activity using the configuration so far
  printf "Getting the repo activity with the configured settings...\n"
  local repo_activity=$(get_repo_activity "${2:-}")
  log_success "total latest activities found in the specified branch(es): "
  echo "$repo_activity" | jq '.total'
  printf "\n\n"

  # 2: With our repo activity ready, we need to extract said data
  # If we passed one param, the loop should only run once as we get one data val lol
  local total_branches=()
  local total_before_commits=()
  local total_after_commits=()

  while read -r line; do
    local trimmed_line=$(trim_string "$line")
    total_branches+=("$trimmed_line")
  done < <(echo "$repo_activity" | jq --raw-output '.data[].ref')

  while read -r line; do
    local trimmed_line=$(trim_string "$line")
    total_before_commits+=("$trimmed_line")
  done < <(echo "$repo_activity" | jq --raw-output '.data[].before')

  while read -r line; do
    local trimmed_line=$(trim_string "$line")
    total_after_commits+=("$trimmed_line")
  done < <(echo "$repo_activity" | jq --raw-output '.data[].after')

  # 3: At last, for every branch, make the force push
  printf "Cleaning up the branch(es)\n\n"

  for ((index = 0; index < "${#total_branches[@]}"; index++)); do
    # Get the valid props
    local current_branch="${total_branches[index]}"
    local before_commit="${total_before_commits[index]}"
    local after_commit="${total_after_commits[index]}"

    # Call the appropriate function
    printf "%d: Looking into branch $CYAN$BOLD%s$RESET...\n" $((index + 1)) "$current_branch"
    force_push_branch "$1" "$current_branch" "$before_commit" "$after_commit"
  done
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
  #1: Get the params, store git branches if provided in a var
  local git_branches_arg=""

  while (($# > 0)); do
    case "$1" in
    -h | --help)
      print_help
      exit 0
      ;;
    -b)
      # Ensure the branches are valid name(s)
      # i.e not comma starting, or 2 comma separated
      if [[ "$2" =~ ^[^,]+(,[^,]+)*$ ]]; then
        git_branches_arg="$2"
        shift 2
      else
        log_error "The branches must be a comma separated value list, or a single item: $2\n"
        print_help
        exit 1
      fi
      ;;
    --branches=*)
      # Ensure the branches are valid name(s)
      # i.e not comma starting, or 2 comma separated
      if [[ "$1" =~ ^--branches=[^,]+(,[^,]+)* ]]; then
        git_branches_arg="${1#*=}"
        shift
      else
        log_error "The branches must be a comma separated value list, or a single item: ${1#*=}\n"
        print_help
        exit 1
      fi
      ;;
    -a)
      FORCE_PUSH_ACTOR="$2"
      shift 2
      ;;
    --actor=*)
      FORCE_PUSH_ACTOR="${1#*=}"
      shift
      ;;
    -t)
      # Ensure the period given is in the valid format
      if [[ "$2" =~ ^(day|week|month|quarter|year)$ ]]; then
        TIME_PERIOD="$2"
        shift 2
      else
        log_error "The time period provided is invalid: $2\n\n"
        print_help
        exit 1
      fi
      ;;
    --time-period=*)
      # Ensure the period given is in the valid format
      if [[ "$1" =~ ^--time-period=(day|week|month|quarter|year)$ ]]; then
        TIME_PERIOD="${1#*=}"
        shift
      else
        log_error "The time period provided is invalid: ${1#*=}\n\n"
        print_help
        exit 1
      fi
      ;;
    -r)
      # Ensure repo is in the valid format
      if [[ "$2" =~ ^[^/]+/[^/]+$ ]]; then
        CURRENT_REPO="$2"
        shift 2
      else
        log_error "The repo format provided should be 'owner/repo': $2\n\n"
        print_help
        exit 1
      fi
      ;;
    --repo=*)
      # Ensure repo is in the valid format
      if [[ "$1" =~ ^--repo=[^/]+/[^/]+$ ]]; then
        CURRENT_REPO="${1#*=}"
        shift
      else
        log_error "The repo format provided should be 'owner/repo': ${1#=}\n\n"
        print_help
        exit 1
      fi
      ;;
    -s)
      # Ensure since date is valid
      if [[ "$2" =~ ^[[:digit:]]{4}-[[:digit:]]{2}-[[:digit:]]{2}$ ]]; then
        FROM_DATE="$2"
        shift 2
      else
        log_error "The since date should be in the format YYYY-MM-DD: $2\n"
        print_help
        exit 1
      fi
      ;;
    --since=*)
      # Ensure since date is valid
      if [[ "$1" =~ ^--since=[[:digit:]]{4}-[[:digit:]]{2}-[[:digit:]]{2}$ ]]; then
        FROM_DATE="${1#*=}"
        shift
      else
        log_error "The since date should be in the format YYYY-MM-DD: ${2#=}\n"
        print_help
        exit 1
      fi
      ;;
    -u)
      # Ensure until date is valid
      if [[ "$2" =~ ^[[:digit:]]{4}-[[:digit:]]{2}-[[:digit:]]{2}$ ]]; then
        TO_DATE="$2"
        shift 2
      else
        log_error "The until date should be in the format YYYY-MM-DD: $2\n"
        print_help
        exit 1
      fi
      ;;
    --until=*)
      # Ensure until date is valid
      if [[ "$1" =~ ^--until=[[:digit:]]{4}-[[:digit:]]{2}-[[:digit:]]{2}$ ]]; then
        TO_DATE="${1#*=}"
        shift
      else
        log_error "The until date should be in the format YYYY-MM-DD: ${2#=}\n"
        print_help
        exit 1
      fi
      ;;
    *)
      log_error "Error: Unknown option '$1'\n\n"
      print_help
      exit 1
      ;;
    esac
  done

  # 2: Then, using the options stored, ensure proper defaults are set
  set_option_defaults "$git_branches_arg"

  # 3: Finally, based on the branches configured, we can run the force pushes
  local temp_dir=$(mktemp -d)
  printf "Cloning problematic repo...\n\n"
  git clone "https://github.com/$CURRENT_REPO" "$temp_dir"

  if (("${#GIT_BRANCHES[@]}" > 0)); then
    for branch in "${GIT_BRANCHES[@]}"; do
      fix_affected_branch "$temp_dir" "$branch"
    done

    exit 0
  fi

  # 4: If no branches are configured, call the function with the defaults
  fix_affected_branch "$temp_dir"
}

## Calling the functions
print_banner
check_dependencies
main "$@"
