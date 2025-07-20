#!/bin/sh

set -eu

USAGE() {
	printf "Usage: %s <search term> <directory1> [directory2 ...]\n" "$0"
	exit 1
}

[ "$#" -lt 2 ] && USAGE

. /opt/muos/script/var/func.sh

# TODO:
# Changing directories and running the script results in, seemingly random occurrences of, an unkillable zombie process.
# Switching between "Local" and "Global" search across directories consistently causes system lock-ups.
#
# The script fails with complex content structures, including multi-tiered directories.
# https://github.com/MustardOS/internal/pull/573#issuecomment-3093861488
#
# Solution: Consider re-introducing some intermediate IO back in to avoid long running process?

# TODO:
# re: FRIENDLY_JSON
# This was a missed file during a recent commit for the friendly file naming scheme system.
# You will need to ensure it is being used at /run/muos/storage/info/name/global.json.
# https://github.com/MustardOS/internal/pull/573#discussion_r2217660401

# TEMP
DEBUG_LOG="$(GET_VAR "device" "storage/rom/mount")/MUOS/info/debug.log"
# Output the raw command line arguments to the debug log, with a timestamp
echo "$(date '+%Y-%m-%d %H:%M:%S') - Running find.sh" >> "$DEBUG_LOG"
echo "  Command: $0 $*" >> "$DEBUG_LOG"
# TEMP

RESULTS_JSON="$(GET_VAR "device" "storage/rom/mount")/MUOS/info/search.json"
SKIP_FILE="$(GET_VAR "device" "storage/sdcard/mount")/MUOS/info/skip.ini"
[ ! -s "$SKIP_FILE" ] && SKIP_FILE="$(GET_VAR "device" "storage/rom/mount")/MUOS/info/skip.ini"

S_TERM="$1"

# Shift one argument over so we are left with only directories to search
shift

# Create temporary directory for intermediate files
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

TMP_MATCHES="$TMP_DIR/matches.txt"

# Convert directories array to JSON
directories=$(printf '%s\n' "$@" | jq -R . | jq -s .)

# First stage: Find matching files and store in temporary file
# Process each directory separately to avoid long-running pipeline
for S_DIR in "$@"; do
    # rg --files: List all files in directory (no content search, just enumerate files)
    # --color=never: Disable ANSI color codes (clean output for piping)
    # --ignore-file: Use skip.ini to exclude unwanted files/directories
    # 2>/dev/null: Suppress permission denied errors
    /opt/muos/bin/rg --color=never --files "$S_DIR" --ignore-file "$SKIP_FILE" 2>/dev/null |

		# rg (second call): Filter filenames by search term
		# --color=never: Disable ANSI color codes for clean piping
		# --pcre2: Use Perl-compatible regex engine (supports advanced patterns)
		# -i: Case-insensitive matching
		# "/(?!.*\/).*$S_TERM": Regex to match only filenames, not directory paths
		#   /: Match paths ending with slash (file paths)
		#   (?!.*\/): Negative lookahead - ensure no slash after this point
		#   .*$S_TERM: Match any characters followed by search term
		/opt/muos/bin/rg --color=never --pcre2 -i "/(?!.*\/).*$S_TERM" |
        # sed: Remove the leading directory path from each file (only affects local search)
        # || true: Prevent script exit when no matches found (rg exits with status 1)
        sed "s|^$S_DIR/||" >> "$TMP_MATCHES" || true
done

# Second stage: Process the collected matches into JSON
# This avoids keeping the entire pipeline active for the full duration
cat "$TMP_MATCHES" |
# Input to jq: File paths (one per line)
# Example:
#   /mnt/sdcard/ROMS/Pico-8/awesome_platform_adventure.p8
#   /mnt/sdcard/ROMS/Ports/open_source_adventure.zip
# jq -R: Read each line as string instead of JSON
# jq -s: read all inputs into an array and use it as
# the single input value
jq -R . | jq -s --arg lookup "$S_TERM" --argjson directories "$directories" '
	# map(...): Transform each file path string into {dir:..., file:...} object
	#   split("/"): Split path by "/" into array of components
	#   {dir: (.[:-1] | join("/")), file: .[-1]}: Create object where:
	#     .[:-1]: All elements except last (directory components)
	#     join("/"): Rejoin directory components with "/"
	#    .[-1]: Last element (filename)
	map(split("/") | {dir: (.[:-1] | join("/")), file: .[-1]}) |

	# group_by(.dir): Group all objects by their "dir" field (sorted)
	# Creates array of arrays, each sub-array contains objects with same directory
	group_by(.dir) |

	# map({...}): Transform each group into key-value pair object
	map({
		# key: .[0].dir: Use directory from first object in group (all have same dir)
		# If directory is empty (e.g. local search, with path removed by sed above),
		# use "." instead
		key: (.[0].dir | if . == "" then "." else . end),

		# value: {content: [...]}: Create object with "content" array
		# map(.file): Extract "file" field from each object in group
		# | sort: Sort filenames alphabetically
		value: {content: map(.file) | sort}
	}) |

	# from_entries: Convert array of {key:..., value:...} objects into single object
	# Each key becomes a property name, each value becomes the property value
	from_entries |

	# Final JSON structure: Create object with lookup term, directories, and folders
	#   $lookup: Use the lookup variable passed from shell
	#   $directories: Use the directories array passed from shell
	#   .: Reference the current grouped folders object
	#
	# Example:
	#   {
	#     "lookup": "adventure",
	#     "directories": ["/mnt/sdcard/ROMS"],
	#     "folders": {
	#       "/mnt/sdcard/ROMS/Pico-8": {
	#         "content": ["awesome_platform_adventure.p8"]
	#       },
	#       "/mnt/sdcard/ROMS/Ports": {
	#         "content": ["open_source_adventure.zip"]
	#       }
	#     }
	#   }
	{lookup: $lookup, directories: $directories, folders: .}
' > "$RESULTS_JSON"