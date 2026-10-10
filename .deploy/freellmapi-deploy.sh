#!/bin/bash
set -euo pipefail
REPO="${1:-.}"
mkdir -p "$REPO/.deploy" "$REPO/.github/workflows"
cd "$REPO"

cat > .deploy/freellmapi-deploy <<'DEPLOYEOF'
#!/bin/bash
# FreeLLMAPI 自动部署脚本 —— 服务器端执行
# 原则: 不覆盖本地化内容 / 数据库在线一致性备份 / 健康检查失败自动回滚
set -uo pipefail

APP_DIR=/opt/freellmapi
SERVICE=freellmapi.service
BACKUP_ROOT=/opt/freellmapi-backup
STAGING=/opt/freellmapi-staging
STATE_FILE="${APP_DIR}/.release-hash"
HISTORY_FILE="${APP_DIR}/.deploy-version"
LOG_FILE=/var/log/freellmapi-deploy.log
HEALTH_URL="http://127.0.0.1:3001/api/ping"
MAX_BACKUPS=5
HEALTH_RETRIES=15
HEALTH_INTERVAL=2

# 部署时必须保留、绝不允许被覆盖的路径
PRESERVE_PATHS=(".env" "server/data")

ARTIFACT=""; DEPS=""; TARGET_SHA=""; MODE="deploy"

log() {
  local m="[$(date '+%Y-%m-%d %H:%M:%S')] [$1] ${*:2}"
  echo "$m"; echo "$m" >> "$LOG_FILE" 2>/dev/null || true
}
die() { log FATAL "$*"; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --artifact) ARTIFACT="$2"; shift 2 ;;
    --deps)     DEPS="$2";     shift 2 ;;
    --sha)      TARGET_SHA="$2"; shift 2 ;;
    --check)    MODE="check";   shift ;;
    --status)   MODE="status";  shift ;;
    -h|--help)  sed -n '2,8p' "$0"; exit 0 ;;
    *)          die "未知参数: $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "必须以 root 运行"
mkdir -p "$BACKUP_ROOT"; touch "$LOG_FILE"

