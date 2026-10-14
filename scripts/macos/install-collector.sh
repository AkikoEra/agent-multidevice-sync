#!/usr/bin/env bash
# 采集端一键部署 (macOS / launchd)
#
# 用法:
#   ./install-collector.sh
#   ./install-collector.sh --url http://<receiver>:9131/sync
#
# 无需 sudo（只操作当前用户目录）
set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
ok(){ printf '%s[✓]%s %s\n' "$GREEN" "$RESET" "$*"; }
err(){ printf '%s[✗]%s %s\n' "$RED" "$RESET" "$*" >&2; }

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
HOME_DIR="${HOME}"
CONF_DIR="$HOME_DIR/.agent-sync"
CONF_FILE="$CONF_DIR/collector.json"
KEY_FILE="$CONF_DIR/sync.key"
LABEL="com.agent.collector"
URL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="$2"; shift 2;;
    *) err "未知参数: $1"; exit 1;;
  esac
done

printf '%sAgent 多端同步 — 采集端部署%s\n\n' "$BOLD" "$RESET"

# ---------- 1. 前置检查 ----------
command -v python3 >/dev/null 2>&1 || { err "python3 未安装 (Xcode CLT 或 Homebrew)"; exit 1; }
ok "python3 $(python3 --version 2>&1 | awk '{print $2}')"

mkdir -p "$CONF_DIR"
ok "配置目录: $CONF_DIR"

# ---------- 2. 密钥 ----------
if [ ! -f "$KEY_FILE" ]; then
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32 > "$KEY_FILE"
  else
    python3 -c "import secrets;open('$KEY_FILE','w').write(secrets.token_hex(32))"
  fi
  chmod 600 "$KEY_FILE"
  ok "已生成密钥（请与接收端交换为同一份）"
else
  ok "密钥已存在，未覆盖"
fi

echo
echo "  ${BOLD}重要: 两台设备必须使用完全相同的密钥${RESET}"
echo "  当前密钥指纹: $(sha256sum "$KEY_FILE" 2>/dev/null | cut -c1-16 || shasum -a 256 "$KEY_FILE" | cut -c1-16)"
echo

# ---------- 3. 配置 ----------
if [ ! -f "$CONF_FILE" ]; then
  if [ -z "$URL" ]; then
    echo "请输入接收端地址 (Tailscale 地址):"
    printf "  URL [http://127.0.0.1:9131/sync]: "
    read -r INPUT_URL
    URL="${INPUT_URL:-http://127.0.0.1:9131/sync}"
  fi

  printf "本机设备名 (唯一, 用于区分来源): "
  read -r DEVICE_NAME
  DEVICE_NAME="${DEVICE_NAME:-$(hostname -s)}"

  printf "Agent 状态库路径 (.json/.sqlite): "
  read -r SOURCE_PATH

  cp "$ROOT/examples/collector.json.example" "$CONF_FILE"
  python3 - "$CONF_FILE" "$URL" "$DEVICE_NAME" "$SOURCE_PATH" <<'PY'
import json, sys
path, url, device, source = sys.argv[1:5]
with open(path, encoding="utf-8") as f:
    cfg = json.load(f)
cfg["url"] = url
cfg["device"] = device
cfg["source"] = source
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  chmod 600 "$CONF_FILE"
  ok "已生成配置: $CONF_FILE"
else
  ok "配置已存在，未覆盖"
fi

# ---------- 4. 自测 ----------
echo
echo "── 自测 ──"
if python3 "$ROOT/scripts/macos/collector.py" --selftest >/dev/null 2>&1; then
  ok "采集端自测通过"
else
  err "自测失败"; python3 "$ROOT/scripts/macos/collector.py" --selftest; exit 1
fi

# ---------- 5. 安装 launchd ----------
PLIST_SRC="$ROOT/scripts/macos/$LABEL.plist"
PLIST_DST="$HOME_DIR/Library/LaunchAgents/$LABEL.plist"
mkdir -p "$HOME_DIR/Library/LaunchAgents"

# 替换占位符
sed -e "s#__REPO__#$ROOT#g" -e "s#__HOME__#$HOME_DIR#g" "$PLIST_SRC" > "$PLIST_DST"
chmod 644 "$PLIST_DST"
ok "已安装 launchd 配置: $PLIST_DST"

# 重载服务
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || \
  launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST" 2>/dev/null || \
  launchctl load "$PLIST_DST"
ok "服务已加载"

sleep 1
if launchctl list 2>/dev/null | grep -q "$LABEL"; then
  ok "服务运行中"
else
  err "服务未运行，日志: $CONF_DIR/collector.err.log"
  exit 1
fi

# ---------- 6. 单次投递测试 ----------
echo
echo "── 投递测试 ──"
if python3 "$ROOT/scripts/macos/collector.py" --config "$CONF_FILE"; then
  ok "投递测试完成"
else
  echo "  (投递未成功 — 确认接收端已启动且密钥一致)"
fi

printf '\n%s部署完成%s\n\n' "$GREEN" "$RESET"
echo "常用命令:"
echo "  tail -f $CONF_DIR/collector.log"
echo "  launchctl list | grep $LABEL"
echo
echo "手动触发一次: ./scripts/macos/trigger-sync.sh"
echo
