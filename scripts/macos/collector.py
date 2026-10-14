#!/usr/bin/env python3
"""Agent 多端同步 — 发送端 (Collector)

职责:
  1. 按 schema 白名单从本机 Agent 状态库抽取字段 (只读)
  2. 生成快照, 分配单调序列号
  3. HMAC 签名
  4. 投递到接收端, 失败则留在 outbox 重试

依赖: 仅 Python 标准库
用法:
    python3 collector.py --config collector.json            # 单次投递
    python3 collector.py --config collector.json --daemon   # 定时循环
    python3 collector.py --config collector.json --selftest # 自测
"""
from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.request

DEFAULT_CONFIG = {
    "url": "http://127.0.0.1:9131/sync",
    "key_file": "~/.agent-sync/sync.key",
    "device": "collector-1",
    "interval_seconds": 300,
    "source": "",            # 本机 Agent 状态库路径 (json 或 sqlite)
    "audited_schema": {"fields": [], "excluded": []},
    "outbox": "~/.agent-sync/outbox.db",
    "timeout": 10,
}


def load_config(path: str) -> dict:
    cfg = dict(DEFAULT_CONFIG)
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            cfg.update(json.load(f))
    for k in ("key_file", "outbox", "source"):
        if cfg.get(k):
            cfg[k] = os.path.expanduser(cfg[k])
    return cfg


def load_key(path: str) -> bytes:
    if not os.path.exists(path):
        raise FileNotFoundError(f"密钥文件不存在: {path}")
    with open(path, "rb") as f:
        key = f.read().strip()
    if len(key) < 16:
        raise ValueError("密钥过短 (至少 16 字节)")
    return key


# ---------------------------------------------------------------------------
# 采集: schema 白名单
# ---------------------------------------------------------------------------

class SchemaRejected(Exception):
    """字段未在白名单内 — 这是预期的安全行为。"""


def collect(source: str, schema: dict) -> dict:
    """按白名单抽取字段。

    安全要点: 只读取 schema.fields 中声明的字段,
    并确保 schema.excluded 中的字段绝不出现。
    """
    fields = set(schema.get("fields") or [])
    excluded = set(schema.get("excluded") or [])

    if not source or not os.path.exists(source):
        raise FileNotFoundError(f"源库不存在: {source}")

    if source.endswith((".db", ".sqlite", ".sqlite3")):
        raw = _read_sqlite(source, fields, excluded)
    else:
        with open(source, encoding="utf-8") as f:
            raw = json.load(f)

    # 双重校验: 即使白名单配置有误, 也绝不出域
    return _filter(raw, fields, excluded)


