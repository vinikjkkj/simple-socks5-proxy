# simple-socks5-proxy
## Script: `setup.sh`

Automates provisioning of a 3proxy SOCKS server on Ubuntu (run as root):
- **[network]** Generates `netplan` with a sequential IPv6 range for the chosen interface.
- **[packages]** Installs 3proxy if missing.
  - Prefers a local `3proxy-0.9.5.x86_64.deb` placed next to the script. If unavailable, falls back to `apt-get install 3proxy`; if that fails and `PROXY_SRC_URL` is set, builds from source.
- **[config]** Writes `/etc/3proxy/3proxy.cfg` with authentication and per-port IPv6 binding.
  - Each port from PORT_BASE to PORT_BASE + COUNT - 1 binds to a fixed IPv6 address from the configured range.
  - A special rotative port (ROTATE_PORT) uses parent 1000 extip PREFIX/SUBNET to randomly select any IPv6 from the subnet for each new connection.
- **[systemd]** Creates/overwrites `3proxy.service` and restarts the daemon.

### Environment variables (defaults)
- `INTERFACE=eth0`
- `PREFIX="2001:db8::"` (example IPv6 prefix, replace with your allocation)
- `COUNT=500`
- `START_INDEX=1`
- `PORT_BASE=10000`
- `ROTATE_PORT=50000`
- `PROXY_USER=proxyuser`
- `PROXY_PASS=change_me`
- `DNS1=2606:4700:4700::1111`
- `DNS2=2001:4860:4860::8888`
- `NETPLAN_FILE=/etc/netplan/60-3proxy-ipv6.yaml`
- `PROXY_CFG=/etc/3proxy/3proxy.cfg`
- `SERVICE_FILE=/etc/systemd/system/3proxy.service`
- `PROXY_DEB_PATH=$(pwd)/3proxy.deb`
- `PROXY_SRC_URL` (empty by default; set to a reachable tarball to build from source)

### Execution
```bash
sudo chmod +x setup.sh
sudo INTERFACE=eth0 PREFIX="2001:db8::" COUNT=500 \
    PORT_BASE=10000 ROTATE_PORT=50000 PROXY_USER=myuser PROXY_PASS=secret \
    ./setup.sh
```
- The script applies netplan, installs 3proxy (local .deb → apt → source), renders the config, and restarts the service.
- Re-running detects existing IPv6 addresses and refreshes configs/service.

### Post-run checks
- `ip -6 addr show dev eth0`
- `sudo systemctl status 3proxy`
- `curl --socks5 user:pass@[IPv6]:PORT -6 https://ifconfig.co/ip`
- `curl --socks5 user:pass@[IPV6]:ROTATE_PORT -6 https://ifconfig.co/ip` (test rotative port)

### Notes
- Use a `/64` prefix belonging to your provider; adjust `COUNT`, `START_INDEX`, `PORT_BASE` as required.
- Open the TCP range in your firewall (`ufw allow 10000:10499/tcp`, or provider rules).
- Monitor logs via `sudo journalctl -fu 3proxy` (the config uses `log @syslog`).
