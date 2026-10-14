#!/usr/bin/env python3
"""探测路由器 UPnP/IGD，读取 WAN 地址并判定是否处于 CGNAT 之后。

用途：Tailscale 无法建立点对点连接时，先判定是不是 CGNAT 导致端口转发失效。

用法:
    probe_router.py                 # 自动发现默认网关
    probe_router.py 192.168.1.1     # 指定网关地址

退出码:
    0 = 公网地址（IPv4 可尝试打洞）
    1 = 私有/保留段（CGNAT，IPv4 无解）
    2 = 无法读取（路由器未响应）
"""
from __future__ import annotations

import ipaddress
import re
import socket
import sys
import urllib.request
import xml.etree.ElementTree as ET

SSDP_ADDR = "239.255.255.250"
SSDP_PORT = 1900
TIMEOUT = 4

PRIVATE_NETS = [
    "100.64.0.0/10",   # 运营商级 NAT 保留段
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "169.254.0.0/16",
]

IGD_PATHS = [
    "/rootDesc.xml",
    "/igd.xml",
    "/description.xml",
    "/gatedesc.xml",
]


def default_gateway() -> str | None:
    """读取系统默认网关地址。"""
    for cmd in (["ip", "route"], ["route", "-n", "get", "default"]):
        try:
            import subprocess
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout
        except Exception:
            continue
        m = re.search(r"default\s+via\s+(\S+)", out)
        if m:
            return m.group(1)
        m = re.search(r"gateway:\s*(\S+)", out)
        if m:
            return m.group(1)
    return None


def ssdp_discover() -> str | None:
    """SSDP 多播发现 IGD 描述地址。"""
    msg = (
        "M-SEARCH * HTTP/1.1\r\n"
        f"HOST: {SSDP_ADDR}:{SSDP_PORT}\r\n"
        'MAN: "ssdp:discover"\r\n'
        "MX: 3\r\n"
        "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n"
        "\r\n"
    )
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(TIMEOUT)
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
        sock.sendto(msg.encode(), (SSDP_ADDR, SSDP_PORT))
        data, _ = sock.recvfrom(2048)
        sock.close()
        m = re.search(r"LOCATION:\s*(\S+)", data.decode(errors="ignore"), re.I)
        if m:
            return m.group(1).strip()
    except Exception:
        pass
    return None


def fetch(url: str) -> str | None:
    try:
        with urllib.request.urlopen(url, timeout=TIMEOUT) as r:
            return r.read().decode(errors="ignore")
    except Exception:
        return None


def find_igd(gateway: str) -> tuple[str, str] | None:
    """返回 (描述文档URL, base URL)。"""
    loc = ssdp_discover()
    if loc:
        xml = fetch(loc)
        if xml and "InternetGatewayDevice" in xml:
            return loc, loc.rsplit("/", 1)[0]

    for port in (5351, 1900, 80):
        for path in IGD_PATHS:
            url = f"http://{gateway}:{port}{path}"
            xml = fetch(url)
            if xml and "InternetGatewayDevice" in xml:
                return url, f"http://{gateway}:{port}"
    return None


def soap_call(base: str, control_url: str, service_type: str,
              action: str, args: str = "") -> str | None:
    url = control_url if control_url.startswith("http") else base + control_url
    body = (
        '<?xml version="1.0"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        f'<s:Body><u:{action} xmlns:u="{service_type}">{args}</u:{action}>'
        "</s:Body></s:Envelope>"
    )
    req = urllib.request.Request(
        url,
        data=body.encode(),
        headers={
            "Content-Type": 'text/xml; charset="utf-8"',
            "SOAPAction": f'"{service_type}#{action}"',
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.read().decode(errors="ignore")
    except Exception:
        return None


def get_wan_ip(xml: str, base: str) -> str | None:
    """从描述文档找到 WAN 服务并调用 GetExternalIPAddress。"""
    root = ET.fromstring(xml)
    ns = {"u": "urn:schemas-upnp-org:device-1-0"}

    service_type = control_url = None
    for svc in root.iter():
        if svc.tag.split("}")[-1] != "service":
            continue
        st = svc.findtext("u:serviceType", namespaces=ns)
        cu = svc.findtext("u:controlURL", namespaces=ns)
        if st and cu and ("WANIPConnection" in st or "WANPPPConnection" in st):
            service_type, control_url = st, cu
            break

    # 描述文档里有时直接带 WAN IP
    m = re.search(r"<WANIPAddress>(.*?)</WANIPAddress>", xml)
    if m and m.group(1).strip():
        return m.group(1).strip()

    if service_type and control_url:
        resp = soap_call(base, control_url, service_type, "GetExternalIPAddress")
        if resp:
            m = re.search(r"<NewExternalIPAddress>(.*?)</", resp)
            if m and m.group(1).strip() and m.group(1) != "0.0.0.0":
                return m.group(1).strip()
    return None


def is_cgnat(ip: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(addr in ipaddress.ip_network(n) for n in PRIVATE_NETS)


def main() -> int:
    gateway = sys.argv[1] if len(sys.argv) > 1 else default_gateway()
    if not gateway:
        print("无法确定默认网关，请手动指定: probe_router.py <gateway-ip>")
        return 2

    print(f"默认网关: {gateway}")

    found = find_igd(gateway)
    if not found:
        print("无法读取 WAN 地址（路由器未响应 UPnP/IGD）")
        print("  可手动查看路由器后台的 WAN 状态页")
        return 2

    desc_url, base = found
    print(f"IGD 描述: {desc_url}")

    xml = fetch(desc_url)
    if not xml:
        print("IGD 描述读取失败")
        return 2

    wan_ip = get_wan_ip(xml, base)
    if not wan_ip:
        print("无法获取 WAN 地址（GetExternalIPAddress 无响应）")
        print("  可手动查看路由器后台的 WAN 状态页")
        return 2

    print(f"WAN 地址: {wan_ip}")
    if is_cgnat(wan_ip):
        print("判定: 私有/保留段 → 处于 CGNAT 之后")
        print("  端口转发无法让外部主动连入，IPv4 直连无解")
        print("  解决方案: 启用 IPv6（见 docs/tailscale-direct.md）")
        return 1

    print("判定: 公网地址 → IPv4 可尝试打洞")
    return 0


if __name__ == "__main__":
    sys.exit(main())
