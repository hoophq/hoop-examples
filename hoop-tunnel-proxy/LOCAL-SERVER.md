# Tunneling a local server

`server.py` is a plain-HTTP JSON server that runs on your machine.
Register it as a hoop httpproxy connection and any hostname you pick —
even one that doesn't exist — routes through the tunnel and lands back
on your own port 9000. The full loop:

```
curl http://myapp.company.com/json      (hostname exists nowhere)
  └► /etc/hosts ► 100.85.109.212 (httpproxy-local.hoop)
       └► TUN ► gVisor ► gRPC ► gateway ► agent (docker)
            └► http://host.docker.internal:9000 ► server.py
```

Every request in that loop is a hoop session: authenticated, audited,
DLP-inspected. You get the whole pipeline against a server you can
read, edit, and restart in one terminal.

Prerequisites: a running gateway + agent and the tunnel daemon from the
[README](README.md), sections 1–2.

## 1. Start the server

```bash
python server.py            # 0.0.0.0:9000
python server.py 8123       # custom port
```

Stdlib only, no venv needed. It binds `0.0.0.0` because the dev agent
lives in the `hoopdev` docker container and reaches the host through
`host.docker.internal` — a loopback-only bind would refuse those
connections.

Routes:

| Path       | Returns                                              |
|------------|------------------------------------------------------|
| `/json`    | Demo payload with a timestamp                        |
| `/headers` | The headers that reached the server — shows what the agent forwarded |
| `/health`  | `{"status": "ok"}`                                   |
| POST any   | Echo of the request body                             |

Sanity check before involving hoop:

```bash
curl http://127.0.0.1:9000/json
```

## 2. Register the connection

```bash
hoop admin create connection httpproxy-local \
  -a default \
  -t application/httpproxy \
  -e REMOTE_URL=http://host.docker.internal:9000 \
  --overwrite
```

`REMOTE_URL` is what the **agent** dials, so it must be an address the
agent can reach. Pick by where your agent runs:

| Agent location            | REMOTE_URL                          |
|---------------------------|-------------------------------------|
| Docker container (dev)    | `http://host.docker.internal:9000`  |
| Bare host, same machine   | `http://localhost:9000`             |
| Another machine           | `http://<your-lan-ip>:9000`         |

Tell the tunnel daemon to pick it up:

```bash
hsh tunnel refresh
hsh tunnel ls | grep local
#   httpproxy-local.hoop   httpproxy  port 80  fdc8:...:4d75
```

## 3. Reach it through the tunnel

Direct, using the `.hoop` name:

```bash
curl http://httpproxy-local.hoop/json
```

The response comes from your server, but the bytes crossed the TUN
device, one gRPC session, the gateway, and the agent. Watch the server
terminal: the request logs `host=host.docker.internal` because the
agent rewrites the Host header from `REMOTE_URL`.

## 4. Redirect a real hostname

`redirect.sh` takes both targets from the environment:

```bash
sudo SOURCE_HOST=myapp.company.com TUNNEL_NAME=httpproxy-local.hoop \
    ./redirect.sh up
#   hosts:   myapp.company.com -> 100.85.109.212 (httpproxy-local.hoop)

curl http://myapp.company.com/json
curl http://myapp.company.com/headers

sudo SOURCE_HOST=myapp.company.com ./redirect.sh down
```

Now any process on this machine that dials
`http://myapp.company.com` transparently goes through hoop and hits
your local server. The hostname never needs to resolve publicly:
`/etc/hosts` answers before DNS gets asked.

Entries are scoped per hostname, so the httpbin redirect from the
README and this one can be up at the same time; `down` for one leaves
the other alone.

## 5. Confirm the session trail

Three places show the same request:

```bash
# server terminal — one line per request, with the rewritten Host:
#   127.0.0.1 "GET /json HTTP/1.1" 200 - host=host.docker.internal

# gateway log:
#   http request, GET http://host.docker.internal:9000/json
#   http response, status=200

hoop admin get sessions      # one session per TCP connection
```

If `/headers` shows `"Host": "host.docker.internal"` you are looking at
tunneled traffic; a direct `curl 127.0.0.1:9000/headers` shows
`"Host": "127.0.0.1:9000"` instead. That one field distinguishes the
two paths at a glance.

## Failure modes

- **`curl http://httpproxy-local.hoop` refused instantly** — the daemon
  hasn't loaded the connection. Run `hsh tunnel refresh` and check
  `hsh tunnel ls`.
- **"Server disconnected without sending a response"** — the agent
  can't reach `REMOTE_URL`. Test from inside the container:
  `docker exec hoopdev wget -qO- http://host.docker.internal:9000/health`.
  A loopback-bound server (`127.0.0.1` instead of `0.0.0.0`) fails
  exactly here.
- **Redirected hostname resolves to the wrong place** — a stale DNS
  cache. `redirect.sh` flushes on `up`/`down`, but long-lived processes
  cache resolutions internally; restart the client process.
- **Port 443** — the tunnel rejects it for httpproxy connections. The
  client URL must be `http://`. `REMOTE_URL` may be anything the agent
  can dial, including `https://`.
