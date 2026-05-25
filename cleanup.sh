#!/bin/bash

set -u

VERSION="1.0"
TMPDIR=""
REPO_URL=""
BRANCH_NAME="main"
GITIGNORE_ONLY=false
FONT_RETAIN_CSV=""
VSCODE_RETAIN_CSV=""
CONFIGS_CSV=""

print_usage() {
    cat <<EOF
Usage: $0 [options]

Interactive cleanup flow for a cloned repository.

Options:
  -h, --help              Show this help message and exit
  --repo=<url>            Use this remote repo URL
  --branch=<name>         Use this branch name (default: main)
  --fonts=<csv>           Retain only these public/fonts files
  --vscode=<csv>          Retain only these .vscode files, and prompt to edit them after cleanup
  --gitignore             Only cleanup .gitignore by either removing entries or replacing with user-pasted content
  --configs=<csv>         A list of configs to clean up, defaults to all *.config.(ts|js|mjs) files.

Behavior:
  - If no flags are supplied, the script does the following:
    - Deletes all files in public/fonts
    - Remove malicious entries in .gitignore, otherwise uses user's text input to replace the whole file
    - Prompts for which .vscode files to retain, deletes the rest, and allows editing of the retained files.
    - Uses user's text input to replace the whole list of config files
  - If --gitignore is supplied, only the .gitignore workflow runs.
  - For .vscode files, retained files can be edited after cleanup.

Examples:
  $0 https://github.com/example/repo.git // Uses the repo URL as a positional argument
  $0 --repo https://github.com/example/repo.git
  $0 --repo https://github.com/example/repo.git --branch=develop
  $0 --repo https://github.com/example/repo.git --fonts=logo.woff2, font.woff2
  $0 --repo https://github.com/example/repo.git --vscode=tasks.json, settings.json
  $0 --repo https://github.com/example/repo.git --gitignore
  $0 --repo https://github.com/example/repo.git --configs="app.config.js, index.config.mjs"

Exit codes:
  0: success
  1: false (e.g. user chose not to proceed with an action)
  2: Error (e.g. missing required inputs, git errors, etc.)
EOF
}

# A function to print an error message and exit with a non-zero status(2)
die() {
    printf 'Error: %s\n' "$1" >&2
    exit 2
}

# A function to trim leading and trailing whitespace from a string, for parsing the csv params
trim_value() {
    local value="$1"
    value="${value#${value%%[![:space:]]*}}"
    value="${value%${value##*[![:space:]]}}"
    printf '%s' "$value"
}

# A function to convert a comma-separated string into newline-separated, while trimming whitespace and ignoring empty items. It does so via the ifs, which makes the csv string split into items and echoed as a newline.
csv_to_lines() {
    local csv="$1"
    local item
    local IFS=,

    for item in $csv; do
        item="$(trim_value "$item")"

        if [[ -n "$item" ]]; then
            printf '%s\n' "$item"
        fi
    done
}

# A function to prompt the user with a yes/no question, returning 0 for yes and 1 for no (default)
prompt_yes_no() {
    local prompt="$1"
    local answer=""

    while true; do
        read -rp "$prompt [y/N]: " answer
        case "$answer" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO|"") return 1 ;;
        esac
    done
}

# A function to prompt the user for multiline input until they enter EOF on its own line, then return the collected input as a single string
prompt_multiline() {
    local prompt="$1"
    local buffer=""
    local line=""

    printf '%s\n' "$prompt" >&2
    printf '%s\n' 'Paste the replacement content, then type EOF on its own line.' >&2

    while IFS= read -r line; do
        if [[ "$line" == "EOF" ]]; then
            break
        fi

        buffer="${buffer}${line}"$'\n'
    done

    printf '%s' "$buffer"
}

# Iterate through the script arguments, setting global variables.
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                print_usage
                exit 0
                ;;
            --repo=*)
                REPO_URL="${1#*=}"
                ;;
            --fonts=*)
                FONT_RETAIN_CSV="${1#*=}"
                ;;
            --vscode=*)
                VSCODE_RETAIN_CSV="${1#*=}"
                ;;
            --gitignore)
                GITIGNORE_ONLY=true
                ;;
            --branch=*)
                [ -z "$REPO_URL" ] || die "Cannot specify --branch without also specifying --repo"
                BRANCH_NAME="${1#*=}"
                ;;
            --configs=*)
                CONFIGS_CSV="${1#*=}" 
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                if [ -z "$REPO_URL" ]; then
                    REPO_URL="$1"
                else
                    die "Unexpected positional argument: $1"
                fi
                ;;
        esac
        shift
    done
}

