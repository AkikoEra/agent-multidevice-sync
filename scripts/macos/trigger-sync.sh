#!/usr/bin/env bash
# 手动触发一次同步并显示结果
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CONF="${HOME}/.agent-sync/collector.json"

if [ ! -f "$CONF" ]; then
  echo "未找到配置: $CONF"
  echo "请先运行 ./scripts/macos/install-collector.sh"
  exit 1
fi

echo "── 配置 ──"
python3 -c "
import json
c=json.load(open('$CONF'))
print('  设备名:  ', c.get('device'))
print('  接收端:  ', c.get('url'))
print('  源库:    ', c.get('source'))
print('  白名单:  ', len((c.get('audited_schema') or {}).get('fields') or []), '个字段')
print('  排除:    ', len((c.get('audited_schema') or {}).get('excluded') or []), '个字段')
"
echo
echo "── 投递 ──"
python3 "$ROOT/scripts/macos/collector.py" --config "$CONF"
echo
echo "── outbox 状态 ──"
python3 -c "
import sqlite3, os, json
c=json.load(open('$CONF'))
p=os.path.expanduser(c.get('outbox','~/.agent-sync/outbox.db'))
if os.path.exists(p):
    conn=sqlite3.connect(p)
    pend=conn.execute(\"SELECT COUNT(*) FROM outbox WHERE status='pending'\").fetchone()[0]
    sent=conn.execute(\"SELECT COUNT(*) FROM outbox WHERE status='sent'\").fetchone()[0]
    print(f'  待发: {pend}   已发: {sent}')
else:
    print('  (outbox 不存在)')
"
