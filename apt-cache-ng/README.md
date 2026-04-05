# apt-cache-ng

APT proxy auto-detection for use with [apt-cacher-ng](https://www.unix-ag.uni-kl.de/~bloch/acng/).

Automatically uses the `apt-cacher-ng` proxy when on the local LAN, and falls back to `DIRECT` otherwise — no manual reconfiguration needed when moving between networks.

## How it works

The script `apt-proxy-autodetect` is called by APT before each HTTP request. It checks:

1. **Default gateway** — if it is not the expected LAN gateway, exit with `DIRECT`.
2. **Local IP** (optional) — if a static LAN IP is configured and the machine does not have it, exit with `DIRECT`.
3. **Proxy reachability** — uses `nc` to test the proxy host/port. If reachable, outputs the proxy URL; otherwise outputs `DIRECT`.

## Configuration

Edit the variables at the top of `apt-proxy-autodetect`:

```sh
LAN_GATEWAY="10.0.0.1"   # Your LAN's default gateway IP
LAN_IP="10.0.0.13"        # Your machine's static LAN IP (comment out if DHCP)
PROXY_HOST="10.0.0.15"    # Host running apt-cacher-ng
PROXY_PORT="3142"          # apt-cacher-ng port (default: 3142)
```

If `LAN_IP` is commented out, only the gateway check and proxy reachability test are used.

## Dependencies

- `ip` (iproute2) — for gateway and address detection
- `nc` (netcat) — for proxy reachability check


## Files

| File | Purpose |
|------|---------|
| `apt-proxy-autodetect` | Shell script placed at `/usr/local/bin/apt-proxy-autodetect` |
| `00proxy-autodetect` | APT config snippet placed at `/etc/apt/apt.conf.d/00proxy-autodetect` |

## Installation

```sh
sudo cp apt-proxy-autodetect /usr/local/bin/apt-proxy-autodetect
sudo chmod +x /usr/local/bin/apt-proxy-autodetect
sudo cp 00proxy-autodetect /etc/apt/apt.conf.d/00proxy-autodetect
sudo apt update
```
