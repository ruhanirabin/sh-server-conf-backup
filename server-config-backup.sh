#!/bin/bash

# Server Configuration Backup System
# Supports MariaDB/MySQL, OpenLiteSpeed, and PHP configurations
# Compatible with Ubuntu 22.x and Debian 12.x

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"
SYSTEM_CONFIG="${CONFIG_DIR}/system.conf"
REPOSITORY_CONFIG="${CONFIG_DIR}/repository.conf"
BACKUP_CONFIG="${CONFIG_DIR}/backup.conf"
LOGGING_CONFIG="${CONFIG_DIR}/logging.conf"
BACKUP_DIR="${SCRIPT_DIR}/backups"
HOSTNAME=$(hostname)

# Security: Default backup user (will be overridden by config)
BACKUP_USER="backup-service"

# Default logging settings (will be overridden by config)
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="backup.log"
LOG_MAX_SIZE="10M"
LOG_MAX_FILES=5
LOG_ROTATION_ENABLED=true
LOG_COMPRESSION=true
LOG_RETENTION_DAYS=30
LOG_LEVEL="INFO"
LOG_TIMESTAMP_FORMAT="%Y-%m-%d %H:%M:%S"

# Default configuration
DEFAULT_GIT_REPO=""
DEFAULT_GIT_BRANCH="main"
DEFAULT_BACKUP_PATHS=(
    "/etc/mysql"
    "/etc/mariadb"
    "/usr/local/lsws/conf"
    "/etc/php"
    "/etc/lsws"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Emoji support (can be disabled by setting DISABLE_EMOJI=true)
if [[ "${DISABLE_EMOJI:-false}" != true ]]; then
    EMOJI_SUCCESS="✅"
    EMOJI_ERROR="❌"
    EMOJI_WARNING="⚠️"
    EMOJI_INFO="ℹ️"
    EMOJI_ROCKET="🚀"
    EMOJI_GEAR="⚙️"
    EMOJI_LOCK="🔒"
    EMOJI_KEY="🔑"
    EMOJI_BACKUP="💾"
    EMOJI_RESTORE="🔄"
    EMOJI_MONITOR="👁️"
    EMOJI_WEBHOOK="🔗"
    EMOJI_CONFIG="📝"
    EMOJI_LOG="📋"
    EMOJI_DRIFT="🔍"
    EMOJI_VALIDATE="✔️"
    EMOJI_SERVICE="🔧"
    EMOJI_GIT="📦"
    EMOJI_SSH="🔐"
    EMOJI_FOLDER="📁"
    EMOJI_FILE="📄"
else
    # Fallback to text symbols
    EMOJI_SUCCESS="[OK]"
    EMOJI_ERROR="[ERR]"
    EMOJI_WARNING="[WARN]"
    EMOJI_INFO="[INFO]"
    EMOJI_ROCKET="[START]"
    EMOJI_GEAR="[SETUP]"
    EMOJI_LOCK="[SEC]"
    EMOJI_KEY="[KEY]"
    EMOJI_BACKUP="[BACKUP]"
    EMOJI_RESTORE="[RESTORE]"
    EMOJI_MONITOR="[MONITOR]"
    EMOJI_WEBHOOK="[WEBHOOK]"
    EMOJI_CONFIG="[CONFIG]"
    EMOJI_LOG="[LOG]"
    EMOJI_DRIFT="[DRIFT]"
    EMOJI_VALIDATE="[VALID]"
    EMOJI_SERVICE="[SERVICE]"
    EMOJI_GIT="[GIT]"
    EMOJI_SSH="[SSH]"
    EMOJI_FOLDER="[DIR]"
    EMOJI_FILE="[FILE]"
fi

# Convert size string to bytes
convert_size_to_bytes() {
    local size="$1"
    local number="${size%[A-Za-z]*}"
    local unit="${size#$number}"
    
    case "${unit^^}" in
        "K"|"KB") echo $((number * 1024)) ;;
        "M"|"MB") echo $((number * 1024 * 1024)) ;;
        "G"|"GB") echo $((number * 1024 * 1024 * 1024)) ;;
        *) echo "$number" ;;
    esac
}

# Check if log rotation is needed
should_rotate_log() {
    local log_file="$1"
    
    if [[ "$LOG_ROTATION_ENABLED" != true ]]; then
        return 1
    fi
    
    if [[ ! -f "$log_file" ]]; then
        return 1
    fi
    
    # Convert size to bytes for comparison
    local max_bytes=$(convert_size_to_bytes "$LOG_MAX_SIZE")
    local current_size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo 0)
    
    [[ $current_size -gt $max_bytes ]]
}

# Clean up old log files
cleanup_old_logs() {
    if [[ -n "$LOG_RETENTION_DAYS" && "$LOG_RETENTION_DAYS" -gt 0 ]]; then
        find "$LOG_DIR" -name "backup.log.*" -type f -mtime +$LOG_RETENTION_DAYS -delete 2>/dev/null || true
    fi
}

# Rotate log files
rotate_logs() {
    local log_file="$LOG_DIR/$LOG_FILE"
    local max_files="$LOG_MAX_FILES"
    
    if [[ ! -f "$log_file" ]]; then
        return 0
    fi
    
    # Check if rotation is needed
    if ! should_rotate_log "$log_file"; then
        return 0
    fi
    
    # Create logs directory if it doesn't exist
    mkdir -p "$LOG_DIR"
    
    # Rotate existing logs (from highest number down)
    for ((i=max_files-1; i>=1; i--)); do
        local current_log="$log_file.$i"
        local next_log="$log_file.$((i+1))"
        
        # Handle compressed logs
        if [[ -f "$current_log.gz" ]]; then
            current_log="$current_log.gz"
            next_log="$next_log.gz"
        fi
        
        if [[ -f "$current_log" ]]; then
            if [[ $i -eq $((max_files-1)) ]]; then
                # Remove the oldest log
                rm -f "$current_log"
            else
                mv "$current_log" "$next_log"
            fi
        fi
    done
    
    # Move current log to .1
    if [[ -f "$log_file" ]]; then
        mv "$log_file" "$log_file.1"
        
        # Compress if enabled
        if [[ "$LOG_COMPRESSION" == true ]]; then
            gzip "$log_file.1"
        fi
    fi
    
    # Create new log file with proper permissions
    touch "$log_file"
    if [[ -n "$BACKUP_USER" ]] && id "$BACKUP_USER" &>/dev/null; then
        chown "$BACKUP_USER:$BACKUP_USER" "$log_file"
    fi
    chmod 640 "$log_file"
    
    # Clean old logs based on retention policy
    cleanup_old_logs
    
    # Log the rotation (to the new file)
    echo "[$(date +"$LOG_TIMESTAMP_FORMAT")] [$(hostname)] [INFO] Log rotation completed" >> "$log_file"
}

# Enhanced logging function
log() {
    local message="$1"
    local level="${2:-INFO}"
    local timestamp=$(date +"$LOG_TIMESTAMP_FORMAT")
    local hostname=$(hostname)
    
    # Ensure log directory exists
    mkdir -p "$LOG_DIR"
    
    # Check if we need to rotate before logging
    rotate_logs
    
    # Log format: [TIMESTAMP] [HOSTNAME] [LEVEL] MESSAGE
    echo "[$timestamp] [$hostname] [$level] $message" >> "$LOG_DIR/$LOG_FILE"
}

# Convenience logging functions
log_error() { 
    log "$1" "ERROR"
    echo -e "${RED}ERROR: $1${NC}" >&2
}

log_warn() { 
    log "$1" "WARN"
    echo -e "${YELLOW}WARNING: $1${NC}"
}

log_info() { 
    log "$1" "INFO"
    echo -e "${BLUE}INFO: $1${NC}"
}

log_debug() { 
    if [[ "$LOG_LEVEL" == "DEBUG" ]]; then
        log "$1" "DEBUG"
        echo -e "${NC}DEBUG: $1${NC}"
    fi
}

# Error handling
error_exit() {
    log_error "$1"
    exit 1
}

# Success message
success() {
    echo -e "${GREEN}${EMOJI_SUCCESS} $1${NC}"
    log_info "SUCCESS: $1"
}

# Warning message
warning() {
    echo -e "${YELLOW}${EMOJI_WARNING} $1${NC}"
    log_warn "$1"
}

# Info message
info() {
    echo -e "${BLUE}${EMOJI_INFO} $1${NC}"
    log_info "$1"
}

# Enhanced message functions with emojis
backup_info() {
    echo -e "${CYAN}${EMOJI_BACKUP} $1${NC}"
    log_info "BACKUP: $1"
}

restore_info() {
    echo -e "${PURPLE}${EMOJI_RESTORE} $1${NC}"
    log_info "RESTORE: $1"
}

config_info() {
    echo -e "${BLUE}${EMOJI_CONFIG} $1${NC}"
    log_info "CONFIG: $1"
}

security_info() {
    echo -e "${RED}${EMOJI_LOCK} $1${NC}"
    log_info "SECURITY: $1"
}

webhook_info() {
    echo -e "${CYAN}${EMOJI_WEBHOOK} $1${NC}"
    log_info "WEBHOOK: $1"
}

# Create system binding configuration
create_system_binding() {
    local hostname="$1"
    local timestamp=$(date -Iseconds)
    local system_id="${hostname}-$(date +%s)"
    
    mkdir -p "$CONFIG_DIR"
    
    cat > "$SYSTEM_CONFIG" << EOF
# System identification and binding
# Generated on: $timestamp
BOUND_HOSTNAME="$hostname"
BOUND_TIMESTAMP="$timestamp"
SYSTEM_ID="$system_id"
INSTALL_DIR="$SCRIPT_DIR"
BACKUP_USER="$BACKUP_USER"
EOF
    
    # Create binding lock file
    echo "$hostname:$timestamp:$system_id" > "$SCRIPT_DIR/.system-binding"
    
    log_info "System binding created for hostname: $hostname"
}

# Update system binding
update_system_binding() {
    local hostname="$1"
    local timestamp=$(date -Iseconds)
    
    if [[ -f "$SYSTEM_CONFIG" ]]; then
        # Update existing config
        sed -i "s/^BOUND_HOSTNAME=.*/BOUND_HOSTNAME=\"$hostname\"/" "$SYSTEM_CONFIG"
        sed -i "s/^BOUND_TIMESTAMP=.*/BOUND_TIMESTAMP=\"$timestamp\"/" "$SYSTEM_CONFIG"
    else
        create_system_binding "$hostname"
    fi
    
    log_info "System binding updated for hostname: $hostname"
}

