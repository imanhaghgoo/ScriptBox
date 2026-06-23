#!/bin/bash
# ==============================================================#
#  NetConf.sh — Interactive Network Configuration Tool          #
#  Supports : static IP, DHCP, DNS, hostname, NTP, preview mode #
#  Author   : Iman Haghgoo                                      #
#  Modified : 2026-05-12                                        #
#  Revision : 0.2                                               #
# ==============================================================#


# ── Configuration Variables ──────────────────────────────────
# Hardcoded timezone — change this value to adjust
TIMEZONE="Asia/Tehran"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Helpers ──────────────────────────────────────────────────

print_banner() {
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║   Network Configuration Script       ║"
    echo "  ║   Interactive Setup (Prompt Mode)    ║"
    echo "  ╚══════════════════════════════════════╝"
    echo -e "${RESET}"
}

ask() {
    # ask <prompt> <varname> [default]
    local prompt="$1"
    local varname="$2"
    local default="$3"
    local input

    if [[ -n "$default" ]]; then
        echo -ne "${BOLD}${prompt}${RESET} [${YELLOW}${default}${RESET}]: "
    else
        echo -ne "${BOLD}${prompt}${RESET}: "
    fi

    read -r input
    input="${input:-$default}"
    eval "$varname='$input'"
}

validate_ip() {
    local ip="$1"
    local re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    if [[ ! $ip =~ $re ]]; then return 1; fi
    IFS='.' read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        (( octet < 0 || octet > 255 )) && return 1
    done
    return 0
}

validate_cidr() {
    local cidr="$1"
    [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]] && return 0
    return 1
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[!] This script must be run as root to apply changes.${RESET}"
        echo -e "    Use: ${YELLOW}sudo $0${RESET}"
        exit 1
    fi
}

# ── Step 1 — Choose interface ─────────────────────────────────

choose_interface() {
    echo -e "\n${CYAN}── Step 1: Network Interface ──────────────────────${RESET}"
    echo -e "Available interfaces:\n"

    mapfile -t IFACES < <(ip -o link show | awk -F': ' '{print $2}' | grep -v lo)
    for i in "${!IFACES[@]}"; do
        STATUS=$(cat /sys/class/net/"${IFACES[$i]}"/operstate 2>/dev/null)
        echo -e "  ${BOLD}[$((i+1))]${RESET} ${IFACES[$i]}  ${YELLOW}(${STATUS})${RESET}"
    done

    echo ""
    ask "Enter interface name or number" IFACE "${IFACES[0]}"

    # Allow numeric selection
    if [[ "$IFACE" =~ ^[0-9]+$ ]]; then
        IFACE="${IFACES[$((IFACE-1))]}"
    fi

    if [[ -z "$IFACE" ]]; then
        echo -e "${RED}[!] No interface selected. Exiting.${RESET}"
        exit 1
    fi
    echo -e "${GREEN}[✓] Interface: ${IFACE}${RESET}"
}

# ── Step 2 — DHCP or Static ───────────────────────────────────

choose_mode() {
    echo -e "\n${CYAN}── Step 2: Configuration Mode ─────────────────────${RESET}"

    # Detect current mode from the selected interface
    CURRENT_MODE_RAW=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2}' | head -1)
    if nmcli -g IP4.METHOD con show --active 2>/dev/null | grep -qi "auto"; then
        DETECTED_MODE="DHCP"
    elif grep -qr "dhcp4: true" /etc/netplan/ 2>/dev/null; then
        DETECTED_MODE="DHCP"
    elif [[ -z "$CURRENT_MODE_RAW" ]]; then
        DETECTED_MODE="unknown"
    else
        DETECTED_MODE="Static"
    fi

    echo -e "  ${YELLOW}Current mode: ${DETECTED_MODE}${RESET}\n"
    ask "Mode — (1) Static IP  (2) DHCP" MODE_CHOICE "1"

    case "$MODE_CHOICE" in
        2|dhcp|DHCP)
            MODE="dhcp"
            echo -e "${GREEN}[✓] Mode: DHCP${RESET}"
            ;;
        *)
            MODE="static"
            echo -e "${GREEN}[✓] Mode: Static IP${RESET}"
            ;;
    esac
}

# ── Step 3 — Static IP details ────────────────────────────────

