#!/bin/bash
# =============================================================================
# Backup script for Directus
# This script performs database and uploads backup with retention policies
#
# Usage:
#   ./backup.sh [backup_directory_path]
#
# Arguments:
#   backup_directory_path - Optional. Custom path to store backups.
#                           If not provided, uses value from .env or default.
# =============================================================================

# Exit on error and pipe failures
set -e
set -o pipefail

# =============================================================================
# Helper Functions (Must be defined before use)
# =============================================================================

# Display help information
show_help() {
    cat << EOF
Directus Backup Script
======================

Description:
  This script performs automated backups of a Directus installation,
  including database dumps and uploads directory. It supports retention
  policies and incremental backups.

Usage:
  ./backup.sh [OPTIONS] [BACKUP_PATH]

Options:
  --help        Display this help message and exit

Arguments:
  BACKUP_PATH   Optional. Path where backups will be stored.
                If not specified, uses value from .env or defaults to ./backups

Environment Variables (can be set in .env):
  BACKUPS_DIR                   Path to store backups (default: ./backups)
  BACKUP_RETENTION_DAYS         Days to keep backups (default: 7)
  BACKUP_RETENTION_COUNT        Minimum number of backups to keep (default: 0)
  BACKUP_ERROR_LOGS_RETENTION_DAYS  Days to keep error logs (default: 30)
  BACKUP_GZIP_LEVEL             Compression level for database (default: 9)

Examples:
  ./backup.sh                   Create backup in default location
  ./backup.sh /mnt/backups      Create backup in /mnt/backups
  ./backup.sh --help            Display this help message

Notes:
  - The script creates a backup directory containing:
    - Database dump (compressed with gzip)
    - Uploads directory (files)
  - A symbolic link 'backup_latest' points to the most recent backup
  - Old backups are automatically removed based on retention settings
EOF
    exit 0
}

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

# =============================================================================
# Configuration (All user configurable settings should be here)
# =============================================================================
SCRIPT_PATH="$(realpath "$0")"
PROJECT_PATH="$(dirname "$SCRIPT_PATH")"
IS_ERROR=0

# Process command line arguments
if [ "$1" = "--help" ]; then
    show_help
fi

# Check if custom backup directory is provided as first argument
if [ -n "$1" ]; then
    CUSTOM_BACKUPS_DIR="$1"
    echo "Using custom backup directory from argument: $CUSTOM_BACKUPS_DIR"
fi

# Load environment variables early to ensure we get BACKUPS_DIR from .env if set
if [ -f "$(get_absolute_path ".env")" ]; then
    source "$(get_absolute_path ".env")"
    # Track if BACKUPS_DIR was set from environment
    if [ -n "$BACKUPS_DIR" ]; then
        BACKUPS_DIR_FROM_ENV="$BACKUPS_DIR"
    fi
fi

# Apply environment variables to configuration if set in .env
# Priority: 1) Command line argument, 2) Environment variable, 3) Default value
BACKUPS_DIR="${CUSTOM_BACKUPS_DIR:-${BACKUPS_DIR:-./directus/data/backups}}"  # Directory to store backups
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"  # How many days to keep backups
BACKUP_RETENTION_COUNT="${BACKUP_RETENTION_COUNT:-0}" # Minimum number of backups to keep
BACKUP_TIMESTAMP=$(date +%s)                  # Current Unix timestamp
BACKUP_FORMATTED_DATE=$(date +"%Y-%m-%d_%H-%M-%S") # Human-readable date
BACKUP_ERROR_DIR="${BACKUPS_DIR}/error_logs"    # Directory for error logs
BACKUP_GZIP_LEVEL="${BACKUP_GZIP_LEVEL:-9}"    # Compression level for gzip (1-9, 9 is max compression)
BACKUP_ERROR_LOGS_RETENTION_DAYS="${BACKUP_ERROR_LOGS_RETENTION_DAYS:-30}" # Days to keep error logs

# =============================================================================
# Helper Functions
# =============================================================================

# Cross-platform date formatting
format_date() {
    local timestamp=$1
    # Check if running on macOS (BSD date) or Linux (GNU date)
    if date -v 1d > /dev/null 2>&1; then
        # macOS / BSD date
        date -r $timestamp "+%Y-%m-%d %H:%M:%S"
    else
        # Linux / GNU date
        date -d @$timestamp "+%Y-%m-%d %H:%M:%S"
    fi
}

