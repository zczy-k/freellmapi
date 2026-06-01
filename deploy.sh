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
DATA_DIR="${APP_DIR}/server/data"
ENV_FILE="${APP_DIR}/.env"
NODE_MAJOR=20
NVM_DIR="/opt/freellmapi-nvm"
BACKUP_DIR="/opt/freellmapi-backup"
DEPLOY_VERSION_FILE="${APP_DIR}/.deploy-version"
SWAP_FILE="${APP_DIR}.swap"
SWAP_FLAG="${APP_DIR}/.swap-created-by-deploy"
PREBUILT_RELEASE_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/dist/freellmapi-release.tar.gz"
BUILD_MODE=false
AUTO_MODE=false
YES_MODE=false
CUSTOM_PORT=""
DOMAIN_FILE="${APP_DIR}/.domain"
NGINX_CONF_FILE="/etc/nginx/sites-available/freellmapi"
NGINX_LINK_FILE="/etc/nginx/sites-enabled/freellmapi"

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
    local prompt="$1 [y/N]："
    read -r -p "$prompt" response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以 root 身份运行。"
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
    log_info "检测到操作系统：${OS_ID} ${OS_VERSION} (${OS_FAMILY})"
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
        log_warn "无法检查端口可用性（未找到 ss/netstat）"
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
        log_error "端口 ${port} 已被占用！"
        log_error "  ${listener}"
        if [[ -n "$proc_info" ]]; then
            log_error "  进程：${proc_info}"
        fi
        log_error "请停止冲突的服务或使用其他端口 (-p PORT)。"
        return 1
    fi

    log_info "端口 ${port} 可用"
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
    log_step "安装系统依赖（仅在缺失时）"
    local pkgs_to_install=()

    for cmd_pkg in "git:git" "curl:curl" "wget:wget" "python3:python3" "make:make" "g++:g++" "ca-certificates:ca-certificates"; do
        local cmd="${cmd_pkg%%:*}"
        local pkg="${cmd_pkg##*:}"
        if ! command -v "$cmd" &>/dev/null; then
            pkgs_to_install+=("$pkg")
        fi
    done

    if [[ ${#pkgs_to_install[@]} -eq 0 ]]; then
        log_info "所有系统依赖已存在"
        return 0
    fi

    log_info "安装缺失的软件包：${pkgs_to_install[*]}"
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
            log_warn "不支持的操作系统，请手动安装：${pkgs_to_install[*]}"
            ;;
    esac
    log_info "系统依赖已安装"
}

install_system_deps_minimal() {
    log_step "安装最小系统依赖（预编译模式）"
    local pkgs_to_install=()

    for cmd_pkg in "curl:curl" "ca-certificates:ca-certificates"; do
        local cmd="${cmd_pkg%%:*}"
        local pkg="${cmd_pkg##*:}"
        if ! command -v "$cmd" &>/dev/null; then
            pkgs_to_install+=("$pkg")
        fi
    done

    if [[ ${#pkgs_to_install[@]} -eq 0 ]]; then
        log_info "所有最小依赖已存在"
        return 0
    fi

    log_info "安装缺失的软件包：${pkgs_to_install[*]}"
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
            log_warn "不支持的操作系统，请手动安装：${pkgs_to_install[*]}"
            ;;
    esac
    log_info "最小依赖已安装"
}

install_nodejs() {
    local nvm_node
    nvm_node=$(find_nvm_node_bin) || true
    if [[ -n "$nvm_node" ]]; then
        local nvm_node_version
        nvm_node_version=$("$nvm_node" -v)
        log_info "Node.js ${nvm_node_version} (nvm) 已安装在 ${NVM_DIR}"
        return 0
    fi

    if command -v node &>/dev/null; then
        local sys_node_version
        sys_node_version=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
        if [[ "$sys_node_version" -ge "$NODE_MAJOR" ]]; then
            log_info "系统 Node.js $(node -v) 满足要求，使用系统版本"
            log_warn "注意：正在使用系统 Node.js。如果其他项目需要不同版本，建议单独安装 nvm。"
            return 0
        else
            log_warn "系统 Node.js $(node -v) 版本过低（需要 >= ${NODE_MAJOR}），通过 nvm 安装..."
        fi
    fi

    log_step "通过 nvm 安装 Node.js ${NODE_MAJOR}（隔离安装，不影响系统）"

    mkdir -p "${NVM_DIR}"

    export NVM_DIR="${NVM_DIR}"
    if ! curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | \
        NVM_DIR="${NVM_DIR}" NVM_SOURCE="" PROFILE="/dev/null" bash 2>&1 | grep -v 'Profile not found\|Create one of them\|Append the following\|export NVM_DIR\|Close and reopen\|This loads nvm' ; then
        log_error "nvm 安装脚本执行失败"
        exit 1
    fi

    if [[ -s "${NVM_DIR}/nvm.sh" ]]; then
        . "${NVM_DIR}/nvm.sh"
    else
        log_error "在 ${NVM_DIR}/nvm.sh 未找到 nvm.sh"
        log_error "检查备用位置 ${NVM_DIR}/.nvm/nvm.sh..."
        if [[ -s "${NVM_DIR}/.nvm/nvm.sh" ]]; then
            NVM_DIR="${NVM_DIR}/.nvm"
            export NVM_DIR
            . "${NVM_DIR}/nvm.sh"
            log_warn "nvm 安装到 ${NVM_DIR}（嵌套 .nvm），正在调整 NVM_DIR"
        else
            log_error "nvm 安装完全失败"
            exit 1
        fi
    fi

    log_info "正在通过 nvm 安装 Node.js ${NODE_MAJOR}..."
    if ! nvm install "${NODE_MAJOR}" 2>&1; then
        log_error "nvm install ${NODE_MAJOR} 失败"
        exit 1
    fi
    nvm alias default "${NODE_MAJOR}" > /dev/null 2>&1

    nvm_node=$(find_nvm_node_bin) || true
    if [[ -n "$nvm_node" ]]; then
        log_info "Node.js $("${nvm_node}" -v) 已安装（隔离在 ${NVM_DIR}）"
    else
        log_error "通过 nvm 安装 Node.js 失败"
        exit 1
    fi
}

setup_swap() {
    local total_swap
    total_swap=$(free -m | awk '/^Swap:/{print $2}')

    if [[ "$total_swap" -ge 1024 ]]; then
        log_info "Swap 已配置（${total_swap}MB），跳过"
        return 0
    fi

    local total_mem
    total_mem=$(free -m | awk '/^Mem:/{print $2}')

    if [[ "$total_mem" -gt 2048 ]]; then
        return 0
    fi

    log_step "设置 Swap（推荐用于 ${total_mem}MB 内存）"
    if ! confirm "在 ${SWAP_FILE} 创建 1GB Swap 文件？"; then
        return 0
    fi

    if [[ -f "$SWAP_FILE" ]]; then
        log_info "Swap 文件已存在于 ${SWAP_FILE}，正在启用..."
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
    log_info "Swap 已配置（1GB，位于 ${SWAP_FILE}）"
}

create_user() {
    if id "$APP_NAME" &>/dev/null; then
        log_info "用户 '$APP_NAME' 已存在"
        return 0
    fi
    useradd --system --no-create-home --shell /usr/sbin/nologin "$APP_NAME" 2>/dev/null || \
    useradd --system --no-create-home --shell /bin/false "$APP_NAME" 2>/dev/null || true
    log_info "用户 '$APP_NAME' 已创建"
}

clone_repo() {
    log_step "克隆仓库"
    if [[ -d "$APP_DIR/.git" ]]; then
        log_info "仓库已存在于 ${APP_DIR}"
        cd "$APP_DIR"
        git reset --hard HEAD --quiet 2>/dev/null || true
        git clean -fd --quiet 2>/dev/null || true
        return 0
    fi

    if [[ -d "$APP_DIR" ]]; then
        log_warn "${APP_DIR} 已存在但不是 git 仓库，正在备份..."
        mv "$APP_DIR" "${APP_DIR}.old.$$"
    fi

    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$APP_DIR" --quiet
    log_info "仓库已克隆"
}

download_prebuilt() {
    log_step "下载预编译版本"
    mkdir -p "$APP_DIR"

    local tmp_file
    tmp_file=$(mktemp)

    log_info "正在从 ${PREBUILT_RELEASE_URL} 下载"
    if ! curl -fsSL -o "$tmp_file" "$PREBUILT_RELEASE_URL" 2>&1; then
        log_error "下载预编译版本失败"
        log_error "这可能意味着 GitHub Actions 工作流尚未运行。"
        log_error "请稍后重试，或使用 --build 模式在本地编译。"
        rm -f "$tmp_file"
        exit 1
    fi

    log_info "正在解压..."
    if ! tar -xzf "$tmp_file" -C "$APP_DIR" 2>&1; then
        log_error "解压预编译版本失败"
        rm -f "$tmp_file"
        exit 1
    fi

    rm -f "$tmp_file"

    if [[ ! -d "${APP_DIR}/server-dist" ]]; then
        log_error "预编译版本缺少 server-dist 目录"
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

    log_info "预编译版本已下载并解压"
}

install_npm_deps() {
    log_step "安装 npm 依赖（包含 devDependencies 用于编译）"
    cd "$APP_DIR"

    local npm_cmd
    npm_cmd=$(get_npm_bin)
    if [[ -z "$npm_cmd" ]]; then
        log_error "未找到 npm"
        exit 1
    fi

    local node_dir
    node_dir=$(dirname "$(get_node_bin)")
    export PATH="${node_dir}:${PATH}"

    log_info "正在执行：${npm_cmd} install"
    if ! $npm_cmd install --no-audit --no-fund 2>&1; then
        log_error "npm install 失败（请查看上方输出）"
        exit 1
    fi

    log_info "npm 依赖已安装"
}

build_app() {
    log_step "编译应用"
    cd "$APP_DIR"

    local node_cmd
    node_cmd=$(get_node_bin)
    if [[ -z "$node_cmd" ]]; then
        log_error "未找到 node"
        exit 1
    fi

    local npm_cmd
    npm_cmd=$(get_npm_bin)

    local node_dir
    node_dir=$(dirname "$node_cmd")
    export PATH="${node_dir}:${PATH}"
    export NODE_OPTIONS="--max-old-space-size=512"

    log_info "正在执行：${npm_cmd} run build"
    if ! $npm_cmd run build 2>&1; then
        log_error "编译失败（请查看上方输出）"
        exit 1
    fi

    log_info "应用已编译"
}

prune_dev_deps() {
    log_step "清理 devDependencies 以节省空间"
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
    log_info "devDependencies 已清理"
}

generate_encryption_key() {
    if [[ -f "$ENV_FILE" ]]; then
        existing_key=$(grep -E "^ENCRYPTION_KEY=" "$ENV_FILE" | cut -d'=' -f2)
        if [[ -n "$existing_key" && "$existing_key" != "your-64-char-hex-key-here" ]]; then
            log_info "ENCRYPTION_KEY 已配置，保留现有密钥"
            return 0
        fi
    fi

    local node_cmd
    node_cmd=$(get_node_bin)
    if [[ -z "$node_cmd" ]]; then
        log_error "未找到 node，无法生成密钥"
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
    log_info "ENCRYPTION_KEY 已生成并保存到 .env"
}

create_env_file() {
    if [[ -f "$ENV_FILE" ]]; then
        log_info ".env 文件已存在，按需更新..."
        generate_encryption_key
        return 0
    fi

    log_step "创建 .env 配置"
    local port="${CUSTOM_PORT:-3001}"

    if [[ "$AUTO_MODE" == "false" && "$YES_MODE" == "false" ]]; then
        read -r -p "    端口 [${port}]：" input_port
        port="${input_port:-$port}"
    fi

    check_port_conflict "$port" || exit 1

    cat > "$ENV_FILE" << EOF
ENCRYPTION_KEY=your-64-char-hex-key-here
PORT=${port}
EOF
    chmod 600 "$ENV_FILE"
    generate_encryption_key
    log_info ".env 已创建（端口=${port}）"
}

create_systemd_service() {
    log_step "创建 systemd 服务"

    local port="${CUSTOM_PORT:-3001}"
    if [[ -f "$ENV_FILE" ]]; then
        port=$(grep -E "^PORT=" "$ENV_FILE" | cut -d'=' -f2 || echo "3001")
        port="${port:-3001}"
    fi

    local node_path
    node_path=$(get_node_bin)
    if [[ -z "$node_path" ]]; then
        log_error "找不到 node 二进制文件，无法创建 systemd 服务"
        exit 1
    fi

    local node_dir
    node_dir=$(dirname "$node_path")

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=FreeLLMAPI - 免费 LLM API 代理
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
RestrictRealtime=true
PrivateDevices=true

CapabilityBoundingSet=
AmbientCapabilities=

ReadWritePaths=${APP_DIR}

SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" > /dev/null 2>&1
    log_info "systemd 服务已创建（沙箱隔离）"
}

setup_auto_upgrade() {
    log_step "设置自动升级定时任务"

    if [[ "$AUTO_MODE" == "false" && "$YES_MODE" == "false" ]]; then
        if ! confirm "启用自动升级检查（每6小时）？"; then
            log_info "自动升级已禁用"
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

    log_info "自动升级定时任务已配置（每6小时）"
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

    local max_retries=15
    local retry=0
    local start_delay=3

    sleep "$start_delay"

    while [[ $retry -lt $max_retries ]]; do
        if curl -sf "http://127.0.0.1:${port}/api/ping" > /dev/null 2>&1; then
            log_info "健康检查通过"
            return 0
        fi
        retry=$((retry + 1))
        if [[ $retry -lt $max_retries ]]; then
            sleep 2
        fi
    done

    log_error "健康检查在 ${max_retries} 次重试后失败"
    log_error "服务状态：$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo '未知')"
    log_error "最近 20 条日志："
    journalctl -u "$SERVICE_NAME" -n 20 --no-pager 2>&1 | while IFS= read -r line; do
        log_error "  $line"
    done
    return 1
}

save_version() {
    if [[ -d "$APP_DIR/.git" ]]; then
        cd "$APP_DIR"
        git rev-parse HEAD > "$DEPLOY_VERSION_FILE" 2>/dev/null || echo "unknown" > "$DEPLOY_VERSION_FILE"
    elif [[ -f "${APP_DIR}/.release-hash" ]]; then
        cat "${APP_DIR}/.release-hash" > "$DEPLOY_VERSION_FILE"
    else
        echo "unknown" > "$DEPLOY_VERSION_FILE"
    fi
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

    log_step "清理上次安装的残留文件"
    write_log "清理残留文件"

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

    log_info "残留文件已清理"
}

do_install() {
    log_step "正在安装 FreeLLMAPI"
    write_log "开始安装"

    check_root
    detect_os

    if is_installed; then
        log_warn "FreeLLMAPI 已安装并运行中"
        if [[ "$YES_MODE" == "true" ]] || confirm "重新安装？"; then
            do_uninstall_internal false
        else
            log_info "已取消"
            exit 0
        fi
    fi

    cleanup_residual

    local port="${CUSTOM_PORT:-3001}"
    check_port_conflict "$port" || exit 1

    if [[ "$BUILD_MODE" == "true" ]]; then
        log_info "编译模式：本地（在服务器上编译）"
        install_system_deps
        create_user
        clone_repo
        install_nodejs
        setup_swap
        install_npm_deps
        build_app
        prune_dev_deps
    else
        log_info "编译模式：预编译（从 GitHub Actions 下载）"
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

    log_step "正在启动 FreeLLMAPI"
    systemctl start "$SERVICE_NAME"

    if health_check; then
        port=$(grep -E "^PORT=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "3001")
        port="${port:-3001}"
        echo ""
        log_info "==========================================="
        log_info " FreeLLMAPI 安装成功！"
        log_info "==========================================="
        log_info ""
        log_info "  控制面板：   http://<your-ip>:${port}"
        log_info "  API：        http://<your-ip>:${port}/v1/chat/completions"
        log_info "  配置文件：   ${ENV_FILE}"
        log_info "  数据目录：   ${DATA_DIR}"
        log_info "  Node.js：    $(get_node_bin)"
        log_info "  日志：       journalctl -u ${SERVICE_NAME} -f"
        log_info ""
        log_warn "  重要：请确保端口 ${port} 在防火墙中已开放！"
        log_warn ""
        log_warn "  防火墙命令（选择其一）："
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
        log_info "  管理命令："
        log_info "    ${0} status      - 查看状态"
        log_info "    ${0} logs        - 查看日志"
        log_info "    ${0} restart     - 重启服务"
        log_info "    ${0} upgrade     - 升级到最新版"
        log_info "    ${0} uninstall   - 卸载所有内容"
        log_info ""
        write_log "安装成功完成"
    else
        log_error "安装已完成但健康检查失败。"
        log_error "查看日志：journalctl -u ${SERVICE_NAME} -n 50"
        exit 1
    fi
}

do_upgrade() {
    local auto_flag="${1:-false}"

    check_root

    if ! is_installed; then
        log_error "FreeLLMAPI 未安装。请先运行 '${0} install'。"
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

    log_step "检查预编译更新"
    write_log "检查预编译更新"

    local current
    current=$(cat "$DEPLOY_VERSION_FILE" 2>/dev/null || echo "unknown")

    log_info "当前版本：${current}"
    log_info "正在下载最新预编译版本..."

    local tmp_file
    tmp_file=$(mktemp)

    if ! curl -fsSL -o "$tmp_file" "$PREBUILT_RELEASE_URL" 2>&1; then
        if [[ "$auto_flag" != "true" ]]; then
            log_error "下载预编译版本失败"
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
                log_info "已是最新版本（相同版本）"
            fi
            rm -f "$tmp_file"
            exit 0
        fi
    fi

    if [[ "$auto_flag" != "true" && "$YES_MODE" == "false" ]]; then
        if ! confirm "发现新版本，是否继续升级？"; then
            log_info "升级已取消"
            rm -f "$tmp_file"
            exit 0
        fi
    fi

    log_step "备份当前版本"
    rm -rf "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    cp -a "${APP_DIR}/server" "${BACKUP_DIR}/" 2>/dev/null || true
    cp -a "${APP_DIR}/client" "${BACKUP_DIR}/" 2>/dev/null || true
    cp -a "${APP_DIR}/shared" "${BACKUP_DIR}/" 2>/dev/null || true
    cp -a "${APP_DIR}/node_modules" "${BACKUP_DIR}/" 2>/dev/null || true
    cp -a "${APP_DIR}/package.json" "${BACKUP_DIR}/" 2>/dev/null || true
    cp -a "$ENV_FILE" "${BACKUP_DIR}/.env.backup"
    cp -a "$DEPLOY_VERSION_FILE" "${BACKUP_DIR}/.deploy-version.backup" 2>/dev/null || true
    log_info "备份已保存到 ${BACKUP_DIR}"

    log_step "正在升级 FreeLLMAPI（预编译模式）"
    write_log "开始预编译升级"

    local upgrade_failed=false

    rm -rf "${APP_DIR}/server" "${APP_DIR}/client" "${APP_DIR}/shared" "${APP_DIR}/node_modules"
    rm -f "${APP_DIR}/package.json" "${APP_DIR}/package-lock.json" "${APP_DIR}/.release-hash"

    if ! tar -xzf "$tmp_file" -C "$APP_DIR" 2>&1; then
        log_error "解压预编译版本失败"
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
        log_step "正在重启服务"
        systemctl restart "$SERVICE_NAME"

        if health_check; then
            rm -rf "$BACKUP_DIR"
            log_info "==========================================="
            log_info " 升级成功！（预编译模式）"
            log_info "==========================================="
            write_log "预编译升级完成"
        else
            upgrade_failed=true
        fi
    fi

    if [[ "$upgrade_failed" == "true" ]]; then
        log_error "升级失败！正在回滚..."
        write_log "升级失败，正在回滚"

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
            log_info "回滚成功，服务已恢复"
        else
            log_error "回滚也失败了！需要手动干预。"
            log_error "备份位于：${BACKUP_DIR}"
        fi
        exit 1
    fi
}

do_upgrade_build() {
    local auto_flag="${1:-false}"

    log_step "检查更新（编译模式）"
    write_log "检查更新"

    cd "$APP_DIR"
    git fetch origin "$BRANCH" --quiet 2>/dev/null || {
        log_error "从远程仓库获取失败"
        exit 1
    }

    local current latest
    current=$(git rev-parse HEAD)
    latest=$(git rev-parse "origin/${BRANCH}")

    if [[ "$current" == "$latest" ]]; then
        if [[ "$auto_flag" != "true" ]]; then
            log_info "已是最新版本（无新提交）"
        fi
        write_log "无可用更新"
        exit 0
    fi

    local current_short latest_short
    current_short=$(git rev-parse --short HEAD)
    latest_short=$(git rev-parse --short "origin/${BRANCH}")
    local commit_count
    commit_count=$(git rev-list "${current}..${latest}" --count 2>/dev/null || echo "?")

    log_info "发现更新：${current_short} -> ${latest_short}（${commit_count} 个新提交）"

    if [[ "$auto_flag" != "true" && "$YES_MODE" == "false" ]]; then
        if ! confirm "是否继续升级？"; then
            log_info "升级已取消"
            exit 0
        fi
    fi

    log_step "备份当前版本"
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
    log_info "备份已保存到 ${BACKUP_DIR}"

    log_step "正在升级 FreeLLMAPI（编译模式）"
    write_log "开始升级：${current_short} -> ${latest_short}"

    local upgrade_failed=false

    cd "$APP_DIR"

    git reset --hard "origin/${BRANCH}" --quiet 2>/dev/null || {
        log_error "git pull 失败"
        upgrade_failed=true
    }

    if [[ "$upgrade_failed" == "false" ]]; then
        install_npm_deps || {
            log_error "npm install 失败"
            upgrade_failed=true
        }
    fi

    if [[ "$upgrade_failed" == "false" ]]; then
        build_app || {
            log_error "编译失败"
            upgrade_failed=true
        }
    fi

    if [[ "$upgrade_failed" == "false" ]]; then
        prune_dev_deps || true
        set_permissions
        log_step "正在重启服务"
        systemctl restart "$SERVICE_NAME"

        if health_check; then
            save_version
            rm -rf "$BACKUP_DIR"
            log_info "==========================================="
            log_info " 升级成功！"
            log_info " ${current_short} -> ${latest_short}"
            log_info "==========================================="
            write_log "升级完成：${current_short} -> ${latest_short}"
        else
            upgrade_failed=true
        fi
    fi

    if [[ "$upgrade_failed" == "true" ]]; then
        log_error "升级失败！正在回滚..."
        write_log "升级失败，正在回滚"

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
            log_info "回滚成功，服务已恢复"
        else
            log_error "回滚也失败了！需要手动干预。"
            log_error "备份位于：${BACKUP_DIR}"
        fi
        exit 1
    fi
}

do_uninstall_internal() {
    local purge="${1:-false}"

    log_step "正在停止服务"
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true

    if [[ -f "$DOMAIN_FILE" ]]; then
        log_step "正在移除域名和 SSL 证书"
        local domain
        domain=$(head -1 "$DOMAIN_FILE" 2>/dev/null)
        do_remove_domain_silent
        if [[ -n "$domain" ]] && command -v certbot &>/dev/null; then
            certbot delete --cert-name "$domain" --non-interactive 2>/dev/null || true
            log_info "SSL 证书已删除（${domain}）"
        fi
    fi

    log_step "正在移除服务文件"
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload 2>/dev/null || true

    log_step "正在移除定时任务"
    rm -f "$CRON_FILE"

    log_step "正在移除日志文件"
    rm -f "$LOG_FILE"

    local port="3001"
    if [[ -f "$ENV_FILE" ]]; then
        port=$(grep -E "^PORT=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "3001")
        port="${port:-3001}"
    fi

    log_step "正在移除应用"
    rm -rf "$APP_DIR"

    log_step "正在移除 nvm Node.js（${NVM_DIR}）"
    rm -rf "$NVM_DIR"

    log_step "正在移除备份"
    rm -rf "$BACKUP_DIR"

    if [[ "$purge" == "true" ]]; then
        log_step "正在清除数据目录"
        rm -rf "$DATA_DIR"
        rm -f "$DEPLOY_VERSION_FILE"

        if [[ -f "$SWAP_FLAG" ]]; then
            log_step "正在移除 Swap（由此脚本创建）"
            if [[ -f "$SWAP_FILE" ]] && swapon --show | grep -q "$SWAP_FILE"; then
                swapoff "$SWAP_FILE" 2>/dev/null || true
            fi
            rm -f "$SWAP_FILE"
            sed -i "\|${SWAP_FILE}|d" /etc/fstab 2>/dev/null || true
            rm -f "$SWAP_FLAG"
        else
            log_info "Swap 非此脚本创建，跳过"
        fi

        log_step "正在移除用户"
        userdel "$APP_NAME" 2>/dev/null || true

        log_warn "防火墙：您可能需要关闭端口 ${port}："
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
            log_info "Swap 文件（${SWAP_FILE}）已保留（使用 purge 移除）"
        fi
        if [[ -d "$DATA_DIR" ]]; then
            log_info "数据目录（${DATA_DIR}）已保留"
        fi
    fi
}

do_uninstall() {
    check_root
    detect_os

    if ! is_installed && [[ ! -d "$APP_DIR" ]]; then
        log_error "FreeLLMAPI 未安装。"
        exit 1
    fi

    echo ""
    log_warn "此操作将从系统中移除 FreeLLMAPI。"
    echo ""
    echo "  选项："
    echo "    1) 仅移除应用（保留数据、.env、Swap）"
    echo "    2) 移除所有内容（包括数据、.env、Swap、用户、nvm Node.js）"
    echo "    3) 取消"
    echo ""

    if [[ "$YES_MODE" == "true" ]]; then
        local purge_choice="2"
    else
        read -r -p "  请选择 [1-3]：" purge_choice
    fi

    case "$purge_choice" in
        1)
            do_uninstall_internal false
            log_info "FreeLLMAPI 已卸载（数据保留在 ${DATA_DIR}）"
            ;;
        2)
            if [[ "$YES_MODE" == "true" ]] || confirm "此操作将删除所有数据，确定吗？"; then
                do_uninstall_internal true
                log_info "FreeLLMAPI 已完全移除（包括所有数据）"
            else
                log_info "卸载已取消"
            fi
            ;;
        *)
            log_info "卸载已取消"
            ;;
    esac
}

do_status() {
    if ! is_installed; then
        log_error "FreeLLMAPI 未安装。"
        exit 1
    fi

    echo ""
    log_info "FreeLLMAPI 状态"
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

    echo "  安装目录：     ${APP_DIR}"
    echo "  版本：         $(get_current_version | head -c 12)"
    echo "  配置文件：     ${ENV_FILE}"
    echo "  数据目录：     ${DATA_DIR}"
    echo "  端口：         ${port}"
    echo "  Node.js：      ${node_version} (${node_path:-N/A})"
    echo "  服务状态：     $(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo '未知')"
    echo "  自动升级：     $([ -f "$CRON_FILE" ] && echo '已启用' || echo '已禁用')"
    echo "  Swap：         $(free -m | awk '/^Swap:/{print $2}')MB"
    echo "  内存占用：     $(ps -o rss= -p "$(pgrep -f 'server/dist/index.js' | head -1)" 2>/dev/null | awk '{printf "%.0fMB\n", $1/1024}' || echo 'N/A')"
    if [[ -f "$DOMAIN_FILE" ]]; then
        local domain_info
        domain_info=$(cat "$DOMAIN_FILE" 2>/dev/null)
        local domain_name domain_https_port
        domain_name=$(echo "$domain_info" | head -1)
        domain_https_port=$(echo "$domain_info" | tail -1)
        if [[ "$domain_https_port" == "443" || -z "$domain_https_port" ]]; then
            echo "  域名：         https://${domain_name}"
        else
            echo "  域名：         https://${domain_name}:${domain_https_port}"
        fi
    else
        echo "  域名：         未配置"
    fi
    echo ""

    if curl -sf "http://127.0.0.1:${port}/api/ping" > /dev/null 2>&1; then
        log_info "健康检查：正常"
    else
        log_error "健康检查：失败"
    fi
    echo ""
}

do_logs() {
    if ! is_installed; then
        log_error "FreeLLMAPI 未安装。"
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
        log_error "FreeLLMAPI 未安装。"
        exit 1
    fi
    systemctl restart "$SERVICE_NAME"
    log_info "服务已重启"
    health_check
}

do_start() {
    check_root
    if ! is_installed; then
        log_error "FreeLLMAPI 未安装。"
        exit 1
    fi
    systemctl start "$SERVICE_NAME"
    log_info "服务已启动"
    health_check
}

do_stop() {
    check_root
    if ! is_installed; then
        log_error "FreeLLMAPI 未安装。"
        exit 1
    fi
    systemctl stop "$SERVICE_NAME"
    log_info "服务已停止"
}

do_check_update() {
    if ! is_installed; then
        exit 0
    fi

    if [[ -d "$APP_DIR/.git" ]]; then
        cd "$APP_DIR"
        git fetch origin "$BRANCH" --quiet 2>/dev/null || exit 0

        local current latest
        current=$(git rev-parse HEAD)
        latest=$(git rev-parse "origin/${BRANCH}" 2>/dev/null || echo "$current")

        if [[ "$current" != "$latest" ]]; then
            local commit_count
            commit_count=$(git rev-list "${current}..${latest}" --count 2>/dev/null || echo "?")
            log_info "发现更新：${commit_count} 个新提交"
        else
            log_info "已是最新版本"
        fi
    else
        local current_hash
        current_hash=$(cat "${APP_DIR}/.release-hash" 2>/dev/null || echo "unknown")
        local tmp_file
        tmp_file=$(mktemp)
        if curl -fsSL -o "$tmp_file" "$PREBUILT_RELEASE_URL" 2>/dev/null; then
            local remote_hash
            remote_hash=$(sha256sum "$tmp_file" | cut -d' ' -f1)
            if [[ "$current_hash" == "$remote_hash" ]]; then
                log_info "已是最新版本"
            else
                log_info "发现更新（新预编译版本）"
            fi
        else
            log_warn "无法检查更新（下载失败）"
        fi
        rm -f "$tmp_file"
    fi
}

install_nginx() {
    if command -v nginx &>/dev/null; then
        log_info "Nginx 已安装"
        return 0
    fi

    log_step "安装 Nginx"
    case "$OS_FAMILY" in
        debian)
            apt-get update -qq
            apt-get install -y -qq nginx > /dev/null 2>&1
            ;;
        rhel)
            if command -v dnf &>/dev/null; then
                dnf install -y -q nginx
            else
                yum install -y -q nginx
            fi
            ;;
        alpine)
            apk add --quiet nginx
            ;;
        *)
            log_error "不支持的操作系统，请手动安装 Nginx"
            return 1
            ;;
    esac

    if command -v nginx &>/dev/null; then
        systemctl enable nginx > /dev/null 2>&1 || true
        systemctl start nginx 2>/dev/null || true
        log_info "Nginx 已安装并启动"
    else
        log_error "Nginx 安装失败"
        return 1
    fi
}

