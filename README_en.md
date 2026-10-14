<div align="center">

[中文](README.md) · **English**

# Agent Multi-Device Sync

### A complete solution for keeping one AI agent consistent across multiple devices.

**Switch devices without losing context; two machines on separate networks, directly connected.**

[![Tailscale direct](https://img.shields.io/badge/Tailscale-direct-0096D6?style=flat-square&logo=tailscale&logoColor=white)](docs/tailscale-direct.md)
[![IPv6](https://img.shields.io/badge/connection-IPv6%20direct-2F80ED?style=flat-square)](docs/tailscale-direct.md)
[![latency](https://img.shields.io/badge/latency-300ms%20%E2%86%92%2017ms-brightgreen?style=flat-square)](docs/tailscale-direct.md#%E5%AE%9E%E6%B5%8B%E7%BB%93%E6%9E%9C)
[![Hermes](https://img.shields.io/badge/Runtime-Hermes%20Agent-8A2BE2?style=flat-square)](docs/architecture.md)
[![MIT license](https://img.shields.io/badge/license-MIT-f4c430?style=flat-square)](LICENSE)

**[Quick start](#quick-start) · [How it works](#how-it-works) · [What gets synced](#what-gets-synced) · [Case studies](#case-studies) · [FAQ](#faq) · [Documentation](#documentation)**

```bash
git clone https://github.com/AkikoEra/agent-multidevice-sync.git
cd agent-multidevice-sync && ./scripts/tailscale/diagnose.sh
```

</div>

> [!IMPORTANT]
> Device-to-device traffic goes through [Tailscale](https://tailscale.com/)'s
> WireGuard tunnel — **no ports are exposed to the public internet**.
> Synced data includes agent session state and configuration. Generate your own
> keys from the `examples/*.example` templates; **never reuse sample values**.

---

<div align="center">

[Quick start](#quick-start) · [How it works](#how-it-works) · [What gets synced](#what-gets-synced) · [Case studies](#case-studies) · [FAQ](#faq) · [Documentation](#documentation)

</div>

## Quick start

Three steps: connect → deploy → verify.

### 1. Confirm both devices can reach each other

```bash
tailscale status
```

Both devices should show `online`. Install [Tailscale](https://tailscale.com/download)
on both and log into the same account if you haven't.

### 2. Diagnose connection quality

```bash
./scripts/tailscale/diagnose.sh
```

The script reports the current path (relay or direct), latency, NAT type and
IPv6 availability, then suggests next steps.

Typical output:

```text
Current path:   DERP(hkg) relay
Latency:        318 ms
NAT type:       Symmetric (MappingVariesByDestIP=true)
IPv6:           Available
Recommendation: Enable IPv6 to establish a direct connection
```

> If it already says `IPv6 direct` with latency under 50 ms, the network layer
> is ready — skip to step 3.

Judgement criteria are documented in the
[Tailscale direct connection guide](docs/tailscale-direct.md).

### 3. Deploy the sync services

```bash
# Linux (receiver)
./scripts/linux/install-receiver.sh

# macOS (collector)
./scripts/macos/install-collector.sh
```

Both scripts check dependencies, generate private config from `examples/`
(never overwriting existing config), register an auto-start service, and print
verification commands.

Then run acceptance:

```bash
./scripts/verify.sh
```

Parameters, systemd/launchd configuration and troubleshooting are in
[Installation](docs/installation.md).

## How it works

Three stages: **collect → transport → apply**.

```text
┌──────────────┐      Tailscale WireGuard        ┌──────────────┐
│   macOS      │ ──────────────────────────────► │   Linux      │
│  (Collector) │  direct / relay fallback        │  (Receiver)  │
│              │  no public ports exposed        │              │
│  reads local │                                 │  verifies    │
│  agent state │  HMAC + monotonic sequence      │  deduplicates│
│  → outbox    │  retry / idempotent delivery    │  → applies   │
└──────────────┘                                 └──────────────┘
```

1. **Collect** — the collector reads local agent state against a schema
   allow-list and produces an immutable snapshot in a local outbox. Fields not
   in the allow-list are rejected outright.
2. **Transport** — snapshots travel over the Tailscale tunnel, each signed with
   HMAC and carrying a monotonic sequence number. Invalid signatures are
   dropped; duplicate sequence numbers are de-duplicated. Offline periods queue
   locally and replay on reconnect.
3. **Apply** — the receiver validates and persists; the agent reads unified
   state on next start.

Network-layer details (why relays happen by default, how to upgrade to direct)
are in [Tailscale direct connection](docs/tailscale-direct.md); the data
contract is in [Sync protocol](docs/sync-protocol.md).

## What gets synced

| Category | Content | Default |
|---|---|---|
| Session metadata | IDs, titles, timestamps, device ownership | ✅ |
| Message history | Archived conversations | ✅ |
| Agent config | Model preferences, skills, tool switches | ✅ |
| Long-term memory | Memory entries and provenance | ✅ |
| Credentials & keys | API keys, tokens, cookies | ❌ never |
| Local paths & env | Absolute paths, environment variables | ❌ never |

**Credentials are never synced** — the collector refuses to read them at the
schema layer, so they never reach the outbox or the wire. See
[Security design](docs/security.md).

For content that shouldn't sync but should persist (large files, model
weights), use the [mixed strategy](docs/mixed-strategy.md) with Git + Tailscale.

## Case studies

### 1. Cross-device session roaming

Two devices on different LANs, each with its own upstream network. After
enabling sync, a conversation on one machine propagates to the other within one
collection cycle, so switching devices doesn't lose context.

**Result:** session state stays consistent across devices.

### 2. From 300 ms relay to 17 ms direct

Initially Tailscale used a Hong Kong DERP relay at ~300 ms. Investigation
showed both devices sat behind carrier CGNAT (no public IPv4), so IPv4 hole
punching was impossible.

After enabling IPv6 on both routers, Tailscale switched to native IPv6:

```text
Before:  pong ... via DERP(hkg) in 320ms   ← relay
After:   pong ... via [IPv6]:63502 in 17ms ← direct
```

**Latency reduced ~18×.** The full investigation, including why port
forwarding cannot help, is in
[Tailscale direct connection](docs/tailscale-direct.md).

### 3. Auto-replay after 7 hours offline

Snapshots accumulated over ~7 hours of offline time were replayed in original
sequence order on reconnect, with every message de-duplicated — no loss, no
duplicates.

**Result:** delivery is idempotent; network flaps don't affect integrity.

## FAQ

<details>
<summary><strong>Do I need a public IP?</strong></summary>

No. All traffic rides Tailscale's WireGuard tunnel, services listen only on
private addresses, and nothing is exposed publicly. Behind CGNAT, multi-layer
NAT or strict firewalls, Tailscale falls back to DERP relays — connectivity
still works, with higher latency.

</details>

<details>
<summary><strong>Relay vs direct — what's the difference?</strong></summary>

Direct means devices talk to each other: low latency, full bandwidth. Relay
means traffic passes through a Tailscale node: latency depends on node
location. Tailscale picks the best path automatically. To reduce latency,
follow the [direct connection guide](docs/tailscale-direct.md); failures fall
back to relay without affecting availability.

</details>

<details>
<summary><strong>I enabled UPnP — why am I still on a relay?</strong></summary>

UPnP only maps **your own layer** of NAT, not the carrier's CGNAT above it.
To check: if the router's WAN address falls within `100.64.0.0/10` or another
private range, there is a carrier-level NAT and port forwarding will never let
outside traffic reach you. IPv6 is the only path.

</details>

<details>
<summary><strong>Will my credentials leak?</strong></summary>

No. The collector reads only allow-listed fields — credential fields are
rejected at the schema layer before being read. The transport layer adds HMAC
verification. See [Security design](docs/security.md). The `.gitignore` also
excludes configs, keys and databases.

</details>

<details>
<summary><strong>What happens if the network drops?</strong></summary>

Snapshots queue in a local outbox and replay in sequence order when connectivity
returns; the receiver de-duplicates. Nothing is lost and nothing is duplicated.

</details>

<details>
<summary><strong>Which platforms are supported?</strong></summary>

Both ends support Linux and macOS, architecture-independent. Windows can reuse
the Linux scripts but is untested here — contributions welcome.

</details>

<details>
<summary><strong>My agent isn't Hermes — can I use this?</strong></summary>

Yes. The sync layer only assumes "a local state store exists" and adapts via
the `collector.json` schema. Hermes Agent is the reference implementation.

</details>

## Documentation

| Document | Contents |
|---|---|
| [Installation](docs/installation.md) | Prerequisites, both ends, systemd/launchd, acceptance |
| [Architecture](docs/architecture.md) | Components, data flow, failure modes, extension points |
| [Tailscale direct connection](docs/tailscale-direct.md) | Diagnosis, CGNAT detection, IPv6, measured results |
| [Sync protocol](docs/sync-protocol.md) | Message format, signing, sequence numbers and dedup |
| [Security design](docs/security.md) | Trust boundaries, key handling, allow-list, threat model |
| [Mixed strategy](docs/mixed-strategy.md) | Splitting content across sync / Git / manual |
| [Troubleshooting](docs/troubleshooting.md) | Symptom-indexed diagnosis paths |
| [Measured evidence](docs/evidence.md) | Raw observations and verification steps |
| [Contributing](CONTRIBUTING.md) | Dev environment and commit rules |
| [Security policy](SECURITY.md) | Vulnerability reporting |

## Star history

If this project helped you, a ⭐ Star is appreciated.

<a href="https://www.star-history.com/?repos=AkikoEra%2Fagent-multidevice-sync&amp;type=date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=AkikoEra/agent-multidevice-sync&amp;type=date&amp;theme=dark&amp;legend=top-left" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=AkikoEra/agent-multidevice-sync&amp;type=date&amp;legend=top-left" />
    <img alt="Star history" src="https://api.star-history.com/chart?repos=AkikoEra/agent-multidevice-sync&amp;type=date&amp;legend=top-left" />
  </picture>
</a>

## Disclaimer

Use this project in compliance with applicable laws and only with authorization
from the network operator concerned.

This project exists for personal multi-device coordination, learning and
research. You are responsible for ensuring the legality and authorization of
what you sync, including conversation data, configuration and third-party
material.

This project provides no capability to circumvent network regulation, evade
access controls, or connect to systems without authorization.
Tailscale is a third-party service governed by its own terms.

## Contributing

Issues and
[Pull Requests](https://github.com/AkikoEra/agent-multidevice-sync/pulls)
are welcome.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the dev environment and checklist.

Before submitting, confirm: **no real IP addresses, keys, endpoints or session
data.**

## License

[MIT](LICENSE)
