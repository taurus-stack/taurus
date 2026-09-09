#!/usr/bin/env bash
# ============================================================================
# Taurus Stack 一键开发启动脚本
#
# 用法:
#   ./scripts/dev.sh              # 启动最小链路：backend + WS + auth + web
#   ./scripts/dev.sh --all        # 完整链路：最小链路 + scheduler + scheduler-worker
#   ./scripts/dev.sh --backend    # 只启动 backend（含 WS）
#   ./scripts/dev.sh --auth       # 只启动 auth
#   ./scripts/dev.sh --web        # 只启动 web
#   ./scripts/dev.sh --scheduler  # 启动 scheduler + worker
#   ./scripts/dev.sh --init       # 仅初始化（install + migrate + init）
#
# 环境要求:
#   - conda 环境 taurus（Python 3.12）
#   - MySQL + Redis（本地或 docker）
#   - Poetry + pnpm
# ============================================================================

set -euo pipefail

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}ℹ${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
err()   { echo -e "${RED}✗${NC} $*"; exit 1; }

# ---------- 路径 ----------
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND="$ROOT/taurus-backend"
AUTH="$ROOT/taurus-auth"
WEB="$ROOT/taurus-web"
SCHEDULER="$ROOT/taurus-scheduler"

# ---------- 参数 ----------
MODE="minimal"   # minimal | all | init | --backend / --auth / --web / --scheduler
for arg in "$@"; do
  case "$arg" in
    --all|--full)     MODE="all" ;;
    --init|--setup)   MODE="init" ;;
    --backend)        MODE="backend" ;;
    --auth)           MODE="auth" ;;
    --web)            MODE="web" ;;
    --scheduler)      MODE="scheduler" ;;
    -h|--help)        sed -n '2,30p' "$0"; exit 0 ;;
    *) err "未知参数: $arg（-h 查看帮助）" ;;
  esac
done

# ---------- 前置检查 ----------
check_conda() {
  if ! command -v conda &>/dev/null; then
    err "未找到 conda，请先安装 Miniconda/Anaconda"
  fi
  # shellcheck disable=SC1091
  source "$(conda info --base)/etc/profile.d/conda.sh"
  if conda env list | grep -qw taurus; then
    conda activate taurus
    ok "conda 环境 taurus 已激活（Python $(python --version | awk '{print $2}')）"
  else
    warn "conda 环境 taurus 不存在，尝试创建..."
    conda create -n taurus python=3.12 -y
    conda activate taurus
  fi
}

check_deps() {
  command -v poetry &>/dev/null || err "未找到 Poetry（pip install poetry）"
  command -v pnpm &>/dev/null   || err "未找到 pnpm（npm install -g pnpm）"
  command -v mysql &>/dev/null  || warn "未找到 mysql 客户端，请确认 MySQL 在运行"
  command -v redis-cli &>/dev/null || warn "未找到 redis-cli，请确认 Redis 在运行"
}

wait_port() {
  local port=$1 name=$2 timeout=${3:-10}
  for i in $(seq 1 "$timeout"); do
    if curl -s "http://localhost:$port/" &>/dev/null \
       || curl -s "http://localhost:$port/health/" &>/dev/null \
       || curl -s "http://localhost:$port/api/health/" &>/dev/null; then
      ok "$name 已就绪（:$port）"
      return 0
    fi
    sleep 1
  done
  warn "$name 超时未响应（:$port），可能需要手动检查"
  return 1
}

# ---------- 各服务启动 ----------
setup_backend() {
  info "=== taurus-backend 安装 + 初始化 ==="
  cd "$BACKEND"
  poetry install -q
  if [ ! -f conf/env.py ]; then
    cp conf/env.example.py conf/env.py
    warn "已生成 conf/env.py，请检查 DB/Redis 配置后再继续"
    warn "然后重新运行: $0 --backend"
    exit 0
  fi
  python manage.py migrate --noinput
  python manage.py init
  ok "backend 初始化完成"
}

start_backend() {
  info "=== 启动 taurus-backend :8000 ==="
  cd "$BACKEND"
  nohup poetry run python manage.py runserver 0.0.0.0:8000 > logs/dev-backend.log 2>&1 &
  echo $! > "$ROOT/.pids/backend.pid"
  wait_port 8000 "backend"
}

