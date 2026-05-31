#!/usr/bin/env bash
set -euo pipefail

APP_NAME="freellmapi"
APP_DIR="/opt/freellmapi"
REPO_URL="https://github.com/zczy-k/freellmapi.git"
BRANCH="main"
SERVICE_NAME="freellmapi"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CRON_FILE="/etc/cron.d/${SERVICE_NAME}-auto-upgrade"
LOG_FILE="/var/log/${SERVICE_NAME}-deploy.log"
DATA_DIR="${APP_DIR}/data"
ENV_FILE="${APP_DIR}/.env"
NODE_MAJOR=20
BACKUP_DIR="/opt/freellmapi-backup"
DEPLOY_VERSION_FILE="${APP_DIR}/.deploy-version"
NODE_INSTALL_FLAG="/opt/.freellmapi-node-installed"
SWAP_FILE="/swapfile"
AUTO_MODE=false
YES_MODE=false
CUSTOM_PORT=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()    { echo -e "${CYAN}==>${NC} ${BOLD}$*${NC}"; }
log_sub()     { echo -e "    $*"; }

confirm() {
    if [[ "$YES_MODE" == "true" ]]; then
        return 0
    fi
    local prompt="$1 [y/N]: "
    read -r -p "$prompt" response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root."
        exit 1
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
        OS_FAMILY=""
        case "$OS_ID" in
            ubuntu|debian|linuxmint|pop|elementary)
                OS_FAMILY="debian"
                ;;
            centos|rhel|rocky|almalinux|fedora|amzn)
                OS_FAMILY="rhel"
                ;;
            alpine)
                OS_FAMILY="alpine"
                ;;
            *)
                OS_FAMILY="unknown"
                ;;
        esac
    elif [[ -f /etc/redhat-release ]]; then
        OS_FAMILY="rhel"
        OS_ID="rhel"
        OS_VERSION="unknown"
    else
        OS_FAMILY="unknown"
        OS_ID="unknown"
        OS_VERSION="unknown"
    fi
    log_info "Detected OS: ${OS_ID} ${OS_VERSION} (${OS_FAMILY})"
}

is_installed() {
    [[ -d "$APP_DIR" && -f "$SERVICE_FILE" ]]
}

get_current_version() {
    if [[ -f "$DEPLOY_VERSION_FILE" ]]; then
        cat "$DEPLOY_VERSION_FILE"
    elif [[ -d "$APP_DIR" ]]; then
        cd "$APP_DIR"
        git rev-parse HEAD 2>/dev/null || echo "unknown"
    else
        echo "not-installed"
    fi
}

get_latest_version() {
    cd "$APP_DIR"
    git fetch origin "$BRANCH" --quiet 2>/dev/null || true
    git rev-parse "origin/${BRANCH}" 2>/dev/null || echo "unknown"
}

write_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

install_system_deps() {
    log_step "Installing system dependencies"
    case "$OS_FAMILY" in
        debian)
            apt-get update -qq
            apt-get install -y -qq git curl wget python3 make g++ ca-certificates gnupg > /dev/null 2>&1
            ;;
        rhel)
            if command -v dnf &>/dev/null; then
                dnf install -y -q git curl wget python3 make gcc-c++ ca-certificates
            else
                yum install -y -q git curl wget python3 make gcc-c++ ca-certificates
            fi
            ;;
        alpine)
            apk add --quiet git curl wget python3 make g++
            ;;
        *)
            log_warn "Unsupported OS family: $OS_FAMILY. Please install manually: git, curl, python3, make, g++"
            ;;
    esac
    log_info "System dependencies installed"
}

install_nodejs() {
    if command -v node &>/dev/null; then
        local node_version
        node_version=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
        if [[ "$node_version" -ge "$NODE_MAJOR" ]]; then
            log_info "Node.js $(node -v) already installed, skipping"
            return 0
        else
            log_warn "Node.js $(node -v) found but version too old (need >= ${NODE_MAJOR}), upgrading..."
        fi
    fi

    log_step "Installing Node.js ${NODE_MAJOR}"
    case "$OS_FAMILY" in
        debian)
            curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - > /dev/null 2>&1
            apt-get install -y -qq nodejs > /dev/null 2>&1
            ;;
        rhel)
            curl -fsSL https://rpm.nodesource.com/setup_${NODE_MAJOR}.x | bash - > /dev/null 2>&1
            if command -v dnf &>/dev/null; then
                dnf install -y -q nodejs
            else
                yum install -y -q nodejs
            fi
            ;;
        alpine)
            apk add --quiet nodejs npm
            ;;
        *)
            log_error "Cannot install Node.js automatically on $OS_FAMILY. Please install Node.js ${NODE_MAJOR}+ manually."
            exit 1
            ;;
    esac

    touch "$NODE_INSTALL_FLAG"
    log_info "Node.js $(node -v) installed"
}

