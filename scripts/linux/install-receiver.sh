#!/usr/bin/env bash
# 接收端一键部署 (Linux / systemd)
#
# 用法:
#   ./install-receiver.sh              # 交互式
#   ./install-receiver.sh --port 9131  # 指定端口
#
# 需要 sudo 权限
set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
ok(){ printf '%s[✓]%s %s\n' "$GREEN" "$RESET" "$*"; }
err(){ printf '%s[✗]%s %s\n' "$RED" "$RESET" "$*" >&2; }

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PREFIX="/opt/agent-sync"
CONF_DIR="/etc/agent-sync"
DATA_DIR="/var/lib/agent-sync"
USER_NAME="agent-sync"
PORT=9131

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2;;
    *) err "未知参数: $1"; exit 1;;
  esac
done

printf '%sAgent 多端同步 — 接收端部署%s\n\n' "$BOLD" "$RESET"

# ---------- 1. 前置检查 ----------
command -v python3 >/dev/null 2>&1 || { err "python3 未安装"; exit 1; }
command -v systemctl >/dev/null 2>&1 || { err "systemd 不可用"; exit 1; }
[ "$(id -u)" = "0" ] || { err "请用 sudo 运行"; exit 1; }
ok "python3 $(python3 --version 2>&1 | awk '{print $2}')"

# ---------- 2. 创建目录与用户 ----------
if ! id "$USER_NAME" >/dev/null 2>&1; then
  useradd --system --home "$DATA_DIR" --shell /usr/sbin/nologin "$USER_NAME"
  ok "已创建系统用户: $USER_NAME"
else
  ok "系统用户已存在: $USER_NAME"
fi

mkdir -p "$PREFIX" "$CONF_DIR" "$DATA_DIR"
chown "$USER_NAME:$USER_NAME" "$DATA_DIR"
ok "目录已就绪"

# ---------- 3. 部署程序 ----------
install -m 755 "$ROOT/scripts/linux/receiver.py" "$PREFIX/receiver.py"
ok "已部署 receiver.py"

# ---------- 4. 生成密钥 (若不存在) ----------
KEY_FILE="$CONF_DIR/sync.key"
if [ ! -f "$KEY_FILE" ]; then
  openssl rand -hex 32 > "$KEY_FILE" 2>/dev/null \
    || python3 -c "import secrets;open('$KEY_FILE','w').write(secrets.token_hex(32))"
  chmod 600 "$KEY_FILE"
  chown "$USER_NAME:$USER_NAME" "$KEY_FILE"
  ok "已生成新密钥: $KEY_FILE"
  echo
  echo "  ${BOLD}请将此密钥安全地复制到发送端 ~/.agent-sync/sync.key${RESET}"
  echo "  (带外交换，不要用邮件/聊天工具)"
  echo
else
  ok "密钥已存在，未覆盖"
fi

# ---------- 5. 生成配置 (若不存在) ----------
CONF_FILE="$CONF_DIR/receiver.json"
if [ ! -f "$CONF_FILE" ]; then
  cat > "$CONF_FILE" <<EOF
{
  "listen_host": "127.0.0.1",
  "listen_port": $PORT,
  "key_file": "$KEY_FILE",
  "database": "$DATA_DIR/state.db",
  "device": "$(hostname -s 2>/dev/null || echo receiver)",
  "log_level": "info",
  "schema_version": 1
}
EOF
  chmod 600 "$CONF_FILE"
  ok "已生成配置: $CONF_FILE"
else
  ok "配置已存在，未覆盖"
fi

# 安全检查: 禁止 0.0.0.0
if grep -q '"listen_host": *"0\.0\.0\.0"' "$CONF_FILE"; then
  err "安全: listen_host 不允许 0.0.0.0，请改为 127.0.0.1 或 Tailscale 地址"
  exit 1
fi

# ---------- 6. 自测 ----------
echo
echo "── 自测 ──"
if python3 "$PREFIX/receiver.py" --selftest >/dev/null 2>&1; then
  ok "接收端自测通过"
else
  err "自测失败"; python3 "$PREFIX/receiver.py" --selftest; exit 1
fi

# ---------- 7. 安装 systemd 服务 ----------
install -m 644 "$ROOT/scripts/linux/agent-receiver.service" \
  /etc/systemd/system/agent-receiver.service
systemctl daemon-reload
systemctl enable agent-receiver >/dev/null 2>&1
systemctl restart agent-receiver
ok "服务已安装并启动"

sleep 2
if systemctl is-active --quiet agent-receiver; then
  ok "服务运行中"
else
  err "服务启动失败，查看日志:"
  echo "  journalctl -u agent-receiver -n 50"
  exit 1
fi

# ---------- 8. 健康检查 ----------
echo
echo "── 健康检查 ──"
if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
  ok "健康检查通过: http://127.0.0.1:$PORT/health"
else
  err "健康检查失败"
  journalctl -u agent-receiver -n 20 --no-pager
  exit 1
fi

printf '\n%s部署完成%s\n\n' "$GREEN" "$RESET"
echo "常用命令:"
echo "  systemctl status agent-receiver"
echo "  journalctl -u agent-receiver -f"
echo "  curl http://127.0.0.1:$PORT/health"
echo
echo "下一步: 在发送端运行 ./scripts/macos/install-collector.sh"
echo
