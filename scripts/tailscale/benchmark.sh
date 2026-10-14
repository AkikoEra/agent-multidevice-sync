#!/usr/bin/env bash
# Tailscale 连接基准测试
# 测量当前路径的延迟与带宽，用于对比中继 vs 直连
#
# 用法: benchmark.sh [peer-tailscale-ip] [次数]
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
if [ -z "$PEER" ]; then
  echo "未找到对端，请指定: benchmark.sh <peer-tailscale-ip>"
  exit 1
fi

N="${2:-20}"

echo "目标: $PEER"
echo "次数: $N"
echo

# ---- 延迟测试 ----
# 注意: tailscale ping 默认 --until-direct=true，直连已建立时立即返回
# 必须显式关闭，否则只能采到 1 个样本
echo "── 延迟测试 ──"
PING_OUT=$($TS ping -c "$N" --until-direct=false --timeout 10s "$PEER" 2>&1 \
           | grep -oE 'in [0-9]+ms' | grep -oE '[0-9]+')

if [ -n "$PING_OUT" ]; then
  # 用 sort 做中位数，避免依赖 gawk 的 asort
  echo "$PING_OUT" | awk '{a[NR]=$1; s+=$1; if(NR==1||$1<min)min=$1; if($1>max)max=$1}
    END{
      n=NR
      printf "  样本数:   %d\n", n
      printf "  最小延迟: %d ms\n", min
      printf "  平均延迟: %d ms\n", s/n
      printf "  最大延迟: %d ms\n", max
    }'
  MED=$(echo "$PING_OUT" | sort -n | awk '{a[NR]=$1} END{
    if(NR==0){exit} if(NR%2) print a[(NR+1)/2]; else printf "%d\n",(a[NR/2]+a[NR/2+1])/2 }')
  printf "  中位延迟: %s ms\n" "$MED"
else
  echo "  测量失败"
fi

echo
echo "── 路径判定 ──"
PATH_OUT=$($TS ping -c 1 --timeout 10s "$PEER" 2>&1)
if echo "$PATH_OUT" | grep -q 'via DERP'; then
  echo "  当前走 DERP 中继（延迟受中继节点位置影响）"
elif echo "$PATH_OUT" | grep -qE 'via \['; then
  echo "  当前 IPv6 点对点直连"
elif echo "$PATH_OUT" | grep -qE 'via [0-9]'; then
  echo "  当前 IPv4 点对点直连"
else
  echo "  无法判定"
fi

echo
echo "── 说明 ──"
echo "  直连延迟通常 5-50ms；中继通常 100-400ms"
echo "  优化方法见 docs/tailscale-direct.md"