setup_swap() {
    local total_swap
    total_swap=$(free -m | awk '/^Swap:/{print $2}')

    if [[ "$total_swap" -ge 1024 ]]; then
        log_info "Swap already configured (${total_swap}MB), skipping"
        return 0
    fi

    local total_mem
    total_mem=$(free -m | awk '/^Mem:/{print $2}')

    if [[ "$total_mem" -gt 2048 ]]; then
        return 0
    fi

    log_step "Setting up swap (recommended for ${total_mem}MB RAM)"
    if ! confirm "Add 1GB swap file?"; then
        return 0
    fi

    if [[ -f "$SWAP_FILE" ]]; then
        log_info "Swap file already exists, enabling..."
        swapon "$SWAP_FILE" 2>/dev/null || true
        return 0
    fi

    fallocate -l 1G "$SWAP_FILE" 2>/dev/null || dd if=/dev/zero of="$SWAP_FILE" bs=1M count=1024 status=progress
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" > /dev/null
    swapon "$SWAP_FILE"

    if ! grep -q "$SWAP_FILE" /etc/fstab 2>/dev/null; then
        echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
    fi

    sysctl vm.swappiness=10 > /dev/null 2>&1 || true
    if ! grep -q "vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
        echo "vm.swappiness=10" >> /etc/sysctl.conf
    fi

    log_info "Swap configured (1GB)"
}

create_user() {
    if id "$APP_NAME" &>/dev/null; then
        log_info "User '$APP_NAME' already exists"
        return 0
    fi
    useradd --system --no-create-home --shell /usr/sbin/nologin "$APP_NAME" 2>/dev/null || \
    useradd --system --no-create-home --shell /bin/false "$APP_NAME" 2>/dev/null || true
    log_info "User '$APP_NAME' created"
}

clone_repo() {
    log_step "Cloning repository"
    if [[ -d "$APP_DIR" ]]; then
        log_warn "$APP_DIR already exists"
        return 0
    fi

    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$APP_DIR" --quiet
    log_info "Repository cloned"
}

install_npm_deps() {
    log_step "Installing npm dependencies"
    cd "$APP_DIR"

    npm install --omit=dev --no-audit --no-fund > /dev/null 2>&1

    if [[ -d "server" ]] && [[ -f "server/package.json" ]]; then
        cd server
        npm install --omit=dev --no-audit --no-fund > /dev/null 2>&1 || true
        cd "$APP_DIR"
    fi

    log_info "npm dependencies installed"
}

build_app() {
    log_step "Building application"
    cd "$APP_DIR"

    export NODE_OPTIONS="--max-old-space-size=512"

    npm run build > /dev/null 2>&1

    log_info "Application built"
}

generate_encryption_key() {
    if [[ -f "$ENV_FILE" ]]; then
        existing_key=$(grep -E "^ENCRYPTION_KEY=" "$ENV_FILE" | cut -d'=' -f2)
        if [[ -n "$existing_key" && "$existing_key" != "your-64-char-hex-key-here" ]]; then
            log_info "ENCRYPTION_KEY already configured, keeping existing"
            return 0
        fi
    fi

    local key
    key=$(node -e "console.log(require('crypto').randomBytes(32).toString('hex'))")

    if [[ -f "$ENV_FILE" ]]; then
        sed -i "s/^ENCRYPTION_KEY=.*/ENCRYPTION_KEY=${key}/" "$ENV_FILE"
    else
        local port="${CUSTOM_PORT:-3001}"
        cat > "$ENV_FILE" << EOF
ENCRYPTION_KEY=${key}
PORT=${port}
EOF
    fi
    chmod 600 "$ENV_FILE"
    log_info "ENCRYPTION_KEY generated and saved to .env"
}