install_certbot() {
    if command -v certbot &>/dev/null; then
        log_info "Certbot 已安装"
        return 0
    fi

    log_step "安装 Certbot（Let's Encrypt 客户端）"
    case "$OS_FAMILY" in
        debian)
            apt-get update -qq
            apt-get install -y -qq certbot python3-certbot-nginx > /dev/null 2>&1
            ;;
        rhel)
            if command -v dnf &>/dev/null; then
                dnf install -y -q certbot python3-certbot-nginx
            else
                yum install -y -q certbot python3-certbot-nginx
            fi
            ;;
        alpine)
            apk add --quiet certbot py3-certbot-nginx
            ;;
        *)
            log_error "不支持的操作系统，请手动安装 Certbot"
            return 1
            ;;
    esac

    if command -v certbot &>/dev/null; then
        log_info "Certbot 已安装"
    else
        log_error "Certbot 安装失败"
        return 1
    fi
}

do_setup_domain() {
    check_root
    detect_os

    if ! is_installed; then
        log_error "FreeLLMAPI 未安装。请先运行 install。"
        exit 1
    fi

    local port
    port=$(grep -E "^PORT=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "3001")
    port="${port:-3001}"

    if [[ -f "$DOMAIN_FILE" ]]; then
        local existing_domain
        existing_domain=$(cat "$DOMAIN_FILE" 2>/dev/null)
        log_warn "已配置域名：${existing_domain}"
        echo ""
        echo "  选项："
        echo "    1) 更换域名"
        echo "    2) 移除域名配置"
        echo "    3) 取消"
        echo ""
        read -r -p "  请选择 [1-3]：" domain_choice
        case "$domain_choice" in
            1) do_remove_domain_silent ;;
            2) do_remove_domain; exit 0 ;;
            *) log_info "已取消"; exit 0 ;;
        esac
    fi

    echo ""
    log_info "配置域名和 SSL 证书"
    log_info "此功能将："
    log_info "  1. 安装 Nginx（如未安装）"
    log_info "  2. 创建本项目专属的 Nginx 反向代理配置"
    log_info "  3. 使用 Let's Encrypt 自动申请 SSL 证书"
    log_info "  4. 配置 HTTP 自动跳转 HTTPS"
    log_info ""
    log_info "前提条件："
    log_info "  - 域名已解析到此服务器的 IP 地址"
    log_info "  - 服务器 80 端口可从外网访问（Let's Encrypt 验证需要）"
    log_info ""

    read -r -p "  请输入域名（例如 api.example.com）：" domain
    domain=$(echo "$domain" | xargs)
    if [[ -z "$domain" ]]; then
        log_error "域名不能为空"
        exit 1
    fi

    local https_port="443"
    read -r -p "  HTTPS 端口 [${https_port}]：" input_https_port
    https_port="${input_https_port:-$https_port}"

    if [[ "$https_port" != "443" ]]; then
        log_info "使用自定义 HTTPS 端口：${https_port}"
        log_info "访问地址将为：https://${domain}:${https_port}"
    fi

    if command -v host &>/dev/null; then
        if ! host "$domain" &>/dev/null; then
            log_warn "无法解析域名 ${domain}，请确认 DNS 已正确配置"
            if ! confirm "继续配置？"; then
                exit 0
            fi
        fi
    elif command -v nslookup &>/dev/null; then
        if ! nslookup "$domain" &>/dev/null; then
            log_warn "无法解析域名 ${domain}，请确认 DNS 已正确配置"
            if ! confirm "继续配置？"; then
                exit 0
            fi
        fi
    else
        log_warn "未安装 DNS 工具（host/nslookup），跳过域名解析验证"
        log_warn "请确保域名 ${domain} 已正确解析到此服务器"
    fi

    local port_80_ok=false
    local port_https_ok=false

    if command -v ss &>/dev/null; then
        local listener_80 listener_https
        listener_80=$(ss -tlnp 2>/dev/null | grep -E ":80\s" | head -1 || true)
        listener_https=$(ss -tlnp 2>/dev/null | grep -E ":${https_port}\s" | head -1 || true)

        if [[ -z "$listener_80" ]]; then
            port_80_ok=true
        elif echo "$listener_80" | grep -q "nginx"; then
            log_info "80 端口由 Nginx 占用，将复用现有 Nginx"
            port_80_ok=true
        else
            log_error "80 端口被非 Nginx 程序占用，Let's Encrypt 证书验证需要 80 端口"
            log_error "  ${listener_80}"
            exit 1
        fi

        if [[ -z "$listener_https" ]]; then
            port_https_ok=true
        elif echo "$listener_https" | grep -q "nginx"; then
            log_info "端口 ${https_port} 由 Nginx 占用，将复用现有 Nginx"
            port_https_ok=true
        else
            log_error "端口 ${https_port} 被非 Nginx 程序占用"
            log_error "  ${listener_https}"
            exit 1
        fi
    else
        port_80_ok=true
        port_https_ok=true
    fi

    install_nginx || exit 1

    local nginx_include_dir=""
    if [[ -d /etc/nginx/sites-enabled ]]; then
        nginx_include_dir="sites-enabled"
        mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    elif [[ -d /etc/nginx/conf.d ]]; then
        nginx_include_dir="conf.d"
        mkdir -p /etc/nginx/conf.d
    else
        mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
        nginx_include_dir="sites-enabled"
    fi

    if [[ "$nginx_include_dir" == "sites-enabled" ]]; then
        NGINX_CONF_FILE="/etc/nginx/sites-available/freellmapi"
        NGINX_LINK_FILE="/etc/nginx/sites-enabled/freellmapi"
        if ! grep -q 'include.*sites-enabled' /etc/nginx/nginx.conf 2>/dev/null; then
            if [[ -f /etc/nginx/nginx.conf ]]; then
                sed -i '/http {/a \    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
                log_info "已将 sites-enabled 加入 nginx.conf"
            fi
        fi
    else
        NGINX_CONF_FILE="/etc/nginx/conf.d/freellmapi.conf"
        NGINX_LINK_FILE=""
    fi

    log_step "创建 Nginx 配置（${domain}）"
    cat > "$NGINX_CONF_FILE" << EOF
