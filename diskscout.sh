#!/bin/bash
# DiskScout — Find the largest files on your Mac
# READ-ONLY: This script NEVER deletes, moves, or modifies any files.

set -uo pipefail

COUNT=50
MIN_SIZE=""
SEARCH_PATH="$HOME"
FORMAT="table"
SHOW_HIDDEN=false
EXCLUDE_SYSTEM=true
OPEN_MODE=false
FORCE_SCAN=false
CACHE_MAX_AGE=3600

usage() {
    cat <<'HELP'
DiskScout — Find the largest files on your Mac

Usage: diskscout.sh [OPTIONS]

Options:
  -n NUM        Number of files to show (default: 50)
  -p PATH       Directory to search (default: ~ home folder)
  -m SIZE       Minimum file size filter (default: 1M). Use 100M, 1G, etc.
  -a            Include hidden/dot files
  -s            Include system directories (/System, /Library, etc.)
  -f            Force fresh scan (ignore cache)
  -c            Output as CSV instead of table
  -o            After results, prompt to reveal any file in Finder
  -h            Show this help

Examples:
  diskscout.sh                     # Top 50 largest files in home folder
  diskscout.sh -n 20 -o            # Top 20, then reveal any in Finder
  diskscout.sh -p /                # Scan entire disk (slower)
  diskscout.sh -p ~/Downloads      # Scan just Downloads
  diskscout.sh -m 1G               # Only files >= 1GB
  diskscout.sh -f                  # Force fresh scan, skip cache
  diskscout.sh -c > report.csv     # Export to CSV

READ-ONLY — will NEVER delete, move, or modify any files.
HELP
    exit 0
}

while getopts "n:p:m:ascofh" opt; do
    case $opt in
        n) COUNT="$OPTARG" ;;
        p) SEARCH_PATH="$OPTARG" ;;
        m) MIN_SIZE="$OPTARG" ;;
        a) SHOW_HIDDEN=true ;;
        s) EXCLUDE_SYSTEM=false ;;
        c) FORMAT="csv" ;;
        o) OPEN_MODE=true ;;
        f) FORCE_SCAN=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Apple logo character (renders on macOS Terminal with system fonts)
APPLE=$(printf '\xEF\xA3\xBF')

# Colors (disabled for CSV or piped output)
if [[ "$FORMAT" == "table" ]] && [[ -t 1 ]]; then
    BOLD="\033[1m"
    DIM="\033[2m"
    CYAN="\033[36m"
    YELLOW="\033[33m"
    RED="\033[31m"
    GREEN="\033[32m"
    BGREEN="\033[92m"
    WHITE="\033[97m"
    MAGENTA="\033[35m"
    RESET="\033[0m"
else
    BOLD="" DIM="" CYAN="" YELLOW="" RED="" GREEN="" BGREEN="" WHITE="" MAGENTA="" RESET=""
    APPLE=""
fi

# 6 months ago as epoch
SIX_MONTHS_AGO=$(date -v-6m +%s 2>/dev/null || date -d '6 months ago' +%s 2>/dev/null || echo 0)

human_size() {
    local bytes=$1
    if (( bytes >= 1073741824 )); then
        printf "%.1f GB" "$(echo "scale=1; $bytes / 1073741824" | bc)"
    elif (( bytes >= 1048576 )); then
        printf "%.1f MB" "$(echo "scale=1; $bytes / 1048576" | bc)"
    elif (( bytes >= 1024 )); then
        printf "%.1f KB" "$(echo "scale=1; $bytes / 1024" | bc)"
    else
        printf "%d B" "$bytes"
    fi
}

time_ago() {
    local mod_epoch=$1
    local now
    now=$(date +%s)
    local diff=$(( now - mod_epoch ))
    local days=$(( diff / 86400 ))
    if (( days >= 365 )); then
        printf "%dyr" $(( days / 365 ))
    elif (( days >= 30 )); then
        printf "%dmo" $(( days / 30 ))
    elif (( days >= 1 )); then
        printf "%dd" "$days"
    else
        printf "<1d"
    fi
}

friendly_dir() {
    local dir="$1"
    if [[ "$dir" == "$HOME" ]]; then
        echo "~"
    elif [[ "$dir" == "$HOME/"* ]]; then
        echo "~/${dir#$HOME/}"
    else
        echo "$dir"
    fi
}

