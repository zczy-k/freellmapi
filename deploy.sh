#!/usr/bin/env bash
set -euo pipefail

APP_NAME="freellmapi"
APP_DIR="/opt/freellmapi"
REPO_URL="https://github.com/zczy-k/freellmapi.git"
REPO_OWNER="zczy-k"
REPO_NAME="freellmapi"
BRANCH="main"
SERVICE_NAME="freellmapi"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CRON_FILE="/etc/cron.d/${SERVICE_NAME}-auto-upgrade"
LOG_FILE="/var/log/${SERVICE_NAME}-deploy.log"
DATA_DIR="${APP_DIR}/data"
ENV_FILE="${APP_DIR}/.env"
NODE_MAJOR=20
NVM_DIR="/opt/freellmapi-nvm"
BACKUP_DIR="/opt/freellmapi-backup"
DEPLOY_VERSION_FILE="${APP_DIR}/.deploy-version"
SWAP_FILE="${APP_DIR}.swap"
SWAP_FLAG="${APP_DIR}/.swap-created-by-deploy"
PREBUILT_RELEASE_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/prebuilt/freellmapi-release.tar.gz"
BUILD_MODE=false
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
log_step()    { echo -e "${CYAN}==>${NC} $*"; }
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

write_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

check_port_conflict() {
    local port="${1:-3001}"

    if ! command -v ss &>/dev/null && ! command -v netstat &>/dev/null; then
        log_warn "Cannot check port availability (ss/netstat not found)"
        return 0
    fi

    local listener=""
    if command -v ss &>/dev/null; then
        listener=$(ss -tlnp 2>/dev/null | grep -E ":${port}\s" | head -1 || true)
    elif command -v netstat &>/dev/null; then
        listener=$(netstat -tlnp 2>/dev/null | grep -E ":${port}\s" | head -1 || true)
    fi

    if [[ -n "$listener" ]]; then
        local proc_info
        proc_info=$(echo "$listener" | awk '{for(i=1;i<=NF;i++) if($i ~ /users/) print $i}')
        log_error "Port ${port} is already in use!"
        log_error "  ${listener}"
        if [[ -n "$proc_info" ]]; then
            log_error "  Process: ${proc_info}"
        fi
        log_error "Please stop the conflicting service or use a different port (-p PORT)."
        return 1
    fi

    log_info "Port ${port} is available"
    return 0
}

find_nvm_node_bin() {
    local found
    found=$(find "${NVM_DIR}/versions/node" -name node -path "*/bin/node" 2>/dev/null | head -1 || true)
    if [[ -n "$found" && -x "$found" ]]; then
        echo "$found"
        return 0
    fi
    return 1
}

find_nvm_npm_bin() {
    local node_bin
    node_bin=$(find_nvm_node_bin) || return 1
    local npm_path
    npm_path="$(dirname "$node_bin")/npm"
    if [[ -x "$npm_path" ]]; then
        echo "$npm_path"
        return 0
    fi
    return 1
}

get_node_bin() {
    local nvm_node
    nvm_node=$(find_nvm_node_bin) && { echo "$nvm_node"; return 0; }
    if command -v node &>/dev/null; then
        command -v node
        return 0
    fi
    echo ""
    return 1
}

get_npm_bin() {
    local nvm_npm
    nvm_npm=$(find_nvm_npm_bin) && { echo "$nvm_npm"; return 0; }
    if command -v npm &>/dev/null; then
        command -v npm
        return 0
    fi
    echo ""
    return 1
}

install_system_deps() {
    log_step "Installing system dependencies (only if missing)"
    local pkgs_to_install=()

    for cmd_pkg in "git:git" "curl:curl" "wget:wget" "python3:python3" "make:make" "g++:g++" "ca-certificates:ca-certificates"; do
        local cmd="${cmd_pkg%%:*}"
        local pkg="${cmd_pkg##*:}"
        if ! command -v "$cmd" &>/dev/null; then
            pkgs_to_install+=("$pkg")
        fi
    done

    if [[ ${#pkgs_to_install[@]} -eq 0 ]]; then
        log_info "All system dependencies already present"
        return 0
    fi

    log_info "Installing missing packages: ${pkgs_to_install[*]}"
    case "$OS_FAMILY" in
        debian)
            apt-get update -qq
            apt-get install -y -qq "${pkgs_to_install[@]}" > /dev/null 2>&1
            ;;
        rhel)
            if command -v dnf &>/dev/null; then
                dnf install -y -q "${pkgs_to_install[@]}"
            else
                yum install -y -q "${pkgs_to_install[@]}"
            fi
            ;;
        alpine)
            apk add --quiet "${pkgs_to_install[@]}"
            ;;
        *)
            log_warn "Unsupported OS. Please install manually: ${pkgs_to_install[*]}"
            ;;
    esac
    log_info "System dependencies installed"
}