collect_static() {
    echo -e "\n${CYAN}── Step 3: IP Address Settings ────────────────────${RESET}"

    # Read current IP, prefix and gateway from the selected interface
    CURRENT_IP=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
    CURRENT_PREFIX=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f2 | head -1)
    CURRENT_GW=$(ip route show default dev "$IFACE" 2>/dev/null | awk '/default/ {print $3}' | head -1)

    # Fallback to any default route if interface-specific not found
    [[ -z "$CURRENT_GW" ]] && CURRENT_GW=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -1)

    echo -e "  ${YELLOW}Current settings on ${IFACE}:${RESET}"
    echo -e "  IP      : ${CURRENT_IP:-none}/${CURRENT_PREFIX:-?}"
    echo -e "  Gateway : ${CURRENT_GW:-none}"
    echo ""

    while true; do
        ask "IP Address" IP_ADDR "${CURRENT_IP}"
        validate_ip "$IP_ADDR" && break
        echo -e "${RED}[!] Invalid IP address. Try again.${RESET}"
    done

    while true; do
        ask "Subnet mask or CIDR prefix" NETMASK "${CURRENT_PREFIX:-24}"
        # Accept CIDR prefix alone (e.g. "24")
        if [[ "$NETMASK" =~ ^[0-9]+$ ]] && (( NETMASK >= 0 && NETMASK <= 32 )); then
            PREFIX="$NETMASK"
            break
        fi
        # Accept dotted notation — convert to prefix length
        if validate_ip "$NETMASK"; then
            IFS='.' read -r -a octs <<< "$NETMASK"
            binary=""
            for o in "${octs[@]}"; do binary+=$(python3 -c "print(bin($o)[2:].zfill(8))"); done
            PREFIX=$(echo "$binary" | tr -cd '1' | wc -c)
            break
        fi
        echo -e "${RED}[!] Invalid subnet mask. Try again.${RESET}"
    done

    while true; do
        ask "Default gateway" GATEWAY "${CURRENT_GW}"
        validate_ip "$GATEWAY" && break
        echo -e "${RED}[!] Invalid gateway IP. Try again.${RESET}"
    done

    echo -e "${GREEN}[✓] IP: ${IP_ADDR}/${PREFIX}  GW: ${GATEWAY}${RESET}"
}

# ── Step 4 — DNS ──────────────────────────────────────────────

collect_dns() {
    echo -e "\n${CYAN}── Step 4: DNS Servers ────────────────────────────${RESET}"

    # Read current DNS from systemd-resolved or /etc/resolv.conf
    mapfile -t CURRENT_DNS < <(
        resolvectl status "$IFACE" 2>/dev/null \
            | awk '/DNS Servers/ {for(i=3;i<=NF;i++) print $i}' \
        || grep -E "^nameserver" /etc/resolv.conf 2>/dev/null \
            | awk '{print $2}'
    )

    CURRENT_DNS1="${CURRENT_DNS[0]}"
    CURRENT_DNS2="${CURRENT_DNS[1]}"

    echo -e "  ${YELLOW}Current DNS on ${IFACE}:${RESET}"
    echo -e "  Primary   : ${CURRENT_DNS1:-none}"
    echo -e "  Secondary : ${CURRENT_DNS2:-none}"
    echo ""

    ask "Primary DNS server"   DNS1 "${CURRENT_DNS1:-8.8.8.8}"
    ask "Secondary DNS server" DNS2 "${CURRENT_DNS2:-8.8.4.4}"
    echo -e "${GREEN}[✓] DNS: ${DNS1}, ${DNS2}${RESET}"
}

# ── Step 5 — Hostname ─────────────────────────────────────────

collect_hostname() {
    echo -e "\n${CYAN}── Step 5: Hostname ───────────────────────────────${RESET}"
    CURRENT_HOST=$(hostname)
    ask "Hostname" NEW_HOSTNAME "$CURRENT_HOST"
    echo -e "${GREEN}[✓] Hostname: ${NEW_HOSTNAME}${RESET}"
}

# ── Step 6 — NTP Servers ─────────────────────────────────────

collect_ntp() {
    echo -e "\n${CYAN}── Step 6: NTP Time Synchronization (systemd-timesyncd) ──${RESET}"

    # Read current NTP settings from timesyncd.conf
    CURRENT_NTP=$(grep -E "^NTP=" /etc/systemd/timesyncd.conf 2>/dev/null | cut -d= -f2)
    CURRENT_FALLBACK=$(grep -E "^FallbackNTP=" /etc/systemd/timesyncd.conf 2>/dev/null | cut -d= -f2)

    echo -e "  ${YELLOW}Current NTP settings:${RESET}"
    echo -e "  NTP         : ${CURRENT_NTP:-none}"
    echo -e "  FallbackNTP : ${CURRENT_FALLBACK:-none}"
    echo -e "  ${YELLOW}Enter one or more servers separated by spaces.${RESET}\n"

    ask "NTP server(s)" NTP_SERVERS "${CURRENT_NTP:-0.pool.ntp.org 1.pool.ntp.org}"
    ask "Fallback NTP server(s)" NTP_FALLBACK "${CURRENT_FALLBACK:-2.pool.ntp.org 3.pool.ntp.org}"

    echo -e "${GREEN}[✓] NTP         : ${NTP_SERVERS}${RESET}"
    echo -e "${GREEN}[✓] NTP Fallback: ${NTP_FALLBACK}${RESET}"
    echo -e "${GREEN}[✓] Timezone    : ${TIMEZONE}  ${YELLOW}(hardcoded)${RESET}"
}