# A function to check for required inputs and prompt the user if they are missing, with validation
ensure_inputs() {
    if [ -z "$REPO_URL" ]; then
        read -rp "Enter the remote repo url: " REPO_URL
    fi

    [ -n "$REPO_URL" ] || die "Remote repo URL is required"

    if [[ -z "$BRANCH_NAME" ]]; then
        read -rp "Enter the branch name (default: main): " BRANCH_NAME
    fi

    BRANCH_NAME="${BRANCH_NAME:-main}"

    if ! $GITIGNORE_ONLY; then
        if [ -z "$FONT_RETAIN_CSV" ]; then
            read -rp "Enter public/fonts files to retain (comma separated, leave blank to remove all): " FONT_RETAIN_CSV
        fi

        if [ -z "$VSCODE_RETAIN_CSV" ]; then
            read -rp "Enter .vscode files to retain (comma separated, leave blank to remove all): " VSCODE_RETAIN_CSV
        fi

        if [[ -z "$CONFIGS_CSV" ]]; then
            read -rp "Enter config files to clean up (comma separated, defaults to all *.config.(ts|js|mjs) files): " CONFIGS_CSV
        fi
    fi
}

# A function to clone the repository into a temporary directory and set up the branch, with error handling
clone_repo() {
    TMPDIR="$(mktemp -d)"
    git clone "$REPO_URL" "$TMPDIR" || die "Failed to clone repository"
    git -C "$TMPDIR" remote set-url origin "$REPO_URL"
    git -C "$TMPDIR" checkout "$BRANCH_NAME" >/dev/null 2>&1 || die "Failed to checkout branch $BRANCH_NAME"
}

# Restoring gitignore can be done in two ways: either by filtering out known malicious entries, or by replacing the entire file with user-pasted content. This function handles both workflows.
restore_gitignore() {
    local gitignore_file="$TMPDIR/.gitignore"
    local corrected_content=""
    local filtered_file=""

    # Automatically skip if no gitignore file exists in the repo, since there's nothing to clean up
    if [[ ! -f "$gitignore_file" ]]; then
        echo "No .gitignore file found in the repository; skipping .gitignore cleanup."
        return 0
    fi

    if prompt_yes_no "Replace .gitignore with pasted content instead of filtering known malicious entries?"; then
        corrected_content="$(prompt_multiline "Paste the corrected .gitignore content:")"
        printf '%s' "$corrected_content" > "$gitignore_file"
        return 0
    fi

    filtered_file="$(mktemp)"

    awk '
        !/branch_structure\.json/ &&
        !/temp_auto_push\.bat/ &&
        !/temp_interactive_push\.bat/ &&
        !/^[[:space:]]*\.gitignore[[:space:]]*$/
    ' "$gitignore_file" > "$filtered_file"

    mv "$filtered_file" "$gitignore_file"
}

# A function to clean up the public/fonts directory by deleting all files except those specified in the FONT_RETAIN_CSV, and then removing any empty directories
cleanup_fonts() {
    local fonts_dir="$TMPDIR/public/fonts"
    local keep_set=""
    local font_file=""
    local font_base=""

     # Automatically skip if no fonts directory exists in the repo, since there's nothing to clean up
    if [[ ! -f "$fonts_dir" ]]; then
        echo "No fonts directory found in the repository; skipping .gitignore cleanup."
        return 0
    fi

    # Format each csv value as a newline-separated list and build a set of basenames to keep, this forms a string of newline separated entries that can be grepped against
    while IFS= read -r font_base; do
        keep_set="${keep_set}
${font_base}"
    done <<EOF
$(csv_to_lines "$FONT_RETAIN_CSV")
EOF

    # Loop through the fonts in the font directory, and delete any whose basenames are not in the keep_set. The keep_set is grepped with fixed string matching for the basename of each font file, and if not found, that font file is deleted.
    while IFS= read -r -d '' font_file; do
        font_base="$(basename "$font_file")"
        if ! printf '%s\n' "$keep_set" | grep -Fxq "$font_base"; then
            rm -f "$font_file"
        fi
    done < <(find "$fonts_dir" -type f -print0)

    # Delete any empty directories in the fonts directory after the file cleanup
    find "$fonts_dir" -type d -empty -delete
}