parse_size_bytes() {
    local input="$1"
    local num="${input%[A-Za-z]*}"
    local unit="${input##*[0-9]}"
    case "$unit" in
        [kK]) echo $(( num * 1024 )) ;;
        [mM]) echo $(( num * 1048576 )) ;;
        [gG]) echo $(( num * 1073741824 )) ;;
        [tT]) echo $(( num * 1099511627776 )) ;;
        *)    echo "$num" ;;
    esac
}

# Shorten long filenames: keep start + extension, collapse the middle
# "2F7A8B3C-91DE-4F0A-B8C7-long-garbage-attachment-name.pdf" → "2F7A8B3C-91D…name.pdf"
MAX_NAME=45
truncate_name() {
    local name="$1"
    local len=${#name}
    (( len <= MAX_NAME )) && { echo "$name"; return; }

    local ext=""
    local base="$name"
    if [[ "$name" == *.* ]]; then
        ext=".${name##*.}"
        base="${name%.*}"
    fi

    local ext_len=${#ext}
    local keep=$(( MAX_NAME - ext_len - 1 ))
    (( keep < 8 )) && keep=8
    local front=$(( keep / 2 ))
    local back=$(( keep - front ))

    echo "${base:0:$front}…${base: -$back}${ext}"
}

# Classify a file path. Output: "category|reason"
# Categories: system, cleanup, normal
classify() {
    local fp="$1"

    # ── SYSTEM / IMPORTANT ────────────────────────────────

    # macOS core OS
    if [[ "$fp" == /System/* || "$fp" == /usr/* || "$fp" == /bin/* || "$fp" == /sbin/* ]]; then
        echo "system|macOS system file — required for your Mac to run"
        return
    fi

    # App bundles
    if [[ "$fp" == *".app/"* ]]; then
        local app_name
        app_name=$(echo "$fp" | sed 's|.*\(/[^/]*\.app\)/.*|\1|' | sed 's|^/||')
        echo "system|Part of ${app_name} — needed for the app to work"
        return
    fi

    # Frameworks
    if [[ "$fp" == *".framework/"* ]]; then
        echo "system|System or app framework — do not remove"
        return
    fi

    # Keychain and security files
    if [[ "$fp" == *.keychain* || "$fp" == */Keychains/* ]]; then
        echo "system|Keychain — contains your passwords and certificates"
        return
    fi

    # Important Library data
    if [[ "$fp" == */Library/Preferences/* ]]; then
        echo "system|App preferences — removing resets app settings"
        return
    fi
    if [[ "$fp" == */Library/Mail/* ]]; then
        echo "system|Mail data — contains your email"
        return
    fi
    if [[ "$fp" == */Library/Messages/* ]]; then
        echo "system|iMessage data — contains your messages"
        return
    fi
    if [[ "$fp" == */Library/Calendars/* ]]; then
        echo "system|Calendar data"
        return
    fi
    if [[ "$fp" == */Library/Contacts/* || "$fp" == */Library/AddressBook/* ]]; then
        echo "system|Contacts data"
        return
    fi
    if [[ "$fp" == */Library/Safari/Bookmarks* || "$fp" == */Library/Safari/History* ]]; then
        echo "system|Safari data — bookmarks and history"
        return
    fi

    # Photo and Music libraries
    if [[ "$fp" == *"Photos Library"* ]]; then
        echo "system|Photos library — contains your photos"
        return
    fi
    if [[ "$fp" == *"Music Library"* || "$fp" == *"iTunes Library"* ]]; then
        echo "system|Music library data"
        return
    fi

    # Core Data / databases in Library
    if [[ "$fp" == */Library/*.sqlite* || "$fp" == */Library/*.db ]]; then
        echo "system|App database — may contain important data"
        return
    fi

    # ── SAFE TO DELETE CANDIDATES ─────────────────────────

    # Caches
    if [[ "$fp" == */Caches/* || "$fp" == */cache/* || "$fp" == */Cache/* ]]; then
        echo "cleanup|App cache — regenerates automatically"
        return
    fi

    # node_modules
    if [[ "$fp" == */node_modules/* ]]; then
        echo "cleanup|Reinstall anytime with npm install or yarn"
        return
    fi

    # Xcode DerivedData
    if [[ "$fp" == */DerivedData/* ]]; then
        echo "cleanup|Xcode build cache — rebuilds automatically"
        return
    fi

    # Build artifacts
    if [[ "$fp" == */.build/* || "$fp" == */__pycache__/* || "$fp" == */build/intermediates/* ]]; then
        echo "cleanup|Build artifact — regenerates on next build"
        return
    fi

    # Debug symbols
    if [[ "$fp" == *.dSYM* ]]; then
        echo "cleanup|Debug symbols — not needed unless debugging crashes"
        return
    fi

    # CocoaPods
    if [[ "$fp" == */Pods/* ]]; then
        echo "cleanup|CocoaPods — reinstall with pod install"
        return
    fi

    # Gradle
    if [[ "$fp" == */.gradle/* ]]; then
        echo "cleanup|Gradle cache — regenerates automatically"
        return
    fi

    # Log files
    if [[ "$fp" == *.log ]]; then
        echo "cleanup|Log file — usually safe to remove"
        return
    fi
    if [[ "$fp" == */Logs/* || "$fp" == */logs/* ]]; then
        echo "cleanup|Log file — usually safe to remove"
        return
    fi
    if [[ "$fp" == */DiagnosticReports/* || "$fp" == */CrashReporter/* ]]; then
        echo "cleanup|Crash report — safe to remove"
        return
    fi

    # Temp files
    if [[ "$fp" == *.tmp || "$fp" == *.temp ]]; then
        echo "cleanup|Temporary file"
        return
    fi

    # iOS device backups
    if [[ "$fp" == */MobileSync/Backup/* ]]; then
        echo "cleanup|iOS backup — verify you have a current one first"
        return
    fi

    # Installers and disk images in user directories
    if [[ "$fp" == "$HOME/"* ]]; then
        case "${fp##*/}" in
            *.dmg)  echo "cleanup|Disk image — delete if already installed"; return ;;
            *.pkg)  echo "cleanup|Installer package — delete if already installed"; return ;;
            *.iso)  echo "cleanup|Disk image — delete if no longer needed"; return ;;
        esac
    fi

    # Archives in Downloads
    if [[ "$fp" == "$HOME/Downloads/"* ]]; then
        case "${fp##*/}" in
            *.zip|*.tar.gz|*.tar.bz2|*.rar|*.7z|*.tgz)
                echo "cleanup|Archive in Downloads — delete if already extracted"
                return ;;
        esac
    fi

    # Homebrew downloads cache
    if [[ "$fp" == */Homebrew/downloads/* ]]; then
        echo "cleanup|Homebrew download cache — run brew cleanup"
        return
    fi

    echo "normal|"
}

# ── Minimum size threshold ────────────────────────────────

if [[ -n "$MIN_SIZE" ]]; then
    MIN_BYTES=$(parse_size_bytes "$MIN_SIZE")
else
    MIN_BYTES=1048576  # Default 1MB — skip tiny files for speed
fi

# ── Build find arguments (fallback scanner) ───────────────

FIND_ARGS=("$SEARCH_PATH" -type f -size +"${MIN_BYTES}c")

if [[ "$EXCLUDE_SYSTEM" == true ]] && [[ "$SEARCH_PATH" == "/" ]]; then
    FIND_ARGS+=( \
        -not -path "/System/*" \
        -not -path "/Library/*" \
        -not -path "/private/*" \
        -not -path "/Volumes/*" \
        -not -path "*/Trash/*" \
    )
fi

if [[ "$SHOW_HIDDEN" == false ]]; then
    FIND_ARGS+=(-not -path "*/.*")
fi

# ── Build grep filters for Spotlight results ──────────────

build_grep_filters() {
    local cmd="cat"
    if [[ "$EXCLUDE_SYSTEM" == true ]] && [[ "$SEARCH_PATH" == "/" ]]; then
        cmd="$cmd | grep -v '^/System/' | grep -v '^/Library/' | grep -v '^/private/' | grep -v '^/Volumes/' | grep -v '/Trash/'"
    fi
    if [[ "$SHOW_HIDDEN" == false ]]; then
        cmd="$cmd | grep -v '/\\.'"
    fi
    echo "$cmd"
}

# ── Cache setup ───────────────────────────────────────────

CACHE_DIR="$HOME/.cache/diskscout"
mkdir -p "$CACHE_DIR" 2>/dev/null
CACHE_KEY=$(echo "${SEARCH_PATH}|${MIN_BYTES}|${SHOW_HIDDEN}|${EXCLUDE_SYSTEM}" | md5)
CACHE_FILE="${CACHE_DIR}/${CACHE_KEY}.cache"

# ── Header ────────────────────────────────────────────────

if [[ "$FORMAT" == "table" ]]; then
    echo ""
    echo -e "${BOLD}  DiskScout${RESET} ${DIM}— Read-Only File Size Scanner${RESET}"
    echo -e "${DIM}  Searching: ${RESET}${SEARCH_PATH}"
    echo -e "${DIM}  Showing:   ${RESET}Top ${COUNT} largest files"
    if [[ -n "$MIN_SIZE" ]]; then
        echo -e "${DIM}  Min size:  ${RESET}${MIN_SIZE}"
    else
        echo -e "${DIM}  Min size:  ${RESET}1 MB ${DIM}(use -m to change)${RESET}"
    fi
fi

# ── Scan (with cache) ─────────────────────────────────────

TMPFILE=$(mktemp)
trap "rm -f $TMPFILE" EXIT
SCAN_METHOD=""
SCAN_TIME=0
CACHE_USED=false

# Check cache first
if [[ "$FORCE_SCAN" == false ]] && [[ -f "$CACHE_FILE" ]]; then
    CACHE_MOD=$(stat -f '%m' "$CACHE_FILE")
    NOW=$(date +%s)
    CACHE_AGE=$(( NOW - CACHE_MOD ))
    if (( CACHE_AGE < CACHE_MAX_AGE )); then
        head -n "$COUNT" "$CACHE_FILE" > "$TMPFILE"
        CACHE_USED=true
        CACHE_MINS=$(( CACHE_AGE / 60 ))
        if (( CACHE_MINS == 0 )); then
            SCAN_METHOD="cache (<1min old)"
        else
            SCAN_METHOD="cache (${CACHE_MINS}min old)"
        fi
    fi
fi

# Scan if no usable cache
if [[ "$CACHE_USED" == false ]]; then
    SCAN_START=$(date +%s)
    SCAN_STORE=$(mktemp)

    # Spinner runs in background during scan
    spinner_pid=""
    if [[ "$FORMAT" == "table" ]] && [[ -t 1 ]]; then
        echo ""
        (
            chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
            i=0
            while true; do
                elapsed=$(( $(date +%s) - SCAN_START ))
                printf "\r${DIM}  %s Scanning... %ds elapsed${RESET}  " "${chars:i%10:1}" "$elapsed"
                sleep 0.2
                i=$((i+1))
            done
        ) &
        spinner_pid=$!
    fi

    # Fast path: Spotlight index (mdfind)
    if command -v mdfind &>/dev/null; then
        FILTER_CMD=$(build_grep_filters)

        eval "mdfind 'kMDItemFSSize > ${MIN_BYTES}' -onlyin '${SEARCH_PATH}' 2>/dev/null | ${FILTER_CMD}" | \
            tr '\n' '\0' | \
            xargs -0 stat -f '%z %m %N' 2>/dev/null | \
            sort -rn | \
            head -n 500 > "$SCAN_STORE"

        if [[ -s "$SCAN_STORE" ]]; then
            SCAN_METHOD="Spotlight"
        fi
    fi

    # Fallback: filesystem walk with size pre-filter
    if [[ -z "$SCAN_METHOD" ]]; then
        find "${FIND_ARGS[@]}" -print0 2>/dev/null | \
            xargs -0 stat -f '%z %m %N' 2>/dev/null | \
            sort -rn | \
            head -n 500 > "$SCAN_STORE"
        SCAN_METHOD="filesystem"
    fi

    # Stop spinner
    if [[ -n "$spinner_pid" ]]; then
        kill "$spinner_pid" 2>/dev/null
        wait "$spinner_pid" 2>/dev/null
        printf "\r                                          \r"
    fi

    SCAN_END=$(date +%s)
    SCAN_TIME=$(( SCAN_END - SCAN_START ))

    # Save to cache and extract requested count
    cp "$SCAN_STORE" "$CACHE_FILE" 2>/dev/null
    head -n "$COUNT" "$SCAN_STORE" > "$TMPFILE"
    rm -f "$SCAN_STORE"
fi

if [[ "$FORMAT" == "table" ]]; then
    if [[ "$CACHE_USED" == true ]]; then
        echo ""
        echo -e "${DIM}  Instant (${SCAN_METHOD}). Use ${RESET}${BOLD}-f${RESET}${DIM} to force fresh scan.${RESET}"
    else
        echo -e "\r${DIM}  Done in ${SCAN_TIME}s (${SCAN_METHOD}). Next run will be instant.${RESET}"
    fi
    echo ""
    echo -e "  ${DIM}LEGEND:${RESET}  ${BGREEN}${APPLE} KEEP${RESET} = important, don't touch    ${RED}✂ CLEANUP${RESET} = safe to delete    ${YELLOW}💤 STALE${RESET} = unused 6+ months"
fi

# ── Parse and display ─────────────────────────────────────

LINE_NUM=0
TOTAL_BYTES=0
SYSTEM_BYTES=0; SYSTEM_COUNT=0
CLEANUP_BYTES=0; CLEANUP_COUNT=0
STALE_BYTES=0; STALE_COUNT=0
NORMAL_BYTES=0; NORMAL_COUNT=0

declare -a RESULT_FILES=()

if [[ "$FORMAT" == "csv" ]]; then
    echo "Rank,Size (Bytes),Size (Human),Category,File Name,Finder Directory,Full Path,Last Modified,Stale,Reason"
fi

while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # Parse: "size mod_epoch filepath"
    size="${line%% *}"
    rest="${line#* }"
    mod_epoch="${rest%% *}"
    filepath="${rest#* }"

    LINE_NUM=$((LINE_NUM + 1))
    TOTAL_BYTES=$((TOTAL_BYTES + size))

    filename=$(basename "$filepath")
    short_name=$(truncate_name "$filename")
    dirpath=$(dirname "$filepath")
    display_dir=$(friendly_dir "$dirpath")
    ago=$(time_ago "$mod_epoch")

    is_stale=false
    if (( mod_epoch < SIX_MONTHS_AGO )); then
        is_stale=true
    fi

    # Classify
    classification=$(classify "$filepath")
    category="${classification%%|*}"
    reason="${classification#*|}"

    RESULT_FILES+=("$filepath")

    if [[ "$FORMAT" == "csv" ]]; then
        ext="${filename##*.}"
        [[ "$ext" == "$filename" ]] && ext=""
        label="$category"
        [[ "$is_stale" == true && "$category" == "normal" ]] && label="stale"
        echo "${LINE_NUM},${size},$(human_size "$size"),${label},\"${filename}\",\"${display_dir}\",\"${filepath}\",${ago},${is_stale},\"${reason}\""
    else
        hsize=$(human_size "$size")

        # Build the badge
        badge=""
        badge_color=""
        detail_line=""

        case "$category" in
            system)
                badge="${BGREEN}${APPLE} KEEP${RESET}"
                badge_color="$BGREEN"
                detail_line="${BGREEN}${DIM}↳ ${reason}${RESET}"
                SYSTEM_BYTES=$((SYSTEM_BYTES + size))
                SYSTEM_COUNT=$((SYSTEM_COUNT + 1))
                ;;
            cleanup)
                badge="${RED}✂ CLEANUP${RESET}"
                badge_color="$RED"
                detail_line="${RED}${DIM}↳ ${reason}${RESET}"
                CLEANUP_BYTES=$((CLEANUP_BYTES + size))
                CLEANUP_COUNT=$((CLEANUP_COUNT + 1))
                ;;
            normal)
                if [[ "$is_stale" == true ]]; then
                    badge="${YELLOW}💤 STALE ${ago}${RESET}"
                    badge_color="$YELLOW"
                    detail_line="${YELLOW}${DIM}↳ Last modified ${ago} ago — review if still needed${RESET}"
                    STALE_BYTES=$((STALE_BYTES + size))
                    STALE_COUNT=$((STALE_COUNT + 1))
                else
                    badge="${DIM}──${RESET}"
                    badge_color="$WHITE"
                    NORMAL_BYTES=$((NORMAL_BYTES + size))
                    NORMAL_COUNT=$((NORMAL_COUNT + 1))
                fi
                ;;
        esac

        # Size color (red for huge, yellow for large)
        size_c="$RESET"
        if (( size >= 1073741824 )); then
            size_c="$RED"
        elif (( size >= 104857600 )); then
            size_c="$YELLOW"
        elif (( size >= 10485760 )); then
            size_c="$CYAN"
        fi

        echo ""
        printf "  ${DIM}#%-3d${RESET}  ${size_c}${BOLD}%10s${RESET}  %-20b  ${WHITE}${BOLD}%s${RESET}\n" \
            "$LINE_NUM" "$hsize" "$badge" "$short_name"
        printf "                          ${DIM}Finder: ${RESET}${CYAN}%s${RESET}\n" "$display_dir"
        if [[ -n "$detail_line" ]]; then
            printf "                          %b\n" "$detail_line"
        fi
    fi
