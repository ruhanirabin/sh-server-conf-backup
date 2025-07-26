# Server Configuration Backup System

A comprehensive backup solution for Ubuntu 22.x and Debian 12.x servers that automatically backs up critical configuration files to Git repositories with selective restore capabilities.

## Features

- **Automated Backup**: Backs up MariaDB/MySQL, OpenLiteSpeed, and PHP configuration files
- **Git Integration**: Supports GitHub, GitLab, Gitea, and other Git providers
- **Hostname-based Organization**: Creates separate folders for each server
- **Selective Restore**: Restore specific configurations or complete system state
- **File Monitoring**: Automatic backup on configuration changes
- **Systemd Integration**: Runs as a system service with periodic backups
- **Minimal User Interaction**: Set it up once and forget about it

## Supported Configurations

### Database Servers
- MariaDB (`/etc/mariadb`, `/etc/mysql`)
- MySQL (`/etc/mysql`)

### Web Servers
- OpenLiteSpeed (`/usr/local/lsws/conf`, `/etc/lsws`)

### PHP
- All PHP versions (`/etc/php`)

## Git Repository Setup

Before installation, you need to create a repository on your preferred Git provider:

### GitHub Setup

1. **Create Repository**:
   - Go to https://github.com/new
   - Repository name: `server-configs` (or your preferred name)
   - Set to **Private** (recommended for security)
   - Don't initialize with README (the script will handle this)

2. **Get Repository URL (SSH ONLY)**:
   - **SSH**: `git@github.com:yourusername/server-configs.git` ✅ **REQUIRED**
   - ❌ HTTPS URLs are NOT supported (authentication complexity)

3. **SSH Key Setup** (Required):
   - Go to Settings → SSH and GPG keys → New SSH key
   - The installer will help you generate and configure SSH keys

### GitLab Setup

1. **Create Repository**:
   - Go to https://gitlab.com/projects/new (or your GitLab instance)
   - Project name: `server-configs`
   - Visibility Level: **Private**
   - Don't initialize with README

2. **Get Repository URL (SSH ONLY)**:
   - **SSH**: `git@gitlab.com:yourusername/server-configs.git` ✅ **REQUIRED**
   - ❌ HTTPS URLs are NOT supported (authentication complexity)

3. **SSH Key Setup** (Required):
   - Go to User Settings → SSH Keys → Add key
   - The installer will help you generate and configure SSH keys

### Gitea Setup

1. **Create Repository**:
   - Go to your Gitea instance (e.g., `https://git.yourdomain.com`)
   - Click "+" → New Repository
   - Repository name: `server-configs`
   - Make it **Private**
   - Don't initialize with README

2. **Get Repository URL (SSH ONLY)**:
   - **SSH**: `git@git.yourdomain.com:yourusername/server-configs.git` ✅ **REQUIRED**
   - ❌ HTTPS URLs are NOT supported (authentication complexity)

3. **SSH Key Setup** (Required):
   - Go to User Settings → SSH/GPG Keys → Add Key
   - The installer will help you generate and configure SSH keys

### Self-hosted Git

For self-hosted Git servers (GitLab CE, Gitea, Forgejo, etc.):
- Replace the domain with your server's domain
- Follow the same authentication patterns
- Ensure your server has network access to the Git server

## Quick Start

### 1. Installation

The installer supports multiple installation modes depending on your privileges:

#### **System-wide Installation (Recommended)**
```bash
# Make scripts executable
chmod +x install.sh server-config-backup.sh

# Run as root for full system installation
sudo ./install.sh
```

#### **User Installation (Limited)**
```bash
# Run as regular user (some features may be limited)
./install.sh
```

#### **User Installation with Sudo**
```bash
# Run as user with sudo access (enhanced features)
./install.sh
```

**What the installer does:**
- ✅ **System Mode**: Creates dedicated backup user, installs to `/opt/server-backup`, full sudo permissions
- ✅ **User-Sudo Mode**: Can create backup user, installs to user directory, limited sudo permissions  
- ✅ **User Mode**: Uses current user, installs to user directory, no sudo permissions
- ✅ **All Modes**: Install dependencies (if possible), configure Git, setup SSH keys

## Installation Mode Comparison