# A function to clean up .vscode files by deleting all files except those specified in the VSCODE_RETAIN_CSV, prompting the user to edit the retained files, and then removing any empty directories
cleanup_vscode() {
    local vscode_dir="$TMPDIR/.vscode"
    local keep_set=""
    local vscode_file=""
    local vscode_base=""
    local new_content=""
     
    # Automatically skip if no vscode directory exists in the repo, since there's nothing to clean up
    if [[ ! -f "$vscode_dir" ]]; then
        echo "No vscode directory found in the repository; skipping .gitignore cleanup."
        return 0
    fi

    # Format each csv value as a newline-separated list and build a set of basenames to keep, this forms a string of newline separated entries that can be grepped against
    while IFS= read -r vscode_base; do
        keep_set="${keep_set}
${vscode_base}"
    done <<EOF
$(csv_to_lines "$VSCODE_RETAIN_CSV")
EOF

    # Loop through the files in the .vscode directory, and delete any whose basenames are not in the keep_set. The keep_set is grepped with fixed string matching for the basename of each vscode file, and if not found, that file is deleted. If the file is retained, prompt the user if they want to edit it, and if so, collect multiline input and overwrite the file with the new content.
    while IFS= read -r -d '' vscode_file; do
        vscode_base="$(basename "$vscode_file")"

        if ! printf '%s\n' "$keep_set" | grep -Fxq "$vscode_base"; then
            rm -f "$vscode_file"
            continue
        fi

        if prompt_yes_no "Edit retained .vscode file $vscode_base now?"; then
            new_content="$(prompt_multiline "Paste the new content for $vscode_base:")"
            printf '%s' "$new_content" > "$vscode_file"
        fi
    done < <(find "$vscode_dir" -type f -print0)

    # Delete any empty directories in the .vscode directory after the file cleanup, since .vscode can contain subdirectories
    find "$vscode_dir" -type d -empty -delete
}

# A function to clean up config files by replacing the entire file with user-pasted content.
cleanup_configs() {
    local config_pattern="*.config.{ts,js,mjs}"
    local config_files=("$TMPDIR"/$config_pattern)

    # Automatically skip if no config files matching the pattern exist in the repo, or any provided
    if [[ ${#config_files[@]} -eq 0 && -z "$CONFIGS_CSV" ]]; then
        echo "No config files found in the repository matching pattern $config_pattern; skipping config cleanup."
        return 0
    fi

    # If configs is provided, set out to look for those files
    if [[ -n "$CONFIGS_CSV" ]]; then
        config_files=()

        while IFS= read -r config_base; do
            local config_path="$TMPDIR/$config_base"

            if [[ -f "$config_path" ]]; then
                config_files+=("$config_path")
            else
                echo "Warning: specified config file $config_base not found in the repository; skipping."
            fi
        done <<EOF
$(csv_to_lines "$CONFIGS_CSV")
EOF
    fi

    # Loop through the config files, and for each file, prompt the user to replace the entire file with pasted content. If not
    for config_file in "${config_files[@]}"; do
        local config_base="$(basename "$config_file")"
        local new_content="$(prompt_multiline "Paste the new content for $config_base:")"
        printf '%s' "$new_content" > "$config_file"
    done
}

# A function to apply the cleanup edits, commit, and push back to the remote repository. It checks if there are any changes to commit, and if not, it skips the commit and push steps.
make_edits() {
    echo "Applying repository cleanup..."

    if ! $GITIGNORE_ONLY; then
        echo "Cleaning public/fonts..."
        cleanup_fonts

        echo "Cleaning .vscode files..."
        cleanup_vscode

        echo "Cleaning config files..."
        cleanup_configs
    fi

    echo "Cleaning .gitignore..."
    restore_gitignore

    echo "Committing the changes..."
    git -C "$TMPDIR" add .

    if git -C "$TMPDIR" diff --cached --quiet; then
        echo "No changes detected; skipping commit and push."
        return 0
    fi

    git -C "$TMPDIR" commit -m "Cleanup infected repository"
    git -C "$TMPDIR" push --force-with-lease origin "$BRANCH_NAME" # use force with lease to avoid overwriting any new commits that may have been pushed to the branch since we cloned it
}

# Calling main
main() {
    parse_args "$@"
    ensure_inputs
    clone_repo

    # In case the command is terminated, remove the temp dir
    trap 'rm -rf "$TMPDIR"' EXIT

    echo "Cloned repository to $TMPDIR"
    echo "Using branch: $BRANCH_NAME"
    make_edits
}

main "$@"