server {
    listen 80;
    server_name ${domain};

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOF

    if [[ -n "$NGINX_LINK_FILE" && ! -L "$NGINX_LINK_FILE" ]]; then
        ln -s "$NGINX_CONF_FILE" "$NGINX_LINK_FILE"
    fi

    if ! nginx -t 2>&1; then
        log_error "Nginx 配置测试失败，正在回滚"
        rm -f "$NGINX_CONF_FILE" "$NGINX_LINK_FILE"
        exit 1
    fi

    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null
    log_info "Nginx 配置已生效（HTTP）"

    log_step "申请 SSL 证书"
    install_certbot || exit 1

    local certbot_email=""
    read -r -p "  请输入邮箱（用于 Let's Encrypt 证书到期提醒，可留空跳过）：" certbot_email
    certbot_email=$(echo "$certbot_email" | xargs)

    local certbot_cmd="certbot --nginx -d $domain --non-interactive --agree-tos --redirect"
    if [[ -n "$certbot_email" ]]; then
        certbot_cmd="$certbot_cmd --email $certbot_email"
    else
        certbot_cmd="$certbot_cmd --register-unsafely-without-email"
    fi

    if $certbot_cmd 2>&1; then
        if [[ "$https_port" != "443" ]]; then
            log_info "正在将 HTTPS 端口从 443 修改为 ${https_port}..."
            sed -i "s/listen 443 ssl/listen ${https_port} ssl/g" "$NGINX_CONF_FILE"
            sed -i "s/listen \[::\]:443 ssl/listen [::]:${https_port} ssl/g" "$NGINX_CONF_FILE"
            if nginx -t 2>&1; then
                systemctl reload nginx 2>/dev/null || true
                log_info "HTTPS 端口已修改为 ${https_port}"
            else
                log_error "修改 HTTPS 端口后 Nginx 配置测试失败，回滚为 443"
                sed -i "s/listen ${https_port} ssl/listen 443 ssl/g" "$NGINX_CONF_FILE"
                sed -i "s/listen \[::\]:${https_port} ssl/listen [::]:443 ssl/g" "$NGINX_CONF_FILE"
                nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
                https_port="443"
            fi
        fi

        echo "$domain" > "$DOMAIN_FILE"
        echo "$https_port" >> "$DOMAIN_FILE"
        log_info "==========================================="
        log_info " 域名和 SSL 配置成功！"
        log_info "==========================================="
        log_info ""
        if [[ "$https_port" == "443" ]]; then
            log_info "  HTTPS 地址：  https://${domain}"
            log_info "  API 地址：    https://${domain}/v1/chat/completions"
        else
            log_info "  HTTPS 地址：  https://${domain}:${https_port}"
            log_info "  API 地址：    https://${domain}:${https_port}/v1/chat/completions"
        fi
        log_info ""
        log_info "  SSL 证书会由 Certbot 自动续期"
        log_info "  证书续期定时任务：systemctl list-timers | grep certbot"
        log_info ""
        log_warn "  建议关闭直接 IP 访问的端口 ${port}，仅通过 Nginx 代理访问"
        log_warn "  关闭命令：ufw deny ${port}/tcp"
        if [[ "$https_port" != "443" ]]; then
            log_warn ""
            log_warn "  请确保防火墙已开放 HTTPS 端口 ${https_port}："
            if command -v ufw &>/dev/null; then
                log_warn "    ufw allow ${https_port}/tcp"
            fi
            if command -v firewall-cmd &>/dev/null; then
                log_warn "    firewall-cmd --permanent --add-port=${https_port}/tcp && firewall-cmd --reload"
            fi
        fi
        log_info ""
    else
        log_error "SSL 证书申请失败"
        log_error "常见原因："
        log_error "  1. 域名未正确解析到此服务器"
        log_error "  2. 80 端口被防火墙拦截（Let's Encrypt 验证需要）"
        log_error "  3. 80 端口被其他服务占用"
        log_error ""
        log_warn "HTTP 反向代理已配置，可手动修复 SSL："
        log_warn "  certbot --nginx -d ${domain}"
        echo "$domain" > "$DOMAIN_FILE"
    fi
}