install_system_deps_minimal() {
    log_step "Installing minimal system dependencies (prebuilt mode)"
    local pkgs_to_install=()

    for cmd_pkg in "curl:curl" "ca-certificates:ca-certificates"; do
        local cmd="${cmd_pkg%%:*}"
        local pkg="${cmd_pkg##*:}"
        if ! command -v "$cmd" &>/dev/null; then
            pkgs_to_install+=("$pkg")
        fi
    done

    if [[ ${#pkgs_to_install[@]} -eq 0 ]]; then
        log_info "All minimal dependencies already present"
        return 0
    fi

    log_info "Installing missing packages: ${pkgs_to_install[*]}"
    case "$OS_FAMILY" in
        debian)
            apt-get update -qq
            apt-get install -y -qq "${pkgs_to_install[@]}" > /dev/null 2>&1
            ;;
        rhel)
            if command -v dnf &>/dev/null; then
                dnf install -y -q "${pkgs_to_install[@]}"
            else
                yum install -y -q "${pkgs_to_install[@]}"
            fi
            ;;
        alpine)
            apk add --quiet "${pkgs_to_install[@]}"
            ;;
        *)
            log_warn "Unsupported OS. Please install manually: ${pkgs_to_install[*]}"
            ;;
    esac
    log_info "Minimal dependencies installed"
}

install_nodejs() {
    local nvm_node
    nvm_node=$(find_nvm_node_bin) || true
    if [[ -n "$nvm_node" ]]; then
        local nvm_node_version
        nvm_node_version=$("$nvm_node" -v)
        log_info "Node.js ${nvm_node_version} (nvm) already installed in ${NVM_DIR}"
        return 0
    fi

    if command -v node &>/dev/null; then
        local sys_node_version
        sys_node_version=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
        if [[ "$sys_node_version" -ge "$NODE_MAJOR" ]]; then
            log_info "System Node.js $(node -v) meets requirements, using it"
            log_warn "Note: Using system Node.js. If other projects need a different version, consider installing nvm separately."
            return 0
        else
            log_warn "System Node.js $(node -v) is too old (need >= ${NODE_MAJOR}), installing via nvm..."
        fi
    fi

    log_step "Installing Node.js ${NODE_MAJOR} via nvm (isolated, no system-wide impact)"

    mkdir -p "${NVM_DIR}"

    export NVM_DIR="${NVM_DIR}"
    if ! curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | \
        NVM_DIR="${NVM_DIR}" NVM_SOURCE="" PROFILE="/dev/null" bash 2>&1; then
        log_error "nvm install script failed"
        exit 1
    fi

    if [[ -s "${NVM_DIR}/nvm.sh" ]]; then
        . "${NVM_DIR}/nvm.sh"
    else
        log_error "nvm.sh not found at ${NVM_DIR}/nvm.sh"
        log_error "Checking alternative location ${NVM_DIR}/.nvm/nvm.sh..."
        if [[ -s "${NVM_DIR}/.nvm/nvm.sh" ]]; then
            NVM_DIR="${NVM_DIR}/.nvm"
            export NVM_DIR
            . "${NVM_DIR}/nvm.sh"
            log_warn "nvm installed to ${NVM_DIR} (nested .nvm), adjusting NVM_DIR"
        else
            log_error "nvm installation failed completely"
            exit 1
        fi
    fi

    log_info "Installing Node.js ${NODE_MAJOR} via nvm..."
    if ! nvm install "${NODE_MAJOR}" 2>&1; then
        log_error "nvm install ${NODE_MAJOR} failed"
        exit 1
    fi
    nvm alias default "${NODE_MAJOR}" > /dev/null 2>&1

    nvm_node=$(find_nvm_node_bin) || true
    if [[ -n "$nvm_node" ]]; then
        log_info "Node.js $("${nvm_node}" -v) installed (isolated at ${NVM_DIR})"
    else
        log_error "Node.js installation via nvm failed"
        exit 1
    fi
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
    if ! confirm "Add 1GB swap file at ${SWAP_FILE}?"; then
        return 0
    fi

    if [[ -f "$SWAP_FILE" ]]; then
        log_info "Swap file already exists at ${SWAP_FILE}, enabling..."
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

    touch "$SWAP_FLAG"
    log_info "Swap configured (1GB at ${SWAP_FILE})"
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
    if [[ -d "$APP_DIR/.git" ]]; then
        log_info "Repository already exists at ${APP_DIR}"
        cd "$APP_DIR"
        git reset --hard HEAD --quiet 2>/dev/null || true
        git clean -fd --quiet 2>/dev/null || true
        return 0
    fi

    if [[ -d "$APP_DIR" ]]; then
        log_warn "${APP_DIR} exists but is not a git repo, backing up..."
        mv "$APP_DIR" "${APP_DIR}.old.$$"
    fi

    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$APP_DIR" --quiet
    log_info "Repository cloned"
}

