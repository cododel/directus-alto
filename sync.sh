#!/bin/bash
# =============================================================================
# Directus Sync Script
# This script allows syncing backups between environments
# =============================================================================

# Exit on error and pipe failures
set -e
set -o pipefail

# =============================================================================
# Environment Configuration - can be overridden externally
# =============================================================================

# Server SSH aliases/hosts
PROD_SERVER="${PROD_SERVER:-fern.co.th}"
DEV_SERVER="${DEV_SERVER:-dev.fern.co.th}"

# Remote directory paths
REMOTE_PROJECT_PATH="${REMOTE_PROJECT_PATH:-/srv/backend-directus}"
REMOTE_BACKUP_SCRIPT="${REMOTE_BACKUP_SCRIPT:-$REMOTE_PROJECT_PATH/backup.sh}"
REMOTE_RESTORE_SCRIPT="${REMOTE_RESTORE_SCRIPT:-$REMOTE_PROJECT_PATH/backup-restore.sh}"
REMOTE_BACKUPS_DIR="${REMOTE_BACKUPS_DIR:-$REMOTE_PROJECT_PATH/directus/data/backups}"
REMOTE_TMP_DIR="${REMOTE_TMP_DIR:-/tmp}"
REMOTE_BACKUP_TARGET_DIR="${REMOTE_BACKUP_TARGET_DIR:-$REMOTE_BACKUPS_DIR}"

# Local directory paths
LOCAL_PROJECT_PATH="${LOCAL_PROJECT_PATH:-./}"
LOCAL_BACKUP_SCRIPT="${LOCAL_BACKUP_SCRIPT:-$LOCAL_PROJECT_PATH/backup.sh}"
LOCAL_RESTORE_SCRIPT="${LOCAL_RESTORE_SCRIPT:-$LOCAL_PROJECT_PATH/backup-restore.sh}"
LOCAL_BACKUPS_DIR="${LOCAL_BACKUPS_DIR:-./directus/data/backups}"
LOCAL_SYNC_DIR="${LOCAL_SYNC_DIR:-$LOCAL_BACKUPS_DIR/sync}"
LOCAL_TMP_DIR="${LOCAL_TMP_DIR:-$LOCAL_SYNC_DIR/tmp}"

# =============================================================================
# Helper Functions
# =============================================================================