# ── Apply NTP via systemd-timesyncd ──────────────────────────

apply_ntp() {
    local cfg="/etc/systemd/timesyncd.conf"
    echo -e "\n${CYAN}── Applying NTP (systemd-timesyncd) ───────────────${RESET}"

    # Rename original to .old
    if [[ -f "$cfg" ]]; then
        mv "$cfg" "${cfg}.old" 2>/dev/null && \
            echo -e "  ${YELLOW}[i] Renamed existing config: ${cfg}.old${RESET}"
    fi

    # Write config — preserve any existing [Time] section structure
    cat > "$cfg" <<EOF
#  /etc/systemd/timesyncd.conf
#  Managed by network_config.sh — $(date)

[Time]
NTP=${NTP_SERVERS}
FallbackNTP=${NTP_FALLBACK}
#RootDistanceMaxSec=5
#PollIntervalMinSec=32
#PollIntervalMaxSec=2048
EOF

    echo -e "${GREEN}[✓] Wrote: ${cfg}${RESET}"

    # Enable NTP sync via timedatectl first
    timedatectl set-ntp true 2>&1 \
        && echo -e "${GREEN}[✓] NTP sync enabled (timedatectl set-ntp true).${RESET}" \
        || echo -e "${RED}[!] Could not enable NTP via timedatectl.${RESET}"

    # Restart timesyncd to pick up new servers
    systemctl restart systemd-timesyncd 2>&1 \
        && echo -e "${GREEN}[✓] systemd-timesyncd restarted.${RESET}" \
        || echo -e "${RED}[!] Failed to restart systemd-timesyncd.${RESET}"

    # Apply hardcoded timezone
    timedatectl set-timezone "$TIMEZONE" 2>&1 \
        && echo -e "${GREEN}[✓] Timezone set to: ${TIMEZONE}${RESET}" \
        || echo -e "${RED}[!] Failed to set timezone '${TIMEZONE}'. Check: timedatectl list-timezones${RESET}"

    # Show sync status
    echo ""
    echo -e "${CYAN}── NTP Sync Status ────────────────────────────────${RESET}"
    timedatectl status 2>/dev/null | grep -E "Local time|UTC|NTP|synchronized|service" \
        | sed "s/^/  /"
}

# ── NTP Preview ───────────────────────────────────────────────

show_ntp_preview() {
    echo ""
    echo "  /etc/systemd/timesyncd.conf preview:"
    echo "    [Time]"
    echo "    NTP=${NTP_SERVERS}"
    echo "    FallbackNTP=${NTP_FALLBACK}"
    echo ""
    echo "  Timezone : ${TIMEZONE}  (hardcoded)"
    echo "  Command  : timedatectl set-ntp true"
}

# ── Step 7 — Review & Confirm ─────────────────────────────────

review_and_confirm() {
    echo -e "\n${CYAN}── Summary ────────────────────────────────────────${RESET}"
    echo -e "  Interface  : ${BOLD}${IFACE}${RESET}"
    echo -e "  Mode       : ${BOLD}${MODE}${RESET}"
    if [[ "$MODE" == "static" ]]; then
        echo -e "  IP Address : ${BOLD}${IP_ADDR}/${PREFIX}${RESET}"
        echo -e "  Gateway    : ${BOLD}${GATEWAY}${RESET}"
        echo -e "  DNS        : ${BOLD}${DNS1}, ${DNS2}${RESET}"
    fi
    echo -e "  Hostname   : ${BOLD}${NEW_HOSTNAME}${RESET}"
    echo -e "  NTP        : ${BOLD}${NTP_SERVERS}${RESET}"
    echo -e "  NTP Fbk    : ${BOLD}${NTP_FALLBACK}${RESET}"
    echo -e "  Timezone   : ${BOLD}${TIMEZONE}${RESET}  ${YELLOW}(hardcoded)${RESET}"
    echo ""
    ask "Apply this configuration? (yes/no/preview)" CONFIRM "yes"
}

# ── Apply — Netplan (Ubuntu/Debian) ───────────────────────────

