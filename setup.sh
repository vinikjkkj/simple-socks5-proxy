#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root." >&2
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

INTERFACE=${INTERFACE:-eth0}
PREFIX=${PREFIX:-"2001:db8::"}
SUBNET=${SUBNET:-"/64"}
GATEWAY=${GATEWAY:-"fe80::1"}
COUNT=${COUNT:-1000}
START_INDEX=${START_INDEX:-1}
PORT_BASE=${PORT_BASE:-10000}
ROTATE_PORT=${ROTATE_PORT:-50000}
PROXY_USER=${PROXY_USER:-admin}
PROXY_PASS=${PROXY_PASS:-admin}
DNS1=${DNS1:-"2606:4700:4700::1111"}
DNS2=${DNS2:-"2001:4860:4860::8888"}
NETPLAN_FILE=${NETPLAN_FILE:-"/etc/netplan/50-cloud-init.yaml"}
PROXY_CFG=${PROXY_CFG:-"/etc/3proxy/3proxy.cfg"}
SERVICE_FILE=${SERVICE_FILE:-"/etc/systemd/system/3proxy.service"}
PROXY_BIN=${PROXY_BIN:-""}
PROXY_DEB_PATH=${PROXY_DEB_PATH:-"${SCRIPT_DIR}/3proxy-0.9.5.x86_64.deb"}
PROXY_SRC_URL=${PROXY_SRC_URL:-""}

if [[ ${COUNT} -le 0 ]]; then
  echo "COUNT must be > 0" >&2
  exit 1
fi

if [[ -z "${PREFIX}" || "${PREFIX}" == "2001:db8::" ]]; then
  echo "ERROR: You must set a valid IPv6 PREFIX (e.g., 2607:f0d0:1002::) before running the script."
  exit 1
fi

if ! command -v netplan >/dev/null 2>&1; then
  echo "netplan command not found. Install netplan or adjust the script for your distro." >&2
  exit 1
fi

addr_hex() {
  printf '%x' "$1"
}

build_ipv6() {
  local host_hex
  host_hex=$(addr_hex "$1")
  printf '%s%s' "$PREFIX" "$host_hex"
}

enable_nonlocal_bind() {
  echo "Enabling non-local IP bind..."
  sysctl -w net.ipv6.ip_nonlocal_bind=1
  grep -q "net.ipv6.ip_nonlocal_bind=1" /etc/sysctl.conf || \
    echo "net.ipv6.ip_nonlocal_bind=1" >> /etc/sysctl.conf
}

add_local_ipv6_block() {
  echo "Adding IPv6 local block ${PREFIX}${SUBNET} to ${INTERFACE} and lo..."
  ip route add local ${PREFIX}${SUBNET} dev lo || true
  ip route add local ${PREFIX}${SUBNET} dev ${INTERFACE} || true
}

find_proxy_bin() {
  if command -v 3proxy >/dev/null 2>&1; then
    PROXY_BIN=$(command -v 3proxy)
  elif [[ -x /usr/sbin/3proxy ]]; then
    PROXY_BIN=/usr/sbin/3proxy
  elif [[ -x /usr/local/sbin/3proxy ]]; then
    PROXY_BIN=/usr/local/sbin/3proxy
  elif [[ -x /usr/bin/3proxy ]]; then
    PROXY_BIN=/usr/bin/3proxy
  else
    PROXY_BIN=""
  fi
}

build_from_source() {
  echo "Building 3proxy from source..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y build-essential wget tar make gcc libc6-dev || {
    echo "Failed installing build prerequisites." >&2
    exit 1
  }
  tmpdir=$(mktemp -d)
  trap 'rm -rf "${tmpdir}"' EXIT
  cd "${tmpdir}"
  if ! wget -q -6 "${PROXY_SRC_URL}" -O 3proxy.tar.gz; then
    if ! wget -q "${PROXY_SRC_URL}" -O 3proxy.tar.gz; then
      echo "Failed downloading 3proxy source from ${PROXY_SRC_URL}. Set PROXY_SRC_URL to a reachable mirror." >&2
      exit 1
    fi
  fi
  tar xf 3proxy.tar.gz
  srcdir=$(tar tf 3proxy.tar.gz | head -n1 | cut -d/ -f1)
  cd "${srcdir}"
  make -f Makefile.Linux
  install -m 755 src/3proxy /usr/local/sbin/3proxy
  install -m 755 src/3proxyctl /usr/local/sbin/3proxyctl || true
  install -m 644 ./cfg/3proxy.cfg.sample /usr/local/etc/3proxy.cfg.sample || true
  cd /
  rm -rf "${tmpdir}"
  trap - EXIT
}

regenerate_netplan() {
  echo "Generating IPv6 netplan with ${COUNT} addresses for ${INTERFACE}..."
  local tmp
  tmp=$(mktemp)
  {
    echo "network:"
    echo "  version: 2"
    echo "  ethernets:"
    echo "    ${INTERFACE}:"
    echo "      addresses:"
    for ((i=0; i<COUNT; i++)); do
      host=$((START_INDEX + i))
      echo "        - $(build_ipv6 "$host")/64"
    done
    echo "      routes:"
    echo "        - to: ::/0"
    echo "          via: ${GATEWAY}"
    echo "          on-link: true"
    echo "      nameservers:"
    echo "        addresses:"
    echo "          - ${DNS1}"
    [[ -n "${DNS2}" ]] && echo "          - ${DNS2}"
  } >"${tmp}"
  install -m 600 "${tmp}" "${NETPLAN_FILE}"
  rm -f "${tmp}"
  netplan apply
}

