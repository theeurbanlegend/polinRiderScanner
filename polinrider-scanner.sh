#!/bin/bash
#
# PolinRider Malware Scanner v1.2
# https://opensourcemalware.com
#
# Scans local git repositories for evidence of PolinRider malware infection.
# PolinRider appends obfuscated JS payloads to config files and uses
# temp_auto_push.bat to amend commits and force-push to GitHub.
#
# Usage:
#   ./polinrider-scanner.sh                        # Scan current directory
#   ./polinrider-scanner.sh /path/to/projects      # Scan specific directory
#   ./polinrider-scanner.sh --verbose /path         # Verbose output
#
# Exit codes:
#   0 - No infections found
#   1 - Infections found
#   2 - Error (invalid path, etc.)

set -u

VERSION="1.2"
VERBOSE=0
JS_ALL=0
SCAN_DIR=""

# PolinRider signatures — original variant (Mar 2026)
PRIMARY_SIG='("rmcej%otb%",2857687)'
SECONDARY_SIG="global\['.+'\]=.*"

# PolinRider signatures — rotated variant (Apr 2026, Cot%3t=shtP)
# Architecture identical; all unique fingerprints rotated as an evasion response to the
# published rmcej_otb_payload YARA rule. Both variants are currently active in the wild.
PRIMARY_SIG_V2='("Cot%3t=shtP",1111436)'

# Known config file glob patterns (used with find -name)
# Note: App.js (capital A) and app.js are different files on case-sensitive (Linux) filesystems
CONFIG_PATTERNS=(
    ".*\.config\.(ts|js|mjs)$"
    ".*\.woff2$"
    ".*(app|index|truffle)\.js$"
)

# TasksJacker / PolinRider merged cluster — known Vercel-hosted C2 subdomains
# Used in .vscode/tasks.json curl|bash payloads with runOn:folderOpen
C2_DOMAINS=(
    "260120.vercel.app"
    "default-configuration.vercel.app"
    "vscode-settings-bootstrap.vercel.app"
    "vscode-settings-config.vercel.app"
    "vscode-bootstrapper.vercel.app"
    "vscode-load-config.vercel.app"
)
STAKINGAME_UUID="e9b53a7c-2342-4b15-b02d-bd8b8f6a03f9"

# Known malicious npm packages published by the PolinRider threat actor
MALICIOUS_PACKAGES=(
    "tailwindcss-style-animate"
    "tailwind-mainanimation"
    "tailwind-autoanimation"
    "tailwind-animationbased"
    "tailwindcss-typography-style"
    "tailwindcss-style-modify"
    "tailwindcss-animate-style"
)

# Colors and bold pattern (disabled if not a terminal)
RED=""
GREEN=""
YELLOW=""
CYAN=""
BOLD=""
RESET=""

# Step 1: If a terminal set the ansi codes
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    RESET='\033[0m'
fi

# Counters
TOTAL_REPOS=0
INFECTED_FILES=0   # files with malware signatures (phase 1)
INFECTED_REPOS=0   # git repos with malicious artifacts (phase 2)

# A function that prints the script metadata
print_banner() {
    printf "\n"
    printf "${BOLD}========================================${RESET}\n"
    printf "${BOLD}  PolinRider Malware Scanner v%s${RESET}\n" "$VERSION"
    printf "${BOLD}  https://opensourcemalware.com${RESET}\n"
    printf "${BOLD}========================================${RESET}\n"
    printf "\n"
}

# A function to demo usage
print_usage() {
    printf "Usage: %s [--verbose] [--js-all] [directory]\n" "$0"
    printf "\n"
    printf "Scans git repositories for PolinRider malware artifacts.\n"
    printf "\n"
    printf "Options:\n"
    printf "  --verbose    Show detailed output for each repository\n"
    printf "  --js-all     Scan all .js files (not just known config files)\n"
    printf "  --help       Show this help message\n"
    printf "\n"
    printf "Examples:\n"
    printf "  %s                          # Scan current directory\n" "$0"
    printf "  %s /path/to/projects        # Scan specific directory\n" "$0"
    printf "  %s --verbose ~/projects     # Verbose scan\n" "$0"
    printf "  %s --js-all ~/projects      # Scan all .js files\n" "$0"
}

# A function to log when verbose is selected
log_verbose() {
    if [ "$VERBOSE" -eq 1 ]; then
        printf "  ${CYAN}[verbose]${RESET} %s\n" "$1"
    fi
}

