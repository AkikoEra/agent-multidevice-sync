#!/usr/bin/env bash
# 发布前敏感信息扫描
#
# 检查仓库中是否残留：
#   1. 真实公网 IPv4 地址（允许回环/私有/保留/文档示例网段）
#   2. 真实 IPv6 全局地址
#   3. 密钥、令牌、私钥
#   4. 真实主机名 / 用户名 / 未白名单域名
#
# 用法: ./scripts/pre-commit-check.sh
# 退出码: 0 = 通过, 1 = 发现敏感信息
set -uo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'
BOLD=$'\033[1m'; RESET=$'\033[0m'

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FAIL=0
FOUND=()

# 额外的通用隐私模式: tailscale status 输出、设备名、真实身份线索
GENERIC_PRIVACY='MacBook Pro|iPhon[a-z]*|Wakiko|的MacBook|@  *(linux|macOS|iOS)|relay "[a-z]{3}"|AkikoEra@|XDR[0-9]{3,4}|路由器型号:|Arch Linux'

# 扫描时排除自身与本地私有名单 (后者已被 .gitignore 屏蔽)
SELF='^\./scripts/pre-commit-check\.sh|^\./\.name-denylist'

# 文档必需的示例地址/占位符白名单
ALLOW_IP_RE='127\.0\.0\.|0\.0\.0\.0|255\.255\.255|192\.168\.[0-9x]+\.|10\.[0-9]{1,3}\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.64\.|100\.x\.x\.x|169\.254\.|239\.255\.255\.250|223\.[56]\.[56]\.[56]|1\.1\.1\.1|8\.8\.8\.8|9\.9\.9\.9|203\.0\.113\.|198\.51\.100\.|192\.0\.2\.|203\.x\.x\.x|\[IPv6|<IPv6|<peer|<gateway|<接收端|<本机|IPv4:|ip_network'

# 合法域名白名单（文档链接 + 标准 DTD）
ALLOW_DOM_RE='github\.com|githubusercontent\.com|star-history\.com|shields\.io|tailscale\.com|xmlsoap\.org|w3\.org|apple\.com|localhost|example\.(com|org|net)'

# 真实主机名/用户名: 使用本地私有名单，避免把真实标识写进公开仓库
# 将你自己的主机名/用户名每行一条写入 .name-denylist (已被 .gitignore 屏蔽)
NAME_DENY_FILE="$ROOT_DIR/.name-denylist"
REAL_NAMES='user-name-pattern'
if [ -f "$NAME_DENY_FILE" ]; then
  # 本地名单: 去注释与空行后用 | 连接
  LOCAL_NAMES=$(grep -vE '^\s*(#|$)' "$NAME_DENY_FILE" 2>/dev/null | paste -sd'|' -)
  [ -n "$LOCAL_NAMES" ] && REAL_NAMES="$LOCAL_NAMES"
fi

scan() {
  local desc="$1" pattern="$2" allowed="$3"
  local hits
  hits=$(grep -rInE "$pattern" . 2>/dev/null \
    | grep -vE '^\./\.git/' \
    | grep -vE "$SELF" \
    | grep -vE "$allowed" \
    | head -15)
  if [ -n "$hits" ]; then
    printf '%s[✗] %s%s\n' "$RED" "$desc" "$RESET"
    printf '%s\n' "$hits" | sed 's/^/     /'
    FAIL=1
    FOUND+=("$desc")
  else
    printf '%s[✓]%s %s\n' "$GREEN" "$RESET" "$desc"
  fi
}

printf '%s敏感信息扫描%s\n\n' "$BOLD" "$RESET"

# ---------- IPv4 ----------
scan "真实 IPv4 地址（已排除私有/保留/示例）" \
  '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' "$ALLOW_IP_RE"

# ---------- IPv6 ----------
scan "真实 IPv6 地址" \
  '\b([0-9a-fA-F]{1,4}:){4,7}[0-9a-fA-F]{1,4}\b' \
  'IPv6|fe80|::1\b|2400:3200|fd7a:115c|^\s*$'

# ---------- 密钥 ----------
scan "疑似密钥/令牌 (40+ 十六进制)" \
  '\b[0-9a-fA-F]{40,}\b' \
  'checksum|sha256|AAAA|hash|正则|pattern|example'

scan "疑似 Bearer/Token/Secret" \
  '(Bearer|api[_-]?key|secret|password|passwd|token)\s*[:=]\s*["'"'"'][^"'"'"']{8,}["'"'"']' \
  'example|占位|your[-_]|xxxx|<|未授权|不要|不得'

scan "私钥块" \
  '-----BEGIN (RSA |EC |OPENSSH |PGP )?PRIVATE KEY' '^$'

scan "AWS Access Key" \
  '\b(AKIA|ASIA)[0-9A-Z]{16}\b' '^$'

scan "GitHub Token" \
  '\bgh[pousr]_[A-Za-z0-9]{36,}\b' '^$'

# ---------- 域名 ----------
scan "未白名单域名" \
  'https?://[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' "$ALLOW_DOM_RE"

# ---------- 主机名 ----------
scan "真实主机名 / 用户名" "$REAL_NAMES" '^$'

# ---------- 数据文件 ----------
# 只抓真实数据文件（部署目录、系统路径），排除脚本中的临时变量与文档示例
scan "疑似真实数据/密钥文件" \
  '(deployment/|/var/lib/|/etc/)[^ ]*\.(db|sqlite|key|pem|p12|pfx)' \
  'example|\.example|pre-commit|\.gitignore|屏蔽|文档|outbox|agent-sync|verify\.sh|collector\.py|receiver\.py|mktemp|WORK|CONTRIBUTING'

# ---------- 通用隐私模式 ----------
scan "设备名 / tailscale status 输出" "$GENERIC_PRIVACY" '<路由器|<peer'

printf '\n'
if [ "$FAIL" = 1 ]; then
  printf '%s发现敏感内容，处理后再提交:%s\n' "$RED" "$RESET"
  for f in "${FOUND[@]}"; do printf '  - %s\n' "$f"; done
  printf '\n处理方式:\n'
  printf '  - IP 地址  → 替换为 <peer>、100.x.x.x、[IPv6] 等占位符\n'
  printf '  - 密钥     → 仅保留在 *.example 模板\n'
  printf '  - 主机名   → 替换为 <peer-host> 等通用名\n'
  printf '  - 域名     → 加入本脚本 ALLOW_DOM_RE 白名单\n'
  printf '  - 文件路径 → 加入 ALLOW 白名单或改写\n'
  exit 1
fi

printf '%s全部通过，未发现敏感信息%s\n\n' "$GREEN" "$RESET"
exit 0