download_prebuilt() {
    log_step "Downloading prebuilt release"
    mkdir -p "$APP_DIR"

    local tmp_file
    tmp_file=$(mktemp)

    log_info "Downloading from ${PREBUILT_RELEASE_URL}"
    if ! curl -fsSL -o "$tmp_file" "$PREBUILT_RELEASE_URL" 2>&1; then
        log_error "Failed to download prebuilt release"
        log_error "This may mean the GitHub Actions workflow hasn't run yet."
        log_error "Try again later, or use --build mode to build locally."
        rm -f "$tmp_file"
        exit 1
    fi

    log_info "Extracting..."
    if ! tar -xzf "$tmp_file" -C "$APP_DIR" 2>&1; then
        log_error "Failed to extract prebuilt release"
        rm -f "$tmp_file"
        exit 1
    fi

    rm -f "$tmp_file"

    if [[ ! -d "${APP_DIR}/server-dist" ]]; then
        log_error "Prebuilt release is missing server-dist directory"
        exit 1
    fi

    mkdir -p "${APP_DIR}/server"
    mv "${APP_DIR}/server-dist" "${APP_DIR}/server/dist"

    if [[ -d "${APP_DIR}/client-dist" ]]; then
        mkdir -p "${APP_DIR}/client"
        mv "${APP_DIR}/client-dist" "${APP_DIR}/client/dist"
    fi

    if [[ -f "${APP_DIR}/server-package.json" ]]; then
        mv "${APP_DIR}/server-package.json" "${APP_DIR}/server/package.json"
    fi
    if [[ -f "${APP_DIR}/client-package.json" ]]; then
        mv "${APP_DIR}/client-package.json" "${APP_DIR}/client/package.json"
    fi

    log_info "Prebuilt release downloaded and extracted"
}

install_npm_deps() {
    log_step "Installing npm dependencies (including devDependencies for build)"
    cd "$APP_DIR"

    local npm_cmd
    npm_cmd=$(get_npm_bin)
    if [[ -z "$npm_cmd" ]]; then
        log_error "npm not found"
        exit 1
    fi

    local node_dir
    node_dir=$(dirname "$(get_node_bin)")
    export PATH="${node_dir}:${PATH}"

    log_info "Running: ${npm_cmd} install"
    if ! $npm_cmd install --no-audit --no-fund 2>&1; then
        log_error "npm install failed (see output above)"
        exit 1
    fi

    log_info "npm dependencies installed"
}

build_app() {
    log_step "Building application"
    cd "$APP_DIR"

    local node_cmd
    node_cmd=$(get_node_bin)
    if [[ -z "$node_cmd" ]]; then
        log_error "node not found"
        exit 1
    fi

    local npm_cmd
    npm_cmd=$(get_npm_bin)

    local node_dir
    node_dir=$(dirname "$node_cmd")
    export PATH="${node_dir}:${PATH}"
    export NODE_OPTIONS="--max-old-space-size=512"

    log_info "Running: ${npm_cmd} run build"
    if ! $npm_cmd run build 2>&1; then
        log_error "Build failed (see output above)"
        exit 1
    fi

    log_info "Application built"
}

