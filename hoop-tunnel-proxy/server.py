"""Local upstream for the hoop httpproxy demo. Stdlib only.

Runs a plain-HTTP JSON server on this machine. Register it in hoop as an
httpproxy connection, then point any hostname at the tunnel with
redirect.sh — requests flow app -> tunnel -> gateway -> agent -> here.

    python server.py            # listens on 0.0.0.0:9000
    python server.py 8123       # custom port

Bind is 0.0.0.0 on purpose: the dev agent lives in the `hoopdev` docker
container and reaches this server via host.docker.internal, which only
works when the server accepts non-loopback connections.

Register in hoop (the agent resolves REMOTE_URL, so use the address the
AGENT can reach — host.docker.internal for a dockerized dev agent,
http://localhost:9000 for an agent on the bare host):

    hoop admin create connection httpproxy-local \
        -a default \
        -t application/httpproxy \
        -e REMOTE_URL=http://host.docker.internal:9000 \
        --overwrite

Then:

    hsh tunnel refresh
    curl http://httpproxy-local.hoop/json           # direct via tunnel
    sudo SOURCE_HOST=myapp.company.com TUNNEL_NAME=httpproxy-local.hoop \
        ./redirect.sh up
    curl http://myapp.company.com/json              # redirected via tunnel
"""

import json
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_PORT = 9000


class Handler(BaseHTTPRequestHandler):
    server_version = "hoop-demo-server/1.0"

    def _send_json(self, status: int, body: dict) -> None:
        payload = json.dumps(body, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        if self.path == "/health":
            self._send_json(200, {"status": "ok"})
        elif self.path == "/json":
            self._send_json(
                200,
                {
                    "message": "served by local server.py through the hoop tunnel",
                    "time": datetime.now(timezone.utc).isoformat(),
                    "path": self.path,
                },
            )
        elif self.path == "/headers":
            # Echo what actually arrived — shows the Host header the
            # redirect preserved and any headers the agent injected.
            self._send_json(200, {"headers": dict(self.headers)})
        else:
            self._send_json(404, {"error": "not found", "path": self.path})

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw) if raw else None
        except json.JSONDecodeError:
            body = raw.decode(errors="replace")
        self._send_json(200, {"echo": body, "path": self.path})

    def log_message(self, fmt: str, *args) -> None:
        # One line per request, with the client and Host header so the
        # tunnel hop is visible in the log.
        sys.stderr.write(
            "%s %s host=%s\n"
            % (self.address_string(), fmt % args, self.headers.get("Host", "-"))
        )


def main() -> None:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PORT
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"server.py listening on 0.0.0.0:{port} (/json /headers /health)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
