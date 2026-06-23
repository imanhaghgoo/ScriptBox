#!/bin/bash

#==============================================================================
# SMC RSyslog Collector Setup Script
# Manages rsyslog configuration for multiple network vendors
# Feeds into Splunk Universal Forwarder -> HQ Splunk Indexer
#==============================================================================

set -euo pipefail

#==============================================================================
# Configuration
#==============================================================================

RSYSLOG_CONF_DIR="/etc/rsyslog.d"
MODULES_FILE="${RSYSLOG_CONF_DIR}/00-SMC-CollectorModules.conf"
TEMPLATES_FILE="${RSYSLOG_CONF_DIR}/01-SMC-CollectorTemplates.conf"
VENDOR_START_NUMBER=101
LOG_BASE_DIR="/var/log/remote"
LOG_RETENTION_DAYS=30
LOG_FILE="/var/log/rsyslog-collector-setup.log"
VERBOSE=false

# Systemd timer for daily log cleanup
SYSTEMD_SERVICE_FILE="/etc/systemd/system/smc-log-cleanup.service"
SYSTEMD_TIMER_FILE="/etc/systemd/system/smc-log-cleanup.timer"

# Backup destination: ~/rsyslog-backups/rsyslog-backup-<timestamp>/
BACKUP_DIR="${HOME}/rsyslog-backups/rsyslog-backup-$(date +%Y-%m-%d_%H-%M)"

# Vendor definitions: "name:port:protocol:template"
# Templates available: StandardFormat | MikrotikFormat
DEFAULT_VENDORS=(
    "cisco:30514:udp:StandardFormat"
    "mikrotik-antenna:31514:udp:MikrotikFormat"
    "mikrotik-router:32514:udp:MikrotikFormat"
    "unifi:33514:udp:StandardFormat"
    "fortigate:34514:tcp:StandardFormat"
    "hpe:35514:udp:StandardFormat"
    "dahua-nvr:36514:udp:StandardFormat"
    "linux-server:37514:tcp:StandardFormat"
)

#==============================================================================
# Color codes
#==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

#==============================================================================
# Logging
# - Always prints to terminal with colors
# - Writes to log file only when --verbose flag is passed
#==============================================================================

log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color=""

    case "$level" in
        INFO)    color="${BLUE}"   ;;
        SUCCESS) color="${GREEN}"  ;;
        WARNING) color="${YELLOW}" ;;
        ERROR)   color="${RED}"    ;;
    esac

    # Always print to terminal
    echo -e "${color}[${level}]${NC} ${message}"

    # Write to log file only if --verbose is set
    if [[ "$VERBOSE" == true ]]; then
        echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE"
    fi
}

#==============================================================================
# Validation
#==============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_message "ERROR" "This script must be run as root"
        exit 1
    fi
}

check_rsyslog() {
    if ! command -v rsyslogd &> /dev/null; then
        log_message "ERROR" "rsyslog is not installed. Install it with: apt install rsyslog"
        exit 1
    fi
}

validate_rsyslog_config() {
    log_message "INFO" "Validating rsyslog configuration..."
    if rsyslogd -N1 &> /dev/null; then
        log_message "SUCCESS" "Configuration is valid"
        return 0
    else
        log_message "ERROR" "Configuration validation failed:"
        rsyslogd -N1
        return 1
    fi
}

validate_vendor_def() {
    local vendor_def="$1"
    local name port protocol template

    IFS=':' read -r name port protocol template <<< "$vendor_def"

    # Validate name
    if [[ -z "$name" ]]; then
        log_message "ERROR" "Vendor name cannot be empty in: $vendor_def"
        return 1
    fi

    # Validate port range
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1024 || port > 65535 )); then
        log_message "ERROR" "Invalid port '$port' for vendor '$name'. Must be 1024-65535"
        return 1
    fi

    # Validate protocol
    if [[ "$protocol" != "udp" && "$protocol" != "tcp" ]]; then
        log_message "ERROR" "Invalid protocol '$protocol' for vendor '$name'. Must be udp or tcp"
        return 1
    fi

    # Validate template
    if [[ "$template" != "StandardFormat" && "$template" != "MikrotikFormat" ]]; then
        log_message "ERROR" "Invalid template '$template' for vendor '$name'. Must be StandardFormat or MikrotikFormat"
        return 1
    fi

    return 0
}

