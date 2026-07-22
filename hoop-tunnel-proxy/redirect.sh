#!/usr/bin/env bash
# redirect.sh — send http://httpbin.org into the hoop tunnel's httpproxy
# connection with zero app changes, by pointing the hostname at the
# connection's stable tunnel IP in /etc/hosts.
#
#   app.py ── http://httpbin.org:80 ─► 100.85.x.x (tunnel IP, via /etc/hosts)
#                                        └► TUN ► gVisor ► gRPC ► gateway ► agent ─TLS► httpbin.org
#
# Why not pf (macOS iptables)? We tried the textbook loopback-bounce
# (`pass out route-to lo0` + `rdr on lo0 -> <tunnel-ip>`): packet capture
# shows the SYN looping on lo0 untranslated — modern macOS pf cannot
# DNAT locally-originated traffic to a REMOTE address; rdr only works
# toward local listeners. The Linux equivalent that does work:
#
#   iptables -t nat -A OUTPUT -p tcp -d <httpbin-ip> --dport 80 \
#       -j DNAT --to-destination <tunnel-ip>:80
#
# /etc/hosts is also strictly better here: immune to CDN IP rotation,
# no IP forwarding sysctl, no route-scope games. The hoop agent runs in
# its own container/host with separate DNS, so REMOTE_URL still resolves
# to the real httpbin.org — no loop.
#
# Usage:
#   sudo ./redirect.sh up       # add hosts entry (+ flush DNS cache)
#   sudo ./redirect.sh down     # remove it (also cleans pf-era leftovers)
#   ./redirect.sh status        # show current state
#   python app.py               # app must use http:// (port 80; the tunnel
#                               # rejects 443 — it has no cert for httpbin.org)
set -euo pipefail

SOURCE_HOST="${SOURCE_HOST:-httpbin.org}"           # host the app dials (env-overridable)
TUNNEL_NAME="${TUNNEL_NAME:-httpproxy-role.hoop}"   # hoop connection (see: hsh tunnel ls)
TUNNEL_RESOLVER="fdc8:b7f6:8b4a::1"       # from /etc/resolver/hoop
MARKER="# hoop-proxy-tunnel"              # tags our /etc/hosts line
# pf-era state files, cleaned up by `down` if a previous version left them
ANCHOR="com.apple/250.HoopTunnelRedirect"
STATE="/tmp/hoop-redirect.routes"
FWDSTATE="/tmp/hoop-redirect.fwd"
TIPSTATE="/tmp/hoop-redirect.tip"

die() { echo "error: $*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo"; }

tunnel_ip() {
    dig @"$TUNNEL_RESOLVER" "$TUNNEL_NAME" A +short +time=2 +tries=1 | head -1
}

flush_dns() {
    dscacheutil -flushcache 2>/dev/null || true
    killall -HUP mDNSResponder 2>/dev/null || true
}

up() {
    need_root
    grep -q "	$SOURCE_HOST	$MARKER" /etc/hosts && die "already up for $SOURCE_HOST; run 'down' first"

    TUNNEL_IP=$(tunnel_ip)
    [ -n "$TUNNEL_IP" ] || die "cannot resolve $TUNNEL_NAME via $TUNNEL_RESOLVER — is hsh-tunneld running? (hsh tunnel up)"

    printf '%s\t%s\t%s\n' "$TUNNEL_IP" "$SOURCE_HOST" "$MARKER" >> /etc/hosts
    flush_dns

    echo "hosts:   $SOURCE_HOST -> $TUNNEL_IP ($TUNNEL_NAME)"
    echo "up. try: python app.py   (URL must be http://$SOURCE_HOST/...)"
}

down() {
    need_root

    # remove our hosts entry
    if grep -q "	$SOURCE_HOST	$MARKER" /etc/hosts; then
        sed -i '' "/	$SOURCE_HOST	$MARKER/d" /etc/hosts
        flush_dns
        echo "hosts:   $SOURCE_HOST entry removed"
    fi

    # clean up anything the old pf-based versions left behind
    pfctl -a "$ANCHOR" -F all 2>/dev/null || true
    if [ -f "$TIPSTATE" ]; then
        route -q delete -host "$(cat "$TIPSTATE")" >/dev/null 2>&1 || true
        rm -f "$TIPSTATE"
    fi
    if [ -f "$STATE" ]; then
        while read -r ip; do
            route -q delete -host "$ip" 127.0.0.1 >/dev/null 2>&1 || true
        done < "$STATE"
        rm -f "$STATE"
    fi
    if [ -f "$FWDSTATE" ]; then
        sysctl -w net.inet.ip.forwarding="$(cat "$FWDSTATE")" >/dev/null 2>&1 || true
        rm -f "$FWDSTATE"
    fi
    echo "down."
}

status() {
    echo "== /etc/hosts =="
    grep "$MARKER" /etc/hosts || echo "(no entry)"
    echo "== resolution =="
    dscacheutil -q host -a name "$SOURCE_HOST" 2>/dev/null | grep ip_address || echo "(unresolved)"
}

case "${1:-}" in
    up)     up ;;
    down)   down ;;
    status) status ;;
    *)      echo "usage: sudo $0 {up|down|status}" >&2; exit 2 ;;
esac