# Check a single file for any known PolinRider signature (both variants).
# Prints a space-separated list of matched variant labels, empty string if clean.
# A file can carry both variants simultaneously (re-infection case documented in Apr 2026).
detect_variant() {
    local file="$1"
    local variants=""
    grep -qF "$PRIMARY_SIG"      "$file" 2>/dev/null && variants="${variants}v1-primary "
    grep -qP "$SECONDARY_SIG"    "$file" 2>/dev/null && variants="${variants}v1-secondary "
    grep -qF "$PRIMARY_SIG_V2"   "$file" 2>/dev/null && variants="${variants}v2-primary "
    printf '%s' "${variants% }"
}

# Scan any directory tree for files matching config patterns and check for malware signatures
scan_for_signatures() {
    local scan_dir="$1"
    local findings=""
    local finding_count=0

    log_verbose "Scanning for signatures under: $scan_dir"

    for pattern in "${CONFIG_PATTERNS[@]}"; do
        while IFS= read -r config_file; do
            if [ -f "$config_file" ]; then
                log_verbose "Checking $config_file"
                local variant
                variant="$(detect_variant "$config_file")"
                if [ -n "$variant" ]; then
                    findings="${findings}  ${RED}-${RESET} ${BOLD}${config_file}${RESET}: PolinRider payload detected (${variant})\n"
                    finding_count=$((finding_count + 1))
                fi
            fi
        done < <(find "$scan_dir" -regextype posix-extended -iregex "$pattern" -type f \
            -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null)
    done

    # If --js-all, scan all .js files — skipping files already covered by CONFIG_PATTERNS
    # to avoid double-counting (e.g. app.js and *.config.js are in both sets)
    if [ "$JS_ALL" -eq 1 ]; then
        while IFS= read -r jsfile; do
            if [ -f "$jsfile" ]; then
                # Make note of already scanned files
                local fname already_scanned
                fname="$(basename "$jsfile")"

                # Mark as scanned if in the config gile
                if [[ "$fname" =~ $pattern ]]; then
                    continue
                fi

                log_verbose "Checking $jsfile"
                local variant
                variant="$(detect_variant "$jsfile")"
                
                if [ -n "$variant" ]; then
                    findings="${findings}  ${RED}-${RESET} ${BOLD}${jsfile}${RESET}: PolinRider payload detected (${variant})\n"
                    finding_count=$((finding_count + 1))
                fi
            fi
        done < <(find "$scan_dir" -name "*.js" -type f \
            -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null)
    fi

    if [ "$finding_count" -gt 0 ]; then
        printf "\n${RED}${BOLD}[INFECTED]${RESET} %d file(s) with malware signatures found\n" "$finding_count"
        printf '%b' "$findings"   # '%b' interprets \n in data; format string stays a literal constant
        INFECTED_FILES=$((INFECTED_FILES + finding_count))
        return 1
    else
        log_verbose "No signature matches found"
        return 0
    fi
}

# Check a git repository root for PolinRider batch/config artifacts
check_git_artifacts() {
    local repo_dir="$1"
    local findings=""
    local finding_count=0

    log_verbose "Checking git artifacts: $repo_dir"

    # Check for batch file entries
    if [ -f "${repo_dir}/temp_auto_push.bat" ]; then
        findings="${findings}  ${RED}-${RESET} ${BOLD}temp_auto_push.bat${RESET}: Propagation script found\n"
        finding_count=$((finding_count + 1))
    fi

    # Check for config.bat
    if [ -f "${repo_dir}/config.bat" ]; then
        findings="${findings}  ${RED}-${RESET} ${BOLD}config.bat${RESET}: Hidden orchestrator found\n"
        finding_count=$((finding_count + 1))
    fi

    # Check .gitignore for config.bat entry — loop so each matched line is counted separately
    if [ -f "${repo_dir}/.gitignore" ]; then
        while IFS= read -r matched_entry; do
            [ -n "$matched_entry" ] || continue
            findings="${findings}  ${RED}-${RESET} ${BOLD}.gitignore${RESET}: ${matched_entry} entry injected\n"
            finding_count=$((finding_count + 1))
        done < <(grep -xE "(config|temp-auto)\.bat" "${repo_dir}/.gitignore" 2>/dev/null)
    fi

    # Check git reflog for suspicious patterns
    if [ -d "${repo_dir}/.git" ]; then
        if git -C "$repo_dir" reflog 2>/dev/null | grep -q "amend"; then
            log_verbose "Found amend entries in reflog"
            # Only flag if combined with other findings
            if [ "$finding_count" -gt 0 ]; then
                findings="${findings}  ${YELLOW}-${RESET} ${BOLD}git reflog${RESET}: Amended commits found (consistent with PolinRider behavior)\n"
            fi
        fi
    fi

    if [ "$finding_count" -gt 0 ]; then
        printf "\n${RED}${BOLD}[INFECTED]${RESET} %s\n" "$repo_dir"
        printf '%b' "$findings"   # '%b' interprets \n in data; format string stays a literal constant
        INFECTED_REPOS=$((INFECTED_REPOS + 1))
        return 1
    else
        log_verbose "Clean: $repo_dir"
        return 0
    fi
}