# Logger function with timestamp
log_message() {
    printf "[%s] %s\n" "$(date +"%Y-%m-%d %H:%M:%S")" "$1"
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
    
    if ! command_exists ssh; then missing_commands+=("ssh"); fi
    if ! command_exists rsync; then missing_commands+=("rsync"); fi
    
    if [ ${#missing_commands[@]} -ne 0 ]; then
        handle_error "Missing required commands: ${missing_commands[*]}"
    fi
}

# Create tar archive of a backup
create_tar_archive() {
    local source_dir=$1
    local target_file=$2
    local source_name=$(basename "$source_dir")
    local source_parent=$(dirname "$source_dir")
    
    log_message "Creating tar archive: $target_file"
    if ! tar -cf "$target_file" -C "$source_parent" "$source_name" 2>/dev/null; then
        handle_error "Failed to create tar archive: $target_file"
    fi
}

# Find latest backup in directory
find_latest_backup() {
    local search_dir=$1
    local backup=$(find "$search_dir" -maxdepth 1 -type d -name "backup_*" | sort -r | head -n 1)
    if [ -z "$backup" ]; then
        handle_error "No backup found in directory: $search_dir"
    fi
    printf "%s" "$backup"
}

# Clean up temporary files
cleanup_temp_files() {
    local files=("$@")
    log_message "Cleaning up temporary files..."
    for file in "${files[@]}"; do
        if [ -n "$file" ]; then
            rm -rf "$file" 2>/dev/null
        fi
    done
}

# Rename backup to include environment
rename_backup_with_environment() {
    local backup_path=$1
    local environment=$2
    
    local original_name=$(basename "$backup_path")
    local env_backup_name="backup_${environment}_$(echo "$original_name" | sed 's/^backup_//')"
    local env_backup_path="$(dirname "$backup_path")/$env_backup_name"
    
    if [ "$original_name" != "$env_backup_name" ]; then
        if ! mv "$backup_path" "$env_backup_path" 2>/dev/null; then
            handle_error "Failed to rename backup from '$backup_path' to '$env_backup_path'"
        fi
        printf "%s" "$env_backup_path"
    else
        printf "%s" "$backup_path"
    fi
}

# Store backup references
store_backup_references() {
    local tar_path=$1
    local backup_dir_path=$2
    
    if ! echo -n "$tar_path" > "$LOCAL_SYNC_DIR/latest_backup.txt" 2>/dev/null; then
        handle_error "Failed to store tar path reference"
    fi
    if ! echo -n "$backup_dir_path" > "$LOCAL_SYNC_DIR/latest_backup_dir.txt" 2>/dev/null; then
        handle_error "Failed to store backup directory reference"
    fi
    log_message "Stored reference to latest backup in $LOCAL_SYNC_DIR/latest_backup.txt"
}

# Usage instructions
usage() {
    echo "Usage: $0 <action> <environment>"
    echo ""
    echo "Actions:"
    echo "  pull        Pull a backup from the specified environment"
    echo "  push        Push a backup to the specified environment"
    echo ""
    echo "Environments:"
    echo "  prod        Production environment ($PROD_SERVER)"
    echo "  dev         Development environment ($DEV_SERVER)"
    echo "  local       Local environment"
    echo ""
    echo "Examples:"
    echo "  $0 pull prod     Pull the latest backup from production"
    echo "  $0 pull dev      Pull the latest backup from development"
    echo "  $0 pull local    Create a backup locally"
    echo "  $0 push dev      Push the latest pulled backup to development"
    echo "  $0 push local    Restore the latest pulled backup locally"
    echo ""
    echo "Note: Backups are stored in the $LOCAL_BACKUPS_DIR directory"
    echo "      Sync artifacts are stored in the $LOCAL_SYNC_DIR directory"
    echo ""
    echo "Environment Variables:"
    echo "  PROD_SERVER        Production server SSH alias/host (REQUIRED)"
    echo "  DEV_SERVER         Development server SSH alias/host (REQUIRED)"
    echo "  REMOTE_PROJECT_PATH Base path on remote servers (default: /srv/backend-directus)"
    echo "  LOCAL_BACKUPS_DIR  Local directory for backups (default: ./.backups)"
    exit 1
}

# Pull backup from environment
pull_backup() {
    # Create file descriptor 3 for data output
    exec 3>&1
    
    local environment=$1
    local ssh_alias
    local backup_script
    local backup_target_dir="$LOCAL_TMP_DIR"
    local timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    local timestamp_unix=$(date +"%s")
    local backup_name="backup_${environment}_${timestamp}_${timestamp_unix}"
    
    case "$environment" in
        prod)
            ssh_alias="$PROD_SERVER"
            backup_script="$REMOTE_BACKUP_SCRIPT"
            ;;
        dev)
            ssh_alias="$DEV_SERVER"
            backup_script="$REMOTE_BACKUP_SCRIPT"
            ;;
        local)
            backup_script="$LOCAL_BACKUP_SCRIPT"
            ;;
        *)
            handle_error "Invalid environment for pull: $environment"
            ;;
    esac
    
    # Create local directories
    mkdir -p "$backup_target_dir"
    mkdir -p "$LOCAL_BACKUPS_DIR"
    mkdir -p "$LOCAL_SYNC_DIR"
    
    log_message "Pulling backup from $environment"
    
    if [ "$environment" = "local" ]; then
        # For local environment, run backup script directly
        log_message "Running local backup script..."
        local temp_dir="$LOCAL_SYNC_DIR/local_temp"
        mkdir -p "$temp_dir"
        
        # Run backup script without specifying output path - it will use its own path
        if ! $backup_script; then
            rm -rf "$temp_dir"
            handle_error "Failed to run backup script locally"
        fi
        
        # Find the latest backup created by the backup script
        local created_backup
        created_backup=$(find_latest_backup "$LOCAL_BACKUPS_DIR")
        
        if [ -z "$created_backup" ]; then
            cleanup_temp_files "$temp_dir"
            handle_error "Failed to find created backup"
        fi
        
        log_message "Found created backup: $created_backup"
        
        # Rename backup to include environment
        created_backup=$(rename_backup_with_environment "$created_backup" "$environment")
        
        # Create tar archive with the correct path
        local backup_archive="$LOCAL_SYNC_DIR/$(basename "$created_backup").tar"
        create_tar_archive "$created_backup" "$backup_archive"
        
        # Clean up
        cleanup_temp_files "$temp_dir"
        
        # Store absolute path to the tar file and backup directory
        local tar_path=$(realpath "$backup_archive")
        local backup_dir_path=$(realpath "$created_backup")
        store_backup_references "$tar_path" "$backup_dir_path"
        
        log_message "Backup successfully created at: $backup_archive"
        log_message "Backup directory location: $created_backup"
        log_message "To restore this backup, run: $0 push local   (local restore)"
        log_message "                     or run: $0 push dev     (push to development)"
        return 0
    fi
    
    # For remote environments
    log_message "Creating backup on $environment ($ssh_alias)..."
    local remote_temp_dir
    remote_temp_dir=$(ssh "$ssh_alias" "mktemp -d")
    
    if [ -z "$remote_temp_dir" ]; then
        handle_error "Failed to create temporary directory on $ssh_alias"
    fi
    
    # Run backup script on remote server without explicit target directory
    # This allows the remote server to use its own .env configuration for backup paths
    log_message "Running backup script on remote server..."
    if ! ssh "$ssh_alias" "cd $REMOTE_PROJECT_PATH && ./backup.sh"; then
        ssh "$ssh_alias" "rm -rf $remote_temp_dir"
        handle_error "Failed to run backup script on remote server"
    fi
    
    # Find the latest backup on the remote server
    log_message "Finding latest backup on remote server..."
    local remote_backup_path
    remote_backup_path=$(ssh "$ssh_alias" "find $REMOTE_BACKUPS_DIR -maxdepth 1 -type d -name 'backup_*' | sort -r | head -n 1")
    
    if [ -z "$remote_backup_path" ]; then
        ssh "$ssh_alias" "rm -rf $remote_temp_dir"
        handle_error "Failed to find created backup on remote server"
    fi
    
    log_message "Found remote backup: $remote_backup_path"
    
    # Create a tar file of the backup directory on the remote server
    log_message "Creating tar archive on remote server..."
    local remote_tar_file="$remote_temp_dir/directus_backup.tar"
    if ! ssh "$ssh_alias" "tar -cf $remote_tar_file -C $(dirname $remote_backup_path) $(basename $remote_backup_path)"; then
        ssh "$ssh_alias" "rm -rf $remote_temp_dir"
        handle_error "Failed to create tar archive on remote server"
    fi
    
    # Pull the tar file using rsync
    log_message "Downloading backup using rsync..."
    if ! rsync -avz --progress "$ssh_alias:$remote_tar_file" "$backup_target_dir/"; then
        ssh "$ssh_alias" "rm -rf $remote_temp_dir"
        handle_error "Failed to download backup from $ssh_alias"
    fi
    
    # Extract the backup locally
    log_message "Extracting backup locally..."
    log_message "backup_target_dir: $backup_target_dir"
    if ! tar -xf "$backup_target_dir/directus_backup.tar" -C "$backup_target_dir"; then
        ssh "$ssh_alias" "rm -rf $remote_temp_dir"
        rm -f "$backup_target_dir/directus_backup.tar"
        handle_error "Failed to extract backup locally"
    fi
    
    # Get the extracted backup name
    local extracted_backup
    extracted_backup=$(find_latest_backup "$backup_target_dir")
    log_message "Found backup: $extracted_backup"
    
    # Rename backup to include environment
    log_message "Renaming backup to include environment: $environment"
    extracted_backup=$(rename_backup_with_environment "$extracted_backup" "$environment")
    log_message "Backup renamed to: $extracted_backup"
    
    # Move the backup to backups directory
    log_message "Moving backup to $LOCAL_BACKUPS_DIR directory..."
    if ! cp -r "$extracted_backup" "$LOCAL_BACKUPS_DIR/" 2>/dev/null; then
        cleanup_temp_files "$remote_temp_dir" "$backup_target_dir/directus_backup.tar"
        handle_error "Failed to move backup to $LOCAL_BACKUPS_DIR directory"
    fi
    
    # Create a local tar file from the extracted backup
    local final_backup_name=$(basename "$extracted_backup")
    local final_backup_path=$(realpath "$LOCAL_BACKUPS_DIR/$final_backup_name")
    local backup_tar_file="$LOCAL_SYNC_DIR/$final_backup_name.tar"
    
    create_tar_archive "$final_backup_path" "$backup_tar_file"
    
    # Clean up
    cleanup_temp_files "$remote_temp_dir" "$backup_target_dir/directus_backup.tar" "$extracted_backup"
    
    # Store absolute path to the tar file and backup directory
    local tar_path=$(realpath "$backup_tar_file")
    local backup_dir_path=$(realpath "$LOCAL_BACKUPS_DIR/$final_backup_name")
    store_backup_references "$tar_path" "$backup_dir_path"
    
    log_message "Backup successfully pulled from $environment and saved locally"
    log_message "Backup directory: $LOCAL_BACKUPS_DIR/$final_backup_name"
    log_message "Backup tar archive: $backup_tar_file"
    log_message "To restore this backup, run: $0 push local   (local restore)"
    log_message "                     or run: $0 push dev     (push to development)"
    
    # Close file descriptor 3
    exec 3>&-
}