prune_dev_deps() {
    log_step "Pruning devDependencies to save space"
    cd "$APP_DIR"

    local npm_cmd
    npm_cmd=$(get_npm_bin)
    if [[ -z "$npm_cmd" ]]; then
        return 0
    fi

    local node_dir
    node_dir=$(dirname "$(get_node_bin)")
    export PATH="${node_dir}:${PATH}"

    $npm_cmd prune --omit=dev > /dev/null 2>&1 || true
    log_info "DevDependencies pruned"
}

generate_encryption_key() {
    if [[ -f "$ENV_FILE" ]]; then
        existing_key=$(grep -E "^ENCRYPTION_KEY=" "$ENV_FILE" | cut -d'=' -f2)
        if [[ -n "$existing_key" && "$existing_key" != "your-64-char-hex-key-here" ]]; then
            log_info "ENCRYPTION_KEY already configured, keeping existing"
            return 0
        fi
    fi

    local node_cmd
    node_cmd=$(get_node_bin)
    if [[ -z "$node_cmd" ]]; then
        log_error "node not found for key generation"
        exit 1
    fi

    local key
    key=$($node_cmd -e "console.log(require('crypto').randomBytes(32).toString('hex'))")

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

    check_port_conflict "$port" || exit 1

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

    local node_path
    node_path=$(get_node_bin)
    if [[ -z "$node_path" ]]; then
        log_error "Cannot find node binary for systemd service"
        exit 1
    fi

    local node_dir
    node_dir=$(dirname "$node_path")

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=FreeLLMAPI - Free LLM API Proxy
After=network.target
Conflicts=

[Service]
Type=simple
User=${APP_NAME}
Group=${APP_NAME}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
Environment=NODE_ENV=production
Environment=PATH=${node_dir}:/usr/local/bin:/usr/bin:/bin
ExecStart=${node_path} ${APP_DIR}/server/dist/index.js
Restart=on-failure
RestartSec=5

MemoryMax=512M
MemoryHigh=400M
CPUQuota=50%

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectClock=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
PrivateDevices=true

CapabilityBoundingSet=
AmbientCapabilities=

ReadWritePaths=${APP_DIR}/data ${APP_DIR}/.env
ReadOnlyPaths=${APP_DIR}/server ${APP_DIR}/client ${APP_DIR}/shared ${APP_DIR}/node_modules ${NVM_DIR}

SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" > /dev/null 2>&1
    log_info "systemd service created (sandboxed, isolated)"
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
    if [[ -d "$NVM_DIR" ]]; then
        chown -R root:root "$NVM_DIR"
    fi
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

cleanup_residual() {
    local found_residual=false

    if [[ -d "$APP_DIR" ]] || [[ -d "$NVM_DIR" ]] || [[ -d "$BACKUP_DIR" ]] || \
       [[ -f "$SERVICE_FILE" ]] || [[ -f "$CRON_FILE" ]] || [[ -f "$LOG_FILE" ]] || \
       [[ -f "$DEPLOY_VERSION_FILE" ]] || [[ -f "$SWAP_FLAG" ]] || \
       id "$APP_NAME" &>/dev/null; then
        found_residual=true
    fi

    if [[ "$found_residual" == "false" ]]; then
        return 0
    fi

    log_step "Cleaning up residual files from previous installation"
    write_log "Cleaning up residual files"

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true

    rm -rf "$APP_DIR"
    rm -rf "$NVM_DIR"
    rm -rf "$BACKUP_DIR"
    rm -f "$SERVICE_FILE"
    rm -f "$CRON_FILE"
    rm -f "$LOG_FILE"
    rm -f "$DEPLOY_VERSION_FILE"
    rm -f "$SWAP_FLAG"

    if [[ -f "$SWAP_FILE" ]] && swapon --show 2>/dev/null | grep -q "$SWAP_FILE"; then
        swapoff "$SWAP_FILE" 2>/dev/null || true
    fi
    rm -f "$SWAP_FILE"
    sed -i "\|${SWAP_FILE}|d" /etc/fstab 2>/dev/null || true

    systemctl daemon-reload 2>/dev/null || true

    if id "$APP_NAME" &>/dev/null; then
        userdel "$APP_NAME" 2>/dev/null || true
    fi

    log_info "Residual files cleaned up"
}

do_install() {
    log_step "Installing FreeLLMAPI"
    write_log "Starting installation"

    check_root
    detect_os

    if is_installed; then
        log_warn "FreeLLMAPI is already installed and running"
        if [[ "$YES_MODE" == "true" ]] || confirm "Reinstall?"; then
            do_uninstall_internal false
        else
            log_info "Aborted"
            exit 0
        fi
    fi

    cleanup_residual

    local port="${CUSTOM_PORT:-3001}"
    check_port_conflict "$port" || exit 1

    if [[ "$BUILD_MODE" == "true" ]]; then
        log_info "Build mode: LOCAL (building on server)"
        install_system_deps
        create_user
        clone_repo
        install_nodejs
        setup_swap
        install_npm_deps
        build_app
        prune_dev_deps
    else
        log_info "Build mode: PREBUILT (downloading from GitHub Actions)"
        install_system_deps_minimal
        create_user
        download_prebuilt
        install_nodejs
        setup_swap
    fi

    create_env_file
    mkdir -p "${DATA_DIR}"
    set_permissions
    create_systemd_service
    setup_auto_upgrade
    save_version

    log_step "Starting FreeLLMAPI"
    systemctl start "$SERVICE_NAME"

    if health_check; then
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
        log_info "  Node.js:    $(get_node_bin)"
        log_info "  Logs:       journalctl -u ${SERVICE_NAME} -f"
        log_info ""
        log_warn "  IMPORTANT: Make sure port ${port} is open in your firewall!"
        log_warn ""
        log_warn "  Firewall commands (choose one):"
        if command -v ufw &>/dev/null; then
            log_warn "    ufw allow ${port}/tcp"
        fi
        if command -v firewall-cmd &>/dev/null; then
            log_warn "    firewall-cmd --permanent --add-port=${port}/tcp && firewall-cmd --reload"
        fi
        if command -v iptables &>/dev/null; then
            log_warn "    iptables -A INPUT -p tcp --dport ${port} -j ACCEPT"
        fi
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

    if [[ "$BUILD_MODE" == "true" ]]; then
        do_upgrade_build "$auto_flag"
    else
        do_upgrade_prebuilt "$auto_flag"
    fi
}

do_upgrade_prebuilt() {
    local auto_flag="${1:-false}"

    log_step "Checking for prebuilt updates"
    write_log "Checking for prebuilt updates"

    local current
    current=$(cat "$DEPLOY_VERSION_FILE" 2>/dev/null || echo "unknown")

    log_info "Current version: ${current}"
    log_info "Downloading latest prebuilt release..."

    local tmp_file
    tmp_file=$(mktemp)

    if ! curl -fsSL -o "$tmp_file" "$PREBUILT_RELEASE_URL" 2>&1; then
        if [[ "$auto_flag" != "true" ]]; then
            log_error "Failed to download prebuilt release"
        fi
        rm -f "$tmp_file"
        exit 1
    fi

    local new_hash
    new_hash=$(sha256sum "$tmp_file" | cut -d' ' -f1)

    if [[ -f "${APP_DIR}/.release-hash" ]]; then
        local old_hash
        old_hash=$(cat "${APP_DIR}/.release-hash")
        if [[ "$old_hash" == "$new_hash" ]]; then
            if [[ "$auto_flag" != "true" ]]; then
                log_info "Already up to date (same release)"
            fi
            rm -f "$tmp_file"
            exit 0
        fi
    fi

    if [[ "$auto_flag" != "true" && "$YES_MODE" == "false" ]]; then
        if ! confirm "New version available. Proceed with upgrade?"; then
            log_info "Upgrade cancelled"
            rm -f "$tmp_file"
            exit 0
        fi
    fi

    log_step "Backing up current version"
    rm -rf "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    cp -a "${APP_DIR}/server" "${BACKUP_DIR}/" 2>/dev/null || true
    cp -a "${APP_DIR}/client" "${BACKUP_DIR}/" 2>/dev/null || true
    cp -a "${APP_DIR}/shared" "${BACKUP_DIR}/" 2>/dev/null || true
    cp -a "${APP_DIR}/node_modules" "${BACKUP_DIR}/" 2>/dev/null || true
    cp -a "${APP_DIR}/package.json" "${BACKUP_DIR}/" 2>/dev/null || true
    cp -a "$ENV_FILE" "${BACKUP_DIR}/.env.backup"
    cp -a "$DEPLOY_VERSION_FILE" "${BACKUP_DIR}/.deploy-version.backup" 2>/dev/null || true
    log_info "Backup saved to ${BACKUP_DIR}"

    log_step "Upgrading FreeLLMAPI (prebuilt)"
    write_log "Starting prebuilt upgrade"

    local upgrade_failed=false

    rm -rf "${APP_DIR}/server" "${APP_DIR}/client" "${APP_DIR}/shared" "${APP_DIR}/node_modules"

    if ! tar -xzf "$tmp_file" -C "$APP_DIR" 2>&1; then
        log_error "Failed to extract prebuilt release"
        upgrade_failed=true
    fi
    rm -f "$tmp_file"

    if [[ "$upgrade_failed" == "false" ]]; then
        mkdir -p "${APP_DIR}/server"
        mv "${APP_DIR}/server-dist" "${APP_DIR}/server/dist"
        if [[ -d "${APP_DIR}/client-dist" ]]; then
            mkdir -p "${APP_DIR}/client"
            mv "${APP_DIR}/client-dist" "${APP_DIR}/client/dist"
        fi
        if [[ -f "${APP_DIR}/server-package.json" ]]; then
            mv "${APP_DIR}/server-package.json" "${APP_DIR}/server/package.json"
        fi
        if [[ -f "${APP_DIR}/client-package.json" ]]; then
            mv "${APP_DIR}/client-package.json" "${APP_DIR}/client/package.json"
        fi

        echo "$new_hash" > "${APP_DIR}/.release-hash"

        set_permissions
        log_step "Restarting service"
        systemctl restart "$SERVICE_NAME"

        if health_check; then
            rm -rf "$BACKUP_DIR"
            log_info "==========================================="
            log_info " Upgrade successful! (prebuilt)"
            log_info "==========================================="
            write_log "Prebuilt upgrade completed"
        else
            upgrade_failed=true
        fi
    fi

    if [[ "$upgrade_failed" == "true" ]]; then
        log_error "Upgrade failed! Rolling back..."
        write_log "Upgrade failed, rolling back"

        systemctl stop "$SERVICE_NAME" 2>/dev/null || true

        rm -rf "${APP_DIR}/server" "${APP_DIR}/client" "${APP_DIR}/shared" "${APP_DIR}/node_modules"
        cp -a "${BACKUP_DIR}/server" "${APP_DIR}/server" 2>/dev/null || true
        cp -a "${BACKUP_DIR}/client" "${APP_DIR}/client" 2>/dev/null || true
        cp -a "${BACKUP_DIR}/shared" "${APP_DIR}/shared" 2>/dev/null || true
        cp -a "${BACKUP_DIR}/node_modules" "${APP_DIR}/node_modules" 2>/dev/null || true
        if [[ -f "${BACKUP_DIR}/.env.backup" ]]; then
            cp -a "${BACKUP_DIR}/.env.backup" "$ENV_FILE"
        fi

        set_permissions
        systemctl start "$SERVICE_NAME"

        sleep 3
        local port
        port=$(grep -E '^PORT=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "3001")
        if curl -sf "http://127.0.0.1:${port:-3001}/api/ping" > /dev/null 2>&1; then
            log_info "Rollback successful, service restored"
        else
            log_error "Rollback also failed! Manual intervention required."
            log_error "Backup is at: ${BACKUP_DIR}"
        fi
        exit 1
    fi
}

do_upgrade_build() {
    local auto_flag="${1:-false}"

    log_step "Checking for updates (build mode)"
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
    mkdir -p "$BACKUP_DIR"
    cp -a "${APP_DIR}/server" "${BACKUP_DIR}/" 2>/dev/null || true
    cp -a "${APP_DIR}/client" "${BACKUP_DIR}/" 2>/dev/null || true
    cp -a "${APP_DIR}/shared" "${BACKUP_DIR}/" 2>/dev/null || true
    cp -a "${APP_DIR}/node_modules" "${BACKUP_DIR}/" 2>/dev/null || true
    cp -a "${APP_DIR}/package-lock.json" "${BACKUP_DIR}/" 2>/dev/null || true
    cp -a "${APP_DIR}/package.json" "${BACKUP_DIR}/" 2>/dev/null || true
    cp -a "$ENV_FILE" "${BACKUP_DIR}/.env.backup"
    cp -a "$DEPLOY_VERSION_FILE" "${BACKUP_DIR}/.deploy-version.backup" 2>/dev/null || true
    log_info "Backup saved to ${BACKUP_DIR}"

    log_step "Upgrading FreeLLMAPI (build mode)"
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
        prune_dev_deps || true
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

        rm -rf "${APP_DIR}/server" "${APP_DIR}/client" "${APP_DIR}/shared" "${APP_DIR}/node_modules"
        cp -a "${BACKUP_DIR}/server" "${APP_DIR}/server" 2>/dev/null || true
        cp -a "${BACKUP_DIR}/client" "${APP_DIR}/client" 2>/dev/null || true
        cp -a "${BACKUP_DIR}/shared" "${APP_DIR}/shared" 2>/dev/null || true
        cp -a "${BACKUP_DIR}/node_modules" "${APP_DIR}/node_modules" 2>/dev/null || true
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

    local port="3001"
    if [[ -f "$ENV_FILE" ]]; then
        port=$(grep -E "^PORT=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "3001")
        port="${port:-3001}"
    fi

    log_step "Removing application"
    rm -rf "$APP_DIR"

    log_step "Removing nvm Node.js at ${NVM_DIR}"
    rm -rf "$NVM_DIR"

    log_step "Removing backup"
    rm -rf "$BACKUP_DIR"

    if [[ "$purge" == "true" ]]; then
        log_step "Purging data directory"
        rm -rf "$DATA_DIR"
        rm -f "$DEPLOY_VERSION_FILE"

        if [[ -f "$SWAP_FLAG" ]]; then
            log_step "Removing swap (created by this script)"
            if [[ -f "$SWAP_FILE" ]] && swapon --show | grep -q "$SWAP_FILE"; then
                swapoff "$SWAP_FILE" 2>/dev/null || true
            fi
            rm -f "$SWAP_FILE"
            sed -i "\|${SWAP_FILE}|d" /etc/fstab 2>/dev/null || true
            rm -f "$SWAP_FLAG"
        else
            log_info "Swap was not created by this script, skipping"
        fi

        log_step "Removing user"
        userdel "$APP_NAME" 2>/dev/null || true

        log_warn "Firewall: You may want to close port ${port}:"
        if command -v ufw &>/dev/null; then
            log_warn "    ufw deny ${port}/tcp"
        fi
        if command -v firewall-cmd &>/dev/null; then
            log_warn "    firewall-cmd --permanent --remove-port=${port}/tcp && firewall-cmd --reload"
        fi
        if command -v iptables &>/dev/null; then
            log_warn "    iptables -D INPUT -p tcp --dport ${port} -j ACCEPT"
        fi
    else
        if [[ -f "$SWAP_FLAG" ]]; then
            log_info "Swap file at ${SWAP_FILE} preserved (use purge to remove)"
        fi
        if [[ -d "$DATA_DIR" ]]; then
            log_info "Data directory at ${DATA_DIR} preserved"
        fi
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
    echo "    1) Remove application only (keep data, .env, swap)"
    echo "    2) Remove everything including data, .env, swap, user, nvm Node.js"
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

    local node_path
    node_path=$(get_node_bin)
    local node_version="N/A"
    if [[ -n "$node_path" ]]; then
        node_version=$("$node_path" -v 2>/dev/null || echo "N/A")
    fi

    echo "  Install dir:   ${APP_DIR}"
    echo "  Version:       $(get_current_version | head -c 12)"
    echo "  Config:        ${ENV_FILE}"
    echo "  Data dir:      ${DATA_DIR}"
    echo "  Port:          ${port}"
    echo "  Node.js:       ${node_version} (${node_path:-N/A})"
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
  --build          Build locally on server instead of downloading prebuilt
  -p, --port PORT  Set port (default: 3001)
  -h, --help       Show this help

Isolation features:
  - Node.js installed via nvm (isolated, no system-wide impact)
  - Dedicated system user (freellmapi)
  - systemd sandbox (no new privs, private /tmp, read-only filesystems)
  - Memory limit 512MB, CPU quota 50%
  - Port conflict detection before install
  - Project-specific swap file (won't touch existing swap)

Examples:
  # Fresh install with defaults
  $(basename "$0") install -y

  # Install with custom port
  $(basename "$0") install -y -p 8080

  # One-line install (prebuilt, recommended for low-spec servers)
  curl -fsSL https://raw.githubusercontent.com/zczy-k/freellmapi/${BRANCH}/deploy.sh | sudo bash -s install -y

  # Install with local build (for servers with enough RAM)
  $(basename "$0") install -y --build

  # Upgrade interactively
  $(basename "$0") upgrade

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
            --build)
                BUILD_MODE=true
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