do_remove_domain_silent() {
    if [[ -f "/etc/nginx/sites-available/freellmapi" ]]; then
        rm -f "/etc/nginx/sites-available/freellmapi"
    fi
    if [[ -L "/etc/nginx/sites-enabled/freellmapi" ]]; then
        rm -f "/etc/nginx/sites-enabled/freellmapi"
    fi
    if [[ -f "/etc/nginx/conf.d/freellmapi.conf" ]]; then
        rm -f "/etc/nginx/conf.d/freellmapi.conf"
    fi
    if command -v nginx &>/dev/null; then
        nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
    fi
    rm -f "$DOMAIN_FILE"
}

do_remove_domain() {
    check_root

    if [[ ! -f "$DOMAIN_FILE" ]]; then
        log_info "未配置域名"
        return 0
    fi

    local domain
    domain=$(head -1 "$DOMAIN_FILE" 2>/dev/null)

    log_step "移除域名配置（${domain}）"

    do_remove_domain_silent

    if [[ -n "$domain" ]] && command -v certbot &>/dev/null; then
        certbot delete --cert-name "$domain" --non-interactive 2>/dev/null || true
    fi

    log_info "域名配置已移除"
    log_info "现在通过 http://<IP>:<端口> 直接访问"
}

show_interactive_menu() {
    echo ""
    echo -e "  ${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "  ${CYAN}║${NC}      ${GREEN}FreeLLMAPI 部署管理器${NC}              ${CYAN}║${NC}"
    echo -e "  ${CYAN}╠══════════════════════════════════════════╣${NC}"
    echo -e "  ${CYAN}║${NC}                                          ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}  ${YELLOW}1)${NC} 安装            （全新安装）         ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}  ${YELLOW}2)${NC} 升级            （更新版本）         ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}  ${YELLOW}3)${NC} 卸载            （移除应用）         ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}  ${YELLOW}4)${NC} 配置域名        （HTTPS/SSL）       ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}  ${YELLOW}5)${NC} 状态            （查看服务）         ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}  ${YELLOW}6)${NC} 日志            （查看日志）         ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}  ${YELLOW}7)${NC} 重启            （重启服务）         ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}  ${YELLOW}8)${NC} 帮助            （更多命令）         ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}  ${YELLOW}0)${NC} 退出                                   ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}                                          ${CYAN}║${NC}"
    echo -e "  ${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""

    if is_installed; then
        local port
        port=$(grep -E "^PORT=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "3001")
        port="${port:-3001}"
        local svc_status
        svc_status=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo 'unknown')
        if [[ "$svc_status" == "active" ]]; then
            log_info "服务正在运行，端口 ${port}"
        else
            log_warn "服务状态：${svc_status}"
        fi
    else
        log_info "FreeLLMAPI 未安装"
    fi

    echo ""
    read -r -p "  请选择 [0-8]：" choice

    case "$choice" in
        1) do_install ;;
        2) do_upgrade "false" ;;
        3) do_uninstall ;;
        4) do_setup_domain ;;
        5) do_status ;;
        6) do_logs ;;
        7) do_restart ;;
        8) show_help ;;
        0) log_info "再见！"; exit 0 ;;
        *) log_error "无效选择"; exit 1 ;;
    esac
}