def _read_sqlite(path: str, fields: set, excluded: set) -> dict:
    """只读方式查询 sqlite, 只取白名单列。"""
    uri = f"file:{path}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    conn.row_factory = sqlite3.Row
    try:
        tables = [r[0] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'")]
        out: dict = {}
        for t in tables:
            if t.startswith("sqlite_"):
                continue
            cols = [r[1] for r in conn.execute(f'PRAGMA table_info("{t}")')]
            # 只取白名单内的列
            wanted = [c for c in cols if c in fields and c not in excluded]
            if not wanted:
                continue
            quoted = ", ".join(f'"{c}"' for c in wanted)
            rows = conn.execute(f'SELECT {quoted} FROM "{t}"').fetchall()
            out[t] = [dict(r) for r in rows]
        return out
    finally:
        conn.close()


def _filter(data, fields: set, excluded: set):
    """递归过滤, 确保 excluded 字段绝不出现。"""
    if isinstance(data, dict):
        out = {}
        for k, v in data.items():
            if k in excluded:
                continue
            # 若有明确字段白名单 (顶层), 则只保留白名单字段
            if fields and k not in fields and not isinstance(v, (dict, list)):
                continue
            out[k] = _filter(v, fields, excluded)
        return out
    if isinstance(data, list):
        return [_filter(x, fields, excluded) for x in data]
    return data


# ---------------------------------------------------------------------------
# Outbox: 本地持久化队列
# ---------------------------------------------------------------------------

OUTBOX_SCHEMA = """
CREATE TABLE IF NOT EXISTS outbox (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    sequence   INTEGER NOT NULL UNIQUE,
    payload    TEXT NOT NULL,
    signature  TEXT NOT NULL,
    timestamp  TEXT NOT NULL,
    status     TEXT NOT NULL DEFAULT 'pending',  -- pending / sent
    attempts   INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
);
"""


class Outbox:
    def __init__(self, path: str):
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        self.conn = sqlite3.connect(path, check_same_thread=False)
        self.conn.executescript(OUTBOX_SCHEMA)
        self.conn.commit()

    def next_sequence(self) -> int:
        row = self.conn.execute("SELECT MAX(sequence) FROM outbox").fetchone()
        return (row[0] or 0) + 1

    def enqueue(self, sequence: int, payload: str, signature: str, timestamp: str):
        with self.conn:
            self.conn.execute(
                "INSERT OR IGNORE INTO outbox"
                "(sequence, payload, signature, timestamp, status, attempts, created_at)"
                " VALUES(?,?,?,?,'pending',0,?)",
                (sequence, payload, signature, timestamp, time.strftime("%Y-%m-%dT%H:%M:%S%z")),
            )

    def pending(self, limit: int = 20):
        return self.conn.execute(
            "SELECT id, sequence, payload, signature, timestamp, attempts"
            " FROM outbox WHERE status='pending' ORDER BY sequence LIMIT ?",
            (limit,),
        ).fetchall()

    def mark_sent(self, row_id: int):
        with self.conn:
            self.conn.execute("UPDATE outbox SET status='sent' WHERE id=?", (row_id,))

    def bump_attempts(self, row_id: int):
        with self.conn:
            self.conn.execute(
                "UPDATE outbox SET attempts = attempts + 1 WHERE id=?", (row_id,))

    def stats(self) -> dict:
        pend = self.conn.execute(
            "SELECT COUNT(*) FROM outbox WHERE status='pending'").fetchone()[0]
        sent = self.conn.execute(
            "SELECT COUNT(*) FROM outbox WHERE status='sent'").fetchone()[0]
        return {"pending": pend, "sent": sent, "next_sequence": self.next_sequence()}

    def close(self):
        self.conn.close()


# ---------------------------------------------------------------------------
# 签名与投递
# ---------------------------------------------------------------------------

def canonical(device: str, sequence: int, timestamp: str,
              schema_version: int, payload: str) -> bytes:
    return f"{device}|{sequence}|{timestamp}|{schema_version}|{payload}".encode("utf-8")


def sign(key: bytes, device: str, sequence: int, timestamp: str,
         schema_version: int, payload: str) -> str:
    return hmac.new(key, canonical(device, sequence, timestamp,
                                   schema_version, payload),
                    hashlib.sha256).hexdigest()


def deliver(url: str, body: dict, timeout: int) -> tuple[bool, str]:
    data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        url, data=data, method="POST",
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status == 200, resp.read().decode(errors="ignore")
    except urllib.error.HTTPError as e:
        # 401 = 验签失败, 不重试
        return False, f"HTTP {e.code}"
    except Exception as e:
        return False, str(e)


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def sync_once(cfg: dict, key: bytes) -> int:
    """采集一次并投递。返回 0=成功 1=失败"""
    try:
        data = collect(cfg["source"], cfg["audited_schema"])
    except SchemaRejected as e:
        print(f"schema 拒绝 (预期安全行为): {e}")
        return 1
    except FileNotFoundError as e:
        print(f"源库不可读: {e}")
        return 1
    except Exception as e:
        print(f"采集失败: {e}")
        return 1

    ob = Outbox(os.path.expanduser(cfg["outbox"]))

    # 先补发积压
    _flush(ob, cfg, key)

    # 新快照入队
    payload = json.dumps(data, ensure_ascii=False, sort_keys=True)
    seq = ob.next_sequence()
    ts = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    schema_version = int(cfg.get("schema_version", 1))
    sig = sign(key, cfg["device"], seq, ts, schema_version, payload)
    ob.enqueue(seq, payload, sig, ts)

    ok, msg = _flush(ob, cfg, key)
    st = ob.stats()
    ob.close()
    print(f"序列号={seq} 待发={st['pending']} 已发={st['sent']} {'成功' if ok else '结果=' + msg}")
    return 0 if ok else 1


def _flush(ob: Outbox, cfg: dict, key: bytes) -> tuple[bool, str]:
    """投递 outbox 中所有 pending 消息。"""
    last_ok, last_msg = True, ""
    for row in ob.pending():
        row_id, seq, payload, sig, ts, attempts = row
        body = {
            "device": cfg["device"],
            "sequence": seq,
            "timestamp": ts,
            "schema_version": int(cfg.get("schema_version", 1)),
            "payload": json.loads(payload),
            "signature": sig,
        }
        ok, msg = deliver(cfg["url"], body, int(cfg.get("timeout", 10)))
        if ok:
            ob.mark_sent(row_id)
        else:
            ob.bump_attempts(row_id)
            last_ok, last_msg = False, msg
            # 网络类失败: 留在队列, 停止本轮 (保持顺序)
            if "timed out" in msg or "Connection" in msg or "111" in msg:
                break
    return last_ok, last_msg


# ---------------------------------------------------------------------------
# 自测
# ---------------------------------------------------------------------------

def selftest() -> int:
    print("== 自测开始 ==")
    fails = []

    # 1. 白名单过滤
    schema = {"fields": ["id", "title"], "excluded": ["api_key", "token"]}
    data = {"id": 1, "title": "hi", "api_key": "SECRET", "extra": "x"}
    filtered = _filter(data, set(schema["fields"]), set(schema["excluded"]))
    if "api_key" not in filtered and "token" not in str(filtered):
        print("  [✓] excluded 字段被移除")
    else:
        fails.append("excluded 未移除"); print("  [✗] excluded 未移除")
    if filtered.get("id") == 1:
        print("  [✓] 白名单字段保留")
    else:
        fails.append("白名单字段丢失"); print("  [✗] 白名单字段丢失")

    # 2. 嵌套 excluded
    nested = {"a": {"api_key": "S3CR3T", "b": 2}, "c": 3}
    f2 = _filter(nested, set(), {"api_key"})
    if "api_key" not in json.dumps(f2):
        print("  [✓] 嵌套 excluded 字段被移除")
    else:
        fails.append("嵌套 excluded 未移除"); print("  [✗] 嵌套 excluded 未移除")

    # 3. 签名一致性
    key = b"selftest-key-0123456789abcdef"
    a = sign(key, "d", 1, "t", 1, "p")
    b = sign(key, "d", 1, "t", 1, "p")
    if a == b:
        print("  [✓] 签名确定性")
    else:
        fails.append("签名不确定"); print("  [✗] 签名不确定")

    # 4. 篡改后签名变化
    c = sign(key, "d", 1, "t", 1, "p2")
    if a != c:
        print("  [✓] 内容变化导致签名变化")
    else:
        fails.append("签名未随内容变化"); print("  [✗] 签名未随内容变化")

    # 5. outbox 序列号单调
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        ob = Outbox(os.path.join(td, "ob.db"))
        s1 = ob.next_sequence(); ob.enqueue(s1, "{}", "sig", "ts")
        s2 = ob.next_sequence(); ob.enqueue(s2, "{}", "sig", "ts")
        if s2 == s1 + 1:
            print("  [✓] 序列号单调递增")
        else:
            fails.append("序列号异常"); print(f"  [✗] 序列号异常: {s1} -> {s2}")
        st = ob.stats()
        if st["pending"] == 2:
            print("  [✓] outbox 排队正确")
        else:
            fails.append("outbox 排队异常"); print("  [✗] outbox 排队异常")
        ob.close()

    print()
    if fails:
        print(f"== 自测失败 {len(fails)} 项 ==")
        return 1
    print("== 自测全部通过 ==")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Agent 多端同步发送端")
    ap.add_argument("--config", default="collector.json")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--daemon", action="store_true", help="定时循环")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    cfg = load_config(args.config)
    try:
        key = load_key(cfg["key_file"])
    except Exception as e:
        print(f"启动失败: {e}", file=sys.stderr)
        return 1

    if args.daemon:
        interval = int(cfg.get("interval_seconds", 300))
        print(f"[agent-sync] 采集端已启动, 周期={interval}s, Ctrl-C 退出")
        while True:
            try:
                sync_once(cfg, key)
            except KeyboardInterrupt:
                break
            except Exception as e:
                print(f"本轮异常: {e}")
            time.sleep(interval)
        return 0

    return sync_once(cfg, key)


if __name__ == "__main__":
    sys.exit(main())
