#!/bin/bash

# Installation script for Server Configuration Backup System
# Compatible with Ubuntu 22.x and Debian 12.x

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Emoji support for installer
if [[ "${DISABLE_EMOJI:-false}" != true ]]; then
    EMOJI_SUCCESS="✅"
    EMOJI_ERROR="❌"
    EMOJI_WARNING="⚠️"
    EMOJI_INFO="ℹ️"
    EMOJI_ROCKET="🚀"
    EMOJI_GEAR="⚙️"
    EMOJI_LOCK="🔒"
else
    EMOJI_SUCCESS="[OK]"
    EMOJI_ERROR="[ERR]"
    EMOJI_WARNING="[WARN]"
    EMOJI_INFO="[INFO]"
    EMOJI_ROCKET="[START]"
    EMOJI_GEAR="[SETUP]"
    EMOJI_LOCK="[SEC]"
fi

info() {
    echo -e "${BLUE}${EMOJI_INFO} $1${NC}"
}

success() {
    echo -e "${GREEN}${EMOJI_SUCCESS} $1${NC}"
}

warning() {
    echo -e "${YELLOW}${EMOJI_WARNING} $1${NC}"
}

error() {
    echo -e "${RED}${EMOJI_ERROR} $1${NC}" >&2
}

security_info() {
    echo -e "${RED}${EMOJI_LOCK} $1${NC}"
}

# Check installation mode and handle user creation
check_installation_mode() {
    if [[ $EUID -eq 0 ]]; then
        # Root installation - full system setup
        INSTALL_MODE="system"
        warning "Running as root - System-wide installation mode"
        warning "SECURITY: Root should NOT have SSH keys in Git providers!"
        echo
        info "Creating dedicated backup user for Git operations..."
        create_backup_user
    else
        # Non-root installation - user mode
        INSTALL_MODE="user"
        info "Running as regular user - User installation mode"
        
        # Check if we can use sudo for some operations
        if sudo -n true 2>/dev/null; then
            INSTALL_MODE="user-sudo"
            info "Sudo access detected - Enhanced user installation"
            
            # Ask if user wants to create system backup user
            echo
            read -p "Create system backup user for better security? (Y/n): " create_user
            if [[ "${create_user:-y}" =~ ^[Yy]$ ]]; then
                info "Creating dedicated backup user for Git operations..."
                create_backup_user
            else
                BACKUP_USER="$USER"
                warning "Using current user ($USER) for backup operations"
                warning "This is less secure than using a dedicated backup user"
            fi
        else
            BACKUP_USER="$USER"
            warning "No sudo access - Using current user ($USER) for backup operations"
            warning "Some features may be limited without root privileges"
        fi
    fi
    
    info "Installation mode: $INSTALL_MODE"
    info "Backup user: $BACKUP_USER"
}