# Logger function with timestamp
log_message() {
    local message="[$(date +"%Y-%m-%d %H:%M:%S")] $1"
    echo "$message"
    
    # Also log to error log if it exists
    if [ -n "$ERROR_LOG" ] && [ -d "$(dirname "$ERROR_LOG")" ]; then
        echo "$message" >> "$ERROR_LOG"
    fi
}

# Debug logger for commands
log_debug() {
    log_message "DEBUG: $1"
}

# Error handler that preserves temp directory
handle_error() {
    IS_ERROR=1
    log_message "ERROR: $1"
    
    # Don't exit but return error status to allow preserving temp dir
    return 1
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check required commands
check_commands() {
    local missing_commands=()
    local critical_error=0
    
    # Critical commands that must be present
    if ! command_exists docker; then
        missing_commands+=("docker")
        critical_error=1
    fi
    
    if ! command_exists rsync; then
        missing_commands+=("rsync")
        critical_error=1
    fi
    
    # Fallback ID generation requires md5sum if uuidgen is missing
    if ! command_exists uuidgen; then
        if ! command_exists md5sum; then
            missing_commands+=("uuidgen/md5sum")
            critical_error=1
        else
            missing_commands+=("uuidgen (using md5sum fallback)")
        fi
    fi
    
    # Non-critical but important commands
    if ! command_exists gzip; then
        missing_commands+=("gzip")
    fi
    
    # Check for bc (used for calculations in retention)
    if ! command_exists bc; then
        missing_commands+=("bc (using fallback arithmetic)")
    fi
    
    if [ ${#missing_commands[@]} -ne 0 ]; then
        log_message "Warning: Missing required commands: ${missing_commands[*]}"
        log_message "Please install these commands to ensure proper operation"
        
        if [ $critical_error -eq 1 ]; then
            log_message "ERROR: Critical commands are missing, backup cannot proceed"
            IS_ERROR=1
            return 1
        fi
    fi
    
    return 0
}

# Check required environment variables
check_environment_vars() {
    local missing_vars=()
    
    if [ -z "$DB_DATABASE" ]; then
        missing_vars+=("DB_DATABASE")
    fi
    
    if [ -z "$DB_USER" ]; then
        missing_vars+=("DB_USER")
    fi
    
    if [ -z "$DB_PASSWORD" ]; then
        missing_vars+=("DB_PASSWORD")
    fi
    
    if [ ${#missing_vars[@]} -ne 0 ]; then
        log_message "Warning: Missing required environment variables: ${missing_vars[*]}"
        log_message "Please check your .env file"
    fi
}

# Save error information to a preserved directory
save_error_info() {
    if [ "$IS_ERROR" -eq 1 ] && [ -d "$TEMP_DIR" ]; then
        local error_dir="$BACKUP_ERROR_DIR/error_${BACKUP_FORMATTED_DATE}_${JOB_ID}"
        mkdir -p "$error_dir"
        
        # Save environment info
        env > "$error_dir/environment.txt"
        
        # Copy error logs
        if [ -f "$ERROR_LOG" ]; then
            cp "$ERROR_LOG" "$error_dir/error.log"
        fi
        
        # Copy any other important info from temp dir
        if [ -d "$TEMP_DIR" ]; then
            for log_file in "$TEMP_DIR"/*.log; do
                if [ -f "$log_file" ]; then
                    cp "$log_file" "$error_dir/"
                fi
            done
        fi
        
        log_message "Error information saved to: $error_dir"
        
        # Clean up temp directory
        rm -rf "$TEMP_DIR"
    fi
}

# Check if directory is a valid completed backup
is_completed_backup() {
    local dir="$1"
    local dirname=$(basename "$dir")
    
    # Check if the directory name matches the pattern backup_DATE_TIMESTAMP
    if [[ $dirname =~ ^backup_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}_[0-9]+$ ]]; then
        return 0 # true
    else
        return 1 # false
    fi
}

# Extract timestamp from backup directory name
extract_timestamp() {
    local dir="$1"
    local dirname=$(basename "$dir")
    
    # Extract the timestamp part (last segment)
    echo "$dirname" | grep -o '[0-9]\+$'
}

# =============================================================================
# Main Backup Functions
# =============================================================================

# Initialize directories
init_directories() {
    log_message "Initializing backup directories..."
    
    # Convert relative paths to absolute before creating any directories
    BACKUPS_DIR=$(get_absolute_path "$BACKUPS_DIR")
    UPLOADS_DIR=$(get_absolute_path "directus/data/uploads")
    BACKUP_ERROR_DIR="$BACKUPS_DIR/error_logs"
    
    # Log backup directory source for clarity
    if [ -n "$CUSTOM_BACKUPS_DIR" ]; then
        log_message "Using backup directory from command line argument"
    elif [ -n "$BACKUPS_DIR_FROM_ENV" ]; then
        log_message "Using backup directory from environment variable"
    else
        log_message "Using default backup directory"
    fi
    
    mkdir -p "$BACKUPS_DIR"
    mkdir -p "$BACKUP_ERROR_DIR"
    
    # Check for required commands - exit if critical commands are missing
    if ! check_commands; then
        handle_error "Initialization failed: missing critical commands"
        return 1
    fi
    
    # Generate JOB_ID and TEMP_DIR after BACKUPS_DIR is set
    if command_exists uuidgen; then
        JOB_ID="job-$(uuidgen | cut -f1 -d-)"
    else
        # Fallback to md5sum if uuidgen is not available
        JOB_ID="job-$(date +%s%N | md5sum | head -c 8)"
    fi
    
    TEMP_DIR="$BACKUPS_DIR/temp_$JOB_ID"
    
    # Create temporary directory for current job
    mkdir -p "$TEMP_DIR"
    mkdir -p "$TEMP_DIR/uploads"
    
    # Update ERROR_LOG path now that TEMP_DIR is created
    ERROR_LOG="$TEMP_DIR/error.log"
    
    # Verify uploads directory
    if [ ! -d "$UPLOADS_DIR" ] || [ ! -r "$UPLOADS_DIR" ]; then
        handle_error "Uploads directory is not accessible: $UPLOADS_DIR"
        return 1
    fi
    
    # Check environment variables
    check_environment_vars
    
    log_message "Using PROJECT_PATH: $PROJECT_PATH"
    log_message "Using BACKUPS_DIR: $BACKUPS_DIR"
    log_message "Using UPLOADS_DIR: $UPLOADS_DIR"
    log_message "Using temporary directory: $TEMP_DIR"
    log_message "Job ID: $JOB_ID"
    return 0
}

# Backup database
backup_database() {
    log_message "Creating database backup..."
    local db_file="$TEMP_DIR/db_backup.sql"
    local error_log="$TEMP_DIR/db_error.log"
    
    # Run the database backup command
    log_debug "Running: docker compose -f $(get_absolute_path "docker-compose.base.yml") exec -T database pg_dump -U $DB_USER $DB_DATABASE"
    if ! docker compose -f "$(get_absolute_path "docker-compose.base.yml")" exec -T database pg_dump -U "$DB_USER" "$DB_DATABASE" > "$db_file" 2> "$error_log"; then
        log_message "Database command failed with exit code: $?"
        if [ -f "$error_log" ]; then
            log_message "Error output: $(cat "$error_log")"
        fi
        handle_error "Database backup command failed"
        return 1
    fi
    
    # Verify the backup is not empty
    if [ ! -s "$db_file" ]; then
        log_message "Database dump is empty"
        if [ -f "$error_log" ]; then
            log_message "Error output: $(cat "$error_log")"
        fi
        handle_error "Database backup is empty"
        return 1
    fi
    
    log_message "Database backup completed: $(du -h "$db_file" | cut -f1) bytes"
    return 0
}

# Backup uploads directory
backup_uploads() {
    log_message "Creating uploads backup..."
    local rsync_options="-a"
    local error_log="$TEMP_DIR/rsync_error.log"
    
    if [ -d "$BACKUPS_DIR/backup_latest" ] && [ -d "$(readlink -f "$BACKUPS_DIR/backup_latest")/uploads" ]; then
        log_message "Performing incremental backup using hardlinks..."
        if ! rsync $rsync_options --delete --link-dest="$(readlink -f "$BACKUPS_DIR/backup_latest")/uploads" \
            "$UPLOADS_DIR/" "$TEMP_DIR/uploads/" 2> "$error_log"; then
            log_message "Rsync error: $(cat "$error_log")"
            handle_error "Incremental uploads backup failed"
            return 1
        fi
    else
        log_message "Performing full backup..."
        if ! rsync $rsync_options "$UPLOADS_DIR/" "$TEMP_DIR/uploads/" 2> "$error_log"; then
            log_message "Rsync error: $(cat "$error_log")"
            handle_error "Full uploads backup failed"
            return 1
        fi
    fi
    
    log_message "Uploads backup completed: $(du -sh "$TEMP_DIR/uploads" | cut -f1) total size"
    return 0
}

# Finalize backup (move from temp to final location)
finalize_backup() {
    log_message "Finalizing backup..."
    
    # Create backup directory with formatted date and timestamp (no tag)
    local backup_dir="$BACKUPS_DIR/backup_${BACKUP_FORMATTED_DATE}_${BACKUP_TIMESTAMP}"
    mkdir -p "$backup_dir"
    
    # Compress database backup with gzip
    log_message "Compressing database backup..."
    local db_file_orig="$TEMP_DIR/db_backup.sql"
    local db_file_compressed="$TEMP_DIR/db_backup.sql.gz"
    
    # Compress the SQL file
    if ! gzip -c -"$BACKUP_GZIP_LEVEL" "$db_file_orig" > "$db_file_compressed"; then
        log_message "Warning: Failed to compress database backup, using uncompressed file"
        # Move uncompressed database backup to final location
        mv "$db_file_orig" "$backup_dir/db_backup.sql"
    else
        # Calculate compression ratio
        local orig_size=$(du -h "$db_file_orig" | cut -f1)
        local compressed_size=$(du -h "$db_file_compressed" | cut -f1)
        log_message "Database compressed from $orig_size to $compressed_size"
        
        # Move compressed database backup to final location
        mv "$db_file_compressed" "$backup_dir/db_backup.sql.gz"
        # Remove original uncompressed file
        rm -f "$db_file_orig"
    fi
    
    # Move uploads to final location
    mv "$TEMP_DIR/uploads" "$backup_dir/uploads"
    
    # Update latest symlink
    if ! ln -sfn "$backup_dir" "$BACKUPS_DIR/backup_latest"; then
        handle_error "Failed to update latest symlink"
        return 1
    fi
    
    # Remove temp directory
    rm -rf "$TEMP_DIR"
    
    log_message "Backup finalized: $(basename "$backup_dir")"
    return 0
}

# Mathematical calculation with fallback if bc is not available
calculate() {
    local expression="$1"
    
    if command_exists bc; then
        echo "$(echo "$expression" | bc -l)"
    else
        # Simple fallback for basic operations
        # Note: This only works for simple integer expressions
        # Convert floating-point expression to integer arithmetic
        local expr_int="${expression//\./}"
        expr_int="${expr_int// /}"
        
        # Evaluate using shell arithmetic
        local result=$((expr_int))
        echo "$result"
    fi
}

# Clean old backups
cleanup_old_backups() {
    log_message "Cleaning up old backups..."
    
    # Remove any temporary directories from failed jobs (older than 1 day)
    find "$BACKUPS_DIR" -type d -name "temp_*" -mtime +1 -exec rm -rf {} \; 2>/dev/null || true
    
    # First remove incomplete backups (those not matching the completed pattern)
    for backup_dir in "$BACKUPS_DIR"/backup_*; do
        if [ -d "$backup_dir" ] && [ "$backup_dir" != "$BACKUPS_DIR/backup_latest" ]; then
            if ! is_completed_backup "$backup_dir"; then
                log_message "Removing incomplete backup: $(basename "$backup_dir")"
                rm -rf "$backup_dir"
            fi
        fi
    done
    
    # Get count of completed backups
    local completed_count=0
    for backup_dir in "$BACKUPS_DIR"/backup_*; do
        if [ -d "$backup_dir" ] && [ "$backup_dir" != "$BACKUPS_DIR/backup_latest" ]; then
            if is_completed_backup "$backup_dir"; then
                completed_count=$((completed_count + 1))
            fi
        fi
    done
    log_message "Found $completed_count completed backups"
    
    # Then remove old backups by days (respecting retention policy)
    if (( $(echo "$BACKUP_RETENTION_DAYS > 0" | bc -l) )); then
        # Use our calculate function which has a fallback if bc is not available
        if [ "$(calculate "$BACKUP_RETENTION_DAYS > 0")" = "1" ]; then
            local cutoff_time
            
            if command_exists bc; then
                cutoff_time=$(echo "$(date +%s) - $BACKUP_RETENTION_DAYS * 86400" | bc)
            else
                # Fallback calculation for systems without bc
                cutoff_time=$(($(date +%s) - BACKUP_RETENTION_DAYS * 86400))
            fi
            
            local formatted_date=$(format_date $cutoff_time)
            log_message "Removing backups older than $formatted_date"
            
            for backup_dir in "$BACKUPS_DIR"/backup_*; do
                if [ -d "$backup_dir" ] && [ "$backup_dir" != "$BACKUPS_DIR/backup_latest" ]; then
                    if is_completed_backup "$backup_dir"; then
                        # Extract timestamp from directory name
                        local timestamp=$(extract_timestamp "$backup_dir")
                        
                        if [ -n "$timestamp" ]; then
                            # Using numeric comparison instead of bc for timestamp comparison
                            if [ "$timestamp" -lt "$cutoff_time" ]; then
                                # Skip deletion if we would go below retention count
                                if [ "$completed_count" -le "$BACKUP_RETENTION_COUNT" ] && [ "$BACKUP_RETENTION_COUNT" -gt 0 ]; then
                                    log_message "Skipping deletion of old backup to maintain minimum count: $(basename "$backup_dir")"
                                    continue
                                fi
                                log_message "Removing old backup by date: $(basename "$backup_dir")"
                                rm -rf "$backup_dir"
                                completed_count=$((completed_count - 1))
                            fi
                        else
                            log_message "Warning: Could not extract timestamp from $(basename "$backup_dir")"
                        fi
                    fi
                fi
            done
        fi
    fi
    
    # Remove excess backups by count
    if [ "$completed_count" -gt "$BACKUP_RETENTION_COUNT" ] && [ "$BACKUP_RETENTION_COUNT" -gt 0 ]; then
        local excess_count=$((completed_count - BACKUP_RETENTION_COUNT))
        log_message "Removing $excess_count excess backups to maintain count limit"
        
        # Find and sort backups by timestamp (oldest first)
        local old_backups=$(find "$BACKUPS_DIR" -type d -name "backup_*" -not -path "$BACKUPS_DIR/backup_latest" | sort)
        
        # Remove oldest backups exceeding the count limit
        local removed=0
        echo "$old_backups" | while read backup_dir; do
            if [ "$removed" -ge "$excess_count" ]; then
                break
            fi
            if [ -d "$backup_dir" ] && is_completed_backup "$backup_dir"; then
                log_message "Removing excess backup: $(basename "$backup_dir")"
                rm -rf "$backup_dir"
                removed=$((removed + 1))
            fi
        done
    fi
    
    # Cleanup old error logs
    log_message "Cleaning up error logs older than $BACKUP_ERROR_LOGS_RETENTION_DAYS days"
    find "$BACKUP_ERROR_DIR" -type d -name "error_*" -mtime +$BACKUP_ERROR_LOGS_RETENTION_DAYS -exec rm -rf {} \; 2>/dev/null || true
    
    log_message "Cleanup completed"
    return 0
}

# =============================================================================
# Main Execution
# =============================================================================

log_message "Starting backup job with script: $SCRIPT_PATH"
trap 'save_error_info' EXIT

# Execute backup steps with error handling
init_directories || IS_ERROR=1

# Exit immediately if initialization failed
if [ "$IS_ERROR" -eq 1 ]; then
    log_message "Backup job failed during initialization."
    exit 1
fi

# Run backup steps sequentially, stop if any step fails
if [ "$IS_ERROR" -eq 0 ]; then
    backup_database || IS_ERROR=1
fi

if [ "$IS_ERROR" -eq 0 ]; then
    backup_uploads || IS_ERROR=1
fi

if [ "$IS_ERROR" -eq 0 ]; then
    finalize_backup || IS_ERROR=1
fi

# Only run cleanup if all previous steps were successful
if [ "$IS_ERROR" -eq 0 ]; then
    cleanup_old_backups || true  # Don't fail the script if cleanup fails
fi

# Check for errors and provide appropriate message
if [ "$IS_ERROR" -eq 1 ]; then
    log_message "Backup job failed. Error logs preserved for analysis."
    exit 1
else
    log_message "Backup job completed successfully"
    exit 0
fi