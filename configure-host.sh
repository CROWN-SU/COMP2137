#!/bin/bash
#
# configure-host.sh
#
# Basic host configuration management script.
# Confirms/applies a hostname, a LAN interface IP address, and/or a
# /etc/hosts entry, based on options given on the command line.
#
# By default this produces NO output unless an error occurs.
# Pass -verbose to also report what was checked/changed.
#
# Usage:
#   configure-host.sh [-verbose] [-name desiredName] [-ip desiredIPAddress] \
#                      [-hostentry desiredName desiredIPAddress]
#
# NOTE: This assumes the LAN interface is named "eth1" (the mgmt
# interface used for scp/ssh is assumed to be eth0). Adjust
# LAN_INTERFACE below if your environment names interfaces differently.

# Ignore TERM, HUP, and INT so the script cannot be interrupted mid-change.
trap '' SIGTERM SIGHUP SIGINT

# ---------------------------------------------------------------------------
# Config / globals
# ---------------------------------------------------------------------------
LAN_INTERFACE="eth1"
HOSTS_FILE="/etc/hosts"
HOSTNAME_FILE="/etc/hostname"
NETPLAN_FILE=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n1)

VERBOSE=0
EXIT_CODE=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
vecho() {
    [ "$VERBOSE" -eq 1 ] && echo "$@"
}

err() {
    echo "ERROR: $*" >&2
    EXIT_CODE=1
}

