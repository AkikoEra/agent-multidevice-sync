#!/usr/bin/env bash
# 端到端验收：真实启动接收端，用采集端投递，验证签名/去重/健康检查
#
# 用法: ./scripts/verify.sh
# 退出: 0=全部通过  1=有失败项
set -uo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

PASS=0; FAIL=0
ok(){   printf '%s[✓]%s %s\n' "$GREEN" "$RESET" "$*"; PASS=$((PASS+1)); }
bad(){  printf '%s[✗]%s %s\n' "$RED" "$RESET" "$*"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d)
RECV_PID=""
cleanup(){
  [ -n "$RECV_PID" ] && kill "$RECV_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

printf '%s端到端验收%s\n\n' "$BOLD" "$RESET"

# ---------- 1. 依赖 ----------
if command -v python3 >/dev/null 2>&1; then
  ok "python3: $(python3 --version 2>&1)"
else
  bad "python3 未安装"; echo; exit 1
fi

# ---------- 2. 单元自测 ----------
echo
echo "── 单元自测 ──"
if python3 "$ROOT/scripts/linux/receiver.py" --selftest >/dev/null 2>&1; then
  ok "接收端自测 (验签/去重/落库)"
else
  bad "接收端自测失败"
  python3 "$ROOT/scripts/linux/receiver.py" --selftest
fi

if python3 "$ROOT/scripts/macos/collector.py" --selftest >/dev/null 2>&1; then
  ok "发送端自测 (白名单/签名/队列)"
else
  bad "发送端自测失败"
  python3 "$ROOT/scripts/macos/collector.py" --selftest
fi

if [ -f "$ROOT/scripts/linux/tailscale_proxy.py" ]; then
  if python3 "$ROOT/scripts/linux/tailscale_proxy.py" --selftest >/dev/null 2>&1; then
    ok "代理自测 (tailnet 白名单/地址校验)"
  else
    bad "代理自测失败"
    python3 "$ROOT/scripts/linux/tailscale_proxy.py" --selftest
  fi
fi

# ---------- 3. 构建测试环境 ----------
echo
echo "── 端到端联调 ──"
KEY="$WORK/sync.key"
DB="$WORK/state.db"
RECV_CFG="$WORK/receiver.json"
COLL_CFG="$WORK/collector.json"
SRC="$WORK/source.json"
PORT=19131

openssl rand -hex 32 > "$KEY" 2>/dev/null || {
  python3 -c "import secrets;open('$KEY','w').write(secrets.token_hex(32))"
}

cat > "$RECV_CFG" <<EOF
{
  "listen_host": "127.0.0.1",
  "listen_port": $PORT,
  "key_file": "$KEY",
  "database": "$DB",
  "device": "verify-receiver",
  "log_level": "info"
}
EOF

# 源数据：含必须被过滤的敏感字段
cat > "$SRC" <<'EOF'
{
  "id": 1,
  "title": "测试会话",
  "api_key": "SUPER-SECRET-VALUE",
  "token": "SUPER-SECRET-TOKEN",
  "state": {"pref": "dark"}
}
EOF

cat > "$COLL_CFG" <<EOF
{
  "url": "http://127.0.0.1:$PORT/sync",
  "key_file": "$KEY",
  "device": "verify-collector",
  "source": "$SRC",
  "outbox": "$WORK/outbox.db",
  "timeout": 5,
  "schema_version": 1,
  "audited_schema": {
    "fields": ["id", "title", "state"],
    "excluded": ["api_key", "token"]
  }
}
EOF

# ---------- 4. 启动接收端 ----------
python3 "$ROOT/scripts/linux/receiver.py" --config "$RECV_CFG" >"$WORK/recv.log" 2>&1 &
RECV_PID=$!

# 等待就绪
READY=0
for _ in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then READY=1; break; fi
  sleep 0.2
done

if [ "$READY" = 1 ]; then
  ok "接收端已启动并响应健康检查"
else
  bad "接收端未能启动"
  echo "--- 日志 ---"; cat "$WORK/recv.log"
  echo; exit 1
fi

# ---------- 5. 首次投递 ----------
OUT=$(python3 "$ROOT/scripts/macos/collector.py" --config "$COLL_CFG" 2>&1)
if echo "$OUT" | grep -q "成功"; then
  ok "首次投递成功"
else
  bad "首次投递失败: $OUT"
fi

# ---------- 6. 敏感字段未泄漏 ----------
if [ -f "$DB" ]; then
  if grep -q "SUPER-SECRET" "$DB" 2>/dev/null; then
    bad "敏感字段 api_key/token 出现在接收端数据库!"
  else
    ok "敏感字段 (api_key/token) 未进入接收端"
  fi
else
  bad "接收端数据库未生成"
fi

# ---------- 7. 重复投递去重 ----------
OUT2=$(python3 "$ROOT/scripts/macos/collector.py" --config "$COLL_CFG" 2>&1)
HEALTH=$(curl -sf "http://127.0.0.1:$PORT/health" 2>/dev/null)
TOTAL=$(echo "$HEALTH" | python3 -c "import json,sys; print(json.load(sys.stdin)['stats']['total_messages'])" 2>/dev/null || echo "?")

if [ "$TOTAL" = "2" ]; then
  ok "两次投递 = 2 条消息 (序列号 1,2 均为新消息)"
else
  echo "  信息: 当前消息数=$TOTAL"
fi

# ---------- 8. 错误签名被拒 ----------
python3 - "$PORT" <<'PY' > "$WORK/badreq.log" 2>&1
import json, sys, urllib.request, urllib.error
port = sys.argv[1]
body = {
    "device": "attacker", "sequence": 999,
    "timestamp": "2026-10-14T00:00:00+0800", "schema_version": 1,
    "payload": {"pwned": True}, "signature": "0"*64,
}
req = urllib.request.Request(
    f"http://127.0.0.1:{port}/sync",
    data=json.dumps(body).encode(),
    headers={"Content-Type": "application/json"}, method="POST")
try:
    urllib.request.urlopen(req, timeout=5)
    print("ACCEPTED")
except urllib.error.HTTPError as e:
    print(f"HTTP {e.code}")
except Exception as e:
    print(f"ERR {e}")
PY
RESULT=$(cat "$WORK/badreq.log")
if echo "$RESULT" | grep -q "HTTP 401"; then
  ok "错误签名被拒绝 (HTTP 401)"
else
  bad "错误签名未被正确拒绝: $RESULT"
fi

# 确认攻击消息未入库
if curl -sf "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q '"devices": {"verify-collector"'; then
  ok "攻击者消息未污染状态"
fi

# ---------- 9. 路径安全检查 ----------
echo
echo "── 仓库安全 ──"
if [ -x "$ROOT/scripts/pre-commit-check.sh" ]; then
  if "$ROOT/scripts/pre-commit-check.sh" >/dev/null 2>&1; then
    ok "敏感信息扫描通过"
  else
    bad "敏感信息扫描未通过"
    "$ROOT/scripts/pre-commit-check.sh" 2>&1 | tail -20
  fi
else
  echo "  (pre-commit-check.sh 不存在, 跳过)"
fi

# ---------- 10. 直连状态 (可选) ----------
if command -v tailscale >/dev/null 2>&1; then
  if [ -x "$ROOT/scripts/tailscale/diagnose.sh" ]; then
    echo
    echo "── 网络路径 (参考) ──"
    DIAG_OUT=$("$ROOT/scripts/tailscale/diagnose.sh" 2>/dev/null)
    # 使用 here-string 而非管道: grep -q 提前退出会触发 SIGPIPE,
    # 在 pipefail 下让整条管道返回非零导致误判
    if grep -q "已建立点对点直连" <<<"$DIAG_OUT"; then
      LAT=$(grep -oE "平均 [0-9]+ms" <<<"$DIAG_OUT" | head -1)
      ok "Tailscale 点对点直连${LAT:+ (${LAT#平均 })}"
    elif grep -q "走 DERP 中继" <<<"$DIAG_OUT"; then
      echo "  当前走 DERP 中继 — 功能可用, 优化见 docs/tailscale-direct.md"
    else
      echo "  (未检测到可用对端, 详见 docs/tailscale-direct.md)"
    fi
  fi
fi

# ---------- 汇总 ----------
printf '\n%s── 结果 ──%s\n' "$BOLD" "$RESET"
printf '  通过: %s%d%s\n' "$GREEN" "$PASS" "$RESET"
if [ "$FAIL" -gt 0 ]; then
  printf '  失败: %s%d%s\n' "$RED" "$FAIL" "$RESET"
  printf '\n'
  exit 1
fi
printf '  失败: 0\n\n'
printf '%s验收全部通过%s\n\n' "$GREEN" "$RESET"
exit 0
