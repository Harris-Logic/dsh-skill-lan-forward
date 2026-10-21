# dsh-skill-lan-forward

A DeepSeek Harness **skill**: reach a loopback-only service on another LAN host
through an SSH local forward bound to a loopback alias (`127.0.0.x`), on any two
endpoints — PC↔PC, PC↔phone, PC↔tablet — instead of exposing `0.0.0.0`.

把「另一台机器上只监听 `127.0.0.1` 的服务」用 SSH 本地转发接到本机 `127.0.0.x`，
适用于任意两端（PC↔PC、PC↔手机、PC↔平板），服务可以是 dsh web、VS Code Server 或任意 HTTP/TCP 服务。

```
client browser → http://127.0.0.2:<P>  ──ssh -N -L──►  peer sshd ──►  127.0.0.1:<P>
```

## Why this is the right shape

- DSH's own docs state wildcard binding is **not supported** and `--host 0.0.0.0`
  is rejected at startup for safety; the documented remote path is SSH forwarding
  where *the SSH client owns the forwarding address*.
- `127.0.0.x` (not `127.0.0.1`) avoids clashing with a same-port service already
  bound on the client, and gives the remote service its own cookie domain.
- Anyone on the LAN can reach `0.0.0.0`; only someone with SSH access can reach a tunnel.

## Usage

```bash
./scripts/forward.sh start  --ssh desk --service 3080 --check 'authentication required'
./scripts/forward.sh status --name desk-3080
./scripts/forward.sh stop   --name desk-3080
```

| Flag | Meaning |
|---|---|
| `--ssh <alias>` | ssh target from `~/.ssh/config`, or `user@host` |
| `--peer <ip>` | override peer address discovery |
| `--service <port\|host:port>` | loopback address on the peer (default `127.0.0.1:<port>`) |
| `--local <ip:port>` | client-side bind (default `127.0.0.2:<service port>`) |
| `--name <tag>` | pidfile/state tag |
| `--check <regex>` | verify the tunnel by matching the HTTP body |
| `--port <n>` | sshd port (default 22) |
| `--open` | open the URL in the default browser |

Peer discovery order: explicit `--peer` → `ssh -G <alias>` HostName (verified on
the ssh port) → WLAN default gateway (hotspot case). MAC lookup is deliberately
not used: hotspot BSSIDs are randomized.

## Files

| File | Purpose |
|---|---|
| `SKILL.md` | full skill text: rationale, three key decisions, pitfalls, troubleshooting, checklist |
| `scripts/forward.sh` | the generic forward manager (start/stop/status, pidfile, lock, port hygiene) |
| `scripts/forward.cmd` | Windows wrapper |
| `scripts/peer-ip.ps1` | Windows peer resolver |
| `install.ps1` / `install.sh` | copy the skill into `~/.dsh/skills/lan-forward` |

## Notes

- Never bind the tunnel to `0.0.0.0`; never open the peer's service to the LAN.
- Windows reserved port ranges make *any* bind fail with `Permission denied`;
  `forward.sh` auto-picks another local port and tells you the permanent fix.
- Phone/tablet peers: keep `termux-wake-lock` on, otherwise the OS freezes the
  service and the tunnel looks broken.

The phone-specific case (hotspot, dsh web, Termux details) lives in
[dsh-skill-phone-tunnel](https://github.com/Harris-Logic/dsh-skill-phone-tunnel).
