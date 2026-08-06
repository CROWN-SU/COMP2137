#!/bin/bash
#
# assignment2.sh
#
# Idempotently configures a target Ubuntu server to match the required
# COMP2137 Assignment 2 configuration:
#   - static 192.168.16.21/24 on the interface facing the 192.168.16 network
#     (the private mgmt interface is left untouched)
#   - /etc/hosts entry for "server1" -> 192.168.16.21 (removing any stale entry)
#   - apache2 and squid installed, default config, enabled/running
#   - a defined list of user accounts, each with:
#       * /home/<user> home directory, bash shell
#       * rsa and ed25519 keypairs
#       * both of their own public keys in authorized_keys
#   - dennis additionally: sudo group membership + one extra authorized key
#
# Safe to re-run. Reports what it checks, what it changes, and any errors.

set -u

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
COLOR_RESET="\033[0m"
COLOR_SECTION="\033[1;36m"
COLOR_OK="\033[1;32m"
COLOR_CHANGE="\033[1;33m"
COLOR_ERR="\033[1;31m"

ERROR_COUNT=0

section() {
    echo -e "\n${COLOR_SECTION}==> $1${COLOR_RESET}"
}

ok() {
    echo -e "  ${COLOR_OK}[OK]${COLOR_RESET}      $1"
}

changed() {
    echo -e "  ${COLOR_CHANGE}[CHANGED]${COLOR_RESET} $1"
}

fail() {
    echo -e "  ${COLOR_ERR}[ERROR]${COLOR_RESET}   $1" >&2
    ERROR_COUNT=$((ERROR_COUNT + 1))
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${COLOR_ERR}This script must be run as root (use sudo).${COLOR_RESET}" >&2
        exit 1
    fi
}