apply_netplan() {
    local cfg="/etc/netplan/99-network-config.yaml"
    echo -e "\n${CYAN}── Applying via Netplan ───────────────────────────${RESET}"
    # renderer: networkd is correct for Ubuntu Server (18.04+)
    # For Ubuntu Desktop use renderer: NetworkManager instead

    # Rename any existing netplan YAML files to .old
    for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
        [[ -f "$f" ]] && mv "$f" "${f}.old" 2>/dev/null && \
            echo -e "  ${YELLOW}[i] Renamed: ${f} → ${f}.old${RESET}"
    done

    if [[ "$MODE" == "dhcp" ]]; then
        cat > "$cfg" <<EOF
network:
  version: 2
  renderer: networkd   # Ubuntu Server
  ethernets:
    ${IFACE}:
      dhcp4: true
EOF
    else
        cat > "$cfg" <<EOF
network:
  version: 2
  renderer: networkd   # Ubuntu Server
  ethernets:
    ${IFACE}:
      dhcp4: false
      addresses:
        - ${IP_ADDR}/${PREFIX}
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${DNS1}, ${DNS2}]
EOF
    fi

    chmod 600 "$cfg"
    echo -e "${GREEN}[✓] Wrote: ${cfg}${RESET}"

    netplan apply 2>&1 && echo -e "${GREEN}[✓] Netplan applied successfully.${RESET}" \
        || echo -e "${RED}[!] netplan apply failed. Check the config above.${RESET}"
}

# ── Apply — nmcli (NetworkManager) ───────────────────────────

apply_nmcli() {
    echo -e "\n${CYAN}── Applying via nmcli ─────────────────────────────${RESET}"
    CON_NAME="static-${IFACE}"

    # Remove existing connection with same name if present
    nmcli con delete "$CON_NAME" 2>/dev/null

    if [[ "$MODE" == "dhcp" ]]; then
        nmcli con add type ethernet ifname "$IFACE" con-name "$CON_NAME" \
            ipv4.method auto
    else
        nmcli con add type ethernet ifname "$IFACE" con-name "$CON_NAME" \
            ipv4.addresses "${IP_ADDR}/${PREFIX}" \
            ipv4.gateway "$GATEWAY" \
            ipv4.dns "${DNS1} ${DNS2}" \
            ipv4.method manual
    fi

    nmcli con up "$CON_NAME" 2>&1 && echo -e "${GREEN}[✓] Connection up: ${CON_NAME}${RESET}" \
        || echo -e "${RED}[!] Failed to bring up connection.${RESET}"
}

# ── Preview only ──────────────────────────────────────────────

show_preview() {
    echo -e "\n${YELLOW}── Preview (no changes applied) ───────────────────${RESET}"
    echo ""
    if [[ "$MODE" == "dhcp" ]]; then
        echo "Netplan YAML preview:"
        echo "  network:"
        echo "    version: 2"
        echo "    ethernets:"
        echo "      ${IFACE}:"
        echo "        dhcp4: true"
    else
        echo "Netplan YAML preview:"
        echo "  network:"
        echo "    version: 2"
        echo "    ethernets:"
        echo "      ${IFACE}:"
        echo "        dhcp4: false"
        echo "        addresses: [${IP_ADDR}/${PREFIX}]"
        echo "        routes:"
        echo "          - to: default"
        echo "            via: ${GATEWAY}"
        echo "        nameservers:"
        echo "          addresses: [${DNS1}, ${DNS2}]"
    fi
    echo ""
    echo "Hostname would be set to: ${NEW_HOSTNAME}"
    echo ""
    show_ntp_preview
    echo ""
    echo -e "${YELLOW}Run as root to apply.${RESET}"
}

# ── Apply hostname ────────────────────────────────────────────

apply_hostname() {
    if [[ "$NEW_HOSTNAME" != "$(hostname)" ]]; then
        hostnamectl set-hostname "$NEW_HOSTNAME" 2>/dev/null \
            && echo -e "${GREEN}[✓] Hostname set to: ${NEW_HOSTNAME}${RESET}" \
            || echo -e "${RED}[!] Could not set hostname (hostnamectl missing?).${RESET}"
    fi
}

# ── Detect backend ────────────────────────────────────────────

detect_backend() {
    if command -v netplan &>/dev/null; then
        BACKEND="netplan"
    elif command -v nmcli &>/dev/null; then
        BACKEND="nmcli"
    else
        BACKEND="unknown"
    fi
}

# ── Main ──────────────────────────────────────────────────────

main() {
    print_banner
    choose_interface
    choose_mode
    [[ "$MODE" == "static" ]] && collect_static
    collect_dns
    collect_hostname
    collect_ntp
    review_and_confirm

    case "${CONFIRM,,}" in
        preview|p)
            show_preview
            ;;
        yes|y)
            require_root
            detect_backend
            case "$BACKEND" in
                netplan) apply_netplan ;;
                nmcli)   apply_nmcli   ;;
                *)
                    echo -e "${RED}[!] No supported network manager found (netplan/nmcli).${RESET}"
                    exit 1
                    ;;
            esac
            apply_hostname
            apply_ntp
            echo -e "\n${GREEN}${BOLD}[✓] Network configuration complete!${RESET}"
            ;;
        *)
            echo -e "${YELLOW}[~] Aborted. No changes made.${RESET}"
            ;;
    esac
}

main
