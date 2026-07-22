# hoop-proxy-tunnel

Run an unchanged Python app against `http://httpbin.org` and have every
request go through a [Hoop](https://hoop.dev) tunnel. The app dials the
real hostname; the OS resolves it to the connection's tunnel IP; the
hoop agent forwards the plain-HTTP bytes to the real upstream over TLS.
Auth, audit, DLP, and guardrails apply to every request because the
bytes cross the agent in cleartext.

```
app.py ── http://httpbin.org:80 ──► 100.85.x.x (tunnel IP via /etc/hosts)
                                        │
                          TUN ► gVisor ► gRPC ► hoop gateway
                                                    │
                                        agent ── TLS ──► httpbin.org
```

The files:

| File          | Purpose                                                        |
|---------------|----------------------------------------------------------------|
| `app.py`      | The app under test. Plain httpx, no hoop awareness.            |
| `redirect.sh` | Points a hostname at the tunnel IP (`up` / `down` / `status`); targets set via `SOURCE_HOST` / `TUNNEL_NAME` env vars. |
| `server.py`   | Local JSON server to tunnel back to your own machine — see [LOCAL-SERVER.md](LOCAL-SERVER.md). |
| `sidecard.py` | Older userspace approach: monkeypatches httpx to rewrite URLs. Superseded by `redirect.sh`, kept for reference. |

## 1. Create the httpproxy connection

You need a hoop gateway with a connected agent. Create a connection of
type `application/httpproxy` whose upstream is httpbin:

```bash
hoop admin create connection httpproxy-role \
  -a default \
  -t application/httpproxy \
  -e REMOTE_URL=https://httpbin.org \
  --overwrite
```

`REMOTE_URL` is the only required env for httpproxy connections. The
agent terminates TLS to that URL; clients of the tunnel speak plain
HTTP on port 80. Keep `REMOTE_URL` on `https://` — the agent's own
fetch then targets port 443 and can never collide with the port-80
redirect on the client side.

## 2. Install hsh and the tunnel daemon

Install both binaries from the tarball on the
[hsh Releases page](https://github.com/hoophq/hsh/releases)
(Homebrew: `brew install hoophq/tap/hsh` once the formula lands). The
tarball ships `hsh` (unprivileged CLI) and `hsh-tunneld` (root daemon
that owns the TUN device). Register the daemon as a system service:

```bash
sudo hsh-tunneld install     # LaunchDaemon on macOS, systemd unit on Linux
```

Then authenticate and bring the tunnel up:

```bash
hsh login                    # browser OAuth flow; also logs the daemon in
hsh tunnel up
hsh tunnel ls
```

`hsh tunnel ls` lists every tunnelable connection with its `*.hoop`
hostname and stable virtual IPs:

```
httpproxy-role.hoop    httpproxy  port 80   fdc8:b7f6:8b4a:...:f8e8
```

Smoke-test the tunnel before adding the redirect:

```bash
curl http://httpproxy-role.hoop/json
```

That works because the daemon routes `*.hoop` DNS to its in-stack
resolver (`/etc/resolver/hoop` on macOS, systemd-resolved on Linux)
and the resolver answers with the connection's virtual IP. The whole
point of this repo is reaching the same connection under the *original*
hostname, so the app needs no `.hoop` URL.

## 3. How redirect.sh works

One `/etc/hosts` line does the whole job:

```
100.85.226.73	httpbin.org	# hoop-proxy-tunnel
```

- `up` resolves `httpproxy-role.hoop` through the tunnel resolver
  (`fdc8:b7f6:8b4a::1`, from `/etc/resolver/hoop`), appends the tagged
  hosts line, and flushes the DNS cache. The tunnel's address allocator
  is deterministic, so the IP survives daemon restarts.
- `down` deletes the tagged line, flushes again, and clears any state a
  pf-based version of the script left behind (anchor rules, host
  routes, the forwarding sysctl).
- `status` prints the hosts line and what `httpbin.org` currently
  resolves to.

After the hosts entry, the app's socket lands on the tunnel IP, the
`100.85/16` route the daemon installed carries it into the TUN, gVisor
accepts the flow, and the daemon opens one gRPC session per TCP
connection against the gateway. Nothing else on the host changes:
port 443 and every other destination still flow normally.

### Why not pf (the macOS iptables)?

We tried the firewall route first and it cannot work on modern macOS.
The textbook recipe bounces outbound packets through loopback so a
`rdr` rule can rewrite them:

```
pass out route-to (lo0 127.0.0.1) proto tcp to <httpbin-ip> port 80 keep state
rdr pass on lo0 proto tcp to <httpbin-ip> port 80 -> <tunnel-ip> port 80
```

Debugging peeled off three kernel-level failures in sequence, each
verified before moving to the next:

1. **Blackholed agent.** The first version steered httpbin through lo0
   with host routes (`route add <ip> 127.0.0.1`). Routes match every
   port, so the agent's own TLS fetch of `REMOTE_URL` (port 443) died
   too and every tunneled request hung. Port-scoped pf `route-to`
   replaced the routes.
2. **Forwarding off.** The rewritten packet re-enters routing on lo0
   with a destination behind utun — that hop is IP forwarding, and
   macOS ships `net.inet.ip.forwarding=0`, silently dropping it.
3. **Interface-scoped routes.** hsh-tunneld's `100.85/16` route carries
   the IFSCOPE flag; the forwarding path ignores scoped routes, so the
   packet got EHOSTUNREACH. Even `route add -interface utunX` creates
   another scoped route — only the gateway form
   (`route add <ip> <utun-addr>`) is unscoped.

With all three fixed — rules matched, forwarding on, an unscoped `UGHS`
route in the table — tcpdump showed the verdict: the SYN appears on lo0
**untranslated** (still destined to httpbin's public IP) and nothing
ever reaches utun. pf's `rdr` on current macOS translates only toward
local listeners; it will not DNAT locally originated traffic to a
remote address. Platform limit, not a configuration error.

On Linux this is a one-liner, and it works because netfilter's OUTPUT
nat hook rewrites before routing:

```bash
iptables -t nat -A OUTPUT -p tcp -d <httpbin-ip> --dport 80 \
  -j DNAT --to-destination <tunnel-ip>:80
```

`/etc/hosts` is also simply better here: immune to CDN IP rotation
(httpbin.org publishes 8 A records that change), no sysctl, no route
surgery, one line to audit.

### Dev-only gotcha: agent DNS loop

If the agent runs on the same machine (or a container sharing its DNS,
like the `hoopdev` docker setup), the hosts entry poisons the agent
too: it resolves `REMOTE_URL`'s `httpbin.org` to the tunnel IP and
dials back into the tunnel — the gateway log shows
`dial tcp 100.85.226.73:443` and the client gets
"Server disconnected without sending a response". Pin the real IP
inside the container:

```bash
docker exec hoopdev sh -c \
  "echo '$(dig @1.1.1.1 +short httpbin.org A | head -1) httpbin.org' >> /etc/hosts"
```

A production agent on another host has its own DNS and never sees the
client's hosts file.

### Limits

- **Port 80 only.** The tunnel rejects 443 for httpproxy connections at
  the SYN: it has no certificate for the redirected hostname, so a TLS
  handshake can never succeed. The app must use `http://` URLs. If the
  app insists on `https://`, use a `tcp`-type connection instead
  (end-to-end TLS, but the agent sees ciphertext and DLP goes blind).
- **Name-based only.** Apps that dial a hardcoded IP bypass
  `/etc/hosts`. On Linux the iptables rule above covers them; on macOS
  there is no transparent option (see the pf post-mortem).
- **Host header.** Requests arrive at the agent with
  `Host: httpbin.org`. The agent forwards to `REMOTE_URL` regardless,
  so this is transparent for httpbin.

## 4. Run

```bash
cd hoop-proxy-tunnel

sudo ./redirect.sh up
#   hosts:   httpbin.org -> 100.85.226.73 (httpproxy-role.hoop)
#   up. try: python app.py   (URL must be http://httpbin.org/...)

python app.py
#   {'slideshow': {...}}          <- served through the hoop session

./redirect.sh status              # hosts line + live resolution
sudo ./redirect.sh down           # remove the entry, flush DNS
```

Verify the traffic went through hoop: the gateway log shows
`http request, GET https://httpbin.org/json` then
`http response, status=200` on connection `httpproxy-role`, and the
session list (`hoop admin get sessions`) grows one session per TCP
connection the app opened.

## The old userspace approach

`sidecard.py` predates the redirect: it monkeypatches
`httpx.Client.send` to rewrite `https://httpbin.org/...` to
`http://httpproxy-role.hoop/...` before the socket ever opens, then
`runpy`s the target script:

```bash
python sidecard.py app.py
```

It needs no root and requires no DNS changes, but it only covers httpx
and requires launching the app through the wrapper. The hosts redirect
covers every process on the host and keeps the app invocation
untouched.