# Scan .vscode/tasks.json files for TasksJacker payloads (PolinRider merged cluster)
# Checks for known C2 subdomains, the StakingGame UUID, and the runOn:folderOpen+curl heuristic
check_tasks_json() {
    local scan_dir="$1"
    local findings=""
    local finding_count=0

    log_verbose "Scanning for malicious tasks.json files under: $scan_dir"

    while IFS= read -r tasks_file; do
        if [ -f "$tasks_file" ]; then
            local file_infected=0
            local file_findings=""

            for domain in "${C2_DOMAINS[@]}"; do
                if grep -qF "$domain" "$tasks_file" 2>/dev/null; then
                    file_findings="${file_findings}C2:${domain} "
                    file_infected=1
                fi
            done

            if grep -qF "$STAKINGAME_UUID" "$tasks_file" 2>/dev/null; then
                file_findings="${file_findings}StakingGame-UUID "
                file_infected=1
            fi

            # Heuristic: tasks that auto-execute curl/wget on folder open
            if grep -qF "folderOpen" "$tasks_file" 2>/dev/null && \
               grep -qE "curl|wget" "$tasks_file" 2>/dev/null; then
                file_findings="${file_findings}runOn:folderOpen+curl/wget "
                file_infected=1
            fi

            if [ "$file_infected" -eq 1 ]; then
                findings="${findings}  ${RED}-${RESET} ${BOLD}${tasks_file}${RESET}: Malicious tasks.json (${file_findings% })\n"
                finding_count=$((finding_count + 1))
            fi
        fi
    done < <(find "$scan_dir" -path "*/.vscode/tasks.json" -type f \
        -not -path "*/node_modules/*" 2>/dev/null)

    if [ "$finding_count" -gt 0 ]; then
        printf "\n${RED}${BOLD}[INFECTED]${RESET} %d tasks.json file(s) with TasksJacker payload found\n" "$finding_count"
        printf '%b' "$findings"
        INFECTED_FILES=$((INFECTED_FILES + finding_count))
        return 1
    else
        log_verbose "No malicious tasks.json found"
        return 0
    fi
}

# Check package.json for known malicious npm dependencies published by the threat actor
check_package_json() {
    local scan_dir="$1"
    local findings=""
    local finding_count=0

    log_verbose "Scanning for malicious npm packages under: $scan_dir"

    while IFS= read -r pkg_file; do
        if [ -f "$pkg_file" ]; then
            local file_infected=0
            local file_findings=""

            for pkg in "${MALICIOUS_PACKAGES[@]}"; do
                if grep -qF "\"${pkg}\"" "$pkg_file" 2>/dev/null; then
                    file_findings="${file_findings}${pkg} "
                    file_infected=1
                fi
            done

            if [ "$file_infected" -eq 1 ]; then
                findings="${findings}  ${RED}-${RESET} ${BOLD}${pkg_file}${RESET}: Malicious npm package(s): ${file_findings% }\n"
                finding_count=$((finding_count + 1))
            fi
        fi
    done < <(find "$scan_dir" -name "package.json" -type f \
        -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null)

    if [ "$finding_count" -gt 0 ]; then
        printf "\n${RED}${BOLD}[INFECTED]${RESET} %d package.json file(s) with malicious npm dependency found\n" "$finding_count"
        printf '%b' "$findings"
        INFECTED_FILES=$((INFECTED_FILES + finding_count))
        return 1
    else
        log_verbose "No malicious npm packages found"
        return 0
    fi
}

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --verbose)
            VERBOSE=1
            shift
            ;;
        --js-all)
            JS_ALL=1
            shift
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        -*)
            printf "Error: Unknown option '%s'\n" "$1" >&2
            print_usage >&2
            exit 2
            ;;
        *)
            if [ -n "$SCAN_DIR" ]; then
                printf "Error: Multiple directories specified\n" >&2
                print_usage >&2
                exit 2
            fi
            SCAN_DIR="$1"
            shift
            ;;
    esac
