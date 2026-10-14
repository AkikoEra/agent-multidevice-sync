#!/usr/bin/env python3
"""Agent 多端同步 — 接收端 (Receiver)

职责:
  1. 接收来自采集端的快照
  2. HMAC 验签 (失败即丢弃)
  3. 序列号去重 (幂等)
  4. 落库

依赖: 仅 Python 标准库 (http.server / hmac / hashlib / sqlite3)
用法:
    python3 receiver.py --config receiver.json
    python3 receiver.py --config receiver.json --selftest

退出码:
    0 正常   1 配置/启动错误
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
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------

DEFAULT_CONFIG = {
    "listen_host": "127.0.0.1",     # 只监听回环或 Tailscale 网卡地址
    "listen_port": 9131,
    "key_file": "/etc/agent-sync/sync.key",
    "database": "/var/lib/agent-sync/state.db",
    "device": "linux-receiver",     # 本机标识
    "log_level": "info",
}

SIGNATURE_HEADER = "X-Sync-Signature"
DEVICE_HEADER = "X-Sync-Device"
SEQUENCE_HEADER = "X-Sync-Sequence"


def load_config(path: str) -> dict:
    cfg = dict(DEFAULT_CONFIG)
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            cfg.update(json.load(f))
    # 展开 ~
    for k in ("key_file", "database"):
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
# 存储层: 序列号去重
# ---------------------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS messages (
    device     TEXT NOT NULL,
    sequence   INTEGER NOT NULL,
    payload    TEXT NOT NULL,
    signature  TEXT NOT NULL,
    received_at TEXT NOT NULL,
    PRIMARY KEY (device, sequence)
);
CREATE TABLE IF NOT EXISTS sync_state (
    device      TEXT PRIMARY KEY,
    max_sequence INTEGER NOT NULL DEFAULT 0,
    updated_at  TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS applied_state (
    key        TEXT PRIMARY KEY,
    value      TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
"""


