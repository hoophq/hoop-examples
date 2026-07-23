#!/usr/bin/env bash
# redirect.sh — send http://httpbin.org into the hoop tunnel's httpproxy
# connection with zero app changes, by pointing the hostname at the
# connection's stable tunnel IP in /etc/hosts.
#
#   app.py ── http://httpbin.org:80 ─► 100.85.x.x (tunnel IP, via /etc/hosts)
#                                        └► TUN ► gVisor ► gRPC ► gateway ► agent ─HTTP► httpbin.org
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
TUNNEL_RESOLVER="${TUNNEL_RESOLVER:-fdc8:b7f6:8b4a::1}"  # tunnel DNS; override for non-default sessions
MARKER="# hoop-proxy-tunnel"              # tags our /etc/hosts line
HOSTS_FILE="/etc/hosts"
HOSTS_TAG=$'\t'"${SOURCE_HOST}"$'\t'"${MARKER}"
PLATFORM="$(uname -s)"
TMP_HOSTS=""
# pf-era state files, cleaned up by `down` if a previous version left them
ANCHOR="com.apple/250.HoopTunnelRedirect"
STATE="/tmp/hoop-redirect.routes"
FWDSTATE="/tmp/hoop-redirect.fwd"
TIPSTATE="/tmp/hoop-redirect.tip"

die() { echo "error: $*" >&2; exit 1; }

case "$PLATFORM" in
    Darwin|Linux) ;;
    *) die "unsupported operating system: $PLATFORM" ;;
esac

cleanup_tmp() {
    [ -z "$TMP_HOSTS" ] || rm -f "$TMP_HOSTS"
}
trap cleanup_tmp EXIT

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo"; }

tunnel_ip() {
    need_command dig
    dig @"$TUNNEL_RESOLVER" "$TUNNEL_NAME" A +short +time=2 +tries=1 2>/dev/null |
        awk 'NR == 1 { first = $0 } END { if (first != "") print first }' || true
}

resolve_source_ip() {
    case "$PLATFORM" in
        Darwin)
            dscacheutil -q host -a name "$SOURCE_HOST" 2>/dev/null |
                awk '$1 == "ip_address:" && $2 !~ /:/ && first == "" { first = $2 }
                     END { if (first != "") print first }' || true
            ;;
        Linux)
            need_command getent
            getent ahostsv4 "$SOURCE_HOST" |
                awk 'NR == 1 { first = $1 } END { if (first != "") print first }' || true
            ;;
    esac
}

flush_dns() {
    case "$PLATFORM" in
        Darwin)
            dscacheutil -flushcache 2>/dev/null || true
            killall -HUP mDNSResponder 2>/dev/null || true
            ;;
        Linux)
            if command -v resolvectl >/dev/null 2>&1; then
                resolvectl flush-caches >/dev/null 2>&1 || true
            elif command -v systemd-resolve >/dev/null 2>&1; then
                systemd-resolve --flush-caches >/dev/null 2>&1 || true
            elif command -v nscd >/dev/null 2>&1; then
                nscd -i hosts >/dev/null 2>&1 || true
            fi
            ;;
    esac
}

up() {
    need_root
    grep -Fq "$HOSTS_TAG" "$HOSTS_FILE" && die "already up for $SOURCE_HOST; run 'down' first"

    TUNNEL_IP=$(tunnel_ip)
    [ -n "$TUNNEL_IP" ] || die "cannot resolve $TUNNEL_NAME via $TUNNEL_RESOLVER — is hsh-tunneld running? (hsh tunnel up)"

    printf '%s\t%s\t%s\n' "$TUNNEL_IP" "$SOURCE_HOST" "$MARKER" >> "$HOSTS_FILE"
    flush_dns

    echo "hosts:   $SOURCE_HOST -> $TUNNEL_IP ($TUNNEL_NAME)"
    echo "up. try: python app.py   (URL must be http://$SOURCE_HOST/...)"
}

remove_hosts_entry() {
    TMP_HOSTS=$(mktemp "${TMPDIR:-/tmp}/hoop-hosts.XXXXXX")
    awk -v needle="$HOSTS_TAG" 'index($0, needle) == 0' "$HOSTS_FILE" > "$TMP_HOSTS"

    # Overwrite the existing inode so this also works when /etc/hosts is
    # bind-mounted, as it is inside Docker containers.
    cat "$TMP_HOSTS" > "$HOSTS_FILE"
    rm -f "$TMP_HOSTS"
    TMP_HOSTS=""
}

cleanup_legacy_macos_state() {
    [ "$PLATFORM" = "Darwin" ] || return 0

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
}

down() {
    need_root

    if grep -Fq "$HOSTS_TAG" "$HOSTS_FILE"; then
        remove_hosts_entry
        flush_dns
        echo "hosts:   $SOURCE_HOST entry removed"
    fi

    cleanup_legacy_macos_state
    echo "down."
}

status() {
    local resolved_ip

    echo "== $HOSTS_FILE =="
    grep -F "$MARKER" "$HOSTS_FILE" || echo "(no entry)"
    echo "== resolution =="
    resolved_ip=$(resolve_source_ip)
    if [ -n "$resolved_ip" ]; then
        echo "ip_address: $resolved_ip"
    else
        echo "(unresolved)"
    fi
}

case "${1:-}" in
    up)     up ;;
    down)   down ;;
    status) status ;;
    *)      echo "usage: sudo $0 {up|down|status}" >&2; exit 2 ;;
esac
