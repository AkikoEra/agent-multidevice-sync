#!/usr/bin/env python3
"""Tailscale 反向代理 — 把来自 tailnet 的请求转发到本机回环后端。

用途:
  后端服务只监听 127.0.0.1，但需要被 tailnet 内的另一台设备访问。
  本代理监听 Tailscale 网卡地址，转发到回环后端，同时做请求头适配。

安全约束 (启动时强制校验):
  1. 只能监听 Tailscale 地址 (100.64.0.0/10) 或回环，禁止 0.0.0.0
  2. 只接受来自 tailnet 地址段的客户端

依赖: 仅 Python 标准库
用法:
    python3 tailscale_proxy.py --backend 127.0.0.1:8000 --listen-port 9119
    python3 tailscale_proxy.py --backend 127.0.0.1:8000 --selftest
"""
from __future__ import annotations

import argparse
import http.client
import ipaddress
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Tailscale 地址段
TAILNET_V4 = ipaddress.ip_network("100.64.0.0/10")      # IPv4 CGNAT 段
TAILNET_V6 = ipaddress.ip_network("fd7a:115c:a1e0::/48")  # IPv6 ULA 段
LOOPBACK = ipaddress.ip_network("127.0.0.0/8")
LOOPBACK6 = ipaddress.ip_network("::1/128")

# 需要转发的请求头
FORWARD_HEADERS = {
    "Content-Type", "Accept", "Authorization",
    "User-Agent", "X-Request-Id", "X-Sync-Signature",
    "X-Sync-Device", "X-Sync-Sequence",
}


def is_trusted(addr: str) -> bool:
    """只信任 tailnet (v4/v6) 与回环地址。"""
    try:
        ip = ipaddress.ip_address(addr.split("%")[0])
    except ValueError:
        return False
    return (ip in TAILNET_V4 or ip in TAILNET_V6
            or ip in LOOPBACK or ip == LOOPBACK6.network_address)


class ProxyHandler(BaseHTTPRequestHandler):
    server_version = "AgentSyncProxy/1.0"
    backend_host = "127.0.0.1"
    backend_port = 8000
    extra_headers: dict = {}

    def log_message(self, fmt, *args):
        print(f"[proxy] {self.address_string()} " + (fmt % args), flush=True)

    def _deny(self, code: int, msg: str):
        body = msg.encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write(body)

    def _forward(self, method: str):
        client = self.address_string()
        if not is_trusted(client):
            self._deny(403, "forbidden: not a tailnet address")
            return

        length = int(self.headers.get("Content-Length") or 0)
        if length > 64 * 1024 * 1024:
            self._deny(413, "payload too large")
            return
        body = self.rfile.read(length) if length else None

        try:
            conn = http.client.HTTPConnection(
                self.backend_host, self.backend_port, timeout=30)
            headers = {k: v for k, v in self.headers.items()
                       if k.lower() in {h.lower() for h in FORWARD_HEADERS}}
            # 请求头适配: 注入后端所需的头
            headers.update(self.extra_headers)
            headers["X-Forwarded-For"] = client
            headers["X-Forwarded-Proto"] = "https"
            if body is not None:
                headers["Content-Length"] = str(len(body))

            conn.request(method, self.path, body=body, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
            conn.close()
        except Exception as e:
            self._deny(502, f"backend error: {e}")
            return

        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() in ("transfer-encoding", "connection",
                             "content-length", "keep-alive"):
                continue
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):     self._forward("GET")
    def do_POST(self):    self._forward("POST")
    def do_PUT(self):     self._forward("PUT")
    def do_PATCH(self):   self._forward("PATCH")
    def do_DELETE(self):  self._forward("DELETE")
    def do_HEAD(self):    self._forward("HEAD")