log_change() {
    # Send a change description to the system log
    logger -t configure-host.sh "$*"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "This script must be run as root to apply system changes."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# -name desiredName
# ---------------------------------------------------------------------------
set_name() {
    local desired="$1"
    local current
    current=$(hostname)
    local changed=0

    # Running hostname
    if [ "$current" == "$desired" ]; then
        vecho "Hostname already set to '$desired'."
    else
        if hostnamectl set-hostname "$desired" 2>/dev/null; then
            vecho "Changed running hostname from '$current' to '$desired'."
            changed=1
        else
            err "Failed to set running hostname to '$desired'."
        fi
    fi

    # /etc/hostname
    if [ -f "$HOSTNAME_FILE" ] && grep -qx "$desired" "$HOSTNAME_FILE"; then
        vecho "$HOSTNAME_FILE already contains '$desired'."
    else
        if echo "$desired" > "$HOSTNAME_FILE"; then
            vecho "Updated $HOSTNAME_FILE to '$desired'."
            changed=1
        else
            err "Failed to update $HOSTNAME_FILE."
        fi
    fi

    # Update any /etc/hosts line referencing the old hostname (e.g. the
    # line that maps this machine's own IP to its own name).
    if [ "$current" != "$desired" ] && grep -qw "$current" "$HOSTS_FILE" 2>/dev/null; then
        if sed -i "s/\b$current\b/$desired/g" "$HOSTS_FILE"; then
            vecho "Updated $HOSTS_FILE: replaced '$current' with '$desired'."
            changed=1
        else
            err "Failed to update $HOSTS_FILE with new hostname."
        fi
    fi

    if [ "$changed" -eq 1 ]; then
        log_change "hostname configured: '$current' -> '$desired'"
    fi
}

# ---------------------------------------------------------------------------
# -ip desiredIPAddress
# ---------------------------------------------------------------------------
set_ip() {
    local desired="$1"
    local current
    current=$(ip -4 -o addr show dev "$LAN_INTERFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    local changed=0

    if [ -z "$current" ]; then
        err "Could not determine current IP address on $LAN_INTERFACE."
        return
    fi

    if [ "$current" == "$desired" ]; then
        vecho "$LAN_INTERFACE IP already set to $desired."
    else
        # Update netplan file (persistent config)
        if [ -n "$NETPLAN_FILE" ] && [ -f "$NETPLAN_FILE" ]; then
            if grep -q "$current" "$NETPLAN_FILE"; then
                if sed -i "s#$current#$desired#g" "$NETPLAN_FILE"; then
                    vecho "Updated $NETPLAN_FILE: $current -> $desired."
                else
                    err "Failed to update netplan file $NETPLAN_FILE."
                fi
            else
                err "Current IP $current not found in $NETPLAN_FILE; not modified."
            fi

            if netplan apply 2>/dev/null; then
                vecho "Applied netplan configuration (new IP: $desired)."
                changed=1
            else
                err "netplan apply failed."
            fi
        else
            err "No netplan file found; cannot persist IP change."
        fi

        # Update /etc/hosts entry(ies) that reference the old IP
        if grep -qw "$current" "$HOSTS_FILE" 2>/dev/null; then
            if sed -i "s/\b$current\b/$desired/g" "$HOSTS_FILE"; then
                vecho "Updated $HOSTS_FILE: $current -> $desired."
                changed=1
            else
                err "Failed to update $HOSTS_FILE with new IP."
            fi
        fi
    fi

    if [ "$changed" -eq 1 ]; then
        log_change "IP address on $LAN_INTERFACE changed: $current -> $desired"
    fi
}

# ---------------------------------------------------------------------------
# -hostentry desiredName desiredIPAddress
# ---------------------------------------------------------------------------
set_hostentry() {
    local desired_name="$1"
    local desired_ip="$2"
    local changed=0

    if [ ! -f "$HOSTS_FILE" ]; then
        err "$HOSTS_FILE not found."
        return
    fi

    # Exact "ip   name" pair already present?
    if grep -qE "^${desired_ip}[[:space:]]+${desired_name}([[:space:]]|$)" "$HOSTS_FILE"; then
        vecho "$HOSTS_FILE already has entry: $desired_ip $desired_name"
        return
    fi

    # If the name exists with a different IP, update that line's IP.
    if grep -qE "^\S+[[:space:]]+${desired_name}([[:space:]]|$)" "$HOSTS_FILE"; then
        if sed -i -E "s/^\S+([[:space:]]+${desired_name}([[:space:]]|$))/${desired_ip}\1/" "$HOSTS_FILE"; then
            vecho "Updated $HOSTS_FILE entry for '$desired_name' to IP $desired_ip."
            changed=1
        else
            err "Failed to update existing hosts entry for $desired_name."
        fi
    else
        # No existing entry for that name; append a new line.
        if echo -e "${desired_ip}\t${desired_name}" >> "$HOSTS_FILE"; then
            vecho "Added $HOSTS_FILE entry: $desired_ip $desired_name"
            changed=1
        else
            err "Failed to add hosts entry for $desired_name."
        fi
    fi

    if [ "$changed" -eq 1 ]; then
        log_change "hosts file entry set: $desired_ip $desired_name"
    fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
if [ $# -eq 0 ]; then
    err "No arguments given. Usage: $0 [-verbose] [-name NAME] [-ip IP] [-hostentry NAME IP]"
    exit 1
fi

# First pass: pick up -verbose wherever it appears so later actions honor it.
for arg in "$@"; do
    [ "$arg" == "-verbose" ] && VERBOSE=1
done

require_root

while [ $# -gt 0 ]; do
    case "$1" in
        -verbose)
            shift
            ;;
        -name)
            if [ -z "$2" ]; then
                err "-name requires an argument."
                shift
            else
                set_name "$2"
                shift 2
            fi
            ;;
        -ip)
            if [ -z "$2" ]; then
                err "-ip requires an argument."
                shift
            else
                set_ip "$2"
                shift 2
            fi
            ;;
        -hostentry)
            if [ -z "$2" ] || [ -z "$3" ]; then
                err "-hostentry requires two arguments: NAME IP"
                shift $(( $# > 1 ? 2 : 1 ))
            else
                set_hostentry "$2" "$3"
                shift 3
            fi
            ;;
        *)
            err "Unknown argument: $1"
            shift
            ;;
    esac
done

exit $EXIT_CODE