# Initialize system binding with hostname validation
initialize_system_binding() {
    local current_hostname=$(hostname)
    
    # Handle command line options
    case "${1:-}" in
        "--rebind-hostname")
            log_info "Rebinding hostname from $BOUND_HOSTNAME to $current_hostname"
            update_system_binding "$current_hostname"
            return 0
            ;;
        "--recovery-mode")
            log_warn "Recovery mode activated - hostname validation bypassed"
            return 0
            ;;
        "--force")
            log_warn "Force mode activated - hostname validation bypassed"
            return 0
            ;;
    esac
    
    # Load existing binding if it exists
    if [[ -f "$SYSTEM_CONFIG" ]]; then
        source "$SYSTEM_CONFIG"
    fi
    
    # Determine binding status
    local binding_status="unknown"
    if [[ ! -f "$SYSTEM_CONFIG" ]]; then
        binding_status="new"
    elif [[ -z "${BOUND_HOSTNAME:-}" ]]; then
        binding_status="unbound"
    elif [[ "$current_hostname" == "$BOUND_HOSTNAME" ]]; then
        binding_status="matched"
    else
        binding_status="mismatched"
    fi
    
    case "$binding_status" in
        "new")
            log_info "New installation detected. Binding to hostname: $current_hostname"
            create_system_binding "$current_hostname"
            ;;
        "unbound")
            log_warn "Configuration exists but no hostname binding found"
            log_warn "Auto-binding to current hostname: $current_hostname"
            update_system_binding "$current_hostname"
            ;;
        "matched")
            log_debug "Hostname binding validated: $current_hostname"
            ;;
        "mismatched")
            log_error "Hostname mismatch detected!"
            log_error "Current hostname: $current_hostname"
            log_error "Bound hostname: $BOUND_HOSTNAME"
            log_error ""
            log_error "If this is intentional, use one of:"
            log_error "  server-backup --rebind-hostname <command>    # Update binding to current hostname"
            log_error "  server-backup --recovery-mode <command>      # Disaster recovery mode"
            log_error "  server-backup --force <command>              # Skip hostname validation (dangerous)"
            exit 1
            ;;
    esac
}

# Send webhook notification
send_webhook() {
    local event="$1"
    local severity="$2"
    local message="$3"
    local data="$4"
    
    # Check if webhooks are enabled
    if [[ "$WEBHOOK_ENABLED" != true ]] || [[ -z "$WEBHOOK_URL" ]]; then
        return 0
    fi
    
    # Check if this event should be sent
    if [[ ! "$WEBHOOK_EVENTS" =~ $event ]]; then
        log_debug "Webhook event $event not in enabled events: $WEBHOOK_EVENTS"
        return 0
    fi
    
    local timestamp=$(date -Iseconds)
    local hostname=$(hostname)
    
    # Create webhook payload
    local payload=$(cat << EOF
{
  "event": "$event",
  "timestamp": "$timestamp",
  "hostname": "$hostname",
  "system_id": "${SYSTEM_ID:-unknown}",
  "severity": "$severity",
  "message": "$message",
  "data": $data,
  "metadata": {
    "backup_system_version": "2.0.0",
    "git_repo": "${GIT_REPO:-unknown}",
    "git_commit": "$(cd "$BACKUP_DIR" 2>/dev/null && git_as_backup_user rev-parse HEAD 2>/dev/null || echo 'unknown')",
    "user": "${BACKUP_USER:-unknown}"
  }
}
EOF
)
    
    # Send webhook with retry logic
    local retry_count=0
    local max_retries="$WEBHOOK_RETRY_COUNT"
    local retry_delay="$WEBHOOK_RETRY_DELAY"
    
    while [[ $retry_count -lt $max_retries ]]; do
        log_debug "Sending webhook (attempt $((retry_count + 1))/$max_retries): $event"
        
        local response=$(curl -s -w "%{http_code}" \
            -X POST \
            -H "Content-Type: application/json" \
            -H "User-Agent: ServerBackup/2.0.0" \
            --max-time "$WEBHOOK_TIMEOUT" \
            --data "$payload" \
            "$WEBHOOK_URL" 2>/dev/null)
        
        local http_code="${response: -3}"
        local response_body="${response%???}"
        
        if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
            log_debug "Webhook sent successfully: $event (HTTP $http_code)"
            return 0
        else
            log_warn "Webhook failed: $event (HTTP $http_code) - attempt $((retry_count + 1))/$max_retries"
            retry_count=$((retry_count + 1))
            
            if [[ $retry_count -lt $max_retries ]]; then
                sleep "$retry_delay"
            fi
        fi
    done
    
    log_error "Webhook failed after $max_retries attempts: $event"
    return 1
}

# Webhook convenience functions
webhook_backup_success() {
    local duration="$1"
    local files_backed_up="$2"
    local commit_hash="$3"
    
    local data=$(cat << EOF
{
  "duration": $duration,
  "files_backed_up": $files_backed_up,
  "commit_hash": "$commit_hash",
  "backup_size": "$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo 'unknown')"
}
EOF
)
    
    send_webhook "backup_success" "info" "Backup completed successfully in ${duration}s" "$data"
}

webhook_backup_failed() {
    local error_message="$1"
    local duration="$2"
    
    local data=$(cat << EOF
{
  "error": "$error_message",
  "duration": $duration,
  "last_successful_backup": "$(cd "$BACKUP_DIR" 2>/dev/null && git_as_backup_user log -1 --format='%ci' 2>/dev/null || echo 'unknown')"
}
EOF
)
    
    send_webhook "backup_failed" "error" "Backup failed: $error_message" "$data"
}

webhook_drift_detected() {
    local changes_json="$1"
    local total_changes="$2"
    local severity="$3"
    
    local data=$(cat << EOF
{
  "changes": $changes_json,
  "total_changes": $total_changes,
  "services_affected": []
}
EOF
)
    
    send_webhook "drift_detected" "$severity" "Configuration drift detected: $total_changes changes" "$data"
}

webhook_validation_failed() {
    local issues_json="$1"
    local backup_blocked="$2"
    
    local data=$(cat << EOF
{
  "issues": $issues_json,
  "backup_blocked": $backup_blocked,
  "auto_fixable": 0,
  "manual_fixes_needed": 0
}
EOF
)
    
    send_webhook "validation_failed" "error" "Configuration validation failed" "$data"
}

webhook_service_restart() {
    local services_json="$1"
    local all_successful="$2"
    local trigger="$3"
    
    local severity="info"
    if [[ "$all_successful" != true ]]; then
        severity="error"
    fi
    
    local data=$(cat << EOF
{
  "trigger": "$trigger",
  "services": $services_json,
  "all_successful": $all_successful
}
EOF
)
    
    send_webhook "service_restart" "$severity" "Service restart completed" "$data"
}

# Comprehensive permissions audit
audit_permissions() {
    local issues_found=0
    
    echo -e "${BLUE}${EMOJI_LOCK} Security & Permissions Audit${NC}"
    echo "=================================="
    echo
    
    # Check script directory permissions
    echo -e "${CYAN}${EMOJI_FOLDER} Script Directory: $SCRIPT_DIR${NC}"
    if [[ -d "$SCRIPT_DIR" ]]; then
        local script_perms=$(stat -c "%a" "$SCRIPT_DIR" 2>/dev/null || stat -f "%A" "$SCRIPT_DIR" 2>/dev/null)
        local script_owner=$(stat -c "%U:%G" "$SCRIPT_DIR" 2>/dev/null || stat -f "%Su:%Sg" "$SCRIPT_DIR" 2>/dev/null)
        echo "  Permissions: $script_perms"
        echo "  Owner: $script_owner"
        
        # Check if backup user can access
        if [[ -n "$BACKUP_USER" ]] && ! sudo -u "$BACKUP_USER" test -r "$SCRIPT_DIR" 2>/dev/null; then
            echo -e "  ${EMOJI_ERROR} Backup user cannot read script directory"
            issues_found=$((issues_found + 1))
        else
            echo -e "  ${EMOJI_SUCCESS} Backup user access: OK"
        fi
    else
        echo -e "  ${EMOJI_ERROR} Script directory not found"
        issues_found=$((issues_found + 1))
    fi
    echo
    
    # Check configuration directory permissions
    echo -e "${CYAN}${EMOJI_CONFIG} Configuration Directory: $CONFIG_DIR${NC}"
    if [[ -d "$CONFIG_DIR" ]]; then
        local config_perms=$(stat -c "%a" "$CONFIG_DIR" 2>/dev/null || stat -f "%A" "$CONFIG_DIR" 2>/dev/null)
        local config_owner=$(stat -c "%U:%G" "$CONFIG_DIR" 2>/dev/null || stat -f "%Su:%Sg" "$CONFIG_DIR" 2>/dev/null)
        echo "  Permissions: $config_perms"
        echo "  Owner: $config_owner"
        
        # Check individual config files
        for config_file in "$SYSTEM_CONFIG" "$REPOSITORY_CONFIG" "$BACKUP_CONFIG" "$LOGGING_CONFIG"; do
            if [[ -f "$config_file" ]]; then
                local file_perms=$(stat -c "%a" "$config_file" 2>/dev/null || stat -f "%A" "$config_file" 2>/dev/null)
                local file_owner=$(stat -c "%U:%G" "$config_file" 2>/dev/null || stat -f "%Su:%Sg" "$config_file" 2>/dev/null)
                local file_name=$(basename "$config_file")
                
                echo "  $file_name: $file_perms ($file_owner)"
                
                # Check if permissions are secure (600 or 640)
                if [[ "$file_perms" != "600" && "$file_perms" != "640" ]]; then
                    echo -e "    ${EMOJI_WARNING} Insecure permissions (should be 600)"
                    issues_found=$((issues_found + 1))
                fi
                
                # Check if backup user owns the file
                if [[ "$file_owner" != "$BACKUP_USER:$BACKUP_USER" ]]; then
                    echo -e "    ${EMOJI_WARNING} Not owned by backup user"
                    issues_found=$((issues_found + 1))
                fi
            else
                echo -e "  ${EMOJI_ERROR} $(basename "$config_file"): Missing"
                issues_found=$((issues_found + 1))
            fi
        done
    else
        echo -e "  ${EMOJI_ERROR} Configuration directory not found"
        issues_found=$((issues_found + 1))
    fi
    echo
    
    # Check backup directory permissions
    echo -e "${CYAN}${EMOJI_BACKUP} Backup Directory: $BACKUP_DIR${NC}"
    if [[ -d "$BACKUP_DIR" ]]; then
        local backup_perms=$(stat -c "%a" "$BACKUP_DIR" 2>/dev/null || stat -f "%A" "$BACKUP_DIR" 2>/dev/null)
        local backup_owner=$(stat -c "%U:%G" "$BACKUP_DIR" 2>/dev/null || stat -f "%Su:%Sg" "$BACKUP_DIR" 2>/dev/null)
        echo "  Permissions: $backup_perms"
        echo "  Owner: $backup_owner"
        
        if [[ "$backup_owner" != "$BACKUP_USER:$BACKUP_USER" ]]; then
            echo -e "  ${EMOJI_WARNING} Not owned by backup user"
            issues_found=$((issues_found + 1))
        else
            echo -e "  ${EMOJI_SUCCESS} Ownership: OK"
        fi
        
        # Check Git repository permissions
        if [[ -d "$BACKUP_DIR/.git" ]]; then
            local git_perms=$(stat -c "%a" "$BACKUP_DIR/.git" 2>/dev/null || stat -f "%A" "$BACKUP_DIR/.git" 2>/dev/null)
            local git_owner=$(stat -c "%U:%G" "$BACKUP_DIR/.git" 2>/dev/null || stat -f "%Su:%Sg" "$BACKUP_DIR/.git" 2>/dev/null)
            echo "  Git directory: $git_perms ($git_owner)"
            
            if [[ "$git_owner" != "$BACKUP_USER:$BACKUP_USER" ]]; then
                echo -e "    ${EMOJI_WARNING} Git directory not owned by backup user"
                issues_found=$((issues_found + 1))
            fi
        fi
    else
        echo -e "  ${EMOJI_ERROR} Backup directory not found"
        issues_found=$((issues_found + 1))
    fi
    echo
    
    # Check log directory permissions
    echo -e "${CYAN}${EMOJI_LOG} Log Directory: $LOG_DIR${NC}"
    if [[ -d "$LOG_DIR" ]]; then
        local log_perms=$(stat -c "%a" "$LOG_DIR" 2>/dev/null || stat -f "%A" "$LOG_DIR" 2>/dev/null)
        local log_owner=$(stat -c "%U:%G" "$LOG_DIR" 2>/dev/null || stat -f "%Su:%Sg" "$LOG_DIR" 2>/dev/null)
        echo "  Permissions: $log_perms"
        echo "  Owner: $log_owner"
        
        # Check log file permissions
        if [[ -f "$LOG_DIR/$LOG_FILE" ]]; then
            local logfile_perms=$(stat -c "%a" "$LOG_DIR/$LOG_FILE" 2>/dev/null || stat -f "%A" "$LOG_DIR/$LOG_FILE" 2>/dev/null)
            local logfile_owner=$(stat -c "%U:%G" "$LOG_DIR/$LOG_FILE" 2>/dev/null || stat -f "%Su:%Sg" "$LOG_DIR/$LOG_FILE" 2>/dev/null)
            echo "  Log file: $logfile_perms ($logfile_owner)"
            
            if [[ "$logfile_perms" != "640" && "$logfile_perms" != "644" ]]; then
                echo -e "    ${EMOJI_WARNING} Log file permissions should be 640"
                issues_found=$((issues_found + 1))
            fi
        fi
    else
        echo -e "  ${EMOJI_ERROR} Log directory not found"
        issues_found=$((issues_found + 1))
    fi
    echo
    
    # Check SSH key permissions (if backup user exists)
    if [[ -n "$BACKUP_USER" ]] && id "$BACKUP_USER" &>/dev/null; then
        local ssh_dir="/home/$BACKUP_USER/.ssh"
        echo -e "${CYAN}${EMOJI_SSH} SSH Directory: $ssh_dir${NC}"
        
        if [[ -d "$ssh_dir" ]]; then
            local ssh_perms=$(stat -c "%a" "$ssh_dir" 2>/dev/null || stat -f "%A" "$ssh_dir" 2>/dev/null)
            local ssh_owner=$(stat -c "%U:%G" "$ssh_dir" 2>/dev/null || stat -f "%Su:%Sg" "$ssh_dir" 2>/dev/null)
            echo "  Permissions: $ssh_perms"
            echo "  Owner: $ssh_owner"
            
            if [[ "$ssh_perms" != "700" ]]; then
                echo -e "  ${EMOJI_ERROR} SSH directory permissions should be 700"
                issues_found=$((issues_found + 1))
            fi
            
            # Check SSH keys
            for key_file in "$ssh_dir"/id_*; do
                if [[ -f "$key_file" && ! "$key_file" =~ \.pub$ ]]; then
                    local key_perms=$(stat -c "%a" "$key_file" 2>/dev/null || stat -f "%A" "$key_file" 2>/dev/null)
                    local key_name=$(basename "$key_file")
                    echo "  Private key $key_name: $key_perms"
                    
                    if [[ "$key_perms" != "600" ]]; then
                        echo -e "    ${EMOJI_ERROR} Private key permissions should be 600"
                        issues_found=$((issues_found + 1))
                    fi
                fi
            done
        else
            echo -e "  ${EMOJI_WARNING} SSH directory not found"
        fi
        echo
    fi
    
    # Check sudoers file
    echo -e "${CYAN}${EMOJI_LOCK} Sudoers Configuration${NC}"
    local sudoers_file="/etc/sudoers.d/backup-service"
    if [[ -f "$sudoers_file" ]]; then
        local sudoers_perms=$(stat -c "%a" "$sudoers_file" 2>/dev/null || stat -f "%A" "$sudoers_file" 2>/dev/null)
        local sudoers_owner=$(stat -c "%U:%G" "$sudoers_file" 2>/dev/null || stat -f "%Su:%Sg" "$sudoers_file" 2>/dev/null)
        echo "  File: $sudoers_file"
        echo "  Permissions: $sudoers_perms"
        echo "  Owner: $sudoers_owner"
        
        if [[ "$sudoers_perms" != "440" ]]; then
            echo -e "  ${EMOJI_ERROR} Sudoers file permissions should be 440"
            issues_found=$((issues_found + 1))
        fi
        
        if [[ "$sudoers_owner" != "root:root" ]]; then
            echo -e "  ${EMOJI_ERROR} Sudoers file should be owned by root:root"
            issues_found=$((issues_found + 1))
        fi
    else
        echo -e "  ${EMOJI_ERROR} Sudoers file not found"
        issues_found=$((issues_found + 1))
    fi
    echo
    
    # Summary
    echo "Audit Summary"
    echo "============="
    if [[ $issues_found -eq 0 ]]; then
        echo -e "${GREEN}${EMOJI_SUCCESS} All permissions are correctly configured!${NC}"
    else
        echo -e "${YELLOW}${EMOJI_WARNING} Found $issues_found permission issues${NC}"
        echo
        echo "To fix permission issues, run:"
        echo "  server-backup fix-permissions"
    fi
    
    return $issues_found
}