class Store:
    """SQLite 存储，负责验签后的落库与去重。"""

    def __init__(self, path: str):
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        self.conn = sqlite3.connect(path, check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self.conn.executescript(SCHEMA)
        self.conn.commit()

    def max_sequence(self, device: str) -> int:
        row = self.conn.execute(
            "SELECT max_sequence FROM sync_state WHERE device = ?", (device,)
        ).fetchone()
        return int(row["max_sequence"]) if row else 0

    def accept(self, device: str, sequence: int, payload: str, signature: str) -> str:
        """幂等接受: 返回 accepted / duplicate。"""
        now = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        try:
            with self.conn:
                self.conn.execute(
                    "INSERT INTO messages(device, sequence, payload, signature, received_at)"
                    " VALUES(?,?,?,?,?)",
                    (device, sequence, payload, signature, now),
                )
                self.conn.execute(
                    "INSERT INTO sync_state(device, max_sequence, updated_at) VALUES(?,?,?)"
                    " ON CONFLICT(device) DO UPDATE SET max_sequence=excluded.max_sequence,"
                    " updated_at=excluded.updated_at",
                    (device, sequence, now),
                )
                # 应用状态: payload 中的 kv 字段
                data = json.loads(payload)
                for key, value in (data.get("state") or {}).items():
                    self.conn.execute(
                        "INSERT INTO applied_state(key, value, updated_at) VALUES(?,?,?)"
                        " ON CONFLICT(key) DO UPDATE SET value=excluded.value,"
                        " updated_at=excluded.updated_at",
                        (key, json.dumps(value, ensure_ascii=False), now),
                    )
        except sqlite3.IntegrityError:
            return "duplicate"
        return "accepted"

    def stats(self) -> dict:
        cur = self.conn.execute("SELECT COUNT(*) FROM messages")
        total = cur.fetchone()[0]
        rows = self.conn.execute(
            "SELECT device, max_sequence FROM sync_state ORDER BY device"
        ).fetchall()
        return {
            "total_messages": total,
            "devices": {r["device"]: r["max_sequence"] for r in rows},
        }

    def close(self) -> None:
        self.conn.close()


# ---------------------------------------------------------------------------
# 验签
# ---------------------------------------------------------------------------

def canonical(device: str, sequence: int, timestamp: str,
              schema_version: int, payload: str) -> bytes:
    """签名的规范化表示 — 收发两端必须完全一致。"""
    return f"{device}|{sequence}|{timestamp}|{schema_version}|{payload}".encode("utf-8")


def verify(key: bytes, device: str, sequence: int, timestamp: str,
           schema_version: int, payload: str, signature: str) -> bool:
    expected = hmac.new(key, canonical(device, sequence, timestamp,
                                       schema_version, payload),
                        hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature)


# ---------------------------------------------------------------------------
# HTTP 服务
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "AgentSync/1.0"
    cfg: dict = {}
    store: Store = None
    key: bytes = b""

    def log_message(self, fmt, *args):  # 静默默认日志
        if self.cfg.get("log_level") == "debug":
            sys.stderr.write("[http] " + fmt % args + "\n")

    # ---- 路由 ----
    def do_GET(self):
        if self.path in ("/health", "/"):
            body = json.dumps({
                "ok": True,
                "service": "agent-sync-receiver",
                "stats": self.store.stats(),
            }, ensure_ascii=False).encode("utf-8")
            self._respond(200, body, "application/json")
        else:
            self._respond(404, b'{"error":"not found"}', "application/json")

    def do_POST(self):
        if self.path != "/sync":
            self._respond(404, b'{"error":"not found"}', "application/json")
            return

        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > 16 * 1024 * 1024:
            self._respond(400, b'{"error":"bad length"}', "application/json")
            return

        raw = self.rfile.read(length)

        # 解析 body (支持 JSON 或 raw payload)
        try:
            doc = json.loads(raw.decode("utf-8"))
        except Exception:
            self._respond(400, b'{"error":"invalid json"}', "application/json")
            return

        device = doc.get("device") or self.headers.get(DEVICE_HEADER, "")
        sequence = doc.get("sequence")
        timestamp = doc.get("timestamp", "")
        schema_version = int(doc.get("schema_version", 1))
        payload_obj = doc.get("payload")
        signature = doc.get("signature") or self.headers.get(SIGNATURE_HEADER, "")

        if not device or not isinstance(sequence, int) or payload_obj is None or not signature:
            self._respond(400, b'{"error":"missing fields"}', "application/json")
            return

        payload = json.dumps(payload_obj, ensure_ascii=False, sort_keys=True)

        # 1. 验签 — 失败即丢弃，不返回细节
        if not verify(self.key, device, sequence, timestamp, schema_version,
                      payload, signature):
            self._log("拒绝: 签名校验失败 device=%s seq=%s" % (device, sequence))
            self._respond(401, b'{"error":"unauthorized"}', "application/json")
            return

        # 2. 序列号去重
        max_seq = self.store.max_sequence(device)
        if sequence <= max_seq:
            self._log("去重: device=%s seq=%s <= max=%s"
                      % (device, sequence, max_seq))
            self._respond(200, json.dumps(
                {"status": "duplicate", "device": device,
                 "max_sequence": max_seq}).encode(), "application/json")
            return

        # 3. 落库
        result = self.store.accept(device, sequence, payload, signature)
        self._log("接受: device=%s seq=%s -> %s" % (device, sequence, result))
        self._respond(200, json.dumps(
            {"status": result, "device": device, "sequence": sequence,
             "max_sequence": self.store.max_sequence(device)}
        ).encode(), "application/json")

    # ---- helpers ----
    def _respond(self, code: int, body: bytes, ctype: str = "text/plain"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _log(self, msg: str):
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        print(f"[{ts}] {msg}", flush=True)


# ---------------------------------------------------------------------------
# selftest
# ---------------------------------------------------------------------------

def selftest() -> int:
    """端到端自测: 构造签名 → 验签 → 去重 → 落库。"""
    print("== 自测开始 ==")
    failures = []

    key = b"selftest-key-0123456789abcdef"
    device = "test-device"
    payload_obj = {"state": {"greeting": "hello"}, "sessions": []}
    payload = json.dumps(payload_obj, ensure_ascii=False, sort_keys=True)
    ts = "2026-10-14T12:00:00+0800"
    seq = 1

    # 1. 正确签名应通过
    sig = hmac.new(key, canonical(device, seq, ts, 1, payload),
                   hashlib.sha256).hexdigest()
    if verify(key, device, seq, ts, 1, payload, sig):
        print("  [✓] 正确签名验签通过")
    else:
        failures.append("正确签名未通过")
        print("  [✗] 正确签名验签失败")

    # 2. 篡改 payload 应失败
    tampered = payload.replace("hello", "evil")
    if not verify(key, device, seq, ts, 1, tampered, sig):
        print("  [✓] 篡改 payload 被拒绝")
    else:
        failures.append("篡改未被拒绝")
        print("  [✗] 篡改 payload 未被拒绝")

    # 3. 错误密钥应失败
    if not verify(b"wrong-key-0123456789abcdefgh", device, seq, ts, 1, payload, sig):
        print("  [✓] 错误密钥被拒绝")
    else:
        failures.append("错误密钥未被拒绝")
        print("  [✗] 错误密钥未被拒绝")

    # 4. 序列号去重
    db = ":memory:"
    store = Store(db)
    r1 = store.accept(device, seq, payload, sig)
    r2 = store.accept(device, seq, payload, sig)
    if r1 == "accepted" and r2 == "duplicate":
        print("  [✓] 序列号去重生效 (accepted → duplicate)")
    else:
        failures.append(f"去重异常: {r1} / {r2}")
        print(f"  [✗] 去重异常: {r1} / {r2}")

    # 5. 低序列号应被拒
    if store.max_sequence(device) == seq:
        print("  [✓] max_sequence 正确更新")
    else:
        failures.append("max_sequence 未更新")
        print("  [✗] max_sequence 未更新")

    store.close()

    print()
    if failures:
        print(f"== 自测失败 {len(failures)} 项 ==")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("== 自测全部通过 ==")
    return 0


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description="Agent 多端同步接收端")
    ap.add_argument("--config", default="receiver.json", help="配置文件路径")
    ap.add_argument("--selftest", action="store_true", help="运行自测并退出")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    try:
        cfg = load_config(args.config)
        key = load_key(cfg["key_file"])
    except Exception as e:
        print(f"启动失败: {e}", file=sys.stderr)
        return 1

    Handler.cfg = cfg
    Handler.key = key
    Handler.store = Store(cfg["database"])

    host, port = cfg["listen_host"], int(cfg["listen_port"])
    # 安全检查: 不允许监听所有接口
    if host in ("0.0.0.0", "::", ""):
        print("拒绝启动: listen_host 不允许 0.0.0.0 (会暴露到非私有网络)",
              file=sys.stderr)
        return 1

    try:
        srv = ThreadingHTTPServer((host, port), Handler)
    except OSError as e:
        print(f"监听失败 {host}:{port} — {e}", file=sys.stderr)
        return 1

    print(f"[agent-sync] 接收端已启动 http://{host}:{port}/")
    print(f"[agent-sync] 数据库: {cfg['database']}")
    print(f"[agent-sync] 健康检查: curl http://{host}:{port}/health")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n[agent-sync] 已停止")
    finally:
        srv.server_close()
        Handler.store.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
