#!/usr/bin/env bash

# Copyright (c) 2021-2026 tteck
# Author: tteck (tteckster)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://coder.com/ | Github: https://github.com/coder/coder

# ────────────────────────────────────────────────────────────────────────────
# Colours & symbols
# ────────────────────────────────────────────────────────────────────────────
YW=$(printf '\033[33m')
BL=$(printf '\033[36m')
RD=$(printf '\033[01;31m')
GN=$(printf '\033[1;92m')
CL=$(printf '\033[m')
BFR="\\r\\033[K"
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"

APP="Coder"
CODER_PORT=3000
CT_HOSTNAME="coder"
CT_RAM=8192
CT_CORES=2
CT_DISK=64
CT_BRIDGE="vmbr0"
DEBIAN_TEMPLATE_FILTER="debian-12-standard"

# ────────────────────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────────────────────
function header_info {
  clear
  cat <<"EOF"
   ______          __
  / ____/___  ____/ /__  _____
 / /   / __ \/ __  / _ \/ ___/
/ /___/ /_/ / /_/ /  __/ /
\____/\____/\__,_/\___/_/

EOF
}

msg_info()  { echo -ne " ${HOLD} ${YW}${1}...${CL}"; }
msg_ok()    { echo -e "${BFR} ${CM} ${GN}${1}${CL}"; }
msg_error() { echo -e "${BFR} ${CROSS} ${RD}${1}${CL}"; }

function die() {
  msg_error "${1:-Unexpected error at line ${BASH_LINENO[0]}}"
  exit 1
}

function confirm() {
  # confirm "Question?" → returns 0 for yes, 1 for no
  while true; do
    read -rp " ${YW}${1}${CL} [y/n] " yn
    case "$yn" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
      *) echo "  Please answer y or n." ;;
    esac
  done
}

function choose() {
  # choose "prompt" opt1 opt2 ... → sets CHOICE to the selected option number (1-based)
  local prompt="$1"; shift
  local opts=("$@")
  echo -e " ${YW}${prompt}${CL}"
  for i in "${!opts[@]}"; do
    echo "   $((i+1))) ${opts[$i]}"
  done
  while true; do
    read -rp "   Selection: " sel
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#opts[@]} )); then
      CHOICE=$sel
      return
    fi
    echo "   Invalid selection."
  done
}

# ────────────────────────────────────────────────────────────────────────────
# INSTALL — runs inside the LXC container
# ────────────────────────────────────────────────────────────────────────────
function install_coder() {
  local IP
  IP=$(hostname -I | awk '{print $1}')

  if [[ "$(id -u)" -ne 0 ]]; then die "Run as root."; fi
  if [ -e /etc/alpine-release ]; then die "Alpine Linux is not supported."; fi

  # ── Dependencies ──────────────────────────────────────────────────────────
  msg_info "Installing dependencies"
  apt-get update &>/dev/null
  apt-get install -y curl ca-certificates postgresql &>/dev/null
  msg_ok "Installed dependencies"

  # ── Docker ────────────────────────────────────────────────────────────────
  if ! command -v docker &>/dev/null; then
    msg_info "Installing Docker"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
      -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      >/etc/apt/sources.list.d/docker.list
    apt-get update &>/dev/null
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin &>/dev/null
    systemctl enable -q --now docker
    msg_ok "Installed Docker"
  else
    msg_ok "Docker already installed"
  fi

  # ── Architecture ──────────────────────────────────────────────────────────
  local ARCH ARCH_CODER
  ARCH=$(dpkg --print-architecture)
  case "$ARCH" in
    amd64|arm64) ARCH_CODER="$ARCH" ;;
    armhf)       ARCH_CODER="armv7" ;;
    *)           die "Unsupported architecture: $ARCH" ;;
  esac

  # ── Fetch latest version ──────────────────────────────────────────────────
  local VERSION
  VERSION=$(curl -fsSL https://api.github.com/repos/coder/coder/releases/latest \
    | grep '"tag_name"' \
    | awk '{print substr($2, 3, length($2)-4)}')
  [[ -z "$VERSION" ]] && die "Could not determine latest Coder version."

  # ── Install / upgrade binary ──────────────────────────────────────────────
  local DEB="/tmp/coder_${VERSION}_linux_${ARCH_CODER}.deb"
  msg_info "Installing Coder v${VERSION}"
  curl -fsSL "https://github.com/coder/coder/releases/download/v${VERSION}/coder_${VERSION}_linux_${ARCH_CODER}.deb" \
    -o "$DEB"
  dpkg -i "$DEB" &>/dev/null
  rm -f "$DEB"
  msg_ok "Installed Coder v${VERSION}"

  # ── PostgreSQL ─────────────────────────────────────────────────────────────
  local DB_PASS
  if [[ -f /etc/coder.d/coder.env ]] && grep -q "CODER_PG_CONNECTION_URL" /etc/coder.d/coder.env; then
    # Upgrade path: keep existing DB credentials
    msg_ok "Reusing existing PostgreSQL credentials"
  else
    msg_info "Configuring PostgreSQL"
    DB_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
    systemctl enable -q --now postgresql
    for _ in $(seq 1 10); do pg_isready -q && break; sleep 1; done
    su -c "psql -c \"CREATE USER coder WITH PASSWORD '${DB_PASS}';\"" postgres 2>/dev/null || true
    su -c "psql -c \"CREATE DATABASE coder OWNER coder;\"" postgres 2>/dev/null || true

    # ── System user ────────────────────────────────────────────────────────
    id -u coder &>/dev/null || useradd --system --create-home --shell /bin/bash coder
    usermod -aG docker coder

    # ── Config file ────────────────────────────────────────────────────────
    mkdir -p /etc/coder.d
    cat <<EOF >/etc/coder.d/coder.env
