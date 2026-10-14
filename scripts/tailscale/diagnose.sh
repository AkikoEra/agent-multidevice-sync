#!/usr/bin/env bash
# Tailscale 连接质量一键诊断
# 输出：当前路径、延迟、NAT 类型、IPv6 可用性、修复建议
set -uo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

info(){ printf '%s\n' "$*"; }
ok(){   printf '%s[✓]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn(){ printf '%s[!]%s %s\n' "$YELLOW" "$RESET" "$*"; }
bad(){  printf '%s[✗]%s %s\n' "$RED" "$RESET" "$*"; }
title(){ printf '\n%s── %s %s──\n' "$CYAN" "$*" "$RESET"; }

# ---------- 0. 前置检查 ----------
title "前置检查"

if ! command -v tailscale >/dev/null 2>&1; then
  # macOS 常见安装路径
  for p in /Applications/Tailscale.app/Contents/MacOS/Tailscale \
           /usr/local/bin/tailscale; do
    [ -x "$p" ] && TAILScale="$p" && break
  done
  if [ -z "${TAILScale:-}" ]; then
    bad "未找到 tailscale，请先安装 https://tailscale.com/download"
    exit 1
  fi
  TS="$TAILScale"
else
  TS=tailscale
fi
ok "tailscale: $($TS version 2>/dev/null | head -1)"

if ! $TS status >/dev/null 2>&1; then
  bad "tailscale 未登录或守护进程未运行"
  info "  尝试: tailscale up"
  exit 1
fi

# ---------- 1. 在线状态 ----------
title "1. 设备在线状态"
ONLINE=0; OFFLINE=0
while IFS= read -r line; do
  case "$line" in
    *offline*) warn "$line"; OFFLINE=$((OFFLINE+1));;
    *online*|*active*) ok "$line"; ONLINE=$((ONLINE+1));;
  esac
done < <($TS status 2>/dev/null | grep -v '^$' | grep -v '^\[')
[ "$ONLINE" -gt 0 ] && ok "在线设备: $ONLINE" || bad "无在线对端"

# ---------- 2. 选择一个 peer ----------
title "2. 连接路径"
PEER=$($TS status 2>/dev/null | awk '$2 !~ /localhost/ && /active|online/ {print $1; exit}')
if [ -z "$PEER" ]; then
  PEER=$($TS status 2>/dev/null | awk '$2 !~ /localhost|^\-/ && $1 ~ /^[0-9a-f]+:/ {print $1; exit}')
fi
if [ -z "$PEER" ]; then
  warn "未找到可测试的对端"
else
  info "测试目标: ${PEER}"
  # ---------- 3. ping 探测 ----------
  PING_OUT=$($TS ping -c 5 --until-direct=false --timeout 10s "$PEER" 2>&1 || true)
  printf '%s\n' "$PING_OUT" | sed 's/^/  /'

  # 判读路径（默认 unknown，只有证据支持时才下结论）
  PATH_TYPE="unknown"
  AVG_MS=""
  if printf '%s' "$PING_OUT" | grep -qi 'via DERP'; then
    PATH_TYPE="derp"
  elif printf '%s' "$PING_OUT" | grep -qE 'via \[?[0-9a-f:]+\]?'; then
    PATH_TYPE="direct"
  fi

  # 计算平均延迟
  AVG_MS=$(printf '%s' "$PING_OUT" | grep -oE 'in [0-9]+ms' \
           | grep -oE '[0-9]+' | awk '{s+=$1;n++} END{if(n)printf "%.0f",s/n}')

  echo
  case "$PATH_TYPE" in
    derp)
      bad "当前走 DERP 中继${AVG_MS:+，平均 ${AVG_MS}ms}"
      info "  中继是保底机制，功能正常但延迟高"
      ;;
    direct)
      if [ -n "$AVG_MS" ] && [ "$AVG_MS" -lt 50 ]; then
        ok "已建立点对点直连，平均 ${AVG_MS}ms"
      else
        ok "已直连，平均 ${AVG_MS:-?}ms"
      fi
      ;;
  esac
  printf '%s\n' "$PING_OUT" | grep -qi 'not established' \
    && warn "  出现 'direct connection not established'"
fi

# ---------- 3. netcheck ----------
title "3. NAT 与网络能力"
# 只保留 Report 段，过滤 portmap 噪音日志
NC=$($TS netcheck 2>/dev/null | sed -n '/Report:/,$p')
printf '%s\n' "$NC" | sed 's/^/  /'