done

# Default to current directory
if [ -z "$SCAN_DIR" ]; then
    SCAN_DIR="."
fi

# Resolve to absolute path
SCAN_DIR="$(cd "$SCAN_DIR" 2>/dev/null && pwd)"
if [ $? -ne 0 ] || [ ! -d "$SCAN_DIR" ]; then
    printf "Error: Directory not found or not accessible: %s\n" "$SCAN_DIR" >&2
    exit 2
fi

print_banner

printf "Scanning: ${BOLD}%s${RESET}\n" "$SCAN_DIR"
printf "\n"

# Phase 1: scan all files under SCAN_DIR for malware signatures (not limited to git repos)
printf "Checking config files for malware signatures...\n"
scan_for_signatures "$SCAN_DIR"

# Phase 2: find git repositories and check for PolinRider batch/config artifacts
# Use an indexed array so paths with spaces are handled correctly
REPO_DIRS=()
while IFS= read -r git_dir; do
    REPO_DIRS+=("$(dirname "$git_dir")")
done < <(find "$SCAN_DIR" -name .git -type d 2>/dev/null | sort)

TOTAL_REPOS=${#REPO_DIRS[@]}

if [ "$TOTAL_REPOS" -gt 0 ]; then
    printf "\nChecking ${BOLD}%d${RESET} git repositories for artifacts...\n" "$TOTAL_REPOS"
    for repo_dir in "${REPO_DIRS[@]}"; do
        check_git_artifacts "$repo_dir"
    done
fi

# Phase 3: check .vscode/tasks.json for TasksJacker payloads (PolinRider merged cluster)
printf "\nChecking .vscode/tasks.json files for TasksJacker payloads...\n"
check_tasks_json "$SCAN_DIR"

# Phase 4: check package.json for known malicious npm dependencies
printf "\nChecking package.json for malicious npm packages...\n"
check_package_json "$SCAN_DIR"

# Print summary
CLEAN_REPOS=$((TOTAL_REPOS - INFECTED_REPOS))
printf "\n"

if [ "$CLEAN_REPOS" -gt 0 ]; then
    printf "${GREEN}${BOLD}[CLEAN]${RESET} %d repositories scanned clean\n" "$CLEAN_REPOS"
fi

printf "\n${BOLD}========================================${RESET}\n"
if [ "$INFECTED_FILES" -gt 0 ] || [ "$INFECTED_REPOS" -gt 0 ]; then
    printf "  ${RED}${BOLD}RESULTS:${RESET}\n"
    [ "$INFECTED_FILES" -gt 0 ] && printf "  ${RED}${BOLD}  %d file(s) with malware signatures${RESET}\n" "$INFECTED_FILES"
    [ "$INFECTED_REPOS" -gt 0 ] && printf "  ${RED}${BOLD}  %d git repo(s) with malicious artifacts${RESET}\n" "$INFECTED_REPOS"
else
    printf "  ${GREEN}${BOLD}RESULTS: No infections found${RESET}\n"
fi
printf "${BOLD}========================================${RESET}\n"

if [ "$INFECTED_FILES" -gt 0 ] || [ "$INFECTED_REPOS" -gt 0 ]; then
    printf "\n${BOLD}REMEDIATION STEPS:${RESET}\n"
    printf "0. Remove the imports for require in the infected config files"
    printf "1. Remove the obfuscated payload from the end of infected config files\n"
    printf "   (anything after the legitimate config beginning with global['!'] or global['_V'])\n"
    printf "   Covers both variants: rmcej%%otb%% (original) and Cot%%3t=shtP (rotated Apr 2026)\n"
    printf "2. Delete temp_auto_push.bat and config.bat if present\n"
    printf "3. Remove \"config.bat\" from .gitignore\n"
    printf "4. Remove any malicious .vscode/tasks.json files referencing known C2 subdomains\n"
    printf "5. Remove malicious npm packages from package.json, then: npm install --package-lock-only\n"
    printf "6. Check npm global packages and VS Code extensions for the initial dropper\n"
    printf "7. Rotate all secrets/tokens in scope during any compromised build\n"
    printf "8. Force-push clean versions to GitHub\n"
    printf "9. Re-scan periodically — the actor re-infects previously-cleaned repos\n"
    printf "\n"
    exit 1
fi

printf "\n"
exit 0
