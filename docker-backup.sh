#!/usr/bin/env bash
#
# Filename: script.sh
#
# Usage:
#   1) First run (no config file):             ./script.sh
#      - Interactive wizard collects all config options
#      - Writes docker-backup.conf
#      - Optionally proceeds with backup
#
#   2) Normal usage (with config):             ./script.sh
#      - Backs up subfolders in SOURCE_PATH:
#         a) docker compose down
#         b) tar folder
#         c) docker compose up -d
#         d) copy tar to DEST_PATH/<today's date>/
#
#   3) Re-run the full wizard at any time:     ./script.sh --setup
#   4) View configured details:                ./script.sh --details
#   5) Enable logging in config:               ./script.sh --logs-on
#   6) Disable logging in config:              ./script.sh --logs-off
#   7) Define persistent exclusions:           ./script.sh --list-containers
#   8) Set backup rotation count (retention):  ./script.sh --rotation
#   9) Help (all switches):                    ./script.sh --help
#

# ---------------- Configuration ----------------

CONFIG_FILE="docker-backup.conf"

# ---------------- Switch Definitions ----------------
declare -A SWITCHES=(
  [--details]="Show current configuration details from docker-backup.conf. Exits afterward."
  [--help]="Display this help message and exit."
  [--list-containers]="List docker-compose folders and choose which to exclude. Exits afterward."
  [--logs-off]="Disable logging (docker-backups.log). Exits afterward."
  [--logs-on]="Enable logging (docker-backups.log). Exits afterward."
  [--rotation]="Set how many dated backups to keep. Exits afterward."
  [--setup]="Run the full interactive wizard (all config options). Exits afterward."
)

# ---------------- Functions ----------------

show_help() {
  echo "Usage: $0 [OPTIONS]"
  echo
  echo "Description:"
  echo "  Manages docker-compose subfolders, backs them up, and stores the archives."
  echo "  Includes toggling of logging, excluding containers, and backup rotation."
  echo
  echo "Options (alphabetical):"
  for switch in $(printf '%s\n' "${!SWITCHES[@]}" | sort); do
    printf "  %-18s %s\n" "$switch" "${SWITCHES[$switch]}"
  done
  echo
  exit 0
}

write_config_safely() {
  cat > "$CONFIG_FILE"
  if [[ $? -ne 0 ]]; then
    echo "ERROR: Could not write the configuration. Please run with elevated permissions."
    exit 1
  fi
}

# Writes final config data in one shot
write_final_config() {
  local source_path="$1"
  local dest_path="$2"
  local logging="$3"
  local excludes="$4"
  local rotation="$5"

  cat <<EOF | write_config_safely
SOURCE_PATH="$source_path"
DEST_PATH="$dest_path"
LOGGING_ENABLED="$logging"
EXCLUDED_CONTAINERS="$excludes"
ROTATION_COUNT="$rotation"
EOF
}

