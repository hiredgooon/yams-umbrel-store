#!/bin/sh
# YAMS: runs gluetun only once a WireGuard config exists, and restarts it in place
# (same container, same network namespace) whenever the dashboard saves a new one.
# Before a restart it raises a flag so qBittorrent shuts itself down first.

CONF=/gluetun/wireguard/wg0.conf
FLAG=/gluetun/restarting
pid=""

stop() {
  [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null && wait "$pid" 2>/dev/null
  exit 0
}
trap stop TERM INT

nap() { sleep "$1" & wait $!; }
checksum() { md5sum "$CONF" 2>/dev/null | cut -d' ' -f1; }

while true; do
  if [ ! -s "$CONF" ]; then
    echo "[yams] No VPN connected yet. Open YAMS in Umbrel and paste your WireGuard file."
    while [ ! -s "$CONF" ]; do nap 3; done
  fi

  sum=$(checksum)
  rm -f "$FLAG"
  # Fork: a Proton file (tunnel address 10.2.0.2) runs gluetun's built-in Proton provider,
  # which supports NAT-PMP port forwarding. The key is read from the file at start, never stored.
  if grep -Eq '^[[:space:]]*Address[[:space:]]*=[[:space:]]*10\.2\.0\.2(/32)?([[:space:]]*,|[[:space:]]*$)' "$CONF"; then
    pk=$(sed -n 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*//p' "$CONF" | head -n1 | tr -d '\r ')
    addr=$(sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' "$CONF" | head -n1 | cut -d, -f1 | tr -d '\r ')
    echo "[yams] Proton file detected. Starting VPN with port forwarding (${PROTON_SERVER_COUNTRIES:-Australia})"
    VPN_SERVICE_PROVIDER=protonvpn WIREGUARD_PRIVATE_KEY="$pk" WIREGUARD_ADDRESSES="${addr:-10.2.0.2/32}" \
      SERVER_COUNTRIES="${PROTON_SERVER_COUNTRIES:-Australia}" PORT_FORWARD_ONLY=on VPN_PORT_FORWARDING=on \
      /gluetun-entrypoint &
    unset pk addr
  else
    echo "[yams] Starting VPN"
    /gluetun-entrypoint &
  fi
  pid=$!
  started=$(date +%s)

  while kill -0 "$pid" 2>/dev/null; do
    nap 3
    if [ "$(checksum)" != "$sum" ]; then
      echo "[yams] VPN settings changed. Pausing downloads, then reconnecting."
      touch "$FLAG"
      nap 12
      kill -TERM "$pid" 2>/dev/null
      break
    fi
  done
  wait "$pid" 2>/dev/null
  pid=""

  # If gluetun crashed straight away (usually a bad config), don't spin too fast.
  if [ $(( $(date +%s) - started )) -lt 20 ]; then
    echo "[yams] VPN stopped quickly. Check the WireGuard file in the YAMS dashboard."
    touch "$FLAG"
    nap 15
  fi
done