done < "$TMPFILE"

# ── Summary ───────────────────────────────────────────────

if [[ "$FORMAT" == "table" ]]; then
    echo ""
    echo -e "  ${DIM}══════════════════════════════════════════════════════════════${RESET}"
    echo -e "  ${BOLD}SUMMARY${RESET}"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"

    if (( SYSTEM_COUNT > 0 )); then
        printf "  ${BGREEN}${APPLE} KEEP${RESET}      %3d files   ${BOLD}%10s${RESET}   ${DIM}Do not delete${RESET}\n" \
            "$SYSTEM_COUNT" "$(human_size $SYSTEM_BYTES)"
    fi

    if (( CLEANUP_COUNT > 0 )); then
        printf "  ${RED}✂ CLEANUP${RESET}   %3d files   ${BOLD}%10s${RESET}   ${DIM}Safe to delete${RESET}\n" \
            "$CLEANUP_COUNT" "$(human_size $CLEANUP_BYTES)"
    fi

    if (( STALE_COUNT > 0 )); then
        printf "  ${YELLOW}💤 STALE${RESET}    %3d files   ${BOLD}%10s${RESET}   ${DIM}Unused 6+ months${RESET}\n" \
            "$STALE_COUNT" "$(human_size $STALE_BYTES)"
    fi

    if (( NORMAL_COUNT > 0 )); then
        printf "  ${DIM}── OTHER${RESET}    %3d files   ${BOLD}%10s${RESET}   ${DIM}Recently used${RESET}\n" \
            "$NORMAL_COUNT" "$(human_size $NORMAL_BYTES)"
    fi

    echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"

    RECOVERABLE=$((CLEANUP_BYTES + STALE_BYTES))
    if (( RECOVERABLE > 0 )); then
        echo -e "  ${BOLD}Potential savings: $(human_size $RECOVERABLE)${RESET} ${DIM}(cleanup + stale)${RESET}"
    fi

    echo ""
    echo -e "  ${GREEN}✓ Read-only scan complete. No files were modified or deleted.${RESET}"

    # Finder reveal mode
    if [[ "$OPEN_MODE" == true ]] && [[ $LINE_NUM -gt 0 ]]; then
        echo ""
        echo -e "  ${BOLD}Reveal in Finder${RESET}"
        echo -e "  ${DIM}Enter a number (1-${LINE_NUM}) to show the file in Finder.${RESET}"
        echo -e "  ${DIM}Press Enter or type 'q' to quit.${RESET}"
        echo ""

        while true; do
            printf "  Open #: "
            read -r choice
            [[ -z "$choice" || "$choice" == "q" || "$choice" == "Q" ]] && break

            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= LINE_NUM )); then
                idx=$((choice - 1))
                target="${RESULT_FILES[$idx]}"
                echo -e "  ${GREEN}Revealing in Finder → $(friendly_dir "$(dirname "$target")")/${BOLD}$(basename "$target")${RESET}"
                open -R "$target"
            else
                echo -e "  ${RED}Enter a number between 1 and ${LINE_NUM}${RESET}"
            fi
        done
    elif [[ "$OPEN_MODE" == false ]] && [[ $LINE_NUM -gt 0 ]]; then
        echo ""
        echo -e "  ${DIM}Tip: Run with ${RESET}${BOLD}-o${RESET}${DIM} to reveal any result in Finder${RESET}"
    fi

    echo ""
fi