# Fix common permission issues
fix_permissions() {
    security_info "Fixing permission issues..."
    
    # Fix script directory ownership
    if [[ -d "$SCRIPT_DIR" ]] && [[ -n "$BACKUP_USER" ]]; then
        info "Setting script directory ownership..."
        chown -R "$BACKUP_USER:$BACKUP_USER" "$SCRIPT_DIR" 2>/dev/null || {
            warning "Could not change script directory ownership (may need sudo)"
        }
    fi
    
    # Fix configuration directory permissions
    if [[ -d "$CONFIG_DIR" ]]; then
        info "Setting configuration directory permissions..."
        chmod 750 "$CONFIG_DIR" 2>/dev/null || true
        chown "$BACKUP_USER:$BACKUP_USER" "$CONFIG_DIR" 2>/dev/null || true
        
        # Fix individual config files
        for config_file in "$CONFIG_DIR"/*.conf; do
            if [[ -f "$config_file" ]]; then
                chmod 600 "$config_file" 2>/dev/null || true
                chown "$BACKUP_USER:$BACKUP_USER" "$config_file" 2>/dev/null || true
            fi
        done
    fi
    
    # Fix backup directory permissions
    if [[ -d "$BACKUP_DIR" ]] && [[ -n "$BACKUP_USER" ]]; then
        info "Setting backup directory permissions..."
        chown -R "$BACKUP_USER:$BACKUP_USER" "$BACKUP_DIR" 2>/dev/null || {
            warning "Could not change backup directory ownership (may need sudo)"
        }
    fi
    
    # Fix log directory permissions
    if [[ -d "$LOG_DIR" ]] && [[ -n "$BACKUP_USER" ]]; then
        info "Setting log directory permissions..."
        chown -R "$BACKUP_USER:$BACKUP_USER" "$LOG_DIR" 2>/dev/null || true
        
        if [[ -f "$LOG_DIR/$LOG_FILE" ]]; then
            chmod 640 "$LOG_DIR/$LOG_FILE" 2>/dev/null || true
        fi
    fi
    
    # Fix SSH directory permissions (if exists)
    if [[ -n "$BACKUP_USER" ]] && id "$BACKUP_USER" &>/dev/null; then
        local ssh_dir="/home/$BACKUP_USER/.ssh"
        if [[ -d "$ssh_dir" ]]; then
            info "Setting SSH directory permissions..."
            chmod 700 "$ssh_dir" 2>/dev/null || true
            chown "$BACKUP_USER:$BACKUP_USER" "$ssh_dir" 2>/dev/null || true
            
            # Fix SSH key permissions
            for key_file in "$ssh_dir"/id_*; do
                if [[ -f "$key_file" && ! "$key_file" =~ \.pub$ ]]; then
                    chmod 600 "$key_file" 2>/dev/null || true
                    chown "$BACKUP_USER:$BACKUP_USER" "$key_file" 2>/dev/null || true
                fi
                if [[ -f "$key_file.pub" ]]; then
                    chmod 644 "$key_file.pub" 2>/dev/null || true
                    chown "$BACKUP_USER:$BACKUP_USER" "$key_file.pub" 2>/dev/null || true
                fi
            done
        fi
    fi
    
    success "Permission fixes applied"
    info "Run 'server-backup audit-permissions' to verify"
}

# Configuration drift detection
detect_config_drift() {
    local since_option="${1:-last-backup}"
    local continuous_mode="${2:-false}"
    
    if [[ ! -d "$BACKUP_DIR/.git" ]]; then
        error_exit "No Git repository found. Run backup first."
    fi
    
    cd "$BACKUP_DIR"
    
    # Get reference point for comparison
    local reference_commit=""
    case "$since_option" in
        "last-backup")
            reference_commit=$(git_as_backup_user log -1 --format='%H' 2>/dev/null)
            ;;
        "last-commit")
            reference_commit=$(git_as_backup_user log -1 --format='%H' 2>/dev/null)
            ;;
        *)
            # Assume it's a commit hash or time specification
            reference_commit=$(git_as_backup_user rev-parse "$since_option" 2>/dev/null)
            ;;
    esac
    
    if [[ -z "$reference_commit" ]]; then
        error_exit "Could not determine reference commit for drift detection"
    fi
    
    log_info "Checking configuration drift since commit: ${reference_commit:0:8}"
    
    # Create temporary backup to compare against
    local temp_backup_dir=$(mktemp -d)
    local host_backup_dir="$temp_backup_dir/$HOSTNAME"
    mkdir -p "$host_backup_dir"
    
    # Backup current configurations
    local changes_detected=false
    local changes_json="["
    local total_changes=0
    local severity="info"
    
    for path in $BACKUP_PATHS; do
        if [[ -d "$path" ]]; then
            local dest_name=$(basename "$path")
            local dest_path="$host_backup_dir/$dest_name"
            local reference_path="$BACKUP_DIR/$HOSTNAME/$dest_name"
            
            # Create current backup
            rsync -av --exclude="*.log" --exclude="*.tmp" --exclude="*.cache" --exclude="*.pid" --exclude="*.sock" "$path/" "$dest_path/" >/dev/null 2>&1
            
            # Compare with reference if it exists
            if [[ -d "$reference_path" ]]; then
                local diff_output=$(diff -r "$reference_path" "$dest_path" 2>/dev/null || true)
                
                if [[ -n "$diff_output" ]]; then
                    changes_detected=true
                    total_changes=$((total_changes + 1))
                    
                    # Count lines changed
                    local lines_changed=$(echo "$diff_output" | wc -l)
                    
                    # Get a preview of changes (first few lines)
                    local diff_preview=$(echo "$diff_output" | head -5 | sed 's/"/\\"/g' | tr '\n' '\\n')
                    
                    # Determine severity based on file type and changes
                    local file_severity="minor"
                    if [[ "$dest_name" =~ (mysql|mariadb) ]] && [[ $lines_changed -gt 5 ]]; then
                        file_severity="major"
                        severity="warn"
                    elif [[ $lines_changed -gt 20 ]]; then
                        file_severity="critical"
                        severity="error"
                    fi
                    
                    # Add to changes JSON
                    if [[ "$changes_json" != "[" ]]; then
                        changes_json+=","
                    fi
                    
                    changes_json+=$(cat << EOF
{
  "file": "$path",
  "type": "modified",
  "lines_changed": $lines_changed,
  "severity": "$file_severity",
  "diff_preview": "$diff_preview"
}
EOF
)
                fi
            else
                # New configuration directory
                changes_detected=true
                total_changes=$((total_changes + 1))
                severity="warn"
                
                if [[ "$changes_json" != "[" ]]; then
                    changes_json+=","
                fi
                
                changes_json+=$(cat << EOF
{
  "file": "$path",
  "type": "new",
  "lines_changed": 0,
  "severity": "major",
  "diff_preview": "New configuration directory detected"
}
EOF
)
            fi
        fi
    done
    
    changes_json+="]"
    
    # Cleanup
    rm -rf "$temp_backup_dir"
    
    # Report results
    if [[ "$changes_detected" == true ]]; then
        log_warn "Configuration drift detected: $total_changes changes"
        
        # Send webhook notification
        webhook_drift_detected "$changes_json" "$total_changes" "$severity"
        
        if [[ "$continuous_mode" != true ]]; then
            echo "Configuration Drift Report"
            echo "========================="
            echo "Reference commit: ${reference_commit:0:8}"
            echo "Total changes: $total_changes"
            echo "Severity: $severity"
            echo
            
            # Parse and display changes
            echo "$changes_json" | jq -r '.[] | "- \(.file): \(.type) (\(.lines_changed) lines changed)"' 2>/dev/null || {
                echo "Changes detected in:"
                for path in $BACKUP_PATHS; do
                    echo "- $path"
                done
            }
        fi
        
        return 1  # Changes detected
    else
        log_info "No configuration drift detected"
        if [[ "$continuous_mode" != true ]]; then
            echo "No configuration drift detected since ${reference_commit:0:8}"
        fi
        return 0  # No changes
    fi
}

# Continuous drift monitoring
start_drift_monitoring() {
    local check_interval="${1:-300}"  # 5 minutes default
    
    log_info "Starting continuous drift monitoring (interval: ${check_interval}s)"
    
    while true; do
        if detect_config_drift "last-backup" true; then
            log_debug "Drift monitoring: No changes detected"
        else
            log_warn "Drift monitoring: Changes detected"
        fi
        
        sleep "$check_interval"
    done
}

# Validate MySQL/MariaDB configuration
validate_mysql_config() {
    local config_file="$1"
    local issues=()
    
    if [[ ! -f "$config_file" ]]; then
        return 0
    fi
    
    # Check for common MySQL configuration issues
    local line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        
        # Skip comments and empty lines
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line// }" ]]; then
            continue
        fi
        
        # Check for common typos
        if [[ "$line" =~ max_connection[^s] ]]; then
            issues+=("{\"file\":\"$config_file\",\"line\":$line_num,\"issue\":\"syntax_error\",\"message\":\"Invalid directive 'max_connection'\",\"suggestion\":\"Did you mean 'max_connections'?\"}")
        fi
        
        # Check for deprecated options
        if [[ "$line" =~ query_cache_size ]]; then
            issues+=("{\"file\":\"$config_file\",\"line\":$line_num,\"issue\":\"deprecated\",\"message\":\"query_cache_size is deprecated in MySQL 8.0+\",\"suggestion\":\"Consider removing this option\"}")
        fi
        
    done < "$config_file"
    
    # Test configuration syntax if mysqld is available
    if command -v mysqld &>/dev/null; then
        local syntax_check=$(mysqld --defaults-file="$config_file" --validate-config 2>&1 || true)
        if [[ -n "$syntax_check" ]]; then
            issues+=("{\"file\":\"$config_file\",\"line\":0,\"issue\":\"syntax_error\",\"message\":\"MySQL syntax validation failed\",\"suggestion\":\"Check configuration syntax\"}")
        fi
    fi
    
    printf '%s\n' "${issues[@]}"
}

# Validate PHP configuration
validate_php_config() {
    local config_file="$1"
    local issues=()
    
    if [[ ! -f "$config_file" ]]; then
        return 0
    fi
    
    # Test PHP configuration syntax
    if command -v php &>/dev/null; then
        local syntax_check=$(php -t -c "$config_file" 2>&1 || true)
        if [[ "$syntax_check" =~ "Parse error" ]] || [[ "$syntax_check" =~ "Fatal error" ]]; then
            issues+=("{\"file\":\"$config_file\",\"line\":0,\"issue\":\"syntax_error\",\"message\":\"PHP syntax validation failed\",\"suggestion\":\"Check configuration syntax\"}")
        fi
    fi
    
    printf '%s\n' "${issues[@]}"
}

# Validate Apache configuration
validate_apache_config() {
    local config_file="$1"
    local issues=()
    
    if [[ ! -f "$config_file" ]]; then
        return 0
    fi
    
    # Test Apache configuration syntax
    if command -v apache2ctl &>/dev/null; then
        local syntax_check=$(apache2ctl -t 2>&1 || true)
        if [[ "$syntax_check" =~ "Syntax error" ]]; then
            issues+=("{\"file\":\"$config_file\",\"line\":0,\"issue\":\"syntax_error\",\"message\":\"Apache syntax validation failed\",\"suggestion\":\"Check configuration syntax\"}")
        fi
    elif command -v httpd &>/dev/null; then
        local syntax_check=$(httpd -t 2>&1 || true)
        if [[ "$syntax_check" =~ "Syntax error" ]]; then
            issues+=("{\"file\":\"$config_file\",\"line\":0,\"issue\":\"syntax_error\",\"message\":\"Apache syntax validation failed\",\"suggestion\":\"Check configuration syntax\"}")
        fi
    fi
    
    printf '%s\n' "${issues[@]}"
}

# Pre-backup validation
validate_before_backup() {
    local fix_issues="${1:-false}"
    local all_issues=()
    local total_issues=0
    local backup_blocked=false
    
    log_info "Running pre-backup validation..."
    
    # Check disk space
    local backup_dir_usage=$(df "$BACKUP_DIR" | awk 'NR==2 {print $5}' | sed 's/%//')
    if [[ "$backup_dir_usage" -gt 90 ]]; then
        all_issues+=("{\"file\":\"$BACKUP_DIR\",\"issue\":\"disk_space\",\"message\":\"Backup directory is ${backup_dir_usage}% full\",\"suggestion\":\"Clean up old backups or increase disk space\"}")
        backup_blocked=true
        total_issues=$((total_issues + 1))
    fi
    
    # Check backup user permissions
    if [[ -n "$BACKUP_USER" ]] && ! id "$BACKUP_USER" &>/dev/null; then
        all_issues+=("{\"file\":\"system\",\"issue\":\"user_missing\",\"message\":\"Backup user $BACKUP_USER does not exist\",\"suggestion\":\"Create backup user or update configuration\"}")
        backup_blocked=true
        total_issues=$((total_issues + 1))
    fi
    
    # Validate each backup path
    for path in $BACKUP_PATHS; do
        if [[ ! -d "$path" ]]; then
            all_issues+=("{\"file\":\"$path\",\"issue\":\"path_missing\",\"message\":\"Backup path does not exist\",\"suggestion\":\"Create directory or remove from backup paths\"}")
            total_issues=$((total_issues + 1))
            continue
        fi
        
        # Check read permissions
        if [[ ! -r "$path" ]]; then
            all_issues+=("{\"file\":\"$path\",\"issue\":\"permission_denied\",\"message\":\"Cannot read backup path\",\"suggestion\":\"Check file permissions\"}")
            backup_blocked=true
            total_issues=$((total_issues + 1))
        fi
        
        # Validate configuration files based on path
        case "$path" in
            */mysql*|*/mariadb*)
                # Find and validate MySQL config files
                while IFS= read -r -d '' config_file; do
                    local mysql_issues=($(validate_mysql_config "$config_file"))
                    all_issues+=("${mysql_issues[@]}")
                    total_issues=$((total_issues + ${#mysql_issues[@]}))
                done < <(find "$path" -name "*.cnf" -type f -print0 2>/dev/null)
                ;;
            */php*)
                # Find and validate PHP config files
                while IFS= read -r -d '' config_file; do
                    local php_issues=($(validate_php_config "$config_file"))
                    all_issues+=("${php_issues[@]}")
                    total_issues=$((total_issues + ${#php_issues[@]}))
                done < <(find "$path" -name "*.ini" -type f -print0 2>/dev/null)
                ;;
            */apache*|*/httpd*)
                # Find and validate Apache config files
                while IFS= read -r -d '' config_file; do
                    local apache_issues=($(validate_apache_config "$config_file"))
                    all_issues+=("${apache_issues[@]}")
                    total_issues=$((total_issues + ${#apache_issues[@]}))
                done < <(find "$path" -name "*.conf" -type f -print0 2>/dev/null)
                ;;
        esac
    done
    
    # Create issues JSON array
    local issues_json="["
    for ((i=0; i<${#all_issues[@]}; i++)); do
        if [[ $i -gt 0 ]]; then
            issues_json+=","
        fi
        issues_json+="${all_issues[i]}"
    done
    issues_json+="]"
    
    # Report results
    if [[ $total_issues -gt 0 ]]; then
        log_error "Validation failed: $total_issues issues found"
        
        # Send webhook notification
        webhook_validation_failed "$issues_json" "$backup_blocked"
        
        echo "Pre-backup Validation Report"
        echo "============================"
        echo "Total issues: $total_issues"
        echo "Backup blocked: $backup_blocked"
        echo
        
        # Display issues
        echo "$issues_json" | jq -r '.[] | "- \(.file): \(.message)"' 2>/dev/null || {
            echo "Issues found in configuration files"
        }
        
        if [[ "$backup_blocked" == true ]]; then
            error_exit "Backup blocked due to critical validation failures"
        fi
        
        return 1  # Issues found
    else
        log_info "Pre-backup validation passed"
        echo "Pre-backup validation: PASSED"
        return 0  # No issues
    fi
}

# Detect services affected by configuration paths
detect_affected_services() {
    local changed_paths=("$@")
    local services=()
    
    for path in "${changed_paths[@]}"; do
        case "$(basename "$path")" in
            "mysql"|"mariadb")
                services+=("mysql" "mariadb")
                ;;
            "php"|"php-fpm"|"php.ini")
                services+=("php-fpm")
                ;;
            "lsws"|"httpd"|"apache2")
                services+=("lsws" "httpd" "apache2")
                ;;
            *)
                # Try to detect service by path
                if [[ "$path" =~ ^/etc/(php|mysql|mariadb|apache2|httpd|lsws)/ ]]; then
                    services+=("${BASH_REMATCH[1]}")
                fi
                ;;
        esac
    done
    
    # Remove duplicates and return unique services
    printf '%s\n' "${services[@]}" | sort -u
}

# Check service health
check_service_health() {
    local service_name="$1"
    local timeout="${2:-10}"
    
    # Check if service is active
    if ! systemctl is-active "$service_name" >/dev/null 2>&1; then
        return 1
    fi
    
    # Service-specific health checks
    case "$service_name" in
        mysql|mariadb)
            timeout "$timeout" mysqladmin ping &>/dev/null
            ;;
        apache2|httpd)
            timeout "$timeout" curl -s http://localhost/server-status &>/dev/null
            ;;
        php-fpm)
            timeout "$timeout" systemctl status php*-fpm | grep -q "active (running)"
            ;;
        lsws)
            timeout "$timeout" /usr/local/lsws/bin/lswsctrl status | grep -q "litespeed is running"
            ;;
        *)
            # Default to systemctl check
            timeout "$timeout" systemctl is-active "$service_name" &>/dev/null
            ;;
    esac
}