#==============================================================================
# Port conflict detection
#==============================================================================

get_used_ports() {
    # Returns an array of ports already defined in existing rsyslog configs
    local -a used_ports=()

    while IFS= read -r line; do
        if [[ $line =~ port=\"([0-9]+)\" ]]; then
            used_ports+=("${BASH_REMATCH[1]}")
        fi
    done < <(grep -h 'port=' "${RSYSLOG_CONF_DIR}"/*.conf 2>/dev/null || true)

    echo "${used_ports[@]:-}"
}

is_port_in_use() {
    local port="$1"
    shift
    local used_ports=("$@")

    for used in "${used_ports[@]:-}"; do
        [[ "$port" == "$used" ]] && return 0
    done
    return 1
}

#==============================================================================
# Next available config number
# Scans existing vendor configs (101+) and returns the next free number
#==============================================================================

get_next_number() {
    local max=$((VENDOR_START_NUMBER - 1))
    local num

    for conf in "${RSYSLOG_CONF_DIR}"/[0-9][0-9][0-9]-*.conf; do
        [[ -f "$conf" ]] || continue
        num=$(basename "$conf" | grep -oP '^\d+')
        if (( num > max )); then
            max=$num
        fi
    done

    echo $((max + 1))
}

#==============================================================================
# Backup
# Moves all existing SMC configs to ~/rsyslog-backups/rsyslog-backup-<timestamp>/
#==============================================================================

backup_existing_configs() {
    local smc_files=()

    # Collect shared SMC files
    [[ -f "$MODULES_FILE" ]]   && smc_files+=("$MODULES_FILE")
    [[ -f "$TEMPLATES_FILE" ]] && smc_files+=("$TEMPLATES_FILE")

    # Collect vendor configs (101+)
    for conf in "${RSYSLOG_CONF_DIR}"/[0-9][0-9][0-9]-*.conf; do
        [[ -f "$conf" ]] && smc_files+=("$conf")
    done

    if [[ ${#smc_files[@]} -eq 0 ]]; then
        log_message "INFO" "No existing SMC configs found, skipping backup"
        return 0
    fi

    log_message "INFO" "Backing up ${#smc_files[@]} existing config(s) to: $BACKUP_DIR"

    mkdir -p "$BACKUP_DIR"

    for f in "${smc_files[@]}"; do
        mv "$f" "$BACKUP_DIR/"
        log_message "INFO" "  Backed up: $(basename "$f")"
    done

    log_message "SUCCESS" "Backup complete: $BACKUP_DIR"
}

#==============================================================================
# Shared configuration files
#==============================================================================

create_modules_file() {
    log_message "INFO" "Creating shared modules file..."

    cat > "$MODULES_FILE" << 'EOF'
# =============================================================================
# 00-SMC-CollectorModules.conf
# SMC RSyslog Collector - Shared Input Modules
# Load UDP and TCP receiver modules once, shared by all vendor rulesets
# =============================================================================

module(load="imudp")
module(load="imtcp")
EOF

    log_message "SUCCESS" "Modules file created: $MODULES_FILE"
}

create_templates_file() {
    log_message "INFO" "Creating shared templates file..."

    cat > "$TEMPLATES_FILE" << 'EOF'
# =============================================================================
# 01-SMC-CollectorTemplates.conf
# SMC RSyslog Collector - Shared Log Format Templates
# =============================================================================

# -----------------------------------------------------------------------------
# MikrotikFormat
# Handles MikroTik's non-standard syslog output where the priority field
# and timestamp are mangled. Reconstructs a clean line from raw message parts.
# -----------------------------------------------------------------------------
template(name="MikrotikFormat" type="list") {
  property(name="timegenerated" dateformat="rfc3339")
  constant(value=" ")
  constant(value="<")
  property(name="pri")
  constant(value=">")
  property(name="rawmsg-after-pri" droplastlf="on")
  constant(value="\n")
}

# -----------------------------------------------------------------------------
# StandardFormat
# Generic syslog format suitable for Cisco, FortiGate, UniFi, HPE,
# Dahua NVR, Linux servers, and most RFC-compliant syslog senders.
# -----------------------------------------------------------------------------
template(name="StandardFormat" type="string"
  string="%timegenerated% %fromhost-ip% %syslogtag%%msg:::drop-last-lf%\n")

# -----------------------------------------------------------------------------
# DynaFile path template
# Resolves to: /var/log/remote/<vendor>/<ip>/<year-month>/<date>.log
# Used by all vendor omfile actions via the dynaFile parameter
# -----------------------------------------------------------------------------
template(name="VendorDynaPath" type="list") {
  constant(value="/var/log/remote/")
  property(name="$!vendor")
  constant(value="/")
  property(name="fromhost-ip")
  constant(value="/")
  property(name="timereported" dateformat="year")
  constant(value="-")
  property(name="timereported" dateformat="month")
  constant(value="/")
  property(name="timereported" dateformat="year")
  constant(value="-")
  property(name="timereported" dateformat="month")
  constant(value="-")
  property(name="timereported" dateformat="day")
  constant(value=".log")
}
EOF

    log_message "SUCCESS" "Templates file created: $TEMPLATES_FILE"
}

#==============================================================================
# Vendor config generation
#==============================================================================

create_vendor_config() {
    local name="$1"
    local port="$2"
    local protocol="$3"
    local template="$4"
    local number="$5"

    local config_file="${RSYSLOG_CONF_DIR}/${number}-${name}.conf"
    local log_dir="${LOG_BASE_DIR}/${name}"

    log_message "INFO" "Creating config for $name (${protocol^^}:$port) using $template..."

    cat > "$config_file" << EOF
# =============================================================================
# ${number}-${name}.conf
# Vendor : ${name}
# Input  : ${protocol^^} port ${port}
# Format : ${template}
# Logs   : ${log_dir}/<ip>/<year-month>/<date>.log
# =============================================================================

input(
    type="im${protocol}"
    port="${port}"
    ruleset="${name}-ruleset"
)

ruleset(name="${name}-ruleset") {

    set \$!vendor = "${name}";

    action(
        type="omfile"
        dynaFile="VendorDynaPath"
        template="${template}"
        dirCreateMode="0755"
        fileCreateMode="0644"
        dirOwner="syslog"
        dirGroup="adm"
    )

    stop
}
EOF

    log_message "SUCCESS" "Config created: $config_file"

    # Create base vendor log directory
    # Monthly and IP subdirectories are created dynamically by rsyslog at runtime
    mkdir -p "$log_dir"
    chown syslog:adm "$log_dir"
    chmod 755 "$log_dir"
    log_message "SUCCESS" "Log directory created: $log_dir"
}

#==============================================================================
# Systemd daily cleanup timer
# Replaces logrotate — deletes .log files older than LOG_RETENTION_DAYS
# and removes empty directories left behind
# Runs daily at 02:00, safe to run while rsyslog is active
#==============================================================================

create_cleanup_timer() {
    log_message "INFO" "Creating systemd log cleanup timer (${LOG_RETENTION_DAYS} day retention)..."

    # Service unit — defines what to run
    cat > "$SYSTEMD_SERVICE_FILE" << EOF
[Unit]
Description=SMC Rsyslog Collector - Daily Log Cleanup
Documentation=Deletes log files older than ${LOG_RETENTION_DAYS} days from ${LOG_BASE_DIR}

[Service]
Type=oneshot
# Delete .log files older than retention period
ExecStart=/usr/bin/find ${LOG_BASE_DIR} -name "*.log" -mtime +${LOG_RETENTION_DAYS} -delete
# Remove empty IP and month directories left behind after file deletion
ExecStart=/usr/bin/find ${LOG_BASE_DIR} -mindepth 2 -maxdepth 3 -type d -empty -delete
EOF

    # Timer unit — defines when to run
    cat > "$SYSTEMD_TIMER_FILE" << EOF
[Unit]
Description=SMC Rsyslog Collector - Daily Log Cleanup Timer

[Timer]
# Run daily at 02:00
OnCalendar=*-*-* 02:00:00
# Run immediately on next boot if last run was missed
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # Enable and start the timer
    systemctl daemon-reload
    systemctl enable --now smc-log-cleanup.timer
    log_message "SUCCESS" "Cleanup timer created and enabled (runs daily at 02:00)"
    log_message "INFO"    "Next run: $(systemctl status smc-log-cleanup.timer | grep 'Trigger:' | xargs)"
}

#==============================================================================
# Install
#==============================================================================

cmd_install() {
    log_message "INFO" "Starting SMC rsyslog collector installation..."

    # Step 1 — backup any existing SMC configs before touching anything
    backup_existing_configs

    # Step 2 — validate all vendor definitions before writing any files
    log_message "INFO" "Validating vendor definitions..."
    for vendor in "${DEFAULT_VENDORS[@]}"; do
        if ! validate_vendor_def "$vendor"; then
            log_message "ERROR" "Fix vendor definition errors before continuing"
            exit 1
        fi
    done
    log_message "SUCCESS" "All vendor definitions are valid"

    # Step 3 — shared files
    create_modules_file
    create_templates_file

    # Step 4 — vendor configs
    local number=$VENDOR_START_NUMBER
    local -a used_ports=()
    IFS=' ' read -r -a used_ports <<< "$(get_used_ports)"

    for vendor in "${DEFAULT_VENDORS[@]}"; do
        IFS=':' read -r name port protocol template <<< "$vendor"

        if is_port_in_use "$port" "${used_ports[@]:-}"; then
            log_message "WARNING" "Port $port already in use, skipping $name"
            continue
        fi

        create_vendor_config "$name" "$port" "$protocol" "$template" "$number"
        used_ports+=("$port")
        number=$((number + 1))
    done

    # Step 5 — daily cleanup timer
    create_cleanup_timer

    # Step 6 — validate and restart
    if validate_rsyslog_config; then
        systemctl restart rsyslog
        log_message "SUCCESS" "rsyslog restarted successfully"
        log_message "SUCCESS" "SMC collector installation complete"
    else
        log_message "ERROR" "Configuration validation failed — rsyslog NOT restarted"
        exit 1
    fi
}

#==============================================================================
# Remove all
# Removes all SMC configs, log directories, and systemd cleanup timer
#==============================================================================

cmd_remove_all() {
    log_message "WARNING" "This will remove ALL SMC rsyslog configs, log files, and directories"
    read -rp "Are you sure? Type YES to confirm: " confirm

    if [[ "$confirm" != "YES" ]]; then
        log_message "INFO" "Aborted"
        exit 0
    fi

    # Remove shared config files
    for f in "$MODULES_FILE" "$TEMPLATES_FILE"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            log_message "SUCCESS" "Removed: $f"
        fi
    done

    # Remove vendor configs (101+)
    local removed=0
    for conf in "${RSYSLOG_CONF_DIR}"/[0-9][0-9][0-9]-*.conf; do
        if [[ -f "$conf" ]]; then
            rm -f "$conf"
            log_message "SUCCESS" "Removed: $conf"
            removed=$((removed + 1))
        fi
    done
    [[ $removed -eq 0 ]] && log_message "INFO" "No vendor configs found to remove"

    # Remove log directory
    if [[ -d "$LOG_BASE_DIR" ]]; then
        rm -rf "$LOG_BASE_DIR"
        log_message "SUCCESS" "Removed log directory: $LOG_BASE_DIR"
    else
        log_message "INFO" "Log directory not found, skipping: $LOG_BASE_DIR"
    fi

    # Remove systemd cleanup timer and service
    if systemctl is-enabled smc-log-cleanup.timer &>/dev/null; then
        systemctl disable --now smc-log-cleanup.timer
        log_message "SUCCESS" "Disabled systemd timer: smc-log-cleanup.timer"
    fi
    for unit in "$SYSTEMD_SERVICE_FILE" "$SYSTEMD_TIMER_FILE"; do
        if [[ -f "$unit" ]]; then
            rm -f "$unit"
            log_message "SUCCESS" "Removed: $unit"
        fi
    done
    systemctl daemon-reload

    # Validate and restart
    if validate_rsyslog_config; then
        systemctl restart rsyslog
        log_message "SUCCESS" "rsyslog restarted"
        log_message "SUCCESS" "SMC collector fully removed"
    fi
}

#==============================================================================
# Remove single vendor
# Removes one vendor's config file and its entire log directory
# Usage: remove <vendor-name>  e.g. remove cisco / remove mikrotik-antenna
#==============================================================================

cmd_remove() {
    local name="$1"

    if [[ -z "$name" ]]; then
        log_message "ERROR" "Usage: $0 remove <vendor-name>"
        log_message "INFO"  "Run '$0 list' to see configured vendors"
        exit 1
    fi

    local found_config=""

    # Find the vendor config file by name (number prefix is unknown, search by name)
    for conf in "${RSYSLOG_CONF_DIR}"/[0-9][0-9][0-9]-"${name}".conf; do
        if [[ -f "$conf" ]]; then
            found_config="$conf"
            break
        fi
    done

    # Remove config file
    if [[ -n "$found_config" ]]; then
        rm -f "$found_config"
        log_message "SUCCESS" "Removed config: $found_config"
    else
        log_message "WARNING" "No config file found for vendor: $name"
    fi

    # Remove vendor log directory and all its contents
    local log_dir="${LOG_BASE_DIR}/${name}"
    if [[ -d "$log_dir" ]]; then
        rm -rf "$log_dir"
        log_message "SUCCESS" "Removed log directory: $log_dir"
    else
        log_message "WARNING" "No log directory found: $log_dir"
    fi

    # Abort if neither config nor logs were found
    if [[ -z "$found_config" && ! -d "$log_dir" ]]; then
        log_message "ERROR" "Vendor '$name' not found — nothing removed"
        log_message "INFO"  "Run '$0 list' to see configured vendors"
        exit 1
    fi

    # Validate and restart
    if validate_rsyslog_config; then
        systemctl restart rsyslog
        log_message "SUCCESS" "rsyslog restarted"
        log_message "SUCCESS" "Vendor '$name' removed successfully"
    fi
}

#==============================================================================
# List vendors
#==============================================================================

cmd_list() {
    log_message "INFO" "Configured SMC vendors:"
    echo ""

    local found=0
    local conf_file filename number name port protocol template

    for conf_file in "${RSYSLOG_CONF_DIR}"/[0-9][0-9][0-9]-*.conf; do
        [[ -f "$conf_file" ]] || continue

        filename=$(basename "$conf_file")

        if [[ $filename =~ ^([0-9]+)-(.+)\.conf$ ]]; then
            number="${BASH_REMATCH[1]}"
            name="${BASH_REMATCH[2]}"

            port=$(grep -oP 'port="\K[0-9]+' "$conf_file" | head -1)
            protocol=$(grep -oP 'type="im\K(udp|tcp)' "$conf_file" | head -1 | tr '[:lower:]' '[:upper:]')
            template=$(grep -oP 'template="\K[^"]+' "$conf_file" | grep -v 'VendorDynaPath' | head -1)

            printf "  ${GREEN}[%s]${NC}  %-20s  %s:%-6s  %s\n" \
                "$number" "$name" "$protocol" "$port" "$template"
            found=$((found + 1))
        fi
    done

    if [[ $found -eq 0 ]]; then
        echo -e "  ${YELLOW}No vendor configs found${NC}"
    fi

    echo ""
}

#==============================================================================
# Usage
#==============================================================================

show_usage() {
    cat << EOF

SMC RSyslog Collector Setup

Usage: $0 [command] [--verbose]

Commands:
  install              Install all vendors (default if no command given)
  remove <name>        Remove a specific vendor config and its logs
  remove-all           Remove all configs, logs, and logrotate entries
  list                 List all configured vendors
  validate             Validate rsyslog configuration

Options:
  --verbose            Also write all output to: $LOG_FILE

Examples:
  $0                          # runs install by default
  $0 install
  $0 install --verbose
  $0 remove cisco
  $0 remove mikrotik-antenna
  $0 remove-all
  $0 list
  $0 validate

EOF
}

#==============================================================================
# Main
#==============================================================================

main() {
    # Parse --verbose flag from any position in arguments
    for arg in "$@"; do
        if [[ "$arg" == "--verbose" ]]; then
            VERBOSE=true
            break
        fi
    done

    # Initialize log file if verbose
    if [[ "$VERBOSE" == true ]]; then
        mkdir -p "$(dirname "$LOG_FILE")"
        echo "========================================" >> "$LOG_FILE"
        echo "SMC Collector started: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
        echo "========================================" >> "$LOG_FILE"
        log_message "INFO" "Verbose logging enabled: $LOG_FILE"
    fi

    # Default command is install if no args given
    local command="${1:-install}"

    # Strip --verbose from positional args
    case "$command" in
        --verbose) command="install" ;;
    esac

    check_root
    check_rsyslog

    case "$command" in
        install)
            cmd_install
            ;;
        remove)
            cmd_remove "${2:-}"
            ;;
        remove-all)
            cmd_remove_all
            ;;
        list)
            cmd_list
            ;;
        validate)
            validate_rsyslog_config
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            log_message "ERROR" "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