# This full wizard is used both on the first run AND if the user calls `--setup`.
run_full_interactive_wizard() {
    echo "=== Full Configuration Wizard ==="
    echo
    # 1) SOURCE_PATH
    local new_source
    while true; do
        read -r -p "Enter the SOURCE path (absolute, no tilde ~): " new_source
        if [[ "$new_source" =~ ^~ ]]; then
            echo "ERROR: Tilde (~) detected. Please use a full absolute path."
        else
            break
        fi
    done

    # 2) DEST_PATH
    local new_dest
    while true; do
        echo
        read -r -p "Enter the DESTINATION path (absolute, no tilde ~): " new_dest
        if [[ "$new_dest" =~ ^~ ]]; then
            echo "ERROR: Tilde (~) detected. Please use a full absolute path."
        else
            break
        fi
    done

    # 3) LOGGING_ENABLED
    local logging="false"
    echo
    read -r -p "Enable logging (append output to '$new_dest/docker-backups.log')? [y/N]: " log_ans
    log_ans="${log_ans,,}"  # to lowercase
    if [[ "$log_ans" == "y" ]]; then
        logging="true"
    fi

    # 4) EXCLUDED_CONTAINERS
    local excludes=""
    if [[ -d "$new_source" ]]; then
        shopt -s nullglob
        declare -a compose_folders=()
        for folder in "$new_source"/*; do
            if [[ -d "$folder" && ( -f "$folder/docker-compose.yml" || -f "$folder/docker-compose.yaml" ) ]]; then
                compose_folders+=("$folder")
            fi
        done
        shopt -u nullglob

        if [[ ${#compose_folders[@]} -gt 0 ]]; then
            echo
            echo "The following subfolders have docker-compose files and can be excluded if desired:"
            for i in "${!compose_folders[@]}"; do
                local folder_name
                folder_name="$(basename "${compose_folders[$i]}")"
                printf "%3d) %s\n" "$((i+1))" "$folder_name"
            done

            echo
            read -r -p "Enter the numbers of containers to exclude (comma-separated), or press ENTER for none: " input
            input="${input//[[:space:]]/}"

            local new_exclusions=()
            if [[ -n "$input" ]]; then
                IFS=',' read -ra indices <<< "$input"
                for val in "${indices[@]}"; do
                    if [[ "$val" =~ ^[0-9]+$ ]]; then
                        local index=$((val-1))
                        if [[ $index -ge 0 && $index -lt ${#compose_folders[@]} ]]; then
                            new_exclusions+=("$(basename "${compose_folders[$index]}")")
                        fi
                    fi
                done
            fi

            if [[ ${#new_exclusions[@]} -gt 0 ]]; then
                excludes="$(IFS=','; echo "${new_exclusions[*]}")"
                echo "Excluding: $excludes"
            fi
        fi
    else
        echo
        echo "WARNING: '$new_source' is not a directory. Skipping exclusions."
    fi

    # 5) ROTATION_COUNT
    local rotation=""
    echo
    read -r -p "Would you like to set a rotation count (limit backups)? [y/N]: " rotate_ans
    rotate_ans="${rotate_ans,,}"
    if [[ "$rotate_ans" == "y" ]]; then
        while true; do
            read -r -p "Enter the number of backups to keep (must be > 0): " rotation
            if [[ "$rotation" =~ ^[0-9]+$ && "$rotation" -gt 0 ]]; then
                echo "Rotation set to $rotation backups."
                break
            elif [[ -z "$rotation" ]]; then
                echo "No rotation set. Defaulting to infinite."
                rotation=""
                break
            else
                echo "ERROR: Please enter a positive integer or press ENTER to skip."
            fi
        done
    fi

    # Write config
    echo
    echo "Writing new config file to '$CONFIG_FILE'..."
    write_final_config "$new_source" "$new_dest" "$logging" "$excludes" "$rotation"

    echo
    echo "Configuration created/updated!"
    echo "SOURCE_PATH:        $new_source"
    echo "DEST_PATH:          $new_dest"
    echo "LOGGING_ENABLED:    $logging"
    echo "EXCLUDED_CONTAINERS:$excludes"
    [[ -n "$rotation" ]] && echo "ROTATION_COUNT:     $rotation" || echo "ROTATION_COUNT:     infinite"

    # 6) Ask if user wants to proceed with backup now (docker restarts)
    echo
    echo "WARNING: Running the backup will shut down and restart Docker containers."
    read -r -p "Do you want to proceed with the backup now? [y/N] " answer
    answer="${answer,,}"  # to lowercase
    if [[ "$answer" != "y" ]]; then
        echo "Exiting without performing backup."
        exit 0
    fi
}

# We keep some of the other code from your original script to handle logging, details, rotation, etc.
set_logging_state() {
    local new_log_value="$1"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat <<EOF | write_config_safely
SOURCE_PATH=""
DEST_PATH=""
LOGGING_ENABLED="$new_log_value"
EXCLUDED_CONTAINERS=""
ROTATION_COUNT=""
EOF
        echo "Created new config with LOGGING_ENABLED='$new_log_value'."
        return
    fi

    source "$CONFIG_FILE"
    local cur_source="${SOURCE_PATH:-}"
    local cur_dest="${DEST_PATH:-}"
    local cur_exclusions="${EXCLUDED_CONTAINERS:-}"
    local cur_rotation="${ROTATION_COUNT:-}"

    cat <<EOF | write_config_safely
SOURCE_PATH="$cur_source"
DEST_PATH="$cur_dest"
LOGGING_ENABLED="$new_log_value"
EXCLUDED_CONTAINERS="$cur_exclusions"
ROTATION_COUNT="$cur_rotation"
EOF

    echo "Config updated: LOGGING_ENABLED='$new_log_value'."
}

list_containers_and_exclude() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "No config file found. Please run './script.sh --setup' first."
        exit 1
    fi

    source "$CONFIG_FILE"
    if [[ ! -d "$SOURCE_PATH" ]]; then
        echo "ERROR: SOURCE_PATH ($SOURCE_PATH) does not exist or is not a directory."
        exit 1
    fi

    shopt -s nullglob
    declare -a compose_folders=()
    for folder in "$SOURCE_PATH"/*; do
        if [[ -d "$folder" && ( -f "$folder/docker-compose.yml" || -f "$folder/docker-compose.yaml" ) ]]; then
            compose_folders+=("$folder")
        fi
    done
    shopt -u nullglob

    if [[ ${#compose_folders[@]} -eq 0 ]]; then
        echo "No folders with docker-compose found in $SOURCE_PATH."
        echo "Nothing to exclude."
        exit 0
    fi

    echo "The following subfolders have docker-compose files:"
    for i in "${!compose_folders[@]}"; do
        local folder_name
        folder_name="$(basename "${compose_folders[$i]}")"
        printf "%3d) %s\n" "$((i+1))" "$folder_name"
    done

    echo
    echo "Currently excluded containers: ${EXCLUDED_CONTAINERS:-none}"
    echo
    read -r -p "Enter numbers to exclude (comma-separated), or press ENTER for none: " input
    input="${input//[[:space:]]/}"

    local new_exclusions=()
    if [[ -n "$input" ]]; then
        IFS=',' read -ra indices <<< "$input"
        for val in "${indices[@]}"; do
            if [[ "$val" =~ ^[0-9]+$ ]]; then
                local index=$((val-1))
                if [[ $index -ge 0 && $index -lt ${#compose_folders[@]} ]]; then
                    new_exclusions+=("$(basename "${compose_folders[$index]}")")
                fi
            fi
        done
    fi

    local joined_exclusions=""
    if [[ ${#new_exclusions[@]} -gt 0 ]]; then
        joined_exclusions="$(IFS=','; echo "${new_exclusions[*]}")"
    fi

    source "$CONFIG_FILE"
    local cur_log="${LOGGING_ENABLED:-false}"
    local cur_rotation="${ROTATION_COUNT:-}"

    cat <<EOF | write_config_safely
SOURCE_PATH="$SOURCE_PATH"
DEST_PATH="$DEST_PATH"
LOGGING_ENABLED="$cur_log"
EXCLUDED_CONTAINERS="$joined_exclusions"
ROTATION_COUNT="$cur_rotation"
EOF

    echo
    echo "Exclusions updated. EXCLUDED_CONTAINERS: '$joined_exclusions'"
    echo "Exiting now (no backups will run)."
    exit 0
}

set_rotation_count() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "No config file found. Please run './script.sh --setup' first."
        exit 1
    fi

    source "$CONFIG_FILE"
    echo "=== Rotation Setup ==="
    if [[ -z "$ROTATION_COUNT" ]]; then
        echo "Current rotation is: Infinite."
    else
        echo "Current rotation: $ROTATION_COUNT backups."
    fi
    echo

    local new_count
    while true; do
        read -r -p "Enter the number of backups (must be > 0): " new_count
        if [[ "$new_count" =~ ^[0-9]+$ && "$new_count" -gt 0 ]]; then
            break
        else
            echo "ERROR: Must be a positive integer."
        fi
    done

    local cur_log="${LOGGING_ENABLED:-false}"
    local cur_exclusions="${EXCLUDED_CONTAINERS:-}"

    cat <<EOF | write_config_safely
SOURCE_PATH="$SOURCE_PATH"
DEST_PATH="$DEST_PATH"
LOGGING_ENABLED="$cur_log"
EXCLUDED_CONTAINERS="$cur_exclusions"
ROTATION_COUNT="$new_count"
EOF

    echo
    echo "Rotation updated to: $new_count"

    if [[ -n "$DEST_PATH" && -d "$DEST_PATH" ]]; then
        readarray -t backups < <(ls -1 "$DEST_PATH" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort)
        local total_backups="${#backups[@]}"
        echo
        echo "Currently, $total_backups dated backup folders in '$DEST_PATH'."
        if (( total_backups > new_count )); then
            local to_remove=$(( total_backups - new_count ))
            echo "On next run, $to_remove oldest backups will be removed."
        else
            echo "No backups will be removed, since $total_backups <= $new_count."
        fi
    else
        echo
        echo "Cannot check existing backups because DEST_PATH='$DEST_PATH' is invalid."
    fi

    echo
    echo "Exiting now (no backups will run)."
    exit 0
}

rotate_old_backups() {
    if [[ -z "$ROTATION_COUNT" || "$ROTATION_COUNT" -le 0 ]]; then
        echo "Rotation is infinite or invalid. No old backups removed."
        return
    fi

    readarray -t backups_list < <(ls -1 "$DEST_PATH" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort -r)
    local total_backups="${#backups_list[@]}"
    if (( total_backups <= ROTATION_COUNT )); then
        echo "No rotation needed. Current backups ($total_backups) <= ROTATION_COUNT ($ROTATION_COUNT)."
        return
    fi

    echo "Rotation needed. Keeping newest $ROTATION_COUNT, removing oldest."
    local remove_index=$(( ROTATION_COUNT ))

    for (( i=remove_index; i<total_backups; i++ )); do
        local old_folder="${backups_list[$i]}"
        local old_path="$DEST_PATH/$old_folder"
        echo "Removing old backup folder: $old_path"
        rm -rf "$old_path"
    done
}

# ---------------- Switch Handling ----------------
case "$1" in
  --details)
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        echo "=== Current Configuration Details ==="
        echo "SOURCE_PATH:         $SOURCE_PATH"
        echo "DEST_PATH:           $DEST_PATH"
        echo "LOGGING_ENABLED:     ${LOGGING_ENABLED:-false}"
        echo "EXCLUDED_CONTAINERS: ${EXCLUDED_CONTAINERS:-none}"
        echo "ROTATION_COUNT:      ${ROTATION_COUNT:-infinite}"
    else
        echo "No config found. Please run '$0' first or use '--setup' to create one."
    fi
    exit 0
    ;;
  --help)
    show_help
    ;;
  --list-containers)
    list_containers_and_exclude
    ;;
  --logs-off)
    set_logging_state "false"
    exit 0
    ;;
  --logs-on)
    set_logging_state "true"
    exit 0
    ;;
  --rotation)
    set_rotation_count
    ;;
  --setup)
    run_full_interactive_wizard
    # If user said "no" to continuing, we exit. If "yes," we proceed with backup steps below.
    ;;
  "")
    # Normal run
    ;;
  *)
    echo "Error: Unknown option '$1'"
    show_help
    ;;
esac

# ---------------- Main Script Logic ----------------

# 1) If no config file yet (and user didn't call --setup above), run the wizard:
if [[ ! -f "$CONFIG_FILE" ]]; then
    run_full_interactive_wizard
fi

# 2) Load config
source "$CONFIG_FILE"

[[ -z "$LOGGING_ENABLED" ]] && LOGGING_ENABLED="false"
[[ -z "$EXCLUDED_CONTAINERS" ]] && EXCLUDED_CONTAINERS=""
if ! [[ "$ROTATION_COUNT" =~ ^[0-9]+$ ]]; then
    ROTATION_COUNT=""
fi

# 3) If logging is on, tee output
if [[ "$LOGGING_ENABLED" == "true" ]]; then
    mkdir -p "$DEST_PATH"
    exec > >(tee -a "$DEST_PATH/docker-backups.log") 2>&1
fi

echo "=== Normal Mode ==="
echo "Using SOURCE_PATH:        $SOURCE_PATH"
echo "Using DEST_PATH:          $DEST_PATH"
echo "LOGGING_ENABLED:          $LOGGING_ENABLED"
echo "EXCLUDED_CONTAINERS:      $EXCLUDED_CONTAINERS"
echo "ROTATION_COUNT:           ${ROTATION_COUNT:-infinite}"
echo

if [[ ! -d "$SOURCE_PATH" ]]; then
    echo "ERROR: SOURCE_PATH ($SOURCE_PATH) does not exist."
    exit 1
fi

# Handle exclusions
IFS=',' read -ra exclude_array <<< "$EXCLUDED_CONTAINERS"
for i in "${!exclude_array[@]}"; do
    exclude_array[$i]="${exclude_array[$i]//[[:space:]]/}"
done

# 4) Create date-based backup folder
DATE_STAMP="$(date +%Y-%m-%d)"
BACKUP_DIR="$DEST_PATH/$DATE_STAMP"
mkdir -p "$BACKUP_DIR"

echo "All tar backups will be placed in: $BACKUP_DIR"
echo "Looping through subfolders in $SOURCE_PATH..."
echo

shopt -s nullglob
for folder in "$SOURCE_PATH"/*; do
    [[ -d "$folder" ]] || continue
    folder_name="$(basename "$folder")"

    # Skip excluded
    if [[ " ${exclude_array[*]} " =~ " $folder_name " ]]; then
        echo "Skipping excluded folder: $folder_name"
        continue
    fi

    if [[ -f "$folder/docker-compose.yml" || -f "$folder/docker-compose.yaml" ]]; then
        echo "-------------------------------------"
        echo "Processing folder: $folder_name"
        echo "Shutting down Docker containers..."
        (
          cd "$folder" || exit
          docker compose down
        )

        TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
        TAR_NAME="${TIMESTAMP}_${folder_name}.tar.gz"

        echo "Compressing folder '$folder_name' into '$TAR_NAME'..."
        tar -czf "$BACKUP_DIR/$TAR_NAME" -C "$SOURCE_PATH" "$folder_name"

        echo "Starting Docker containers..."
        (
          cd "$folder" || exit
          docker compose up -d
        )

        echo "Backup created at: $BACKUP_DIR/$TAR_NAME"
    else
        echo "-------------------------------------"
        echo "Folder '$folder_name' has NO docker-compose.yml|.yaml."
        echo "Compressing folder but skipping Docker steps..."

        TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
        TAR_NAME="${TIMESTAMP}_${folder_name}.tar.gz"
        tar -czf "$BACKUP_DIR/$TAR_NAME" -C "$SOURCE_PATH" "$folder_name"

        echo "Backup created at: $BACKUP_DIR/$TAR_NAME"
    fi
done
shopt -u nullglob

# 5) Also back up the script and config
SCRIPT_NAME="$(basename "$0")"
echo
echo "Creating archive of script and config..."
tar -czf "$BACKUP_DIR/script_and_config.tar.gz" "$SCRIPT_NAME" "$CONFIG_FILE"
echo "Archive saved at: $BACKUP_DIR/script_and_config.tar.gz"

echo
rotate_old_backups

echo
echo "-------------------------------------"
echo "All done!"