show_help() {
    cat << EOF

FreeLLMAPI 部署管理器

用法：$(basename "$0") <命令> [选项]

命令：
  install          安装 FreeLLMAPI
  upgrade          升级到最新版本
  uninstall        卸载 FreeLLMAPI
  domain           配置域名和 SSL 证书
  status           查看服务状态
  logs [-f]        查看日志（-f 实时跟踪）
  start            启动服务
  stop             停止服务
  restart          重启服务
  check-update     检查是否有可用更新

选项：
  -y, --yes        跳过所有确认提示
  --auto           非交互模式（用于定时任务）
  --build          在服务器本地编译，而非下载预编译版本
  -p, --port PORT  设置端口（默认：3001）
  -h, --help       显示此帮助

隔离特性：
  - Node.js 通过 nvm 安装（隔离，不影响系统）
  - 专用系统用户（freellmapi）
  - systemd 沙箱（无新权限、私有 /tmp、只读文件系统）
  - 内存限制 512MB，CPU 配额 50%
  - 安装前检测端口冲突
  - 项目专用 Swap 文件（不影响现有 Swap）

示例：
  # 一行命令，交互式菜单
  curl -fsSL https://raw.githubusercontent.com/zczy-k/freellmapi/${BRANCH}/deploy.sh -o /tmp/deploy.sh && sudo bash /tmp/deploy.sh

  # 一行命令，直接安装（跳过菜单）
  curl -fsSL https://raw.githubusercontent.com/zczy-k/freellmapi/${BRANCH}/deploy.sh | sudo bash -s install -y

  # 使用自定义端口安装
  sudo $(basename "$0") install -y -p 8080

  # 本地编译安装（适用于内存充足的服务器）
  sudo $(basename "$0") install -y --build

  # 交互式升级
  sudo $(basename "$0") upgrade

  # 完全卸载（包括数据）
  sudo $(basename "$0") uninstall -y

EOF
}

main() {
    if [[ $# -eq 0 ]]; then
        check_root
        show_interactive_menu
        exit 0
    fi

    local command=""
    local extra_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            install|upgrade|uninstall|domain|status|logs|start|stop|restart|check-update)
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
                log_error "未知选项：$1"
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
        domain)
            do_setup_domain
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
            log_error "未知命令：$command"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
