#!/bin/bash
# =============================================================================
# Restore script for Directus
# This script restores the database and uploads from a specified backup directory
# =============================================================================

# Exit on error and pipe failures
set -e
set -o pipefail

# =============================================================================
# Helper Functions (Copied/Adapted from backup.sh)
# =============================================================================

# Convert relative path to absolute path relative to PROJECT_PATH
get_absolute_path() {
    local path="$1"

    # Check if path is already absolute
    if [[ "$path" = /* ]]; then
        echo "$path"
    else
        # Use PWD as fallback if PROJECT_PATH is not set yet
        local base_path="${PROJECT_PATH:-$(pwd)}"
        echo "$base_path/$path"
    fi
}

# Logger function with timestamp
log_message() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1"
}

# Debug logger for commands
log_debug() {
    log_message "DEBUG: $1"
}

# Error handler
handle_error() {
    log_message "ERROR: $1"
    exit 1
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check required commands
check_commands() {
    local missing_commands=()
    local critical_error=0

    # Critical commands for restore
    if ! command_exists docker; then missing_commands+=("docker"); critical_error=1; fi
    if ! command_exists rsync; then missing_commands+=("rsync"); critical_error=1; fi
    if ! command_exists gunzip; then missing_commands+=("gunzip"); critical_error=1; fi
    # psql is needed inside the container, check docker exec works later

    if [ ${#missing_commands[@]} -ne 0 ]; then
        log_message "Warning: Missing required commands on host: ${missing_commands[*]}"
        log_message "Please install these commands to ensure proper operation"

        if [ $critical_error -eq 1 ]; then
            handle_error "Critical commands are missing, restore cannot proceed"
        fi
    fi

    # Check if psql is available inside the container
    log_debug "Checking for psql inside the database container..."
    if ! docker compose -f "$DOCKER_COMPOSE_FILE" exec -T database bash -c "command -v psql > /dev/null 2>&1"; then
         handle_error "psql command not found inside the database container. Cannot restore database."
    fi
     log_message "psql found inside the container."

    return 0
}

# Check required environment variables
check_environment_vars() {
    local missing_vars=()

    if [ -z "$DB_DATABASE" ]; then missing_vars+=("DB_DATABASE"); fi
    if [ -z "$DB_USER" ]; then missing_vars+=("DB_USER"); fi
    if [ -z "$DB_PASSWORD" ]; then missing_vars+=("DB_PASSWORD"); fi
    # DB_HOST and DB_PORT are implicitly handled by docker compose exec

    if [ ${#missing_vars[@]} -ne 0 ]; then
        handle_error "Missing required environment variables: ${missing_vars[*]}. Please check your .env file"
    fi
}

# =============================================================================
# Configuration and Initialization
# =============================================================================
SCRIPT_PATH="$(realpath "$0")"
PROJECT_PATH="$(dirname "$SCRIPT_PATH")" # Assumes script is in backend-directus
ENV_FILE="$(get_absolute_path ".env")"
DOCKER_COMPOSE_FILE="$(get_absolute_path "docker-compose.base.yml")"

# Check if backup path argument is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <path_to_backup_directory>"
    echo "Example: $0 ./backups/backup_latest"
    echo "Example: $0 ./backups/backup_2023-10-27_12-00-00_1698417600"
    exit 1
fi

BACKUP_SOURCE_PATH_ARG="$1"
BACKUP_SOURCE_DIR="" # Will be resolved absolute path

# Load environment variables
if [ -f "$ENV_FILE" ]; then
    log_message "Loading environment variables from $ENV_FILE"
    # Temporarily disable exit on error for source, in case .env contains errors
    set +e
    source "$ENV_FILE"
    set -e
else
    handle_error ".env file not found at $ENV_FILE"
fi

# Check required environment variables after loading .env
check_environment_vars

# Resolve backup path (handle relative paths and symlinks)
log_message "Resolving backup source path: $BACKUP_SOURCE_PATH_ARG"
if [ -L "$BACKUP_SOURCE_PATH_ARG" ]; then
    # Handle symlink
    BACKUP_SOURCE_DIR="$(realpath "$BACKUP_SOURCE_PATH_ARG")"
    log_message "Symlink detected, resolved to: $BACKUP_SOURCE_DIR"
elif [ -d "$BACKUP_SOURCE_PATH_ARG" ]; then
    # Handle directory
    BACKUP_SOURCE_DIR="$(realpath "$BACKUP_SOURCE_PATH_ARG")"
    log_message "Using directory: $BACKUP_SOURCE_DIR"
else
    handle_error "Backup source path is not a valid directory or symlink: $BACKUP_SOURCE_PATH_ARG"
fi

# Validate backup directory contents
DB_BACKUP_GZ="$BACKUP_SOURCE_DIR/db_backup.sql.gz"
UPLOADS_BACKUP_DIR="$BACKUP_SOURCE_DIR/uploads"

if [ ! -f "$DB_BACKUP_GZ" ]; then
    handle_error "Database backup file not found: $DB_BACKUP_GZ"
fi

if [ ! -d "$UPLOADS_BACKUP_DIR" ]; then
    handle_error "Uploads backup directory not found: $UPLOADS_BACKUP_DIR"
fi

# Target directories
UPLOADS_TARGET_DIR=$(get_absolute_path "directus/data/uploads")
TEMP_DIR=$(mktemp -d -t directus_restore_XXXXXX)

# Check required commands
check_commands

log_message "Using PROJECT_PATH: $PROJECT_PATH"
log_message "Using BACKUP_SOURCE_DIR: $BACKUP_SOURCE_DIR"
log_message "Using UPLOADS_TARGET_DIR: $UPLOADS_TARGET_DIR"
log_message "Using temporary directory: $TEMP_DIR"

# =============================================================================
# Restore Functions
# =============================================================================

# Restore database
restore_database() {
    log_message "Starting database restore..."
    local db_backup_sql="$TEMP_DIR/db_backup.sql"

    # Decompress database backup
    log_message "Decompressing $DB_BACKUP_GZ..."
    if ! gunzip -c "$DB_BACKUP_GZ" > "$db_backup_sql"; then
        handle_error "Failed to decompress database backup"
    fi
    log_message "Database backup decompressed to $db_backup_sql"

    # Check decompressed file size
    if [ ! -s "$db_backup_sql" ]; then
        handle_error "Decompressed database backup is empty"
    fi

    # Drop and recreate the database before restoring
    log_message "Dropping existing database '$DB_DATABASE'..."
    if ! docker compose -f "$DOCKER_COMPOSE_FILE" exec -T -e PGPASSWORD="$DB_PASSWORD" database dropdb -U "$DB_USER" --if-exists "$DB_DATABASE"; then
        log_message "Warning: Failed to drop database (might not exist). Continuing..."
        # Don't exit here, maybe the DB just didn't exist
    fi

    log_message "Creating new database '$DB_DATABASE'..."
    if ! docker compose -f "$DOCKER_COMPOSE_FILE" exec -T -e PGPASSWORD="$DB_PASSWORD" database createdb -U "$DB_USER" "$DB_DATABASE"; then
        handle_error "Failed to create new database '$DB_DATABASE'"
    fi

    # Restore the database using psql
    log_message "Restoring database from $db_backup_sql..."
    log_debug "Running: docker compose ... exec -T database psql -U $DB_USER -d $DB_DATABASE < $db_backup_sql"
    if ! docker compose -f "$DOCKER_COMPOSE_FILE" exec -T -e PGPASSWORD="$DB_PASSWORD" database psql -U "$DB_USER" -d "$DB_DATABASE" < "$db_backup_sql"; then
        handle_error "Database restore command (psql) failed"
    fi

    log_message "Database restore completed successfully."
}

# Restore uploads directory
restore_uploads() {
    log_message "Starting uploads restore..."

    # Ensure target uploads directory exists
    mkdir -p "$UPLOADS_TARGET_DIR"

    # Use rsync to sync backup to target, deleting extraneous files in target
    local rsync_options="-a --delete"
    log_message "Syncing uploads from $UPLOADS_BACKUP_DIR/ to $UPLOADS_TARGET_DIR/"
    log_debug "Running: rsync $rsync_options $UPLOADS_BACKUP_DIR/ $UPLOADS_TARGET_DIR/"

    if ! rsync $rsync_options "$UPLOADS_BACKUP_DIR/" "$UPLOADS_TARGET_DIR/"; then
        handle_error "Uploads restore command (rsync) failed"
    fi

    log_message "Uploads restore completed successfully."
    log_message "Total size restored: $(du -sh "$UPLOADS_TARGET_DIR" | cut -f1)"
}

# Cleanup temporary files
cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        log_message "Cleaning up temporary directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
}

# =============================================================================
# Main Execution
# =============================================================================

log_message "Starting Directus restore from: $BACKUP_SOURCE_DIR"
trap cleanup EXIT # Ensure cleanup runs even on error

# --- Confirmation ---
echo "WARNING: This will overwrite the current database '$DB_DATABASE' and uploads directory '$UPLOADS_TARGET_DIR'. Are you sure? (y/N) "
read -n 1 -r
echo # Move to a new line
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_message "Restore aborted by user."
    exit 1
fi
# --- End Confirmation ---


log_message "Proceeding with restore..."

# Stop directus container to avoid conflicts during restore
log_message "Stopping Directus container..."
if ! docker compose -f "$DOCKER_COMPOSE_FILE" stop directus; then
    log_message "Warning: Failed to stop Directus container. It might already be stopped or not running."
fi

# Execute restore steps
restore_database
restore_uploads

# Restart directus container automatically
log_message "Restarting Directus container..."
if ! docker compose -f "$DOCKER_COMPOSE_FILE" up -d directus; then
    handle_error "Failed to restart Directus container"
fi

log_message "Restore job finished successfully."
exit 0