| Feature | System Mode (Root) | User-Sudo Mode | User Mode |
|---------|-------------------|-----------------|-----------|
| **Installation Location** | `/opt/server-backup` | `~/server-backup` | `~/server-backup` |
| **Backup User** | `backup-service` | `backup-service` (optional) | Current user |
| **System Config Access** | ✅ Full access via sudo | ✅ Limited sudo access | ❌ User-readable only |
| **Package Installation** | ✅ Automatic | ✅ Automatic | ❌ Manual required |
| **Service Integration** | ✅ Systemd service | ✅ User systemd service | ❌ Manual only |
| **Security Level** | 🔒 Highest | 🔒 High | ⚠️ Basic |
| **Recommended For** | Production servers | Development servers | Personal use |

### **When to Use Each Mode:**

#### **🔒 System Mode (Root) - Production Recommended**
- **Use when**: Production servers, multiple users, maximum security
- **Benefits**: Dedicated backup user, full system access, systemd integration
- **Requirements**: Root access during installation

#### **🔒 User-Sudo Mode - Development/Testing**
- **Use when**: Development servers, single user with sudo access
- **Benefits**: Most features available, can create backup user
- **Requirements**: Sudo access for some operations

#### **⚠️ User Mode - Personal/Limited**
- **Use when**: Personal systems, no admin access, testing only
- **Benefits**: No special privileges needed
- **Limitations**: Cannot backup system configs, limited functionality

### 2. Initialize Backup System

```bash
server-backup init
```

### 3. Perform First Backup

```bash
server-backup backup
```

### 4. Install Automatic Backup Service

```bash
server-backup install-service
```

## Manual Configuration

If you prefer to configure manually instead of using the installer:

### 1. Edit Configuration File

```bash
sudo nano /opt/server-backup/backup-config.conf
```

### 2. Set Your Git Repository (SSH ONLY)

Only SSH URLs are supported for reliability and security:

```bash
# GitHub
GIT_REPO="git@github.com:yourusername/server-configs.git"

# GitLab
GIT_REPO="git@gitlab.com:yourusername/server-configs.git"

# Gitea/Self-hosted
GIT_REPO="git@git.yourdomain.com:yourusername/server-configs.git"
```

### 3. Configure SSH Authentication

SSH is the recommended method for server automation:

```bash
# Check for existing SSH keys first
ls -la ~/.ssh/id_*

# If you have existing keys, you can use them
# Common key files: id_rsa, id_ed25519, id_ecdsa

# Generate new SSH key if needed (choose one):
# RSA (most compatible)
ssh-keygen -t rsa -b 4096 -C "your.email@example.com"

# Ed25519 (modern, more secure)
ssh-keygen -t ed25519 -C "your.email@example.com"

# Display public key to add to your Git provider
cat ~/.ssh/id_rsa.pub      # for RSA key
cat ~/.ssh/id_ed25519.pub  # for Ed25519 key

# Test SSH connection
ssh -T git@github.com    # for GitHub
ssh -T git@gitlab.com    # for GitLab
ssh -T git@yourdomain.com # for self-hosted
```

### 4. Test Configuration

```bash
# Test Git connectivity
server-backup status

# Perform test backup
server-backup backup
```

## Usage

### Basic Commands

```bash
# Show help
server-backup --help

# Check system status
server-backup status

# Perform manual backup
server-backup backup

# List available backups
server-backup list

# Restore from backup (interactive)
server-backup restore

# Restore specific commit
server-backup restore abc1234

# Restore specific path from commit
server-backup restore abc1234 /etc/mysql

# Start file monitoring (foreground)
server-backup monitor
```

### Configuration

Edit `/opt/server-backup/backup-config.conf`:

```bash
# Git repository configuration (SSH ONLY)
GIT_REPO="git@github.com:yourusername/server-configs.git"  # SSH URL required
GIT_BRANCH="main"
GIT_USER_NAME="Your Name"
GIT_USER_EMAIL="your.email@example.com"

# Backup paths (space-separated)
BACKUP_PATHS="/etc/mysql /etc/mariadb /usr/local/lsws/conf /etc/php /etc/lsws"

# Backup settings
AUTO_COMMIT=true
COMPRESS_BACKUPS=false
EXCLUDE_PATTERNS=("*.log" "*.tmp" "*.cache" "*.pid" "*.sock" "*.lock")

# Monitoring settings
ENABLE_MONITORING=false
MONITOR_INTERVAL=300  # seconds
```