# Restart services with health checks
restart_services() {
    local services=("$@")
    local trigger="${RESTART_TRIGGER:-manual}"
    local services_json="["
    local all_successful=true
    local service_count=0
    
    if [[ ${#services[@]} -eq 0 ]]; then
        log_info "No services to restart"
        return 0
    fi
    
    log_info "Restarting ${#services[@]} services: ${services[*]}"
    
    for service in "${services[@]}"; do
        # Skip if service doesn't exist
        if ! systemctl list-unit-files | grep -q "^$service.service"; then
            log_warn "Service $service not found, skipping"
            continue
        fi
        
        local start_time=$(date +%s.%N)
        local action="restart"
        local status="failed"
        local health_check="failed"
        
        log_info "Restarting service: $service"
        
        # Determine restart method based on service
        case "$service" in
            apache2|httpd|nginx)
                # Try graceful reload first, then restart if needed
                if systemctl reload "$service" 2>/dev/null; then
                    action="reload"
                    status="success"
                else
                    systemctl restart "$service" 2>/dev/null && status="success"
                fi
                ;;
            *)
                # Standard restart
                systemctl restart "$service" 2>/dev/null && status="success"
                ;;
        esac
        
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "0")
        
        # Health check
        if [[ "$status" == "success" ]]; then
            sleep 2  # Give service time to start
            if check_service_health "$service" 10; then
                health_check="passed"
                log_info "Service $service restarted successfully"
            else
                health_check="failed"
                all_successful=false
                log_error "Service $service started but failed health check"
            fi
        else
            all_successful=false
            log_error "Failed to restart service: $service"
        fi
        
        # Add to services JSON
        if [[ $service_count -gt 0 ]]; then
            services_json+=","
        fi
        
        services_json+=$(cat << EOF
{
  "name": "$service",
  "action": "$action",
  "status": "$status",
  "duration": $duration,
  "health_check": "$health_check"
}
EOF
)
        service_count=$((service_count + 1))
    done
    
    services_json+="]"
    
    # Send webhook notification
    webhook_service_restart "$services_json" "$all_successful" "$trigger"
    
    # Report results
    if [[ "$all_successful" == true ]]; then
        success "All services restarted successfully"
        return 0
    else
        error_exit "Some services failed to restart properly"
    fi
}