# Coder configuration — edit then: systemctl restart coder
CODER_PG_CONNECTION_URL=postgresql://coder:${DB_PASS}@localhost/coder?sslmode=disable
CODER_HTTP_ADDRESS=0.0.0.0:${CODER_PORT}
CODER_ACCESS_URL=http://${IP}:${CODER_PORT}
# Uncomment for workspace app support:
# CODER_WILDCARD_ACCESS_URL=*.coder.example.com
EOF
    chmod 600 /etc/coder.d/coder.env
    msg_ok "Configured PostgreSQL"
  fi

  # ── Dockge ────────────────────────────────────────────────────────────────
  if [[ ! -f /opt/dockge/compose.yaml ]]; then
    msg_info "Installing Dockge"
    mkdir -p /opt/stacks /opt/dockge
    curl -fsSL https://raw.githubusercontent.com/louislam/dockge/master/compose.yaml \
      -o /opt/dockge/compose.yaml
    docker compose -f /opt/dockge/compose.yaml up -d &>/dev/null
    msg_ok "Installed Dockge"
  else
    msg_info "Updating Dockge"
    docker compose -f /opt/dockge/compose.yaml pull &>/dev/null
    docker compose -f /opt/dockge/compose.yaml up -d &>/dev/null
    msg_ok "Updated Dockge"
  fi

  # ── Systemd service ───────────────────────────────────────────────────────
  msg_info "Enabling Coder service"
  cat <<EOF >/etc/systemd/system/coder.service
[Unit]
Description=Coder — Remote Development Platform
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=coder
Group=coder
EnvironmentFile=/etc/coder.d/coder.env
ExecStart=/usr/bin/coder server
Restart=on-failure
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable -q coder
  systemctl restart coder
  sleep 3
  systemctl is-active --quiet coder || die "Coder service failed to start. Check: journalctl -u coder -n 50"
  msg_ok "Coder service running"

  echo -e "
${GN}${APP} is ready on $(hostname).${CL}

  Coder   : ${BL}http://${IP}:${CODER_PORT}${CL}
  Dockge  : ${BL}http://${IP}:5001${CL}
  Config  : /etc/coder.d/coder.env
  Logs    : journalctl -u coder -f

  ${YW}Open the Coder URL above to create your admin account.${CL}
"
}

# ────────────────────────────────────────────────────────────────────────────
# PROXMOX HOST — LXC creation / update
# ────────────────────────────────────────────────────────────────────────────
function find_coder_containers() {
  # Prints "CTID hostname" lines for any container whose hostname contains "coder"
  pct list 2>/dev/null | awk 'NR>1 {print $1, $3}' | grep -i "coder" || true
}

function next_ctid() {
  pvesh get /cluster/nextid 2>/dev/null || \
    awk -F'/' '/^\/etc\/pve\/lxc\/[0-9]+\.conf$/{id=substr($5,1,length($5)-5); if(id>max)max=id} END{print max+1}' \
      <(find /etc/pve/lxc -name '*.conf' 2>/dev/null)
}

function pick_storage() {
  # Prefer local-lvm; fall back to first available storage with content rootdir
  local candidates
  candidates=$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
  echo "$candidates" | grep -q "local-lvm" && { echo "local-lvm"; return; }
  echo "$candidates" | head -1
}

function ensure_template() {
  # Downloads latest Debian 12 standard template to local storage if not present
  local STORAGE="local"
  local TEMPLATE
  TEMPLATE=$(pveam available --section system 2>/dev/null \
    | awk '{print $2}' \
    | grep "^${DEBIAN_TEMPLATE_FILTER}" \
    | sort -V | tail -1)
  [[ -z "$TEMPLATE" ]] && die "Could not find a ${DEBIAN_TEMPLATE_FILTER} template in pveam."

  if ! pveam list "$STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
    msg_info "Downloading template ${TEMPLATE}"
    pveam download "$STORAGE" "$TEMPLATE" &>/dev/null || die "Template download failed."
    msg_ok "Downloaded ${TEMPLATE}"
  fi
  echo "${STORAGE}:vztmpl/${TEMPLATE}"
}