def selftest() -> int:
    print("== 自测开始 ==")
    fails = []

    # 1. tailnet 地址应可信
    if is_trusted("100.64.0.1"):   # tailnet 段内的示例地址
        print("  [✓] tailnet 地址被信任")
    else:
        fails.append("tailnet 未信任"); print("  [✗] tailnet 地址未被信任")

    # 2. 回环应可信
    if is_trusted("127.0.0.1"):
        print("  [✓] 回环地址被信任")
    else:
        fails.append("回环未信任"); print("  [✗] 回环地址未被信任")

    # 3. 公网地址应拒绝
    if not is_trusted("203.0.113.5"):
        print("  [✓] 公网地址被拒绝")
    else:
        fails.append("公网未拒绝"); print("  [✗] 公网地址未被拒绝")

    # 4. 私有 LAN 地址应拒绝 (192.168 不属于 tailnet)
    if not is_trusted("192.168.1.10"):
        print("  [✓] 非 tailnet 私有地址被拒绝")
    else:
        fails.append("LAN 未拒绝"); print("  [✗] 非 tailnet 私有地址未被拒绝")

    # 5. IPv6 tailnet 地址
    if is_trusted("fd7a:115c:a1e0::1"):
        print("  [✓] tailnet IPv6 地址被信任")
    else:
        fails.append("tailnet IPv6 未信任"); print("  [✗] tailnet IPv6 未被信任")

    print()
    if fails:
        print(f"== 自测失败 {len(fails)} 项 ==")
        return 1
    print("== 自测全部通过 ==")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Tailscale 反向代理")
    ap.add_argument("--backend", default="127.0.0.1:8000",
                    help="后端地址 host:port")
    ap.add_argument("--listen-host", default="",
                    help="监听地址 (留空则自动选择 Tailscale 地址)")
    ap.add_argument("--listen-port", type=int, default=9119)
    ap.add_argument("--header", action="append", default=[],
                    help="注入的请求头, 格式: Name:Value (可多次)")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    bh, bp = args.backend.rsplit(":", 1)
    ProxyHandler.backend_host = bh
    ProxyHandler.backend_port = int(bp)
    for h in args.header:
        if ":" in h:
            k, v = h.split(":", 1)
            ProxyHandler.extra_headers[k.strip()] = v.strip()

    # 自动选择监听地址: 优先 Tailscale 网卡
    listen = args.listen_host
    if not listen:
        listen = _tailscale_addr() or "127.0.0.1"

    # 安全校验: 禁止监听所有接口
    if listen in ("0.0.0.0", "::", ""):
        print("拒绝启动: 不允许监听 0.0.0.0", file=sys.stderr)
        return 1

    try:
        ip = ipaddress.ip_address(listen)
        if ip not in TAILNET_V4 and ip not in TAILNET_V6 \
                and ip not in LOOPBACK and ip != LOOPBACK6.network_address:
            print(f"拒绝启动: {listen} 既非 Tailscale 地址也非回环地址",
                  file=sys.stderr)
            return 1
    except ValueError:
        pass  # 主名，交给系统解析

    try:
        srv = ThreadingHTTPServer((listen, args.listen_port), ProxyHandler)
    except OSError as e:
        print(f"监听失败 {listen}:{args.listen_port} — {e}", file=sys.stderr)
        return 1

    print(f"[proxy] 监听 http://{listen}:{args.listen_port}")
    print(f"[proxy] 转发到 http://{bh}:{bp}")
    print(f"[proxy] 客户端限制: 仅 tailnet (100.64.0.0/10) 与回环")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n[proxy] 已停止")
    finally:
        srv.server_close()
    return 0


def _tailscale_addr() -> str | None:
    """从系统接口中找出 Tailscale 地址。"""
    try:
        import socket
        for info in socket.getaddrinfo(socket.gethostname(), None,
                                       socket.AF_INET):
            ip = info[4][0]
            if ipaddress.ip_address(ip) in TAILNET_V4:
                return ip
    except Exception:
        pass
    # fallback: 读接口
    try:
        import subprocess
        out = subprocess.run(["ip", "-4", "-o", "addr", "show", "tailscale0"],
                             capture_output=True, text=True, timeout=5).stdout
        for part in out.split():
            if "/" in part:
                return part.split("/")[0]
    except Exception:
        pass
    return None


if __name__ == "__main__":
    sys.exit(main())