create_env_file() {
    if [[ -f "$ENV_FILE" ]]; then
        log_info ".env file already exists, updating if needed..."
        generate_encryption_key
        return 0
    fi

    log_step "Creating .env configuration"
    local port="${CUSTOM_PORT:-3001}"

    if [[ "$AUTO_MODE" == "false" && "$YES_MODE" == "false" ]]; then
        read -r -p "    Port [${port}]: " input_port
        port="${input_port:-$port}"
    fi

    cat > "$ENV_FILE" << EOF
ENCRYPTION_KEY=your-64-char-hex-key-here
PORT=${port}
EOF
    chmod 600 "$ENV_FILE"
    generate_encryption_key
    log_info ".env created (PORT=${port})"
}

create_systemd_service() {
    log_step "Creating systemd service"

    local port="${CUSTOM_PORT:-3001}"
    if [[ -f "$ENV_FILE" ]]; then
        port=$(grep -E "^PORT=" "$ENV_FILE" | cut -d'=' -f2 || echo "3001")
        port="${port:-3001}"
    fi

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=FreeLLMAPI - Free LLM API Proxy
After=network.target

[Service]
Type=simple
User=${APP_NAME}
Group=${APP_NAME}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
Environment=NODE_ENV=production
ExecStart=$(command -v node) ${APP_DIR}/server/dist/index.js
Restart=on-failure
RestartSec=5
MemoryMax=512M

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${APP_DIR}/data ${APP_DIR}/.env
ReadOnlyPaths=${APP_DIR}/server ${APP_DIR}/client ${APP_DIR}/shared ${APP_DIR}/node_modules

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" > /dev/null 2>&1
    log_info "systemd service created and enabled"
}

setup_auto_upgrade() {
    log_step "Setting up auto-upgrade cron job"

    if [[ "$AUTO_MODE" == "false" && "$YES_MODE" == "false" ]]; then
        if ! confirm "Enable automatic upgrade check (every 6 hours)?"; then
            log_info "Auto-upgrade disabled"
            return 0
        fi
    fi

    local script_path
    script_path=$(readlink -f "$0" 2>/dev/null || echo "${APP_DIR}/deploy.sh")

    cat > "$CRON_FILE" << EOF
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 */6 * * * root ${script_path} upgrade --auto >> ${LOG_FILE} 2>&1
EOF
    chmod 644 "$CRON_FILE"

    log_info "Auto-upgrade cron configured (every 6 hours)"
}

set_permissions() {
    chown -R root:root "$APP_DIR"
    chown -R "${APP_NAME}:${APP_NAME}" "${DATA_DIR}"
    chown "${APP_NAME}:${APP_NAME}" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    chmod 755 "${APP_DIR}/server/dist/index.js" 2>/dev/null || true
}