#### Example Configurations for Different Providers (SSH ONLY):

**GitHub:**
```bash
GIT_REPO="git@github.com:yourusername/server-configs.git"
```

**GitLab:**
```bash
GIT_REPO="git@gitlab.com:yourusername/server-configs.git"
```

**Gitea/Self-hosted:**
```bash
GIT_REPO="git@git.yourdomain.com:yourusername/server-configs.git"
```

⚠️ **Note**: HTTPS URLs are not supported due to authentication complexity with personal access tokens.

## Repository Structure

Your Git repository will be organized as follows:

```
server-configs/
├── server1.example.com/
│   ├── README.md
│   ├── mysql/
│   │   ├── my.cnf
│   │   └── conf.d/
│   ├── php/
│   │   ├── 8.1/
│   │   └── 8.2/
│   └── lsws/
│       └── conf/
├── server2.example.com/
│   ├── README.md
│   ├── mariadb/
│   └── php/
└── server3.example.com/
    └── ...
```

## Advanced Features

### Automatic Monitoring

Enable file monitoring to automatically backup when configurations change:

```bash
# Edit configuration
sudo nano /opt/server-backup/backup-config.conf

# Set ENABLE_MONITORING=true
ENABLE_MONITORING=true
MONITOR_INTERVAL=300  # Check every 5 minutes

# Restart the service
sudo systemctl restart config-backup.timer
```

### Selective Restore

The system provides three levels of restore granularity:

#### 1. Interactive Restore Menu
```bash
server-backup restore abc1234
```
Shows an interactive menu with options:
- Individual configurations (MySQL, PHP, OpenLiteSpeed)
- Complete restore (all configurations)
- Cancel operation

#### 2. Command-Line Specific Restore
```bash
# Restore only MySQL configuration
server-backup restore abc1234 /etc/mysql

# Restore only PHP configuration  
server-backup restore abc1234 /etc/php

# Restore only OpenLiteSpeed configuration
server-backup restore abc1234 /usr/local/lsws/conf
```

#### 3. Safety Features
- **Automatic Backup**: Creates backup of current config before restore
- **Confirmation Prompts**: Asks for confirmation before overwriting
- **Service Restart Suggestions**: Recommends which services to restart
- **Commit Validation**: Verifies commit exists before attempting restore

#### Example Interactive Session
```
$ server-backup restore a1b2c3d

Commit Information:
===================
commit a1b2c3d Author: backup-service
Date: 2024-01-15 10:30:00
Config backup for web-server-01

Available configurations to restore:
====================================
1. mysql → /etc/mysql
2. php → /etc/php  
3. lsws → /usr/local/lsws/conf
4. all → Restore all configurations
5. quit → Cancel restore

Select option (1-5): 1

This will overwrite current configuration in /etc/mysql
Continue? (y/N): y

Creating backup of current configuration...
Restoring /etc/mysql...
Restored /etc/mysql
Previous config backed up to: /etc/mysql.backup_20240115_103045

Consider restarting related services:
  sudo systemctl restart mysql
  sudo systemctl restart mariadb
```

### Custom Backup Paths

Add additional paths to backup by editing the configuration:

```bash
# Edit configuration
sudo nano /opt/server-backup/backup-config.conf

# Add custom paths
BACKUP_PATHS="/etc/mysql /etc/mariadb /usr/local/lsws/conf /etc/php /etc/lsws /etc/nginx /etc/apache2"
```

## Systemd Service

The system installs a systemd service for automatic backups:

```bash
# Check service status
sudo systemctl status config-backup.timer

# View recent backups
sudo journalctl -u config-backup.service -f

# Manual service control
sudo systemctl start config-backup.service
sudo systemctl stop config-backup.timer
sudo systemctl restart config-backup.timer
```

## Security Considerations

### Critical Security Features

- **User Separation**: Root reads system files, but Git operations run as dedicated `backup-service` user
- **No Root SSH Keys**: SSH keys are created for the backup user, NOT root
- **Service Account**: Use dedicated service accounts in Git providers, not personal accounts
- **Private Repositories**: Always use private Git repositories for configuration backups
- **Limited Permissions**: Backup user has minimal required permissions via sudoers

### Security Best Practices