function create_lxc() {
  local CTID="$1"
  local HOSTNAME="$2"

  local STORAGE TMPL
  STORAGE=$(pick_storage)
  [[ -z "$STORAGE" ]] && die "No suitable storage found for rootfs."
  TMPL=$(ensure_template)

  msg_info "Creating LXC container ${CTID} (${HOSTNAME})"
  pct create "$CTID" "$TMPL" \
    --hostname "$HOSTNAME" \
    --cores "$CT_CORES" \
    --memory "$CT_RAM" \
    --rootfs "${STORAGE}:${CT_DISK}" \
    --net0 "name=eth0,bridge=${CT_BRIDGE},ip=dhcp" \
    --features "nesting=1,keyctl=1" \
    --unprivileged 0 \
    --onboot 1 \
    --start 1 \
    &>/dev/null || die "pct create failed."
  msg_ok "Created LXC container ${CTID}"

  msg_info "Waiting for container network"
  local tries=0
  local ct_ip=""
  while [[ -z "$ct_ip" && $tries -lt 30 ]]; do
    sleep 2
    ct_ip=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')
    ((tries++))
  done
  [[ -z "$ct_ip" ]] && die "Container did not get an IP after 60s."
  msg_ok "Container IP: ${ct_ip}"
}

function run_install_in_ct() {
  local CTID="$1"
  msg_info "Copying installer into container ${CTID}"
  pct push "$CTID" "$0" /tmp/coder-install.sh &>/dev/null
  pct exec "$CTID" -- chmod +x /tmp/coder-install.sh
  msg_ok "Copied installer"

  msg_info "Running installer inside container ${CTID}"
  # Pass a flag so the script knows to go straight to install_coder()
  pct exec "$CTID" -- bash /tmp/coder-install.sh --inside-lxc
  msg_ok "Installer finished"
}

function proxmox_mode() {
  local existing
  existing=$(find_coder_containers)

  if [[ -n "$existing" ]]; then
    echo -e "\n${YW}Existing Coder container(s) found:${CL}"
    echo "$existing" | while read -r ctid hostname; do
      local state
      state=$(pct status "$ctid" 2>/dev/null | awk '{print $2}')
      echo "   CTID ${BL}${ctid}${CL}  hostname=${hostname}  state=${state}"
    done
    echo ""

    choose "What would you like to do?" \
      "Update an existing container" \
      "Create a new container"

    case "$CHOICE" in
      1)
        # Update
        local ctid_list=()
        while read -r ctid _; do ctid_list+=("$ctid"); done <<<"$existing"

        local TARGET_CTID
        if [[ ${#ctid_list[@]} -eq 1 ]]; then
          TARGET_CTID="${ctid_list[0]}"
        else
          choose "Which container to update?" "${ctid_list[@]}"
          TARGET_CTID="${ctid_list[$((CHOICE-1))]}"
        fi

        local state
        state=$(pct status "$TARGET_CTID" 2>/dev/null | awk '{print $2}')
        if [[ "$state" != "running" ]]; then
          msg_info "Starting container ${TARGET_CTID}"
          pct start "$TARGET_CTID" &>/dev/null
          sleep 3
          msg_ok "Container started"
        fi

        run_install_in_ct "$TARGET_CTID"
        return
        ;;
      2)
        # Fall through to new container creation below
        ;;
    esac
  fi

  # ── New container ──────────────────────────────────────────────────────────
  local CTID
  CTID=$(next_ctid)
  echo -e "\n${YW}New container defaults:${CL}"
  echo "   CTID      : ${CTID}"
  echo "   Hostname  : ${CT_HOSTNAME}"
  echo "   Cores     : ${CT_CORES}"
  echo "   RAM       : ${CT_RAM} MB"
  echo "   Disk      : ${CT_DISK} GB"
  echo "   Bridge    : ${CT_BRIDGE}"
  echo ""

  confirm "Proceed with these settings?" || {
    echo "  Adjust CT_* variables at the top of this script and re-run."
    exit 0
  }

  create_lxc "$CTID" "$CT_HOSTNAME"
  run_install_in_ct "$CTID"
}

# ────────────────────────────────────────────────────────────────────────────
# Entry point
# ────────────────────────────────────────────────────────────────────────────
header_info

if [[ "${1:-}" == "--inside-lxc" ]]; then
  # Called by pct exec — go straight to install
  install_coder
  exit 0
fi

if command -v pveversion >/dev/null 2>&1; then
  # Running on the Proxmox host
  if ! confirm "This will install ${APP} in an LXC container on $(hostname). Proceed?"; then
    exit 0
  fi
  proxmox_mode
else
  # Running directly inside a container
  if ! confirm "This will install ${APP} on $(hostname). Proceed?"; then
    exit 0
  fi
  install_coder
fi