health_check() {
    local port
    port=$(grep -E "^PORT=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "3001")
    port="${port:-3001}"

    local max_retries=10
    local retry=0

    while [[ $retry -lt $max_retries ]]; do
        if curl -sf "http://127.0.0.1:${port}/api/ping" > /dev/null 2>&1; then
            log_info "Health check passed"
            return 0
        fi
        retry=$((retry + 1))
        sleep 2
    done

    log_error "Health check failed after ${max_retries} retries"
    return 1
}

save_version() {
    cd "$APP_DIR"
    git rev-parse HEAD > "$DEPLOY_VERSION_FILE" 2>/dev/null || echo "unknown" > "$DEPLOY_VERSION_FILE"
}

do_install() {
    log_step "Installing FreeLLMAPI"
    write_log "Starting installation"

    check_root
    detect_os

    if is_installed; then
        log_warn "FreeLLMAPI is already installed at ${APP_DIR}"
        if confirm "Reinstall?"; then
            do_uninstall_internal false
        else
            log_info "Aborted"
            exit 0
        fi
    fi

    install_system_deps
    install_nodejs
    setup_swap
    create_user
    clone_repo
    install_npm_deps
    build_app
    create_env_file
    mkdir -p "${DATA_DIR}"
    set_permissions
    create_systemd_service
    setup_auto_upgrade
    save_version

    log_step "Starting FreeLLMAPI"
    systemctl start "$SERVICE_NAME"

    if health_check; then
        local port
        port=$(grep -E "^PORT=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "3001")
        port="${port:-3001}"
        echo ""
        log_info "==========================================="
        log_info " FreeLLMAPI installed successfully!"
        log_info "==========================================="
        log_info ""
        log_info "  Dashboard:  http://<your-ip>:${port}"
        log_info "  API:        http://<your-ip>:${port}/v1/chat/completions"
        log_info "  Config:     ${ENV_FILE}"
        log_info "  Data:       ${DATA_DIR}"
        log_info "  Logs:       journalctl -u ${SERVICE_NAME} -f"
        log_info ""
        log_info "  Management commands:"
        log_info "    ${0} status      - Check status"
        log_info "    ${0} logs        - View logs"
        log_info "    ${0} restart     - Restart service"
        log_info "    ${0} upgrade     - Upgrade to latest"
        log_info "    ${0} uninstall   - Remove everything"
        log_info ""
        write_log "Installation completed successfully"
    else
        log_error "Installation completed but health check failed."
        log_error "Check logs: journalctl -u ${SERVICE_NAME} -n 50"
        exit 1
    fi
}

do_upgrade() {
    local auto_flag="${1:-false}"

    check_root

    if ! is_installed; then
        log_error "FreeLLMAPI is not installed. Run '${0} install' first."
        exit 1
    fi

    log_step "Checking for updates"
    write_log "Checking for updates"

    cd "$APP_DIR"
    git fetch origin "$BRANCH" --quiet 2>/dev/null || {
        log_error "Failed to fetch from remote"
        exit 1
    }

    local current latest
    current=$(git rev-parse HEAD)
    latest=$(git rev-parse "origin/${BRANCH}")

    if [[ "$current" == "$latest" ]]; then
        if [[ "$auto_flag" != "true" ]]; then
            log_info "Already up to date (no new commits)"
        fi
        write_log "No update available"
        exit 0
    fi

    local current_short latest_short
    current_short=$(git rev-parse --short HEAD)
    latest_short=$(git rev-parse --short "origin/${BRANCH}")
    local commit_count
    commit_count=$(git rev-list "${current}..${latest}" --count 2>/dev/null || echo "?")

    log_info "Update available: ${current_short} -> ${latest_short} (${commit_count} new commits)"

    if [[ "$auto_flag" != "true" && "$YES_MODE" == "false" ]]; then
        if ! confirm "Proceed with upgrade?"; then
            log_info "Upgrade cancelled"
            exit 0
        fi
    fi

    log_step "Backing up current version"
    rm -rf "$BACKUP_DIR"
    cp -a "$APP_DIR" "$BACKUP_DIR"
    cp -a "$ENV_FILE" "${BACKUP_DIR}/.env.backup"
    log_info "Backup saved to ${BACKUP_DIR}"

    log_step "Upgrading FreeLLMAPI"
    write_log "Starting upgrade: ${current_short} -> ${latest_short}"

    local upgrade_failed=false

    cd "$APP_DIR"

    git reset --hard "origin/${BRANCH}" --quiet 2>/dev/null || {
        log_error "git pull failed"
        upgrade_failed=true
    }

    if [[ "$upgrade_failed" == "false" ]]; then
        install_npm_deps || {
            log_error "npm install failed"
            upgrade_failed=true
        }
    fi

    if [[ "$upgrade_failed" == "false" ]]; then
        build_app || {
            log_error "Build failed"
            upgrade_failed=true
        }
    fi

    if [[ "$upgrade_failed" == "false" ]]; then
        set_permissions
        log_step "Restarting service"
        systemctl restart "$SERVICE_NAME"

        if health_check; then
            save_version
            rm -rf "$BACKUP_DIR"
            log_info "==========================================="
            log_info " Upgrade successful!"
            log_info " ${current_short} -> ${latest_short}"
            log_info "==========================================="
            write_log "Upgrade completed: ${current_short} -> ${latest_short}"
        else
            upgrade_failed=true
        fi
    fi

    if [[ "$upgrade_failed" == "true" ]]; then
        log_error "Upgrade failed! Rolling back..."
        write_log "Upgrade failed, rolling back"

        systemctl stop "$SERVICE_NAME" 2>/dev/null || true

        rm -rf "${APP_DIR}/server"
        rm -rf "${APP_DIR}/client"
        rm -rf "${APP_DIR}/shared"
        rm -rf "${APP_DIR}/node_modules"
        rm -rf "${APP_DIR}/package-lock.json"

        cp -a "${BACKUP_DIR}/server" "${APP_DIR}/server" 2>/dev/null || true
        cp -a "${BACKUP_DIR}/client" "${APP_DIR}/client" 2>/dev/null || true
        cp -a "${BACKUP_DIR}/shared" "${APP_DIR}/shared" 2>/dev/null || true
        cp -a "${BACKUP_DIR}/node_modules" "${APP_DIR}/node_modules" 2>/dev/null || true
        cp -a "${BACKUP_DIR}/package-lock.json" "${APP_DIR}/package-lock.json" 2>/dev/null || true

        if [[ -f "${BACKUP_DIR}/.env.backup" ]]; then
            cp -a "${BACKUP_DIR}/.env.backup" "$ENV_FILE"
        fi

        set_permissions
        systemctl start "$SERVICE_NAME"

        sleep 3
        if curl -sf "http://127.0.0.1:$(grep -E '^PORT=' "$ENV_FILE" | cut -d'=' -f2 || echo 3001)/api/ping" > /dev/null 2>&1; then
            log_info "Rollback successful, service restored"
        else
            log_error "Rollback also failed! Manual intervention required."
            log_error "Backup is at: ${BACKUP_DIR}"
        fi
        exit 1
    fi
}

do_uninstall_internal() {
    local purge="${1:-false}"

    log_step "Stopping service"
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true

    log_step "Removing service files"
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload 2>/dev/null || true

    log_step "Removing cron job"
    rm -f "$CRON_FILE"

    log_step "Removing log file"
    rm -f "$LOG_FILE"

    log_step "Removing application"
    rm -rf "$APP_DIR"

    log_step "Removing backup"
    rm -rf "$BACKUP_DIR"

    if [[ "$purge" == "true" ]]; then
        log_step "Purging data directory"
        rm -rf "$DATA_DIR"
        rm -f "$DEPLOY_VERSION_FILE"
    fi

    if [[ -f "$NODE_INSTALL_FLAG" ]]; then
        log_step "Node.js was installed by this script"
        if [[ "$purge" == "true" ]] || confirm "Remove Node.js (installed by deploy script)?"; then
            case "$OS_FAMILY" in
                debian)
                    apt-get remove -y -qq nodejs > /dev/null 2>&1 || true
                    rm -f /etc/apt/sources.list.d/nodesource.list
                    ;;
                rhel)
                    if command -v dnf &>/dev/null; then
                        dnf remove -y -q nodejs 2>/dev/null || true
                    else
                        yum remove -y -q nodejs 2>/dev/null || true
                    fi
                    rm -f /etc/yum.repos.d/nodesource*.repo
                    ;;
            esac
            rm -f "$NODE_INSTALL_FLAG"
            log_info "Node.js removed"
        fi
    fi

    if [[ "$purge" == "true" ]]; then
        log_step "Removing swap (if created by this script)"
        if [[ -f "$SWAP_FILE" ]] && swapon --show | grep -q "$SWAP_FILE"; then
            swapoff "$SWAP_FILE" 2>/dev/null || true
        fi
        rm -f "$SWAP_FILE"
        sed -i "\|${SWAP_FILE}|d" /etc/fstab 2>/dev/null || true

        log_step "Removing user"
        userdel "$APP_NAME" 2>/dev/null || true
    fi
}

