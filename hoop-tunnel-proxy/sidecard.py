"""Run an unchanged HTTPX application through Hoop Tunnel.

Rewrites:
    https://httpbin.org/... -> http://httpbin.hoop/...

Usage:
    python sidecar.py app.py
"""

import runpy
import sys

import httpx

SOURCE_HOST = "httpbin.org"
TUNNEL_HOST = "httpproxy-role.hoop"


def rewrite(request: httpx.Request) -> None:
    if request.url.host != SOURCE_HOST:
        return

    request.url = request.url.copy_with(
        scheme="http",
        host=TUNNEL_HOST,
        port=None,
    )


_original_send = httpx.Client.send
_original_async_send = httpx.AsyncClient.send


def send(self, request, *args, **kwargs):
    rewrite(request)
    return _original_send(self, request, *args, **kwargs)


async def async_send(self, request, *args, **kwargs):
    rewrite(request)
    return await _original_async_send(self, request, *args, **kwargs)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: python sidecar.py <application.py>")

    application = sys.argv[1]

    httpx.Client.send = send
    httpx.AsyncClient.send = async_send

    sys.argv = [application]
    runpy.run_path(application, run_name="__main__")


if __name__ == "__main__":
    main()