show_status() {
  echo "===== FreeLLMAPI 部署状态 ====="
  echo "当前部署 commit : $(cat "$STATE_FILE" 2>/dev/null || echo '(未知)')"
  echo "服务状态         : $(systemctl is-active "$SERVICE" 2>/dev/null)"
  echo "服务启动         : $(systemctl show "$SERVICE" -p ExecMainStartTimestamp --value 2>/dev/null)"
  local ce  ce=$(echo | timeout 10 openssl s_client -connect 127.0.0.1:443 \
 -servername freeapi.cni.de5.net 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  echo "证书到期         : ${ce:-'(读取失败)'}"
  echo "最近版本备份     : $(ls -1dt "$BACKUP_ROOT"/release-* 2>/dev/null | head -1 || echo '(无)')"
}

check_mode() {
  log INFO "检查模式: 当前 $(cat "$STATE_FILE" 2>/dev/null || echo unknown)"
  log INFO "服务 $(systemctl is-active "$SERVICE")"
}

preflight() {
  log INFO "=== 前置检查 ==="
  [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ] || die "产物包不存在: $ARTIFACT"
  [ -n "$TARGET_SHA" ] || die "必须提供 --sha <commit>"
  command -v systemctl >/dev/null || die "缺少 systemctl"
  [ -d "$APP_DIR" ] || die "应用目录不存在: $APP_DIR"
  local av
  av=$(df -Pm "$APP_DIR" | awk 'NR==2 {print $4}')
  log INFO "可用磁盘: ${av} MB"
  [ "$av" -ge 500 ] || die "磁盘空间不足 (<500MB)"
  for p in "${PRESERVE_PATHS[@]}"; do
    [ -e "$APP_DIR/$p" ] && log INFO "保留项就位: $p" || log WARN "保留项不存在(跳过): $p"
  done
  log INFO "产物内容预览:"
  tar -tzf "$ARTIFACT" 2>/dev/null | head -12 | sed 's/^/    /'
  tar -tzf "$ARTIFACT" 2>/dev/null | grep -q "server/dist/index.js" \
    || die "产物缺少 server/dist/index.js，构建失败或包不完整"
}

backup_database() {
  local db="$APP_DIR/server/data/freeapi.db"
  [ -f "$db" ] || { log WARN "数据库不存在，跳过"; return 0; }
  local dst="${BACKUP_ROOT}/db-$1.db"
  # 用 SQLite 在线备份 API —— 直接 cp 在 WAL 未 checkpoint 时会拿到损坏的库
  if python3 - "$db" "$dst" <<'PYEOF'
import sqlite3, sys
s, d = sys.argv[1], sys.argv[2]
try:
    src = sqlite3.connect(f"file:{s}?mode=ro", uri=True, timeout=30)
    dst = sqlite3.connect(d); src.backup(dst); dst.close(); src.close()
except Exception as e:
    print(f"backup error: {e}", file=sys.stderr); sys.exit(1)
PYEOF
  then
    if python3 -c "
import sqlite3,sys
c=sqlite3.connect(sys.argv[1]); r=c.execute('PRAGMA integrity_check').fetchone()[0]
c.close(); sys.exit(0 if r=='ok' else 1)" "$dst" 2>/dev/null; then
      log INFO "数据库已备份并通过完整性校验: $dst ($(du -h "$dst"|cut -f1))"
    else
      die "数据库备份完整性校验失败，中止部署"
    fi
  else
    die "数据库备份失败，中止部署"
  fi
}

backup_release() {
  local dst="${BACKUP_ROOT}/release-$1"
  mkdir -p "$dst"
  log INFO "备份当前版本到 $dst"
  for i in server/dist client/dist shared package.json package-lock.json; do
    [ -e "$APP_DIR/$i" ] && cp -a "$APP_DIR/$i" "$dst/" 2>/dev/null || true
  done
  cp -a "$STATE_FILE" "$dst/.release-hash" 2>/dev/null || true
  ls -1dt "$BACKUP_ROOT"/release-* 2>/dev/null | tail -n +$((MAX_BACKUPS+1)) \
    | while read -r old; do log INFO "清理旧备份: $old"; rm -rf "$old"; done
}

stage_artifact() {
  log INFO "=== 解压产物到暂存区 ==="
  rm -rf "$STAGING"; mkdir -p "$STAGING"
  tar -xzf "$ARTIFACT" -C "$STAGING" || die "解压产物失败"
  [ -f "$STAGING/server/dist/index.js" ] || die "暂存区缺少入口文件"
  [ -f "$STAGING/manifest.json" ] && {
    log INFO "产物清单:"
    python3 -c "
import json,sys
m=json.load(open(sys.argv[1]))
[print(f'    {k}: {v}') for k,v in m.items()]" "$STAGING/manifest.json"
  }
}

deps_needed() {
  local o="$APP_DIR/package-lock.json" n="$STAGING/package-lock.json"
  [ -f "$n" ] || { echo unknown; return; }
  [ -f "$o" ] || { echo yes; return; }
  [ "$(sha256sum "$o"|cut -d' ' -f1)" != "$(sha256sum "$n"|cut -d' ' -f1)" ] \
    && echo yes || echo no
}

switch_release() {
  log INFO "=== 切换版本 ==="
  systemctl stop "$SERVICE" || die "停服失败"
  for i in server/dist client/dist shared package.json package-lock.json manifest.json; do
    [ -e "$STAGING/$i" ] || continue
    rm -rf "${APP_DIR:?}/${i}"; cp -a "$STAGING/$i" "$APP_DIR/" || die "替换 $i 失败"
    log INFO "已替换 $i"
  done
  local need; need=$(deps_needed)
  if [ "$need" = yes ]; then
    [ -f "$DEPS" ] || die "lock 已变化但未提供 --deps，中止以防版本错配"
    log INFO "依赖变化，安装新 node_modules ..."
    rm -rf "${APP_DIR:?}/node_modules"
    tar -xzf "$DEPS" -C "$APP_DIR" || die "依赖解压失败"
  else
    log INFO "依赖未变化，沿用现有 node_modules"
  fi
  chown -R freellmapi:freellmapi "$APP_DIR" 2>/dev/null || true
  echo "$TARGET_SHA" > "$STATE_FILE"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $TARGET_SHA" >> "$HISTORY_FILE"
  log INFO "版本已记录: $TARGET_SHA"
}

health_check() {
  log INFO "=== 健康检查 ==="
  for i in $(seq 1 $HEALTH_RETRIES); do
    systemctl start "$SERVICE" 2>/dev/null || true
    sleep "$HEALTH_INTERVAL"
    local c    c=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$HEALTH_URL" 2>/dev/null)
    [ "$c" = 200 ] && { log INFO "健康检查通过 (第 $i 次)"; return 0; }
    log INFO "等待就绪 $i/$HEALTH_RETRIES (HTTP=$c)"
  done
  log ERROR "健康检查失败"; return 1
}

rollback() {
  local src="${BACKUP_ROOT}/release-$1"
  log ERROR "!!! 开始回滚 !!!"
  [ -d "$src" ] || { log ERROR "备份不存在，无法回滚"; return 1; }
  systemctl stop "$SERVICE" 2>/dev/null || true
  for i in server/dist client/dist shared package.json package-lock.json; do
    [ -e "$src/$i" ] || continue
    rm -rf "${APP_DIR:?}/${i}"; cp -a "$src/$i" "$APP_DIR/"
    log INFO "已回滚 $i"
  done
  [ -f "$src/.release-hash" ] && cp -a "$src/.release-hash" "$STATE_FILE"
  chown -R freellmapi:freellmapi "$APP_DIR" 2>/dev/null || true
  systemctl start "$SERVICE" || log ERROR "旧版启动失败，需人工介入"
  sleep 5
  local c
  c=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$HEALTH_URL" 2>/dev/null)
  [ "$c" = 200 ] && { log INFO "!!! 回滚成功 !!!"; return 0; }
  log ERROR "!!! 回滚后仍异常，需人工介入 !!!"; return 1
}

main() {
  case "$MODE" in status) show_status; exit 0 ;; check) check_mode; exit 0 ;; esac
  log INFO "======== 开始部署 ========"
  local cur; cur=$(cat "$STATE_FILE" 2>/dev/null || echo unknown)
  [ "$cur" = "$TARGET_SHA" ] && { log INFO "版本一致，跳过"; exit 0; }
  log INFO "当前=$cur 目标=$TARGET_SHA"
  preflight
  local st; st=$(date '+%Y%m%d-%H%M%S')
  backup_database "$st"; backup_release "$st"; stage_artifact; switch_release "$st"
  if health_check; then
    rm -rf "$STAGING"; log INFO "======== 部署成功 ========"; exit 0
  fi
  log ERROR "健康检查未通过"
  rollback "$st" && exit 1 || exit 2
}
main "$@"
DEPLOYEOF

chmod +x .deploy/freellmapi-deploy
echo "✅ 已创建 .deploy/freellmapi-deploy"