# Auto-detect and restart affected services
restart_affected_services() {
    local changed_paths=("$@")
    
    if [[ ${#changed_paths[@]} -eq 0 ]]; then
        # If no specific paths provided, use all backup paths
        changed_paths=($BACKUP_PATHS)
    fi
    
    log_info "Detecting services affected by paths: ${changed_paths[*]}"
    
    local affected_services=($(detect_affected_services "${changed_paths[@]}"))
    
    if [[ ${#affected_services[@]} -eq 0 ]]; then
        log_info "No services detected for restart"
        return 0
    fi
    
    log_info "Detected affected services: ${affected_services[*]}"
    
    # Set restart trigger for webhook
    RESTART_TRIGGER="auto_detected"
    restart_services "${affected_services[@]}"
}

# Create default configuration files
create_default_configs() {
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$LOG_DIR"
    
    # Create system config if it doesn't exist
    if [[ ! -f "$SYSTEM_CONFIG" ]]; then
        create_system_binding "$(hostname)"
    fi
    
    # Create repository config
    if [[ ! -f "$REPOSITORY_CONFIG" ]]; then
        cat > "$REPOSITORY_CONFIG" << EOF
# Git repository configuration
GIT_REPO=""
GIT_BRANCH="main"
GIT_USER_NAME=""
GIT_USER_EMAIL=""
AUTO_COMMIT=true
EOF
        log_info "Created default repository configuration at $REPOSITORY_CONFIG"
    fi
    
    # Create backup config
    if [[ ! -f "$BACKUP_CONFIG" ]]; then
        cat > "$BACKUP_CONFIG" << EOF
# Backup behavior settings
BACKUP_PATHS="/etc/mysql /etc/mariadb /usr/local/lsws/conf /etc/php /etc/lsws"
COMPRESS_BACKUPS=false
EXCLUDE_PATTERNS=("*.log" "*.tmp" "*.cache" "*.pid" "*.sock" "*.lock")
ENABLE_MONITORING=false
MONITOR_INTERVAL=300
EOF
        log_info "Created default backup configuration at $BACKUP_CONFIG"
    fi
    
    # Create logging config
    if [[ ! -f "$LOGGING_CONFIG" ]]; then
        cat > "$LOGGING_CONFIG" << EOF
# Log management settings
LOG_DIR="$LOG_DIR"
LOG_FILE="backup.log"
LOG_MAX_SIZE="10M"
LOG_MAX_FILES=5
LOG_ROTATION_ENABLED=true
LOG_COMPRESSION=true
LOG_RETENTION_DAYS=30
LOG_LEVEL="INFO"
LOG_TIMESTAMP_FORMAT="%Y-%m-%d %H:%M:%S"

# Webhook settings
WEBHOOK_ENABLED=false
WEBHOOK_URL=""
WEBHOOK_EVENTS="backup_success,backup_failed,drift_detected,validation_failed,service_restart"
WEBHOOK_TIMEOUT=30
WEBHOOK_RETRY_COUNT=3
WEBHOOK_RETRY_DELAY=5
EOF
        log_info "Created default logging configuration at $LOGGING_CONFIG"
    fi
}

# Load all configuration files
load_all_configs() {
    # Load logging config first (affects logging behavior)
    if [[ -f "$LOGGING_CONFIG" ]]; then
        source "$LOGGING_CONFIG"
    fi
    
    # Load system config
    if [[ -f "$SYSTEM_CONFIG" ]]; then
        source "$SYSTEM_CONFIG"
    fi
    
    # Load repository config
    if [[ -f "$REPOSITORY_CONFIG" ]]; then
        source "$REPOSITORY_CONFIG"
    fi
    
    # Load backup config
    if [[ -f "$BACKUP_CONFIG" ]]; then
        source "$BACKUP_CONFIG"
    fi
}

# SECURITY: Validate configuration values
validate_config() {
    # Validate Git repository URL - ONLY SSH supported
    if [[ -n "$GIT_REPO" ]]; then
        if [[ ! "$GIT_REPO" =~ ^git@ ]]; then
            error_exit "Invalid GIT_REPO format in configuration. Only SSH URLs supported (git@...)"
        fi
        if [[ ! "$GIT_REPO" =~ ^git@[a-zA-Z0-9.-]+:[a-zA-Z0-9._/-]+\.git$ ]]; then
            error_exit "Invalid SSH Git URL format. Expected: git@hostname:username/repo.git"
        fi
    fi
    
    # Validate backup paths
    for path in $BACKUP_PATHS; do
        # Prevent path traversal
        if [[ "$path" =~ \.\. ]]; then
            error_exit "Path traversal detected in BACKUP_PATHS: $path"
        fi
        # Ensure absolute paths
        if [[ ! "$path" =~ ^/ ]]; then
            error_exit "Relative paths not allowed in BACKUP_PATHS: $path"
        fi
    done
    
    # Validate backup user
    if [[ -n "$BACKUP_USER" ]]; then
        if ! id "$BACKUP_USER" &>/dev/null; then
            error_exit "Backup user $BACKUP_USER does not exist"
        fi
    fi
    
    # Validate log settings
    if [[ -n "$LOG_MAX_SIZE" ]]; then
        if [[ ! "$LOG_MAX_SIZE" =~ ^[0-9]+[KMG]?B?$ ]]; then
            error_exit "Invalid LOG_MAX_SIZE format: $LOG_MAX_SIZE. Use format like 10M, 100K, 1G"
        fi
    fi
}

# Load configuration
load_config() {
    # Load environment settings first (affects emoji display)
    local env_file="$CONFIG_DIR/environment.conf"
    if [[ -f "$env_file" ]]; then
        source "$env_file"
    fi
    
    # Check if this is a legacy installation
    local legacy_config="${SCRIPT_DIR}/backup-config.conf"
    if [[ -f "$legacy_config" && ! -d "$CONFIG_DIR" ]]; then
        log_warn "Legacy configuration detected. Consider migrating to new format."
        log_warn "Run: server-backup migrate-config"
        
        # Load legacy config for now
        source "$legacy_config"
        validate_config
        return 0
    fi
    
    # Create default configs if they don't exist
    if [[ ! -d "$CONFIG_DIR" ]]; then
        log_info "No configuration found. Creating default configuration..."
        create_default_configs
    fi
    
    # Load all configuration files
    load_all_configs
    
    # Validate configuration
    validate_config
    
    # Set proper permissions on config files
    chmod 600 "$CONFIG_DIR"/*.conf 2>/dev/null || true
}

# Create default configuration
create_default_config() {
    cat > "$CONFIG_FILE" << EOF
# Git repository configuration
GIT_REPO="$DEFAULT_GIT_REPO"
GIT_BRANCH="$DEFAULT_GIT_BRANCH"
GIT_USER_NAME=""
GIT_USER_EMAIL=""

# Security: Backup user for Git operations (NOT root!)
BACKUP_USER="backup-service"

# Backup paths (space-separated)
BACKUP_PATHS="${DEFAULT_BACKUP_PATHS[*]}"

# Backup settings
AUTO_COMMIT=true
COMPRESS_BACKUPS=false
EXCLUDE_PATTERNS=("*.log" "*.tmp" "*.cache" "*.pid" "*.sock")

# Monitoring settings
ENABLE_MONITORING=false
MONITOR_INTERVAL=300  # seconds
EOF
    info "Default configuration created at $CONFIG_FILE"
    info "Please edit the configuration file and run the script again."
    exit 0
}

# Check dependencies
check_dependencies() {
    local deps=("git" "rsync")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        error_exit "Missing dependencies: ${missing_deps[*]}. Please install them first."
    fi
}

# Execute Git command as backup user
git_as_backup_user() {
    if [[ "$USER" == "$BACKUP_USER" ]]; then
        # Already running as backup user
        git "$@"
    else
        # Run as backup user
        sudo -u "$BACKUP_USER" git "$@"
    fi
}

# Initialize Git repository
init_git_repo() {
    if [[ -z "$GIT_REPO" ]]; then
        error_exit "GIT_REPO not configured. Please set it in $CONFIG_FILE"
    fi
    
    # Ensure backup directory exists and has proper ownership
    mkdir -p "$BACKUP_DIR"
    chown -R "$BACKUP_USER:$BACKUP_USER" "$BACKUP_DIR"
    
    cd "$BACKUP_DIR"
    
    if [[ ! -d ".git" ]]; then
        config_info "Initializing Git repository as $BACKUP_USER..."
        git_as_backup_user init
        git_as_backup_user remote add origin "$GIT_REPO"
        
        if [[ -n "$GIT_USER_NAME" ]]; then
            git_as_backup_user config user.name "$GIT_USER_NAME"
        fi
        
        if [[ -n "$GIT_USER_EMAIL" ]]; then
            git_as_backup_user config user.email "$GIT_USER_EMAIL"
        fi
        
        # Create hostname directory
        mkdir -p "$HOSTNAME"
        echo "# Server Configuration Backup for $HOSTNAME" > "$HOSTNAME/README.md"
        echo "Generated on $(date)" >> "$HOSTNAME/README.md"
        echo "Backup user: $BACKUP_USER (NOT root for security)" >> "$HOSTNAME/README.md"
        
        chown -R "$BACKUP_USER:$BACKUP_USER" "$HOSTNAME"
        
        git_as_backup_user add .
        git_as_backup_user commit -m "Initial commit for $HOSTNAME"
        git_as_backup_user branch -M "$GIT_BRANCH"
        git_as_backup_user push -u origin "$GIT_BRANCH"
    fi
# Backup function
perform_backup() {
    local validate_first="${1:-false}"
    local restart_services_after="${2:-false}"
    local start_time=$(date +%s.%N)
    local backup_timestamp=$(date '+%Y%m%d_%H%M%S')
    local changes_detected=false
    local files_backed_up=0
    local commit_hash=""
    
    # Pre-backup validation if requested
    if [[ "$validate_first" == true ]]; then
        log_info "Running pre-backup validation..."
        if ! validate_before_backup; then
            local duration=$(echo "$(date +%s.%N) - $start_time" | bc 2>/dev/null || echo "0")
            webhook_backup_failed "Pre-backup validation failed" "$duration"
            error_exit "Backup aborted due to validation failures"
        fi
    fi
    
    cd "$BACKUP_DIR"
    
    backup_info "Starting backup process..."
    
    # Create hostname-specific backup directory
    local host_backup_dir="$BACKUP_DIR/$HOSTNAME"
    mkdir -p "$host_backup_dir"
    
    # Process each backup path
    for path in $BACKUP_PATHS; do
        if [[ -d "$path" ]]; then
            local dest_name=$(basename "$path")
            local dest_path="$host_backup_dir/$dest_name"
            
            backup_info "Backing up $path to $dest_path"
            
            # SECURITY: Create exclude pattern file with secure permissions
            local exclude_file=$(mktemp)
            chmod 600 "$exclude_file"  # Secure permissions
            chown "$BACKUP_USER:$BACKUP_USER" "$exclude_file" 2>/dev/null || true
            
            for pattern in "${EXCLUDE_PATTERNS[@]}"; do
                # SECURITY: Sanitize exclude patterns to prevent injection
                local safe_pattern=$(echo "$pattern" | sed 's/[;&|`$()]//g')
                echo "$safe_pattern" >> "$exclude_file"
            done
            
            # SECURITY: Sync files with additional safety checks
            # Validate source and destination paths
            if [[ ! -d "$path" ]]; then
                warning "Source path does not exist: $path"
                rm -f "$exclude_file"
                continue
            fi
            
            # Ensure destination is within backup directory
            if [[ ! "$dest_path" =~ ^"$BACKUP_DIR" ]]; then
                local duration=$(echo "$(date +%s.%N) - $start_time" | bc 2>/dev/null || echo "0")
                webhook_backup_failed "Security violation: destination path outside backup directory" "$duration"
                error_exit "Destination path outside backup directory: $dest_path"
            fi
            
            # Use rsync with additional security options
            if rsync -av --delete --exclude-from="$exclude_file" --no-specials --no-devices --safe-links "$path/" "$dest_path/"; then
                # Count files backed up
                local file_count=$(find "$dest_path" -type f | wc -l)
                files_backed_up=$((files_backed_up + file_count))
                changes_detected=true
            else
                warning "Failed to backup $path"
                rm -f "$exclude_file"
                continue
            fi
            
            rm -f "$exclude_file"
        else
            warning "Path $path does not exist, skipping..."
        fi
    done
    
    # Check for changes and commit (as backup user)
    if [[ "$changes_detected" == true ]]; then
        # Ensure proper ownership before Git operations
        chown -R "$BACKUP_USER:$BACKUP_USER" "$BACKUP_DIR"
        
        git_as_backup_user add .
        
        if git_as_backup_user diff --staged --quiet; then
            info "No changes detected in configuration files"
            local duration=$(echo "$(date +%s.%N) - $start_time" | bc 2>/dev/null || echo "0")
            webhook_backup_success "$duration" "$files_backed_up" "no-changes"
        else
            local commit_msg="Config backup for $HOSTNAME - $(date '+%Y-%m-%d %H:%M:%S')"
            git_as_backup_user commit -m "$commit_msg"
            commit_hash=$(git_as_backup_user rev-parse HEAD)
            
            if [[ "$AUTO_COMMIT" == true ]]; then
                commit_hash=$(git_as_backup_user commit -m "Backup for $HOSTNAME on $(date '+%Y-%m-%d %H:%M:%S')")
                git_as_backup_user push origin "$GIT_BRANCH"
                webhook_backup_success "$duration" "$files_backed_up" "$commit_hash"
            else
                webhook_backup_success "$duration" "$files_backed_up" "no-commit"
            fi
            fi
        fi
        
        # Restart services if requested
        if [[ "$restart_services_after" == true ]]; then
            RESTART_TRIGGER="post_backup"
            restart_affected_services
        fi
    else
        local duration=$(echo "$(date +%s.%N) - $start_time" | bc 2>/dev/null || echo "0")
        webhook_backup_failed "No files found to backup" "$duration"
        error_exit "No files found to backup"
    fi
}

# List available backups
list_backups() {
    cd "$BACKUP_DIR"
    
    if [[ ! -d ".git" ]]; then
        error_exit "No Git repository found. Run backup first."
    fi
    
    info "Available backups for $HOSTNAME:"
    git_as_backup_user log --oneline --grep="$HOSTNAME" | head -20
}

# Show commit details
show_commit_info() {
    local commit_hash="$1"
    
    info "Commit Information:"
    echo "==================="
    git_as_backup_user show --stat "$commit_hash" | head -20
    echo
}

# List available paths in backup
list_backup_paths() {
    local temp_restore_dir="$1"
    local available_paths=()
    
    if [[ -d "$temp_restore_dir/$HOSTNAME" ]]; then
        for item in "$temp_restore_dir/$HOSTNAME"/*; do
            if [[ -d "$item" ]]; then
                available_paths+=($(basename "$item"))
            fi
        done
    fi
    
    echo "${available_paths[@]}"
}

# Restore function with enhanced selective capabilities
restore_backup() {
    local commit_hash="$1"
    local restore_path="$2"
    
    if [[ -z "$commit_hash" ]]; then
        error_exit "Commit hash required for restore"
    fi
    
    cd "$BACKUP_DIR"
    
    if [[ ! -d ".git" ]]; then
        error_exit "No Git repository found"
    fi
    
    # Validate commit exists
    if ! git_as_backup_user cat-file -e "$commit_hash" 2>/dev/null; then
        error_exit "Commit $commit_hash not found"
    fi
    
    show_commit_info "$commit_hash"
    
    # Create temporary restore directory
    local temp_restore_dir=$(mktemp -d)
    
    # Checkout specific commit to temp directory (as backup user)
    git_as_backup_user --work-tree="$temp_restore_dir" checkout "$commit_hash" -- "$HOSTNAME/" || {
        error_exit "Failed to checkout commit $commit_hash"
    }
    
    if [[ -n "$restore_path" ]]; then
        # Command-line specific path restore
        restore_specific_path "$temp_restore_dir" "$restore_path"
    else
        # Interactive restore menu
        interactive_restore_menu "$temp_restore_dir"
    fi
    
    # Cleanup
    rm -rf "$temp_restore_dir"
}

# Restore specific path (non-interactive)
restore_specific_path() {
    local temp_restore_dir="$1"
    local restore_path="$2"
    
    local source_path="$temp_restore_dir/$HOSTNAME/$(basename "$restore_path")"
    
    if [[ -d "$source_path" ]]; then
        warning "This will overwrite current configuration in $restore_path"
        read -p "Continue? (y/N): " confirm
        
        # SECURITY: Validate user input to prevent injection
        confirm=$(echo "$confirm" | tr -d '[:space:]' | head -c 1)
        
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            info "Creating backup of current configuration..."
            local backup_suffix=$(date '+%Y%m%d_%H%M%S')
            cp -r "$restore_path" "${restore_path}.backup_${backup_suffix}" 2>/dev/null || true
            
            info "Restoring $restore_path from backup..."
            rsync -av --delete "$source_path/" "$restore_path/"
            success "Restored $restore_path"
            info "Previous config backed up to: ${restore_path}.backup_${backup_suffix}"
        else
            info "Restore cancelled"
        fi
    else
        error_exit "Path not found in backup: $restore_path"
    fi
}

# Interactive restore menu
interactive_restore_menu() {
    local temp_restore_dir="$1"
    local available_paths=($(list_backup_paths "$temp_restore_dir"))
    
    if [[ ${#available_paths[@]} -eq 0 ]]; then
        error_exit "No backup paths found in commit"
    fi
    
    echo
    info "Available configurations to restore:"
    echo "===================================="
    
    # Show available paths with descriptions
    for i in "${!available_paths[@]}"; do
        local path_name="${available_paths[i]}"
        local full_path=""
        
        # Map backup directory to system path
        for sys_path in $BACKUP_PATHS; do
            if [[ "$(basename "$sys_path")" == "$path_name" ]]; then
                full_path="$sys_path"
                break
            fi
        done
        
        echo "$((i+1)). $path_name → $full_path"
    done
    
    echo "$((${#available_paths[@]}+1)). all → Restore all configurations"
    echo "$((${#available_paths[@]}+2)). quit → Cancel restore"
    echo
    
    while true; do
        read -p "Select option (1-$((${#available_paths[@]}+2))): " choice
        
        # SECURITY: Validate numeric input and prevent injection
        choice=$(echo "$choice" | tr -d '[:space:]' | sed 's/[^0-9]//g' | head -c 2)
        
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            if [[ "$choice" -ge 1 && "$choice" -le ${#available_paths[@]} ]]; then
                # Restore specific configuration
                local selected_path="${available_paths[$((choice-1))]}"
                restore_single_config "$temp_restore_dir" "$selected_path"
                break
            elif [[ "$choice" -eq $((${#available_paths[@]}+1)) ]]; then
                # Restore all
                restore_all_configs "$temp_restore_dir"
                break
            elif [[ "$choice" -eq $((${#available_paths[@]}+2)) ]]; then
                # Quit
                info "Restore cancelled"
                break
            fi
        fi
        
        warning "Invalid choice. Please select 1-$((${#available_paths[@]}+2))"
    done
}

# Restore single configuration
restore_single_config() {
    local temp_restore_dir="$1"
    local selected_path="$2"
    local source_path="$temp_restore_dir/$HOSTNAME/$selected_path"
    
    # Find corresponding system path
    local target_path=""
    for path in $BACKUP_PATHS; do
        if [[ "$(basename "$path")" == "$selected_path" ]]; then
            target_path="$path"
            break
        fi
    done
    
    if [[ -z "$target_path" ]]; then
        error_exit "Could not determine system path for $selected_path"
    fi
    
    warning "This will overwrite current configuration in $target_path"
    read -p "Continue? (y/N): " confirm
    
    # SECURITY: Validate user input to prevent injection
    confirm=$(echo "$confirm" | tr -d '[:space:]' | head -c 1)
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        info "Creating backup of current configuration..."
        local backup_suffix=$(date '+%Y%m%d_%H%M%S')
        cp -r "$target_path" "${target_path}.backup_${backup_suffix}" 2>/dev/null || true
        
        info "Restoring $target_path..."
        rsync -av --delete "$source_path/" "$target_path/"
        success "Restored $target_path"
        info "Previous config backed up to: ${target_path}.backup_${backup_suffix}"
        
        # Suggest service restart
        suggest_service_restart "$selected_path"
    else
        info "Restore cancelled"
    fi
}

# Restore all configurations
restore_all_configs() {
    local temp_restore_dir="$1"
    
    warning "This will overwrite ALL current configurations!"
    echo "The following will be restored:"
    
    for path in $BACKUP_PATHS; do
        local source_name=$(basename "$path")
        local source_path="$temp_restore_dir/$HOSTNAME/$source_name"
        if [[ -d "$source_path" ]]; then
            echo "  - $path"
        fi
    done
    
    echo
    read -p "Continue with full restore? (y/N): " confirm
    
    # SECURITY: Validate user input to prevent injection
    confirm=$(echo "$confirm" | tr -d '[:space:]' | head -c 1)
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local backup_suffix=$(date '+%Y%m%d_%H%M%S')
        
        for path in $BACKUP_PATHS; do
            local source_name=$(basename "$path")
            local source_path="$temp_restore_dir/$HOSTNAME/$source_name"
            
            if [[ -d "$source_path" ]]; then
                info "Backing up and restoring $path..."
                cp -r "$path" "${path}.backup_${backup_suffix}" 2>/dev/null || true
                rsync -av --delete "$source_path/" "$path/"
            fi
        done
        
        success "All configurations restored"
        info "Previous configs backed up with suffix: .backup_${backup_suffix}"
        
        echo
        warning "Consider restarting the following services:"
        echo "  - MySQL/MariaDB: sudo systemctl restart mysql"
        echo "  - OpenLiteSpeed: sudo systemctl restart lsws"
        echo "  - PHP-FPM: sudo systemctl restart php*-fpm"
    else
        info "Full restore cancelled"
    fi
}

# Suggest service restart based on restored configuration
suggest_service_restart() {
    local config_type="$1"
    
    echo
    info "Consider restarting related services:"
    
    case "$config_type" in
        "mysql"|"mariadb")
            echo "  sudo systemctl restart mysql"
            echo "  sudo systemctl restart mariadb"
            ;;
        "lsws"|"conf")
            echo "  sudo systemctl restart lsws"
            echo "  /usr/local/lsws/bin/lswsctrl restart"
            ;;
        "php")
            echo "  sudo systemctl restart php*-fpm"
            echo "  sudo systemctl reload php*-fpm"
            ;;
        *)
            echo "  Check which services use this configuration"
            ;;
    esac
}

# Monitor file changes
start_monitoring() {
    if ! command -v inotifywait &> /dev/null; then
        error_exit "inotifywait not found. Please install inotify-tools package."
    fi
    
    info "Starting file monitoring..."
    
    # Create monitoring paths string
    local monitor_paths=""
    for path in $BACKUP_PATHS; do
        if [[ -d "$path" ]]; then
            monitor_paths="$monitor_paths $path"
        fi
    done
    
    if [[ -z "$monitor_paths" ]]; then
        error_exit "No valid paths to monitor"
    fi
    
    # Monitor for changes
    while true; do
        inotifywait -r -e modify,create,delete,move $monitor_paths &> /dev/null
        info "Configuration change detected, performing backup..."
        perform_backup
        sleep "$MONITOR_INTERVAL"
    done
}

# Install systemd service for monitoring
install_service() {
    local service_file="/etc/systemd/system/config-backup.service"
    local timer_file="/etc/systemd/system/config-backup.timer"
    
    info "Installing systemd service..."
    
    # Create service file
    sudo tee "$service_file" > /dev/null << EOF
[Unit]
Description=Server Configuration Backup
After=network.target

[Service]
Type=oneshot
User=root
Group=root
ExecStart=$SCRIPT_DIR/server-config-backup.sh backup
WorkingDirectory=$SCRIPT_DIR
# Security: Script runs as root for file access, but Git operations use backup user
PrivateNetwork=false
ProtectSystem=strict
ReadWritePaths=$SCRIPT_DIR
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    # Create timer file for periodic backups
    sudo tee "$timer_file" > /dev/null << EOF
[Unit]
Description=Run config backup every hour
Requires=config-backup.service

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable config-backup.timer
    sudo systemctl start config-backup.timer
    
    success "Systemd service installed and started"
}

# Show usage
show_usage() {
    cat << EOF
Server Configuration Backup System

Usage: $0 [HOSTNAME_OPTIONS] [COMMAND] [OPTIONS]

Hostname Options:
    --rebind-hostname   Update hostname binding to current system
    --recovery-mode     Bypass hostname validation (disaster recovery)
    --force             Skip all hostname validation (dangerous)

Commands:
    init                Initialize backup system and Git repository
    backup [OPTIONS]    Perform backup of configuration files
    restore [COMMIT] [OPTIONS] Restore from backup (interactive or specific commit)
    list                List available backups
    monitor             Start file monitoring (foreground)
    drift-check [SINCE] Check for configuration drift
    validate [OPTIONS]  Validate configurations before backup
    restart-services [SERVICES] Restart affected services
    setup-webhook <URL> [EVENTS] Configure webhook notifications
    disable-webhook     Disable webhook notifications
    show-webhook        Show current webhook configuration
    show-config         Show all configuration files and values
    audit-permissions   Audit file and directory permissions
    fix-permissions     Fix common permission issues
    disable-emoji       Disable emoji display (for compatibility)
    enable-emoji        Enable emoji display
    test-webhook        Test webhook configuration
    install-service     Install systemd service for automatic backups
    status              Show backup status and configuration
    migrate-config      Migrate legacy configuration to new format
    rotate-logs         Force log rotation

Backup Options:
    --validate-first    Run validation before backup
    --restart-services  Restart affected services after backup

Restore Options:
    --restart-services  Restart affected services after restore

Validation Options:
    --fix-common-issues Attempt to fix common configuration issues

Drift Check Options:
    --continuous [INTERVAL] Start continuous drift monitoring

Options:
    -h, --help          Show this help message

Examples:
    $0 init                           # Initialize the backup system
    $0 backup --validate-first        # Backup with pre-validation
    $0 backup --restart-services      # Backup and restart services
    $0 restore abc1234 --restart-services # Restore and restart services
    $0 drift-check                    # Check drift since last backup
    $0 drift-check --continuous 300   # Monitor drift every 5 minutes
    $0 validate                       # Validate current configurations
    $0 restart-services               # Auto-detect and restart services
    $0 restart-services mysql apache2 # Restart specific services
    $0 setup-webhook https://hooks.n8n.io/webhook/abc123
    $0 disable-webhook                # Disable webhook notifications
    $0 show-webhook                   # Show webhook configuration
    $0 audit-permissions              # Check all permissions
    $0 fix-permissions                # Fix permission issues
    $0 test-webhook                   # Test webhook configuration

Hostname Examples:
    $0 --rebind-hostname backup      # Update hostname binding and backup
    $0 --recovery-mode restore abc123 # Restore in recovery mode
    $0 --force backup                 # Force backup ignoring hostname

Webhook Events:
    backup_success, backup_failed, drift_detected, validation_failed, service_restart

Configuration files: $CONFIG_DIR/
    system.conf         # System identification and hostname binding
    repository.conf     # Git repository settings
    backup.conf         # Backup paths and behavior
    logging.conf        # Log management settings
EOF
}

# Show status
show_status() {
    info "Backup System Status"
    echo "===================="
    echo "Current Hostname: $HOSTNAME"
    echo "Bound Hostname: ${BOUND_HOSTNAME:-'Not bound'}"
    echo "System ID: ${SYSTEM_ID:-'Not set'}"
    echo "Backup Directory: $BACKUP_DIR"
    echo "Configuration Directory: $CONFIG_DIR"
    echo "Log Directory: $LOG_DIR"
    echo
    
    # System Configuration
    echo "System Configuration:"
    if [[ -f "$SYSTEM_CONFIG" ]]; then
        echo "  ✓ System config: $SYSTEM_CONFIG"
        echo "    Bound to: ${BOUND_HOSTNAME:-'Unknown'}"
        echo "    Bound on: ${BOUND_TIMESTAMP:-'Unknown'}"
        echo "    Backup user: ${BACKUP_USER:-'Unknown'}"
    else
        echo "  ✗ System config: Missing"
    fi
    
    # Repository Configuration
    echo
    echo "Repository Configuration:"
    if [[ -f "$REPOSITORY_CONFIG" ]]; then
        echo "  ✓ Repository config: $REPOSITORY_CONFIG"
        echo "    Git Repository: ${GIT_REPO:-'Not configured'}"
        echo "    Git Branch: ${GIT_BRANCH:-'main'}"
        echo "    Auto Commit: ${AUTO_COMMIT:-'true'}"
    else
        echo "  ✗ Repository config: Missing"
    fi
    
    # Backup Configuration
    echo
    echo "Backup Configuration:"
    if [[ -f "$BACKUP_CONFIG" ]]; then
        echo "  ✓ Backup config: $BACKUP_CONFIG"
        echo "    Monitoring: ${ENABLE_MONITORING:-'false'}"
        echo "    Monitor Interval: ${MONITOR_INTERVAL:-'300'}s"
        echo
        echo "  Backup Paths:"
        for path in $BACKUP_PATHS; do
            if [[ -d "$path" ]]; then
                echo "    ✓ $path"
            else
                echo "    ✗ $path (not found)"
            fi
        done
    else
        echo "  ✗ Backup config: Missing"
    fi
    
    # Logging Configuration
    echo
    echo "Logging Configuration:"
    if [[ -f "$LOGGING_CONFIG" ]]; then
        echo "  ✓ Logging config: $LOGGING_CONFIG"
        echo "    Log file: $LOG_DIR/$LOG_FILE"
        echo "    Max size: ${LOG_MAX_SIZE:-'10M'}"
        echo "    Max files: ${LOG_MAX_FILES:-'5'}"
        echo "    Rotation: ${LOG_ROTATION_ENABLED:-'true'}"
        echo "    Compression: ${LOG_COMPRESSION:-'true'}"
        echo "    Retention: ${LOG_RETENTION_DAYS:-'30'} days"
        
        # Show current log file size
        if [[ -f "$LOG_DIR/$LOG_FILE" ]]; then
            local log_size=$(stat -f%z "$LOG_DIR/$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_DIR/$LOG_FILE" 2>/dev/null || echo 0)
            local log_size_mb=$((log_size / 1024 / 1024))
            echo "    Current size: ${log_size_mb}MB"
        fi
        
        # Show webhook configuration
        echo
        echo "  Webhook Configuration:"
        echo "    Enabled: ${WEBHOOK_ENABLED:-false}"
        if [[ "$WEBHOOK_ENABLED" == true ]]; then
            echo "    URL: ${WEBHOOK_URL:-'Not set'}"
            echo "    Events: ${WEBHOOK_EVENTS:-'Not set'}"
        else
            echo "    Status: Disabled"
        fi
    else
        echo "  ✗ Logging config: Missing"
    fi
    
    # Git Repository Status
    echo
    if [[ -d "$BACKUP_DIR/.git" ]]; then
        cd "$BACKUP_DIR"
        echo "Git Repository Status:"
        git_as_backup_user status --porcelain | head -10
        echo
        echo "Recent Commits:"
        git_as_backup_user log --oneline -5
        echo
        echo "Security Info:"
        echo "  Git operations run as: $BACKUP_USER"
        echo "  Root access: File reading only"
        echo "  Hostname binding: ${BOUND_HOSTNAME:-'Not bound'}"
    else
        warning "Git repository not initialized"
    fi
}

# Migrate legacy configuration
migrate_config() {
    local legacy_config="${SCRIPT_DIR}/backup-config.conf"
    
    if [[ ! -f "$legacy_config" ]]; then
        error_exit "No legacy configuration found to migrate"
    fi
    
    log_info "Migrating legacy configuration to new format..."
    
    # Load legacy config
    source "$legacy_config"
    
    # Create new config directory
    mkdir -p "$CONFIG_DIR"
    
    # Create system config
    create_system_binding "$(hostname)"
    
    # Create repository config
    cat > "$REPOSITORY_CONFIG" << EOF
# Git repository configuration (migrated from legacy)
GIT_REPO="${GIT_REPO:-}"
GIT_BRANCH="${GIT_BRANCH:-main}"
GIT_USER_NAME="${GIT_USER_NAME:-}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-}"
AUTO_COMMIT=${AUTO_COMMIT:-true}
EOF
    
    # Create backup config
    cat > "$BACKUP_CONFIG" << EOF
# Backup behavior settings (migrated from legacy)
BACKUP_PATHS="${BACKUP_PATHS:-/etc/mysql /etc/mariadb /usr/local/lsws/conf /etc/php /etc/lsws}"
COMPRESS_BACKUPS=${COMPRESS_BACKUPS:-false}
EXCLUDE_PATTERNS=(${EXCLUDE_PATTERNS[@]:-"*.log" "*.tmp" "*.cache" "*.pid" "*.sock" "*.lock"})
ENABLE_MONITORING=${ENABLE_MONITORING:-false}
MONITOR_INTERVAL=${MONITOR_INTERVAL:-300}
EOF
    
    # Create logging config
    cat > "$LOGGING_CONFIG" << EOF
# Log management settings (new)
LOG_DIR="$LOG_DIR"
LOG_FILE="backup.log"
LOG_MAX_SIZE="10M"
LOG_MAX_FILES=5
LOG_ROTATION_ENABLED=true
LOG_COMPRESSION=true
LOG_RETENTION_DAYS=30
LOG_LEVEL="INFO"
LOG_TIMESTAMP_FORMAT="%Y-%m-%d %H:%M:%S"
EOF
    
    # Backup legacy config
    mv "$legacy_config" "${legacy_config}.backup"
    
    success "Configuration migrated successfully!"
    log_info "Legacy config backed up to: ${legacy_config}.backup"
    log_info "New configuration files created in: $CONFIG_DIR"
}

# Force log rotation
rotate_logs_now() {
    load_config
    log_info "Manual log rotation requested"
    
    # Temporarily disable size check for manual rotation
    local original_enabled="$LOG_ROTATION_ENABLED"
    LOG_ROTATION_ENABLED=true
    
    # Force rotation by setting max size to 0
    local original_max_size="$LOG_MAX_SIZE"
    LOG_MAX_SIZE="0"
    
    rotate_logs
    
    # Restore original settings
    LOG_ROTATION_ENABLED="$original_enabled"
    LOG_MAX_SIZE="$original_max_size"
    
    success "Log rotation completed"
}

# Main function
main() {
    # Handle hostname-related options first
    local hostname_option=""
    case "${1:-}" in
        --rebind-hostname|--recovery-mode|--force)
            hostname_option="$1"
            shift
            ;;
    esac
    
    # Parse command line arguments
    case "${1:-}" in
        init)
            load_config
            initialize_system_binding "$hostname_option"
            check_dependencies
            init_git_repo
            ;;
        backup)
            load_config
            initialize_system_binding "$hostname_option"
            check_dependencies
            
            # Parse backup options
            local validate_first=false
            local restart_services=false
            shift  # Remove 'backup' command
            
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --validate-first)
                        validate_first=true
                        shift
                        ;;
                    --restart-services)
                        restart_services=true
                        shift
                        ;;
                    *)
                        error_exit "Unknown backup option: $1"
                        ;;
                esac
                shift
            done
            
            perform_backup "$validate_first" "$restart_services"
            ;;
        restore)
            load_config
            initialize_system_binding "$hostname_option"
            
            # Parse restore options
            local commit_hash="${2:-}"
            local restore_path="${3:-}"
            local restart_services=false
            shift 2 2>/dev/null || shift $# 2>/dev/null  # Remove 'restore' and commit hash
            
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --restart-services)
                        restart_services=true
                        shift
                        ;;
                    *)
                        if [[ -z "$restore_path" ]]; then
                            restore_path="$1"
                        else
                            error_exit "Unknown restore option: $1"
                        fi
                        shift
                        ;;
                esac
            done
            
            restore_backup "$commit_hash" "$restore_path"
            
            if [[ "$restart_services" == true ]]; then
                RESTART_TRIGGER="post_restore"
                restart_affected_services
            fi
            ;;
        list)
            load_config
            initialize_system_binding "$hostname_option"
            list_backups
            ;;
        monitor)
            load_config
            initialize_system_binding "$hostname_option"
            check_dependencies
            start_monitoring
            ;;
        drift-check)
            load_config
            initialize_system_binding "$hostname_option"
            
            local since_option="${2:-last-backup}"
            local continuous="${3:-false}"
            
            if [[ "$since_option" == "--continuous" ]]; then
                start_drift_monitoring "${3:-300}"
            else
                detect_config_drift "$since_option" "$continuous"
            fi
            ;;
        validate)
            load_config
            initialize_system_binding "$hostname_option"
            
            local fix_issues=false
            if [[ "${2:-}" == "--fix-common-issues" ]]; then
                fix_issues=true
            fi
            
            validate_before_backup "$fix_issues"
            ;;
        restart-services)
            load_config
            initialize_system_binding "$hostname_option"
            
            shift  # Remove command
            if [[ $# -eq 0 ]]; then
                # Auto-detect services
                RESTART_TRIGGER="manual"
                restart_affected_services
            else
                # Restart specific services
                RESTART_TRIGGER="manual"
                restart_services "$@"
            fi
            ;;
        setup-webhook)
            load_config
            
            local webhook_url="${2:-}"
            local events="${3:-}"
            
            if [[ -z "$webhook_url" ]]; then
                error_exit "Webhook URL required. Usage: setup-webhook <url> [events]"
            fi
            
            # Update logging config
            sed -i "s|^WEBHOOK_URL=.*|WEBHOOK_URL=\"$webhook_url\"|" "$LOGGING_CONFIG"
            sed -i "s|^WEBHOOK_ENABLED=.*|WEBHOOK_ENABLED=true|" "$LOGGING_CONFIG"
            
            if [[ -n "$events" ]]; then
                sed -i "s|^WEBHOOK_EVENTS=.*|WEBHOOK_EVENTS=\"$events\"|" "$LOGGING_CONFIG"
            fi
            
            success "Webhook configured: $webhook_url"
            ;;
        disable-webhook)
            load_config
            
            # Update logging config to disable webhook
            sed -i "s|^WEBHOOK_ENABLED=.*|WEBHOOK_ENABLED=false|" "$LOGGING_CONFIG"
            
            success "Webhook disabled"
            ;;
        test-webhook)
            load_config
            
            if [[ "$WEBHOOK_ENABLED" != true ]] || [[ -z "$WEBHOOK_URL" ]]; then
                error_exit "Webhook not configured. Use: server-backup setup-webhook <url>"
            fi
            
            local test_data='{"test": true, "message": "Webhook test from server backup system"}'
            send_webhook "test" "info" "Webhook test message" "$test_data"
            
            if [[ $? -eq 0 ]]; then
                success "Webhook test successful"
            else
                error_exit "Webhook test failed"
            fi
            ;;
        show-webhook)
            load_config
            
            echo -e "${CYAN}${EMOJI_WEBHOOK} Webhook Configuration${NC}"
            echo "========================"
            echo "Enabled: ${WEBHOOK_ENABLED:-false}"
            echo "URL: ${WEBHOOK_URL:-'Not configured'}"
            echo "Events: ${WEBHOOK_EVENTS:-'Not configured'}"
            echo "Timeout: ${WEBHOOK_TIMEOUT:-30}s"
            echo "Retry Count: ${WEBHOOK_RETRY_COUNT:-3}"
            echo "Retry Delay: ${WEBHOOK_RETRY_DELAY:-5}s"
            echo
            echo "Configuration file: $LOGGING_CONFIG"
            ;;
        show-config)
            load_config
            
            echo -e "${BLUE}${EMOJI_CONFIG} All Configuration Files${NC}"
            echo "=========================="
            echo
            
            echo -e "${CYAN}${EMOJI_FILE} System Configuration ($SYSTEM_CONFIG):${NC}"
            if [[ -f "$SYSTEM_CONFIG" ]]; then
                echo -e "  ${EMOJI_SUCCESS} Exists"
                echo "  Bound Hostname: ${BOUND_HOSTNAME:-'Not set'}"
                echo "  System ID: ${SYSTEM_ID:-'Not set'}"
                echo "  Backup User: ${BACKUP_USER:-'Not set'}"
            else
                echo -e "  ${EMOJI_ERROR} Missing"
            fi
            echo
            
            echo -e "${CYAN}${EMOJI_GIT} Repository Configuration ($REPOSITORY_CONFIG):${NC}"
            if [[ -f "$REPOSITORY_CONFIG" ]]; then
                echo -e "  ${EMOJI_SUCCESS} Exists"
                echo "  Git Repo: ${GIT_REPO:-'Not set'}"
                echo "  Git Branch: ${GIT_BRANCH:-'Not set'}"
                echo "  Auto Commit: ${AUTO_COMMIT:-'Not set'}"
            else
                echo -e "  ${EMOJI_ERROR} Missing"
            fi
            echo
            
            echo -e "${CYAN}${EMOJI_BACKUP} Backup Configuration ($BACKUP_CONFIG):${NC}"
            if [[ -f "$BACKUP_CONFIG" ]]; then
                echo -e "  ${EMOJI_SUCCESS} Exists"
                echo "  Backup Paths: ${BACKUP_PATHS:-'Not set'}"
                echo "  Monitoring: ${ENABLE_MONITORING:-'Not set'}"
            else
                echo -e "  ${EMOJI_ERROR} Missing"
            fi
            echo
            
            echo -e "${CYAN}${EMOJI_LOG} Logging Configuration ($LOGGING_CONFIG):${NC}"
            if [[ -f "$LOGGING_CONFIG" ]]; then
                echo -e "  ${EMOJI_SUCCESS} Exists"
                echo "  Log Level: ${LOG_LEVEL:-'Not set'}"
                echo "  Log Rotation: ${LOG_ROTATION_ENABLED:-'Not set'}"
                echo "  Webhook Enabled: ${WEBHOOK_ENABLED:-'Not set'}"
                echo "  Webhook URL: ${WEBHOOK_URL:-'Not set'}"
            else
                echo -e "  ${EMOJI_ERROR} Missing"
            fi
            ;;
        audit-permissions)
            load_config
            audit_permissions
            ;;
        fix-permissions)
            load_config
            fix_permissions
            ;;
        disable-emoji)
            # Create or update environment setting
            local env_file="$CONFIG_DIR/environment.conf"
            mkdir -p "$CONFIG_DIR"
            echo "DISABLE_EMOJI=true" > "$env_file"
            success "Emojis disabled. Restart script to take effect."
            ;;
        enable-emoji)
            # Create or update environment setting
            local env_file="$CONFIG_DIR/environment.conf"
            mkdir -p "$CONFIG_DIR"
            echo "DISABLE_EMOJI=false" > "$env_file"
            success "Emojis enabled. Restart script to take effect."
            ;;
        install-service)
            install_service
            ;;
        status)
            load_config
            initialize_system_binding "$hostname_option"
            show_status
            ;;
        migrate-config)
            migrate_config
            ;;
        rotate-logs)
            rotate_logs_now
            ;;
        -h|--help|help)
            show_usage
            ;;
        *)
            if [[ -z "${1:-}" ]]; then
                show_usage
            else
                error_exit "Unknown command: $1"
            fi
            ;;
    esac
}

# Run main function
main "$@"