start_websocket() {
  info "=== 启动 WebSocket :8765 ==="
  cd "$BACKEND"
  nohup poetry run python manage/run_websocket_server.py > logs/dev-websocket.log 2>&1 &
  echo $! > "$ROOT/.pids/ws.pid"
  wait_port 8765 "WebSocket" 5 || true
}

setup_auth() {
  info "=== taurus-auth 安装 + 初始化 ==="
  cd "$AUTH"
  poetry install -q
  if [ ! -f .env ]; then
    cp .env.example .env
    warn "已生成 .env，请与 backend 共享 JWT secret 后再继续"
    exit 0
  fi
  poetry run python manage.py migrate --noinput
  ok "auth 初始化完成"
}

start_auth() {
  info "=== 启动 taurus-auth :8001 ==="
  cd "$AUTH"
  nohup poetry run python manage.py runserver 0.0.0.0:8001 > "$ROOT/logs/dev-auth.log" 2>&1 &
  echo $! > "$ROOT/.pids/auth.pid"
  wait_port 8001 "auth"
}

start_web() {
  info "=== 启动 taurus-web :3000 ==="
  cd "$WEB"
  pnpm install --frozen-lockfile -q 2>/dev/null || pnpm install
  nohup pnpm run dev > "$ROOT/logs/dev-web.log" 2>&1 &
  echo $! > "$ROOT/.pids/web.pid"
  wait_port 3000 "web" 15
}

start_scheduler() {
  info "=== 启动 taurus-scheduler :9101 ==="
  cd "$SCHEDULER"
  if [ ! -f .env ]; then
    cp .env.example .env
    warn "已生成 scheduler/.env，请检查 DB/Redis 配置"
    exit 0
  fi
  nohup poetry run python -m scheduler.main > "$ROOT/logs/dev-scheduler.log" 2>&1 &
  echo $! > "$ROOT/.pids/scheduler.pid"
  wait_port 9101 "scheduler"
}

start_worker() {
  info "=== 启动 scheduler-worker ==="
  cd "$BACKEND"
  nohup poetry run python manage.py run_scheduler_worker --workers 4 > "$ROOT/logs/dev-worker.log" 2>&1 &
  echo $! > "$ROOT/.pids/worker.pid"
  ok "scheduler-worker 已启动"
}

# ---------- 汇总 ----------
show_summary() {
  echo
  echo "=============================================="
  echo -e "  ${GREEN}Taurus Stack 开发环境已就绪${NC}"
  echo "=============================================="
  echo
  echo "  前端:     http://localhost:3000"
  echo "  Backend:  http://localhost:8000"
  echo "  Swagger:  http://localhost:8000/api/schema/swagger-ui/"
  echo "  Auth:     http://localhost:8001"
  echo "  WS:       ws://localhost:8765"
  [ "$MODE" = "all" ] && echo "  Scheduler: http://localhost:9101"
  echo
  echo -e "  默认账号: ${YELLOW}superadmin${NC} / ${YELLOW}admin123456${NC}"
  echo
  echo "  日志:"
  for f in "$ROOT"/logs/dev-*.log; do
    [ -f "$f" ] && echo "    $(basename "$f")"
  done
  echo
  echo "  停止: pkill -f 'manage.py runserver|run_websocket|scheduler.main|run_scheduler_worker|pnpm run dev'"
  echo "=============================================="
}

# ---------- 主流程 ----------
mkdir -p "$ROOT/logs" "$ROOT/.pids"
check_conda
check_deps

case "$MODE" in
  init)
    setup_backend
    setup_auth
    ok "初始化完成，接下来启动: $0"
    ;;
  backend)
    setup_backend
    start_backend
    start_websocket
    ;;
  auth)
    setup_auth
    start_auth
    ;;
  web)
    start_web
    ;;
  scheduler)
    start_scheduler
    start_worker
    ;;
  minimal|all)
    setup_backend
    start_backend
    start_websocket
    setup_auth
    start_auth
    start_web
    [ "$MODE" = "all" ] && { start_scheduler; start_worker; }
    show_summary
    ;;
esac