- Configuration files may contain sensitive information
- Use private Git repositories exclusively
- SSH key authentication is mandatory for automation
- Restrict access to backup directories (`chmod 600`)
- Review exclude patterns to avoid backing up sensitive temporary files
- Use deploy keys or service accounts in Git providers
- Regularly rotate SSH keys
- Monitor backup logs for unauthorized access attempts

### User Separation Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Root User     │    │  Backup User     │    │  Git Provider   │
│                 │    │  (backup-service)│    │  (GitHub/GitLab) │
├─────────────────┤    ├──────────────────┤    ├─────────────────┤
│ • Read system   │───▶│ • Git operations │───▶│ • SSH key auth  │
│   config files  │    │ • Repository mgmt│    │ • Service account│
│ • File backup   │    │ • Commit & push  │    │ • Private repo   │
│ • NO Git access │    │ • NO system files│    │ • Deploy keys    │
└─────────────────┘    └──────────────────┘    └─────────────────┘
```

## Authentication Setup

### SSH Key Authentication (Recommended)

SSH keys provide secure, password-free authentication:

```bash
# Check for existing SSH keys first
ls -la ~/.ssh/id_*

# Generate SSH key if you don't have one (choose one type):
# RSA (most compatible)
ssh-keygen -t rsa -b 4096 -C "your.email@example.com"

# Ed25519 (modern, more secure, smaller)
ssh-keygen -t ed25519 -C "your.email@example.com"

# Display public key to copy
cat ~/.ssh/id_rsa.pub      # for RSA key
cat ~/.ssh/id_ed25519.pub  # for Ed25519 key
```

**Add to your Git provider:**

- **GitHub**: Settings → SSH and GPG keys → New SSH key
- **GitLab**: User Settings → SSH Keys → Add key  
- **Gitea**: User Settings → SSH/GPG Keys → Add Key

**Test SSH connection:**
```bash
# GitHub
ssh -T git@github.com

# GitLab
ssh -T git@gitlab.com

# Gitea (replace with your domain)
ssh -T git@git.yourdomain.com
```

### Why SSH Only?

**HTTPS is NOT supported** because:
- Most Git providers deprecated password authentication
- Personal access tokens are complex to manage in automation
- Tokens expire and require rotation
- SSH keys are more reliable for server automation
- Better security with proper key management

**SSH Benefits:**
- No token expiration issues
- Simpler automation setup
- Better security practices
- Universal support across Git providers

## Troubleshooting

### Common Issues

1. **Git Authentication Failed**
   
   **SSH Troubleshooting:**
   ```bash
   # Test SSH connection
   ssh -T git@github.com  # or gitlab.com, or your domain
   
   # If fails, check SSH key is added to your Git provider
   cat ~/.ssh/id_rsa.pub
   
   # Regenerate SSH key if needed
   ssh-keygen -t rsa -b 4096 -C "your.email@example.com"
   
   # Or use Ed25519 (modern, more secure)
   ssh-keygen -t ed25519 -C "your.email@example.com"
   ```

2. **Permission Denied**
   ```bash
   # Ensure proper permissions
   sudo chown -R root:root /opt/server-backup
   sudo chmod +x /opt/server-backup/server-config-backup.sh
   ```

3. **Missing Dependencies**
   ```bash
   # Install manually
   sudo apt-get update
   sudo apt-get install git rsync inotify-tools
   ```

4. **Service Not Starting**
   ```bash
   # Check logs
   sudo journalctl -u config-backup.service
   
   # Reload systemd
   sudo systemctl daemon-reload
   sudo systemctl restart config-backup.timer
   ```

### Log Files

Check logs for troubleshooting:
- Main log: `/opt/server-backup/backup.log`
- System logs: `sudo journalctl -u config-backup.service`

## Why This Approach?

This Git-based solution is the most effective because:

1. **Version Control**: Full history of all configuration changes
2. **Distributed**: Works with any Git provider (GitHub, GitLab, Gitea, self-hosted)
3. **Scalable**: Easy to replicate across multiple servers
4. **Selective**: Restore individual files or complete configurations
5. **Automated**: Set-and-forget operation with monitoring
6. **Organized**: Hostname-based structure keeps servers separate
7. **Lightweight**: Minimal dependencies and resource usage

## License

This script system is provided as-is for server administration purposes. Use at your own risk and always test restores in a safe environment first.