ensure_ipv6_addresses() {
  local missing=0
  for ((i=0; i<COUNT; i++)); do
    host=$((START_INDEX + i))
    ipv6=$(build_ipv6 "$host")
    if ! ip -6 addr show dev "${INTERFACE}" | grep -q "${ipv6}"; then
      missing=1
      break
    fi
  done
  if [[ ${missing} -eq 1 ]]; then
    regenerate_netplan
  else
    echo "IPv6 addresses already configured on ${INTERFACE}."
  fi
}

install_from_deb() {
  echo "Installing 3proxy from local package ${PROXY_DEB_PATH}..."
  if [[ ! -f "${PROXY_DEB_PATH}" ]]; then
    echo "ERROR: Local package ${PROXY_DEB_PATH} not found." >&2
    exit 1
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  if ! dpkg -i "${PROXY_DEB_PATH}"; then
    apt-get install -y -f
    dpkg -i "${PROXY_DEB_PATH}"
  fi
}

ensure_packages() {
  if ! command -v 3proxy >/dev/null 2>&1; then
    if [[ -f "${PROXY_DEB_PATH}" ]]; then
      install_from_deb
    else
      echo "Attempting to install 3proxy via apt..."
      if ! apt-get update || ! apt-get install -y 3proxy; then
        if [[ -n "${PROXY_SRC_URL}" ]]; then
          echo "3proxy package not found or installation failed. Falling back to source build." >&2
          build_from_source
        else
          echo "ERROR: Unable to install 3proxy. Provide a local package at ${PROXY_DEB_PATH} or set PROXY_SRC_URL." >&2
          exit 1
        fi
      fi
    fi
  fi
  find_proxy_bin
  if [[ -z "${PROXY_BIN}" ]]; then
    echo "ERROR: 3proxy binary not found after installation." >&2
    exit 1
  fi
  echo "3proxy binary detected at ${PROXY_BIN}"
}

write_proxy_cfg() {
  if [[ -f "${PROXY_CFG}" ]]; then
    echo "Backing up existing 3proxy config to ${PROXY_CFG}.bak"
    cp "${PROXY_CFG}" "${PROXY_CFG}.bak"
  fi

  echo "Writing ${PROXY_CFG} with ${COUNT} listeners and rotative port ${ROTATE_PORT}..."
  {
    echo "nserver ${DNS1}"
    [[ -n "${DNS2}" ]] && echo "nserver ${DNS2}"
    echo "nscache 65536"
    echo "timeouts 1 5 30 60 180 1800 15 60"
    echo "setgid nogroup"
    echo "setuid nobody"
    echo "log @syslog"
    echo "logformat \"L%Y-%m-%d %H:%M:%S %N %p %E %U %C:%c %R:%r %O %I %h %T\""
    echo "flush"
    echo "auth strong"
    echo "users ${PROXY_USER}:CL:${PROXY_PASS}"
    echo "allow ${PROXY_USER}"

    for ((i=0; i<COUNT; i++)); do
      host=$((START_INDEX + i))
      port=$((PORT_BASE + i))
      ipv6=$(build_ipv6 "$host")
      echo "socks -p${port} -6 -i:: -e${ipv6}"
    done
    echo "flush"
    echo "allow ${PROXY_USER}"
    echo "parent 1000 extip ${PREFIX}${SUBNET} 0"
    echo "socks -p${ROTATE_PORT} -6 -i::"

  } >"${PROXY_CFG}"

  chmod 600 "${PROXY_CFG}"
}

write_service() {
  echo "Writing systemd unit ${SERVICE_FILE}"
  cat <<EOF >"${SERVICE_FILE}"
[Unit]
Description=3proxy SOCKS service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${PROXY_BIN} ${PROXY_CFG}
Restart=on-failure
RestartSec=5s
ExecReload=/bin/kill -HUP \$MAINPID
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable 3proxy >/dev/null 2>&1 || true
}

start_proxy() {
  if [[ -z "${PROXY_BIN}" ]]; then
    echo "ERROR: 3proxy binary path is undefined." >&2
    exit 1
  fi
  echo "Restarting 3proxy..."
  if ! systemctl restart 3proxy; then
    echo "systemd restart failed; attempting direct launch" >&2
    pkill 3proxy >/dev/null 2>&1 || true
    "${PROXY_BIN}" "${PROXY_CFG}"
  fi
}

summary() {
  echo "Summary:"
  echo "- Interface: ${INTERFACE}"
  echo "- IPv6 prefix: ${PREFIX} (hosts ${START_INDEX}..$((START_INDEX + COUNT - 1)))"
  echo "- Individual SOCKS ports: ${PORT_BASE}..$((PORT_BASE + COUNT - 1))"
  echo "- Rotative SOCKS port: ${ROTATE_PORT}"
  echo "- 3proxy config: ${PROXY_CFG}"
  echo "- systemd unit: ${SERVICE_FILE}"
}

enable_nonlocal_bind
add_local_ipv6_block
ensure_ipv6_addresses
ensure_packages
write_proxy_cfg
write_service
start_proxy
summary