# ----------------------------------------------------------------------------
# 1. Network configuration
# ----------------------------------------------------------------------------
configure_network() {
    section "Network configuration (192.168.16.21/24)"

    local target_ip="192.168.16.21"
    local target_cidr="192.168.16.21/24"

    local target_iface
    target_iface=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')

    if [ -z "$target_iface" ]; then
        target_iface=$(ip -o -4 addr show 2>/dev/null | awk '$4 ~ /^192\.168\.16\./ {print $2; exit}')
    fi

    if [ -z "$target_iface" ]; then
        fail "Could not determine which network interface faces the 192.168.16 network. Skipping network configuration."
        return
    fi

    ok "Identified target interface: $target_iface"

    local netplan_file
    netplan_file=$(grep -l -E "^\s*${target_iface}:" /etc/netplan/*.yaml 2>/dev/null | head -n1)

    if [ -z "$netplan_file" ]; then
        netplan_file=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n1)
        if [ -z "$netplan_file" ]; then
            netplan_file="/etc/netplan/01-netcfg.yaml"
            fail "No existing netplan file found; will create $netplan_file. Please verify network config manually."
        fi
    fi

    local current_ip
    current_ip=$(ip -o -4 addr show dev "$target_iface" 2>/dev/null | awk '{print $4}' | head -n1)

    if [ "$current_ip" = "$target_cidr" ] && grep -qE "dhcp4:[[:space:]]*(no|false)" "$netplan_file" 2>/dev/null; then
        ok "Interface $target_iface already has address $target_cidr configured"
        return
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        fail "python3 is required to edit netplan configuration but was not found."
        return
    fi

    python3 - "$netplan_file" "$target_iface" "$target_cidr" <<'PYEOF'
import sys, re, io

netplan_file, iface, cidr = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    import yaml
except ImportError:
    sys.exit(2)

try:
    with open(netplan_file) as f:
        data = yaml.safe_load(f) or {}
except FileNotFoundError:
    data = {}

data.setdefault("network", {})
data["network"].setdefault("version", 2)
data["network"].setdefault("ethernets", {})

stanza = data["network"]["ethernets"].setdefault(iface, {})
stanza.pop("dhcp4", None)
stanza["dhcp4"] = False
stanza["addresses"] = [cidr]

with open(netplan_file, "w") as f:
    yaml.safe_dump(data, f, default_flow_style=False)

print("PYTHON_EDIT_OK")
PYEOF
    local py_status=$?

    if [ $py_status -eq 2 ]; then
        fail "python3-yaml module not available; cannot safely edit netplan config."
        return
    elif [ $py_status -ne 0 ]; then
        fail "Failed to edit netplan configuration file $netplan_file"
        return
    fi

    chmod 600 "$netplan_file" 2>/dev/null

    if netplan apply 2>/tmp/netplan_err; then
        changed "Set $target_iface to $target_cidr in $netplan_file and applied netplan"
    else
        fail "netplan apply failed: $(cat /tmp/netplan_err 2>/dev/null)"
    fi
}

# ----------------------------------------------------------------------------
# 2. /etc/hosts
# ----------------------------------------------------------------------------
configure_hosts() {
    section "/etc/hosts entry for server1"

    local hostsfile="/etc/hosts"
    local target_ip="192.168.16.21"
    local hostname="server1"

    if grep -qE "^${target_ip}[[:space:]]+${hostname}(\s|$)" "$hostsfile"; then
        ok "/etc/hosts already has '$target_ip $hostname'"
    else
        if grep -qE "[[:space:]]${hostname}([[:space:]]|$)" "$hostsfile"; then
            sed -i.bak -E "/[[:space:]]${hostname}([[:space:]]|$)/d" "$hostsfile"
            changed "Removed stale /etc/hosts entry for $hostname"
        fi
        echo -e "${target_ip}\t${hostname}" >> "$hostsfile"
        changed "Added '$target_ip $hostname' to /etc/hosts"
    fi
}

# ----------------------------------------------------------------------------
# 3. Packages
# ----------------------------------------------------------------------------
install_packages() {
    section "Software installation"

    local need_update=1

    install_pkg() {
        local pkg="$1"
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            ok "$pkg is already installed"
        else
            if [ "$need_update" -eq 1 ]; then
                apt-get update -qq >/tmp/apt_update_err 2>&1
                need_update=0
            fi
            if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" >/tmp/apt_install_err 2>&1; then
                changed "Installed $pkg"
            else
                fail "Failed to install $pkg: $(tail -n5 /tmp/apt_install_err 2>/dev/null)"
                return
            fi
        fi

        if systemctl is-enabled "$pkg" >/dev/null 2>&1; then
            :
        else
            systemctl enable "$pkg" >/dev/null 2>&1
        fi

        if systemctl is-active "$pkg" >/dev/null 2>&1; then
            ok "$pkg service is running"
        else
            if systemctl start "$pkg" >/tmp/svc_err 2>&1; then
                changed "Started $pkg service"
            else
                fail "Could not start $pkg service: $(cat /tmp/svc_err 2>/dev/null)"
            fi
        fi
    }

    install_pkg apache2
    install_pkg squid
}

# ----------------------------------------------------------------------------
# 4. User accounts
# ----------------------------------------------------------------------------
USERLIST=(dennis aubrey captain snibbles brownie scooter sandy perrier cindy tiger yoda)
DENNIS_EXTRA_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG4rT3vTt99Ox5kndS4HmgTrKBT8SKzhK4rhGkEVGlCI student@generic-vm"

configure_users() {
    section "User accounts"

    for user in "${USERLIST[@]}"; do
        local home="/home/${user}"

        if id "$user" >/dev/null 2>&1; then
            ok "User '$user' already exists"
        else
            if useradd -m -d "$home" -s /bin/bash "$user" >/tmp/useradd_err 2>&1; then
                changed "Created user '$user'"
            else
                fail "Failed to create user '$user': $(cat /tmp/useradd_err 2>/dev/null)"
                continue
            fi
        fi

        if [ ! -d "$home" ]; then
            mkdir -p "$home"
            chown "${user}:${user}" "$home" 2>/dev/null
            changed "Created missing home directory $home for '$user'"
        fi

        local current_shell
        current_shell=$(getent passwd "$user" | cut -d: -f7)
        if [ "$current_shell" != "/bin/bash" ]; then
            if chsh -s /bin/bash "$user" >/dev/null 2>&1; then
                changed "Set shell to /bin/bash for '$user'"
            else
                fail "Failed to set shell for '$user'"
            fi
        fi

        local current_home
        current_home=$(getent passwd "$user" | cut -d: -f6)
        if [ "$current_home" != "$home" ]; then
            if usermod -d "$home" "$user" >/dev/null 2>&1; then
                changed "Set home directory to $home for '$user'"
            else
                fail "Failed to set home directory for '$user'"
            fi
        fi

        local ssh_dir="${home}/.ssh"
        mkdir -p "$ssh_dir"
        chown "${user}:${user}" "$ssh_dir" 2>/dev/null
        chmod 700 "$ssh_dir" 2>/dev/null

        for algo in rsa ed25519; do
            local keyfile="${ssh_dir}/id_${algo}"
            if [ -f "$keyfile" ] && [ -f "${keyfile}.pub" ]; then
                ok "'$user' already has an ${algo} keypair"
            else
                if sudo -u "$user" ssh-keygen -t "$algo" -f "$keyfile" -N "" -q </dev/null >/tmp/keygen_err 2>&1; then
                    changed "Generated ${algo} keypair for '$user'"
                else
                    fail "Failed to generate ${algo} keypair for '$user': $(cat /tmp/keygen_err 2>/dev/null)"
                fi
            fi
        done

        local authfile="${ssh_dir}/authorized_keys"
        touch "$authfile"

        for algo in rsa ed25519; do
            local pubfile="${ssh_dir}/id_${algo}.pub"
            if [ -f "$pubfile" ]; then
                local pubkey
                pubkey=$(awk '{print $1" "$2}' "$pubfile")
                if grep -qF "$pubkey" "$authfile" 2>/dev/null; then
                    :
                else
                    cat "$pubfile" >> "$authfile"
                    changed "Added '$user' own ${algo} public key to authorized_keys"
                fi
            fi
        done

        if [ "$user" = "dennis" ]; then
            if grep -qF "$DENNIS_EXTRA_KEY" "$authfile" 2>/dev/null; then
                ok "dennis already has the required extra authorized key"
            else
                echo "$DENNIS_EXTRA_KEY" >> "$authfile"
                changed "Added required extra authorized key for dennis"
            fi

            if id -nG dennis 2>/dev/null | tr ' ' '\n' | grep -qx "sudo"; then
                ok "dennis is already in the sudo group"
            else
                if usermod -aG sudo dennis >/dev/null 2>&1; then
                    changed "Added dennis to sudo group"
                else
                    fail "Failed to add dennis to sudo group"
                fi
            fi
        fi

        chown -R "${user}:${user}" "$ssh_dir" 2>/dev/null
        chmod 700 "$ssh_dir" 2>/dev/null
        chmod 600 "$authfile" 2>/dev/null
        chmod 600 "${ssh_dir}"/id_* 2>/dev/null
        chmod 644 "${ssh_dir}"/*.pub 2>/dev/null
    done
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    echo "=========================================================="
    echo " Assignment 2 - Server Configuration Script"
    echo " Run at: $(date)"
    echo "=========================================================="

    require_root
    configure_network
    configure_hosts
    install_packages
    configure_users

    echo -e "\n=========================================================="
    if [ "$ERROR_COUNT" -eq 0 ]; then
        echo -e "${COLOR_OK}All checks completed with no errors.${COLOR_RESET}"
    else
        echo -e "${COLOR_ERR}Completed with $ERROR_COUNT error(s). See [ERROR] lines above.${COLOR_RESET}"
    fi
    echo "=========================================================="

    exit "$([ "$ERROR_COUNT" -eq 0 ] && echo 0 || echo 1)"
}

main "$@"