# Push backup to environment
push_backup() {
    local environment=$1
    local ssh_alias
    local latest_backup
    
    # Create sync directory if it doesn't exist
    mkdir -p "$LOCAL_SYNC_DIR"
    
    # First, try to find directory path from latest_backup_dir.txt
    if [ -f "$LOCAL_SYNC_DIR/latest_backup_dir.txt" ]; then
        local backup_dir_path=$(cat "$LOCAL_SYNC_DIR/latest_backup_dir.txt")
        # Remove any trailing whitespace or newlines
        backup_dir_path=$(echo -n "$backup_dir_path" | tr -d '[:space:]')
        
        if [ -d "$backup_dir_path" ]; then
            log_message "Using backup directory from $LOCAL_SYNC_DIR/latest_backup_dir.txt: $backup_dir_path"
            latest_backup="$backup_dir_path"
        else
            log_message "Backup directory specified in latest_backup_dir.txt not found: '$backup_dir_path'"
        fi
    fi
    
    # If backup directory not found, try the tar file
    if [ -z "$latest_backup" ] && [ -f "$LOCAL_SYNC_DIR/latest_backup.txt" ]; then
        local backup_tar_path=$(cat "$LOCAL_SYNC_DIR/latest_backup.txt")
        # Remove any trailing whitespace or newlines
        backup_tar_path=$(echo -n "$backup_tar_path" | tr -d '[:space:]')
        
        if [ -f "$backup_tar_path" ]; then
            log_message "Using backup tar from $LOCAL_SYNC_DIR/latest_backup.txt: $backup_tar_path"
            
            # Extract backup name from tar path
            local backup_name=$(basename "$backup_tar_path" .tar)
            local backup_dir="$LOCAL_BACKUPS_DIR/$backup_name"
            
            # Check if the backup directory exists
            if [ ! -d "$backup_dir" ]; then
                log_message "Extracting backup from tar file..."
                if ! tar -xf "$backup_tar_path" -C "$LOCAL_BACKUPS_DIR"; then
                    handle_error "Failed to extract backup from tar file"
                fi
            fi
            
            latest_backup="$backup_dir"
        else
            log_message "Backup tar specified in latest_backup.txt not found: '$backup_tar_path'"
        fi
    fi
    
    # If still not found, search for latest backup
    if [ -z "$latest_backup" ]; then
        latest_backup=$(find_latest_backup "$LOCAL_BACKUPS_DIR")
    fi
    
    if [ -z "$latest_backup" ]; then
        handle_error "No backup found. Please run '$0 pull prod', '$0 pull dev' or '$0 pull local' first"
    fi
    
    log_message "Found local backup: $latest_backup"
    
    case "$environment" in
        prod)
            handle_error "SECURITY RESTRICTION: Pushing to production environment is not allowed"
            ;;
        dev)
            ssh_alias="$DEV_SERVER"
            ;;
        local)
            # No SSH alias needed for local
            ;;
        *)
            handle_error "Invalid environment for push: $environment"
            ;;
    esac
    
    if [ "$environment" = "local" ]; then
        # For local environment, directly run the restore script
        log_message "Running restore script locally..."
        if ! "$LOCAL_RESTORE_SCRIPT" "$latest_backup"; then
            handle_error "Failed to run restore script locally"
        fi
        log_message "Backup successfully restored locally"
        return 0
    fi
    
    # Create a tar file of the backup
    local local_tar_file="$LOCAL_SYNC_DIR/directus_backup_push.tar"
    create_tar_archive "$latest_backup" "$local_tar_file"
    
    # Push the tar file to the remote server
    log_message "Uploading backup to $environment ($ssh_alias)..."
    local remote_tmp_dir="$REMOTE_TMP_DIR"
    if ! rsync -avz --progress "$local_tar_file" "$ssh_alias:$remote_tmp_dir/"; then
        handle_error "Failed to upload backup to $ssh_alias"
    fi
    
    # Extract the backup on the remote server
    log_message "Extracting backup on remote server..."
    if ! ssh "$ssh_alias" "tar -xf $remote_tmp_dir/directus_backup_push.tar -C $remote_tmp_dir/" 2>/dev/null; then
        handle_error "Failed to extract backup on remote server"
    fi
    
    # Run the restore script on the remote server
    log_message "Running restore script on remote server..."
    local remote_backup_dir="$remote_tmp_dir/$(basename "$latest_backup")"
    if ! ssh "$ssh_alias" "$REMOTE_RESTORE_SCRIPT $remote_backup_dir" 2>/dev/null; then
        handle_error "Failed to run restore script on remote server"
    fi
    
    # Clean up
    cleanup_temp_files "$local_tar_file"
    ssh "$ssh_alias" "rm -rf $remote_tmp_dir/directus_backup_push.tar $remote_backup_dir"
    
    log_message "Backup successfully pushed and restored on $environment"
}

# =============================================================================
# Main Execution
# =============================================================================

# Check for required commands
check_commands

# Check arguments
if [ $# -lt 2 ]; then
    usage
fi

action="$1"
environment="$2"

case "$action" in
    pull)
        pull_backup "$environment"
        ;;
    push)
        push_backup "$environment"
        ;;
    *)
        handle_error "Unknown action: $action"
        ;;
esac

exit 0