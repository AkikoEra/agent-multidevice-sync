#!/usr/bin/env bash
# 持续监控 Tailscale 连接路径，检测从中继回落
#
# 用法: watch-path.sh [peer] [间隔秒]
# 退出: Ctrl-C
set -uo pipefail

TS=$(command -v tailscale || echo \
  $([ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ] && \
    echo /Applications/Tailscale.app/Contents/MacOS/Tailscale))

if [ -z "$TS" ] || [ ! -x "$TS" ]; then
  echo "未找到 tailscale"; exit 1
fi

PEER="${1:-}"
if [ -z "$PEER" ]; then
  PEER=$($TS status 2>/dev/null | awk '$2 !~ /localhost/ && /active|online/ {print $1; exit}')
fi
INTERVAL="${2:-10}"

if [ -z "$PEER" ]; then
  echo "未找到对端"; exit 1
fi

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; RESET=$'\033[0m'

echo "监控目标: $PEER"
echo "间隔: ${INTERVAL}s   退出: Ctrl-C"
echo
printf '%-20s %-14s %s\n' "时间" "路径" "延迟"
echo "────────────────────────────────────────────────────"

LAST_PATH=""
while true; do
  NOW=$(date '+%H:%M:%S')
  OUT=$($TS ping -c 1 --until-direct=false --timeout 8s "$PEER" 2>&1)

  if echo "$OUT" | grep -q 'via DERP'; then
    PATH_NAME="DERP中继"
    COLOR=$YELLOW
  elif echo "$OUT" | grep -qE 'via \['; then
    PATH_NAME="IPv6直连"
    COLOR=$GREEN
  elif echo "$OUT" | grep -qE 'via [0-9]'; then
    PATH_NAME="IPv4直连"
    COLOR=$GREEN
  elif echo "$OUT" | grep -qi 'no answer'; then
    PATH_NAME="无响应"
    COLOR=$RED
  else
    PATH_NAME="未知"
    COLOR=$RED
  fi

  LAT=$(echo "$OUT" | grep -oE 'in [0-9]+ms' | grep -oE '[0-9]+' | head -1)
  LAT="${LAT:-—}ms"

  printf '%-20s %s%-14s%s %s\n' "$NOW" "$COLOR" "$PATH_NAME" "$RESET" "$LAT"

  # 路径变化时告警
  if [ -n "$LAST_PATH" ] && [ "$PATH_NAME" != "$LAST_PATH" ]; then
    case "$PATH_NAME" in
      DERP中继|无响应)
        printf '%s  ↑ 路径发生变化，已回落到 %s%s\n' "$RED" "$PATH_NAME" "$RESET"
        ;;
    esac
  fi
  LAST_PATH="$PATH_NAME"

  sleep "$INTERVAL"
done