V4=$(printf '%s' "$NC" | grep -E '^\s*\* IPv4:' | sed 's/.*IPv4: //' | head -1)
V6=$(printf '%s' "$NC" | grep -E '^\s*\* IPv6:' | sed 's/.*IPv6: //' | head -1)
VARIES=$(printf '%s' "$NC" | grep -E '^\s*\* MappingVariesByDestIP:' | sed 's/.*: //' | head -1)
PMAP=$(printf '%s' "$NC" | grep -E '^\s*\* PortMapping:' | sed 's/.*: //' | head -1)
UDP=$(printf '%s' "$NC" | grep -E '^\s*\* UDP:' | sed 's/.*UDP: //' | head -1)

echo
case "$UDP" in false*) bad "出站 UDP 不可用，无法打洞";; *) ok "UDP 出站: $UDP";; esac

case "$V6" in
  yes*) ok "IPv6: ${V6%%,*}" ;;
  *)    warn "IPv6: ${V6:-未检测到}" ;;
esac

case "$VARIES" in
  true)  warn "MappingVariesByDestIP: true = 对称型 NAT，IPv4 打洞基本失败" ;;
  false) ok "MappingVariesByDestIP: false = 锥型 NAT，IPv4 可打洞" ;;
esac

case "$PMAP" in
  *UPnP*|*NAT-PMP*|*PCP*) ok "PortMapping: $PMAP" ;;
  *) warn "无端口映射能力（PortMapping 为空）" ;;
esac

# ---------- 4. CGNAT 判定 ----------
title "4. CGNAT 判定"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROBE="$SCRIPT_DIR/probe_router.py"
GW=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
if [ -z "$GW" ]; then
  GW=$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')
fi

if [ -f "$PROBE" ]; then
  WAN_OUT=$(python3 "$PROBE" ${GW:+"$GW"} 2>&1)
  WAN_RC=$?
  printf '%s\n' "$WAN_OUT" | sed 's/^/  /'
  case "$WAN_RC" in
    1) CGNAT=1 ;;
    0) CGNAT=0 ;;
    *) CGNAT=unknown ;;
  esac
else
  info "未找到 probe_router.py，请手动查看路由器 WAN 地址"
  CGNAT=unknown
fi

# ---------- 5. 结论与建议 ----------
title "结论与建议"

NEED_IPV6=0
case "$PATH_TYPE" in
  direct)
    ok "已建立点对点直连，无需进一步优化"
    [ "${CGNAT:-unknown}" = "1" ] && info "  注: 仍处于 CGNAT 之后，直连依赖 IPv6 路径"
    ;;
  derp)
    warn "当前走 DERP 中继"
    if [ "${CGNAT:-unknown}" = "1" ]; then
      info "  CGNAT 已确认 —— IPv4 端口转发无效，不要在这层浪费时间"
    fi
    case "$VARIES" in
      true) info "  IPv4 为对称 NAT，IPv4 打洞不可行" ;;
    esac
    case "$V6" in
      yes*)
        info "  本机已有 IPv6，需确认对端也有，然后重启 tailscaled"
        info "  sudo systemctl restart tailscaled"
        ;;
      *)
        NEED_IPV6=1
        ;;
    esac
    ;;
  *) info "无法判断路径（未找到可测试的对端）" ;;
esac

if [ "$NEED_IPV6" = 1 ]; then
  bad "IPv6 不可用 —— 这是 CGNAT 环境下直连的关键"
  info ""
  info "修复步骤:"
  info "  1. 确认系统支持: ip -6 addr show scope global   (Linux)"
  info "                        ifconfig | grep inet6      (macOS)"
  info "  2. 在路由器后台开启 IPv6（双栈/前缀委派）"
  info "  3. 验证: ping -6 -c 3 2400:3200::1"
  info "  4. 重启: sudo systemctl restart tailscaled   (Linux)"
  info "             sudo launchctl kickstart -k system/com.tailscale.tailscaled  (macOS)"
  info "  5. 复测: $0"
  info ""
  info "  详见: docs/tailscale-direct.md"
elif [ "${CGNAT:-unknown}" = "1" ] && [ "$PATH_TYPE" = "derp" ]; then
  warn "CGNAT + 无 IPv6 → 只能走中继，功能可用，延迟较高"
  info "  可接受则不必强求直连；否则按上面步骤启用 IPv6"
fi

printf '\n%s诊断完成%s\n\n' "$BOLD" "$RESET"