# Create dedicated backup user
create_backup_user() {
    local backup_user="backup-service"
    
    # Check if user already exists
    if id "$backup_user" &>/dev/null; then
        info "Backup user '$backup_user' already exists"
    else
        info "Creating backup user '$backup_user'..."
        if [[ $EUID -eq 0 ]]; then
            useradd -r -s /bin/bash -d /home/$backup_user -m "$backup_user"
        else
            sudo useradd -r -s /bin/bash -d /home/$backup_user -m "$backup_user"
        fi
        success "Created backup user '$backup_user'"
    fi
    
    # Set global variable for later use
    BACKUP_USER="$backup_user"
    BACKUP_USER_HOME="/home/$backup_user"
    
    # Configure backup user permissions (only if we have the necessary privileges)
    if [[ $EUID -eq 0 ]] || sudo -n true 2>/dev/null; then
        info "Configuring backup user permissions..."
        
        # Add backup user to necessary groups for reading config files
        if [[ $EUID -eq 0 ]]; then
            usermod -a -G adm "$backup_user" 2>/dev/null || true
        else
            sudo usermod -a -G adm "$backup_user" 2>/dev/null || true
        fi
        
        # Create sudoers rule for specific backup operations
        local sudoers_content="# Allow backup-service user to read system configuration files
# SECURITY: Specific paths only, no wildcards that could allow privilege escalation
$backup_user ALL=(root) NOPASSWD: /bin/cat /etc/mysql/*, /bin/cat /etc/mariadb/*, /bin/cat /usr/local/lsws/conf/*, /bin/cat /etc/php/*, /bin/cat /etc/lsws/*
$backup_user ALL=(root) NOPASSWD: /usr/bin/rsync --dry-run --exclude=\"*.log\" --exclude=\"*.tmp\" --exclude=\"*.cache\" --exclude=\"*.pid\" --exclude=\"*.sock\" /etc/mysql/ /*, /usr/bin/rsync --dry-run --exclude=\"*.log\" --exclude=\"*.tmp\" --exclude=\"*.cache\" --exclude=\"*.pid\" --exclude=\"*.sock\" /etc/mariadb/ /*, /usr/bin/rsync --dry-run --exclude=\"*.log\" --exclude=\"*.tmp\" --exclude=\"*.cache\" --exclude=\"*.pid\" --exclude=\"*.sock\" /usr/local/lsws/conf/ /*, /usr/bin/rsync --dry-run --exclude=\"*.log\" --exclude=\"*.tmp\" --exclude=\"*.cache\" --exclude=\"*.pid\" --exclude=\"*.sock\" /etc/php/ /*, /usr/bin/rsync --dry-run --exclude=\"*.log\" --exclude=\"*.tmp\" --exclude=\"*.cache\" --exclude=\"*.pid\" --exclude=\"*.sock\" /etc/lsws/ /*
$backup_user ALL=(root) NOPASSWD: /usr/bin/rsync -av --exclude=\"*.log\" --exclude=\"*.tmp\" --exclude=\"*.cache\" --exclude=\"*.pid\" --exclude=\"*.sock\" /etc/mysql/ /*, /usr/bin/rsync -av --exclude=\"*.log\" --exclude=\"*.tmp\" --exclude=\"*.cache\" --exclude=\"*.pid\" --exclude=\"*.sock\" /etc/mariadb/ /*, /usr/bin/rsync -av --exclude=\"*.log\" --exclude=\"*.tmp\" --exclude=\"*.cache\" --exclude=\"*.pid\" --exclude=\"*.sock\" /usr/local/lsws/conf/ /*, /usr/bin/rsync -av --exclude=\"*.log\" --exclude=\"*.tmp\" --exclude=\"*.cache\" --exclude=\"*.pid\" --exclude=\"*.sock\" /etc/php/ /*, /usr/bin/rsync -av --exclude=\"*.log\" --exclude=\"*.tmp\" --exclude=\"*.cache\" --exclude=\"*.pid\" --exclude=\"*.sock\" /etc/lsws/ /*
$backup_user ALL=(root) NOPASSWD: /usr/bin/find /etc/mysql -type f -name \"*.cnf\" -o -name \"*.conf\", /usr/bin/find /etc/mariadb -type f -name \"*.cnf\" -o -name \"*.conf\", /usr/bin/find /usr/local/lsws/conf -type f -name \"*.conf\" -o -name \"*.xml\", /usr/bin/find /etc/php -type f -name \"*.ini\" -o -name \"*.conf\", /usr/bin/find /etc/lsws -type f -name \"*.conf\" -o -name \"*.xml\""
        
        if [[ $EUID -eq 0 ]]; then
            echo "$sudoers_content" > /etc/sudoers.d/backup-service
            chmod 440 /etc/sudoers.d/backup-service
        else
            echo "$sudoers_content" | sudo tee /etc/sudoers.d/backup-service > /dev/null
            sudo chmod 440 /etc/sudoers.d/backup-service
        fi
        
        success "Configured backup user permissions"
    else
        warning "Cannot configure sudoers without root/sudo access"
        warning "Backup user will have limited permissions"
    fi
}

# Detect OS
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
        info "Detected OS: $OS $VER"
        
        case $ID in
            ubuntu)
                if [[ ! "$VER" =~ ^22\. ]]; then
                    warning "This script is optimized for Ubuntu 22.x, but will attempt to continue"
                fi
                ;;
            debian)
                if [[ ! "$VER" =~ ^12\. ]]; then
                    warning "This script is optimized for Debian 12.x, but will attempt to continue"
                fi
                ;;
            *)
                warning "Unsupported OS detected. Proceeding anyway..."
                ;;
        esac
    else
        error "Cannot detect OS version"
        exit 1
    fi
}

# Install dependencies
install_dependencies() {
    info "Installing required dependencies..."
    
    local packages=(
        "git"
        "rsync"
        "inotify-tools"
        "curl"
        "wget"
    )
    
    # Check if we can install packages
    if [[ $EUID -eq 0 ]]; then
        # Root installation
        apt-get update
        for package in "${packages[@]}"; do
            if ! dpkg -l | grep -q "^ii  $package "; then
                info "Installing $package..."
                apt-get install -y "$package"
            else
                info "$package is already installed"
            fi
        done
    elif sudo -n true 2>/dev/null; then
        # User with sudo
        sudo apt-get update
        for package in "${packages[@]}"; do
            if ! dpkg -l | grep -q "^ii  $package "; then
                info "Installing $package..."
                sudo apt-get install -y "$package"
            else
                info "$package is already installed"
            fi
        done
    else
        # User without sudo - check if packages exist
        warning "Cannot install packages without root/sudo access"
        local missing_packages=()
        
        for package in "${packages[@]}"; do
            if ! command -v "$package" &>/dev/null; then
                missing_packages+=("$package")
            else
                info "$package is available"
            fi
        done
        
        if [[ ${#missing_packages[@]} -gt 0 ]]; then
            error "Missing required packages: ${missing_packages[*]}"
            echo
            echo "Please install them manually:"
            echo "  sudo apt-get install ${missing_packages[*]}"
            echo
            read -p "Continue anyway? (y/N): " continue_anyway
            if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
    fi
    
    success "Dependencies check completed"
}

# Setup backup directory
setup_directories() {
    local install_dir="${1:-/opt/server-backup}"
    
    info "Setting up directories in $install_dir..."
    
    mkdir -p "$install_dir"
    cp server-config-backup.sh "$install_dir/"
    chmod +x "$install_dir/server-config-backup.sh"
    
    # Set proper ownership for backup user
    if [[ -n "${BACKUP_USER:-}" ]]; then
        chown -R "$BACKUP_USER:$BACKUP_USER" "$install_dir"
        info "Set ownership of $install_dir to $BACKUP_USER"
    fi
    
    # Create symlink for easy access
    if [[ ! -f /usr/local/bin/server-backup ]]; then
        ln -s "$install_dir/server-config-backup.sh" /usr/local/bin/server-backup
        success "Created symlink: /usr/local/bin/server-backup"
    fi
    
    success "Setup completed in $install_dir"
}

# Configure Git (interactive)
configure_git() {
    echo
    info "Git Configuration Setup"
    echo "======================="
    
    echo "Supported Git providers:"
    echo "1. GitHub (github.com)"
    echo "2. GitLab (gitlab.com)"
    echo "3. Gitea/Self-hosted"
    echo
    
    echo "SSH Repository URL examples (ONLY SSH supported):"
    echo "  GitHub:   git@github.com:username/server-configs.git"
    echo "  GitLab:   git@gitlab.com:username/server-configs.git"
    echo "  Gitea:    git@git.yourdomain.com:username/server-configs.git"
    echo
    warning "HTTPS URLs are NOT supported due to authentication complexity"
    warning "SSH is required for reliable server automation"
    echo
    
    read -p "Enter your Git repository URL: " git_repo
    
    # SECURITY: Validate and sanitize Git repository URL
    # Remove any potential path traversal attempts
    git_repo=$(echo "$git_repo" | sed 's/\.\.//g' | sed 's/[;&|`$()]//g')
    
    # ONLY SSH URLs are supported
    if [[ ! "$git_repo" =~ ^git@ ]]; then
        error "Only SSH Git URLs are supported. Must start with 'git@'"
        error "Example: git@github.com:username/repo.git"
        exit 1
    fi
    
    # Validate SSH URL format
    if [[ ! "$git_repo" =~ ^git@[a-zA-Z0-9.-]+:[a-zA-Z0-9._/-]+\.git$ ]]; then
        error "Invalid SSH Git URL format."
        error "Expected format: git@hostname:username/repo.git"
        error "Your input: $git_repo"
        exit 1
    fi
    
    read -p "Enter your Git username: " git_user
    read -p "Enter your Git email: " git_email
    read -p "Enter Git branch name [main]: " git_branch
    git_branch=${git_branch:-main}
    
    # SECURITY: Sanitize user inputs
    git_user=$(echo "$git_user" | sed 's/[;&|`$()]//g' | head -c 50)
    git_email=$(echo "$git_email" | sed 's/[;&|`$()]//g' | head -c 100)
    git_branch=$(echo "$git_branch" | sed 's/[;&|`$()]//g' | head -c 50)
    
    # Validate email format
    if [[ ! "$git_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        error "Invalid email format"
        exit 1
    fi
    
    # Detect Git provider
    local provider="Unknown"
    if [[ "$git_repo" =~ github\.com ]]; then
        provider="GitHub"
    elif [[ "$git_repo" =~ gitlab\.com ]]; then
        provider="GitLab"
    else
        provider="Self-hosted"
    fi
    
    echo
    info "Detected Git provider: $provider"
    
    # Test Git connectivity
    info "Testing Git connectivity..."
    if git ls-remote "$git_repo" &>/dev/null; then
        success "Git repository is accessible"
    else
        warning "Cannot access Git repository."
        echo
        echo "SSH Authentication troubleshooting:"
        case $provider in
            "GitHub")
                echo "  - Add your SSH key to GitHub Settings → SSH and GPG keys"
                echo "  - Test SSH: ssh -T git@github.com"
                ;;
            "GitLab")
                echo "  - Add your SSH key to GitLab User Settings → SSH Keys"
                echo "  - Test SSH: ssh -T git@gitlab.com"
                ;;
            *)
                echo "  - Add your SSH key to your Git provider's SSH key settings"
                echo "  - Test SSH connection to your Git server"
                ;;
        esac
        echo
        read -p "Continue anyway? (y/N): " continue_anyway
        if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
            error "Setup cancelled. Please fix Git connectivity and try again."
            exit 1
        fi
    fi
    
    echo
    echo "Git configuration:"
    echo "  Provider: $provider"
    echo "  Repository: $git_repo"
    echo "  Username: $git_user"
    echo "  Email: $git_email"
    echo "  Branch: $git_branch"
}

# Create initial configuration
create_config() {
    local install_dir="${1:-/opt/server-backup}"
    local config_dir="$install_dir/config"
    local log_dir="$install_dir/logs"
    
    info "Creating configuration files..."
    
    # Create directories
    mkdir -p "$config_dir"
    mkdir -p "$log_dir"
    
    # Create system configuration
    local system_config="$config_dir/system.conf"
    local timestamp=$(date -Iseconds)
    local system_id="$(hostname)-$(date +%s)"
    
    tee "$system_config" > /dev/null << EOF
# System identification and binding
# Generated on: $timestamp
BOUND_HOSTNAME="$(hostname)"
BOUND_TIMESTAMP="$timestamp"
SYSTEM_ID="$system_id"
INSTALL_DIR="$install_dir"
BACKUP_USER="$BACKUP_USER"
EOF
    
    # Create repository configuration
    local repo_config="$config_dir/repository.conf"
    tee "$repo_config" > /dev/null << EOF
# Git repository configuration
GIT_REPO="$git_repo"
GIT_BRANCH="$git_branch"
GIT_USER_NAME="$git_user"
GIT_USER_EMAIL="$git_email"
AUTO_COMMIT=true
EOF
    
    # Create backup configuration
    local backup_config="$config_dir/backup.conf"
    tee "$backup_config" > /dev/null << EOF
# Backup behavior settings
BACKUP_PATHS="/etc/mysql /etc/mariadb /usr/local/lsws/conf /etc/php /etc/lsws"
COMPRESS_BACKUPS=false
EXCLUDE_PATTERNS=("*.log" "*.tmp" "*.cache" "*.pid" "*.sock" "*.lock")
ENABLE_MONITORING=false
MONITOR_INTERVAL=300
EOF
    
    # Create logging configuration
    local logging_config="$config_dir/logging.conf"
    tee "$logging_config" > /dev/null << EOF
# Log management settings
LOG_DIR="$log_dir"
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
    
    # Set proper permissions
    chmod 600 "$config_dir"/*.conf
    chown -R "$BACKUP_USER:$BACKUP_USER" "$config_dir"
    chown -R "$BACKUP_USER:$BACKUP_USER" "$log_dir"
    
    # Create system binding lock file
    echo "$(hostname):$timestamp:$system_id" > "$install_dir/.system-binding"
    chown "$BACKUP_USER:$BACKUP_USER" "$install_dir/.system-binding"
    
    success "Configuration files created in $config_dir"
    info "System bound to hostname: $(hostname)"
}

# Check for existing SSH keys for backup user
check_existing_ssh_keys() {
    local ssh_dir="${BACKUP_USER_HOME:-$HOME}/.ssh"
    local existing_keys=()
    
    if [[ -d "$ssh_dir" ]]; then
        # Check for common SSH key types
        local key_types=("id_rsa" "id_ed25519" "id_ecdsa" "id_dsa")
        
        for key_type in "${key_types[@]}"; do
            if [[ -f "$ssh_dir/$key_type" && -f "$ssh_dir/$key_type.pub" ]]; then
                existing_keys+=("$key_type")
            fi
        done
    fi
    
    echo "${existing_keys[@]}"
}

# Display existing SSH keys
display_existing_keys() {
    local keys=("$@")
    local ssh_dir="${BACKUP_USER_HOME:-$HOME}/.ssh"
    
    if [[ ${#keys[@]} -gt 0 ]]; then
        info "Found existing SSH keys for $BACKUP_USER:"
        for key in "${keys[@]}"; do
            echo "  - $ssh_dir/$key ($(ssh-keygen -l -f "$ssh_dir/$key.pub" 2>/dev/null | awk '{print $1 " " $4}'))"
        done
        echo
    fi
}

# Setup SSH key for Git (for backup user)
setup_ssh_key() {
    echo
    
    info "Setting up SSH key for backup user: $BACKUP_USER"
    warning "SECURITY: SSH keys will be created for $BACKUP_USER, NOT root!"
    echo
    
    # Check for existing SSH keys first
    local existing_keys=($(check_existing_ssh_keys))
    
    # SSH setup is mandatory since only SSH is supported
    info "SSH repository detected. SSH key setup is required."
    setup_ssh=y
    
    if [[ "$setup_ssh" =~ ^[Yy]$ ]]; then
        local ssh_dir="${BACKUP_USER_HOME}/.ssh"
        
        # Ensure SSH directory exists with proper permissions
        if [[ ! -d "$ssh_dir" ]]; then
            mkdir -p "$ssh_dir"
            chmod 700 "$ssh_dir"
            chown "$BACKUP_USER:$BACKUP_USER" "$ssh_dir"
        fi
        # Display existing keys if any
        if [[ ${#existing_keys[@]} -gt 0 ]]; then
            display_existing_keys "${existing_keys[@]}"
            
            echo "Options:"
            echo "1. Use existing SSH key"
            echo "2. Generate new SSH key"
            echo
            read -p "Choose option (1/2) [1]: " key_option
            key_option=${key_option:-1}
            
            if [[ "$key_option" == "1" ]]; then
                # Let user choose which existing key to use
                if [[ ${#existing_keys[@]} -eq 1 ]]; then
                    selected_key="${existing_keys[0]}"
                    info "Using existing SSH key: $selected_key"
                else
                    echo "Select SSH key to use:"
                    for i in "${!existing_keys[@]}"; do
                        echo "$((i+1)). ${existing_keys[i]}"
                    done
                    echo
                    read -p "Enter choice (1-${#existing_keys[@]}) [1]: " key_choice
                    key_choice=${key_choice:-1}
                    
                    if [[ "$key_choice" -ge 1 && "$key_choice" -le ${#existing_keys[@]} ]]; then
                        selected_key="${existing_keys[$((key_choice-1))]}"
                        info "Using existing SSH key: $selected_key"
                    else
                        error "Invalid choice. Using first key: ${existing_keys[0]}"
                        selected_key="${existing_keys[0]}"
                    fi
                fi
                
                local ssh_key_path="$ssh_dir/$selected_key"
            else
                # Generate new key
                local ssh_key_path="$ssh_dir/id_rsa"
                
                # Ask for key type
                echo "SSH key types:"
                echo "1. RSA (4096-bit) - Most compatible"
                echo "2. Ed25519 - Modern, secure, smaller"
                echo
                read -p "Choose key type (1/2) [2]: " key_type_choice
                key_type_choice=${key_type_choice:-2}
                
                if [[ "$key_type_choice" == "1" ]]; then
                    ssh_key_path="$ssh_dir/id_rsa"
                    info "Generating RSA SSH key for $BACKUP_USER..."
                    sudo -u "$BACKUP_USER" ssh-keygen -t rsa -b 4096 -C "$git_email" -f "$ssh_key_path" -N ""
                else
                    ssh_key_path="$ssh_dir/id_ed25519"
                    info "Generating Ed25519 SSH key for $BACKUP_USER..."
                    sudo -u "$BACKUP_USER" ssh-keygen -t ed25519 -C "$git_email" -f "$ssh_key_path" -N ""
                fi
                
                success "SSH key generated at $ssh_key_path"
            fi
        else
            # No existing keys, generate new one
            info "No existing SSH keys found for $BACKUP_USER. Generating new key..."
            
            echo "SSH key types:"
            echo "1. RSA (4096-bit) - Most compatible"
            echo "2. Ed25519 - Modern, secure, smaller"
            echo
            read -p "Choose key type (1/2) [2]: " key_type_choice
            key_type_choice=${key_type_choice:-2}
            
            if [[ "$key_type_choice" == "1" ]]; then
                local ssh_key_path="$ssh_dir/id_rsa"
                info "Generating RSA SSH key for $BACKUP_USER..."
                sudo -u "$BACKUP_USER" ssh-keygen -t rsa -b 4096 -C "$git_email" -f "$ssh_key_path" -N ""
            else
                local ssh_key_path="$ssh_dir/id_ed25519"
                info "Generating Ed25519 SSH key for $BACKUP_USER..."
                sudo -u "$BACKUP_USER" ssh-keygen -t ed25519 -C "$git_email" -f "$ssh_key_path" -N ""
            fi
            
            success "SSH key generated at $ssh_key_path"
        fi
        
        echo
        info "Add this public key to your Git provider:"
        echo "========================================"
        cat "$ssh_key_path.pub"
        echo "========================================"
        echo
        
        # Provider-specific instructions
        echo "IMPORTANT: Add this key to your Git provider using a SERVICE ACCOUNT, not your personal account!"
        echo
        if [[ "$git_repo" =~ github\.com ]]; then
            echo "GitHub: Create a service account or use deploy keys"
            echo "  - Service account: Settings → SSH and GPG keys → New SSH key"
            echo "  - Deploy key: Repository → Settings → Deploy keys → Add deploy key"
            echo "Title: $(hostname)-backup-service"
        elif [[ "$git_repo" =~ gitlab\.com ]]; then
            echo "GitLab: Create a service account or use deploy keys"
            echo "  - Service account: User Settings → SSH Keys → Add key"
            echo "  - Deploy key: Project → Settings → Repository → Deploy Keys"
            echo "Title: $(hostname)-backup-service"
        else
            echo "Add this key to your Git provider's SSH key settings"
            echo "Suggested title: $(hostname)-backup-service"
        fi
        echo
        
        read -p "Press Enter after adding the key to your Git provider..."
        
        # Test SSH connection based on provider (as backup user)
        info "Testing SSH connection as $BACKUP_USER..."
        local ssh_test_result=""
        
        if [[ "$git_repo" =~ github\.com ]]; then
            ssh_test_result=$(sudo -u "$BACKUP_USER" ssh -T git@github.com 2>&1 || true)
            if echo "$ssh_test_result" | grep -q "successfully authenticated"; then
                success "GitHub SSH authentication successful for $BACKUP_USER"
            else
                warning "GitHub SSH test failed. Output: $ssh_test_result"
                echo "Make sure you've added the public key to your GitHub service account."
            fi
        elif [[ "$git_repo" =~ gitlab\.com ]]; then
            ssh_test_result=$(sudo -u "$BACKUP_USER" ssh -T git@gitlab.com 2>&1 || true)
            if echo "$ssh_test_result" | grep -q "Welcome"; then
                success "GitLab SSH authentication successful for $BACKUP_USER"
            else
                warning "GitLab SSH test failed. Output: $ssh_test_result"
                echo "Make sure you've added the public key to your GitLab service account."
            fi
        else
            # Extract hostname from SSH URL for custom Git servers
            local git_host=$(echo "$git_repo" | sed -n 's/git@\([^:]*\):.*/\1/p')
            if [[ -n "$git_host" ]]; then
                ssh_test_result=$(sudo -u "$BACKUP_USER" ssh -T "git@$git_host" 2>&1 || true)
                if echo "$ssh_test_result" | grep -qE "(Welcome|successfully authenticated|Hi)"; then
                    success "SSH authentication successful for $BACKUP_USER on $git_host"
                else
                    warning "SSH test for $git_host inconclusive. Output: $ssh_test_result"
                    echo "Make sure you've added the public key to your Git provider."
                fi
            else
                warning "Could not determine Git host for SSH testing"
            fi
        fi
        
        # Store the key path for potential future use
        echo "SSH_KEY_PATH=\"$ssh_key_path\"" >> /tmp/backup_install_vars
        echo "BACKUP_USER=\"$BACKUP_USER\"" >> /tmp/backup_install_vars
    fi
}

# Main installation function
main() {
    echo -e "${BLUE}${EMOJI_ROCKET} Server Configuration Backup System Installer${NC}"
    echo "=================================================="
    echo
    
    check_installation_mode
    detect_os
    
    # Get installation directory
    read -p "Enter installation directory [/opt/server-backup]: " install_dir
    install_dir=${install_dir:-/opt/server-backup}
    
    install_dependencies
    setup_directories "$install_dir"
    configure_git
    setup_ssh_key
    create_config "$install_dir"
    
    echo
    success "Installation completed successfully!"
    echo
    info "Next steps:"
    echo "1. Initialize the backup system: server-backup init"
    echo "2. Perform your first backup: server-backup backup"
    echo "3. Install automatic backup service: server-backup install-service"
    echo "4. Check status: server-backup status"
    echo
    info "Configuration file: $install_dir/backup-config.conf"
    info "You can edit this file to customize backup paths and settings."
}

# Check if script exists
if [[ ! -f "server-config-backup.sh" ]]; then
    error "server-config-backup.sh not found in current directory"
    exit 1
fi

main "$@"