do_uninstall() {
    check_root
    detect_os

    if ! is_installed && [[ ! -d "$APP_DIR" ]]; then
        log_error "FreeLLMAPI is not installed."
        exit 1
    fi

    echo ""
    log_warn "This will remove FreeLLMAPI from your system."
    echo ""
    echo "  Options:"
    echo "    1) Remove application only (keep data and .env)"
    echo "    2) Remove everything including data, .env, swap, user"
    echo "    3) Cancel"
    echo ""

    if [[ "$YES_MODE" == "true" ]]; then
        local purge_choice="2"
    else
        read -r -p "  Select [1-3]: " purge_choice
    fi

    case "$purge_choice" in
        1)
            do_uninstall_internal false
            log_info "FreeLLMAPI uninstalled (data preserved at ${DATA_DIR})"
            ;;
        2)
            if [[ "$YES_MODE" == "true" ]] || confirm "This will DELETE all data. Are you sure?"; then
                do_uninstall_internal true
                log_info "FreeLLMAPI completely removed (including all data)"
            else
                log_info "Uninstall cancelled"
            fi
            ;;
        *)
            log_info "Uninstall cancelled"
            ;;
    esac
}

do_status() {
    if ! is_installed; then
        log_error "FreeLLMAPI is not installed."
        exit 1
    fi

    echo ""
    log_info "FreeLLMAPI Status"
    echo "  ─────────────────────────────────────"

    local port
    port=$(grep -E "^PORT=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "3001")
    port="${port:-3001}"

    echo "  Install dir:   ${APP_DIR}"
    echo "  Version:       $(get_current_version | head -c 12)"
    echo "  Config:        ${ENV_FILE}"
    echo "  Data dir:      ${DATA_DIR}"
    echo "  Port:          ${port}"
    echo "  Service:       $(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo 'unknown')"
    echo "  Auto-upgrade:  $([ -f "$CRON_FILE" ] && echo 'enabled' || echo 'disabled')"
    echo "  Swap:          $(free -m | awk '/^Swap:/{print $2}')MB"
    echo "  Memory usage:  $(ps -o rss= -p "$(pgrep -f 'server/dist/index.js' | head -1)" 2>/dev/null | awk '{printf "%.0fMB\n", $1/1024}' || echo 'N/A')"
    echo ""

    if curl -sf "http://127.0.0.1:${port}/api/ping" > /dev/null 2>&1; then
        log_info "Health check: OK"
    else
        log_error "Health check: FAILED"
    fi
    echo ""
}

do_logs() {
    if ! is_installed; then
        log_error "FreeLLMAPI is not installed."
        exit 1
    fi

    if [[ "${1:-}" == "-f" ]]; then
        journalctl -u "$SERVICE_NAME" -f
    else
        journalctl -u "$SERVICE_NAME" -n 100 --no-pager
    fi
}

do_restart() {
    check_root
    if ! is_installed; then
        log_error "FreeLLMAPI is not installed."
        exit 1
    fi
    systemctl restart "$SERVICE_NAME"
    log_info "Service restarted"
    health_check
}

do_start() {
    check_root
    if ! is_installed; then
        log_error "FreeLLMAPI is not installed."
        exit 1
    fi
    systemctl start "$SERVICE_NAME"
    log_info "Service started"
    health_check
}

do_stop() {
    check_root
    if ! is_installed; then
        log_error "FreeLLMAPI is not installed."
        exit 1
    fi
    systemctl stop "$SERVICE_NAME"
    log_info "Service stopped"
}

do_check_update() {
    if ! is_installed; then
        exit 0
    fi

    cd "$APP_DIR"
    git fetch origin "$BRANCH" --quiet 2>/dev/null || exit 0

    local current latest
    current=$(git rev-parse HEAD)
    latest=$(git rev-parse "origin/${BRANCH}" 2>/dev/null || echo "$current")

    if [[ "$current" != "$latest" ]]; then
        local commit_count
        commit_count=$(git rev-list "${current}..${latest}" --count 2>/dev/null || echo "?")
        log_info "Update available: ${commit_count} new commits"
    fi
}

show_help() {
    cat << EOF

FreeLLMAPI Deployment Manager

Usage: $(basename "$0") <command> [options]

Commands:
  install          Install FreeLLMAPI
  upgrade          Upgrade to latest version
  uninstall        Remove FreeLLMAPI
  status           Show service status
  logs [-f]        View logs (-f to follow)
  start            Start service
  stop             Stop service
  restart          Restart service
  check-update     Check if update is available

Options:
  -y, --yes        Skip all confirmation prompts
  --auto           Non-interactive mode (for cron)
  -p, --port PORT  Set port (default: 3001)
  -h, --help       Show this help

Examples:
  # Fresh install with defaults
  $(basename "$0") install -y

  # Install with custom port
  $(basename "$0") install -y -p 8080

  # Upgrade interactively
  $(basename "$0") upgrade

  # One-line install
  curl -fsSL https://raw.githubusercontent.com/zczy-k/freellmapi/${BRANCH}/deploy.sh | sudo bash -s install -y

  # Complete removal including data
  $(basename "$0") uninstall -y

EOF
}

main() {
    if [[ $# -eq 0 ]]; then
        show_help
        exit 0
    fi

    local command=""
    local extra_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            install|upgrade|uninstall|status|logs|start|stop|restart|check-update)
                command="$1"
                shift
                ;;
            -y|--yes)
                YES_MODE=true
                shift
                ;;
            --auto)
                AUTO_MODE=true
                YES_MODE=true
                shift
                ;;
            -p|--port)
                CUSTOM_PORT="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -f)
                extra_args+=("-f")
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    case "$command" in
        install)
            do_install
            ;;
        upgrade)
            do_upgrade "$AUTO_MODE"
            ;;
        uninstall)
            do_uninstall
            ;;
        status)
            do_status
            ;;
        logs)
            do_logs "${extra_args[0]:-}"
            ;;
        start)
            do_start
            ;;
        stop)
            do_stop
            ;;
        restart)
            do_restart
            ;;
        check-update)
            do_check_update
            ;;
        "")
            show_help
            ;;
        *)
            log_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
