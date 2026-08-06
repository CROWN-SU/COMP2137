#!/bin/bash
# =========================================
# Script Name:  sysreport.sh
# Course:       COMP2137 - Linux Automation
# Assignment:   1 - System Report Script
# Author:       Asad
# Date:         2026-06-10
# Description:  Generates a formatted system information report covering
#               hardware identity, network configuration, and live system
#               status. All data is gathered dynamically at runtime so the
#               report is always current. Designed to run on any Linux system.
# Usage:        sudo ./sysreport.sh
# ======================================================================


# --------------------------------------------------------------------
# SECTION 1 - REPORT IDENTITY
# Who ran the report, on which machine, and when.
# -----------------------------------------------------------------------------

# hostname command returns the network name of this machine
HOST=$(hostname)

# whoami returns the username of whoever is running the script
REPUSER=$(whoami)

# date with a custom format: YYYY-MM-DD HH:MM:SS
DATETIME=$(date "+%Y-%m-%d %H:%M:%S")


# ---------------------------------------------------------------------------
# SECTION 2 - OPERATING SYSTEM
# Source reads the /etc/os-release file as if it were a script, loading
# its key=value pairs as shell variables. PRETTY_NAME gives us the full
# human-readable OS name (e.g. "Ubuntu 24.04.4 LTS").
# -----------------------------------------------------------------------------

source /etc/os-release
OS=$PRETTY_NAME


# -----------------------------------------------------------------------------
# SECTION 3 - UPTIME
# uptime -p prints uptime in a readable format like "up 3 hours, 46 minutes".
# The -p (pretty) flag keeps it clean without the load averages appended.
# -----------------------------------------------------------------------------

UP=$(uptime -p)


# -----------------------------------------------------------------------------
# SECTION 4 - CPU
# /proc/cpuinfo is a virtual file the kernel keeps updated with processor info.
# grep pulls the "model name" line, head -1 takes only the first CPU listed
# (avoids duplicates on multi-core systems), cut splits on ":" and takes the
# value side, and sed trims the leading space.
# -----------------------------------------------------------------------------

CPU=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^ //')


# -----------------------------------------------------------------------------
# SECTION 5 - RAM
# /proc/meminfo is another kernel virtual file listing memory statistics.
# grep finds the MemTotal line, then awk converts the value from kilobytes
# to gigabytes and prints it with one decimal place.
# -----------------------------------------------------------------------------

RAM=$(grep MemTotal /proc/meminfo | awk '{printf "%.1f GB", $2/1024/1024}')


# -----------------------------------------------------------------------------
# SECTION 6 - DISK(S)
# lsblk lists block devices. The flags used:
#   -d        list only the disk itself, not its partitions
#   -o        choose output columns: NAME, SIZE, MODEL, TYPE
# awk then filters to only rows where TYPE=="disk" and a MODEL name exists,
# printing the model and size together. This skips loop devices (snaps),
# CD-ROMs, and partition entries.
# The fallback runs if every disk has a blank MODEL field (common in some VMs),
# and simply prints the device name and size instead.
# -----------------------------------------------------------------------------

DISKS=$(lsblk -d -o NAME,SIZE,MODEL,TYPE 2>/dev/null \
    | awk '$4=="disk" && $3!="" {print $3, "("$2")"}')

# Fallback: if the MODEL column came back empty (some VM environments)
# use the device name (e.g. sda) and size instead
if [ -z "$DISKS" ]; then
    DISKS=$(lsblk -d -o NAME,SIZE,TYPE 2>/dev/null \
        | awk '$3=="disk" {print $1, "("$2")"}')
fi


# -----------------------------------------------------------------------------
# SECTION 7 - VIDEO CARD
# lspci lists all PCI devices. grep filters to lines containing vga, display,
# or 3d (case-insensitive with -i) which covers GPU entries across vendors.
# cut splits on ":" and takes field 3, which is the device description.
# sed removes the leading space.
# -----------------------------------------------------------------------------

VIDEO=$(lspci 2>/dev/null | grep -i "vga\|display\|3d" | cut -d: -f3 | sed 's/^ //')


# -----------------------------------------------------------------------------
# SECTION 8 - NETWORK (IP, GATEWAY, DNS)
# "ip r" prints the routing table. The default route line looks like:
#   default via 192.168.37.2 dev ens33 proto ...
# awk extracts field 3 (gateway IP) and field 5 (interface name).
#
# "ip a show <interface>" lists addresses on that interface.
# awk finds the "inet" line (IPv4), splits the CIDR notation (e.g.
# 192.168.37.132/24) on "/" and prints just the IP part.
#
# /etc/resolv.conf lists DNS servers. grep finds lines starting with
# "nameserver", head -1 takes the first one, awk prints the IP.
# -----------------------------------------------------------------------------

GW=$(ip r | awk '/default/{print $3; exit}')
IFACE=$(ip r | awk '/default/{print $5; exit}')
IP=$(ip a show "$IFACE" 2>/dev/null | awk '/inet /{split($2,a,"/"); print a[1]; exit}')
DNS=$(grep "^nameserver" /etc/resolv.conf 2>/dev/null | head -1 | awk '{print $2}')


# -----------------------------------------------------------------------------
# SECTION 9 - LOGGED IN USERS
# "who" lists each active login session. awk extracts just the username column,
# sort -u removes duplicates, tr replaces newlines with spaces for one-line
# output, and sed trims the trailing space.
# -----------------------------------------------------------------------------

USERS=$(who | awk '{print $1}' | sort -u | tr '\n' ' ' | sed 's/ $//')


# -----------------------------------------------------------------------------
# SECTION 10 - DISK FREE SPACE
# df -h prints human-readable sizes. The -x flags exclude virtual/temporary
# filesystems (tmpfs, devtmpfs) and squashfs (used by snap packages) so only
# real local filesystems appear. awk prints the mount point and available
# space. tr collapses the newlines into a single space-separated line.
# -----------------------------------------------------------------------------

DISKFREE=$(df -h -x tmpfs -x devtmpfs -x squashfs 2>/dev/null \
    | awk 'NR>1 {print $6, "free:", $4}' \
    | tr '\n' '   ')


# -----------------------------------------------------------------------------
# SECTION 11 - PROCESS COUNT
# "ps aux" lists every running process. tail skips the header line, then
# wc -l counts the remaining lines — one per process.
# -----------------------------------------------------------------------------

PROCS=$(ps aux 2>/dev/null | tail -n +2 | wc -l)


# -----------------------------------------------------------------------------
# SECTION 12 - LOAD AVERAGES
# uptime includes load averages at the end of its output, in the format:
#   "load average: 0.02, 0.03, 0.00"
# awk splits on "load average:" and prints everything after it.
# sed removes the leading space.
# The three numbers represent averages over 1, 5, and 15 minutes.
# -----------------------------------------------------------------------------

LOAD=$(uptime | awk -F'load average:' '{print $2}' | sed 's/^ //')


# -----------------------------------------------------------------------------
# SECTION 13 - LISTENING NETWORK PORTS
# "ss -tlnp" shows TCP (-t) listening (-l) sockets with numeric ports (-n)
# and the process name (-p). awk skips the header row, splits the local
# address field on ":" and extracts the port number (last element of the
# array). sort -un sorts numerically and removes duplicates. tr and sed
# format the list as comma-separated values.
# -----------------------------------------------------------------------------

PORTS=$(ss -tlnp 2>/dev/null \
    | awk 'NR>1{split($4,a,":"); print a[length(a)]}' \
    | sort -un \
    | tr '\n' ',' \
    | sed 's/,$//')


# -----------------------------------------------------------------------------
# ufw status prints whether the firewall is active or inactive.
# sudo is needed because ufw requires root to read its status.
# head -1 takes only the status line, awk prints the second word (active/inactive).
# -----------------------------------------------------------------------------

UFW=$(sudo ufw status 2>/dev/null | head -1 | awk '{print $2}')


cat <<REPORT

System Report for $HOST generated by $REPUSER, on $DATETIME

System Information
------------------
OS:           $OS
Uptime:       $UP
CPU:          $CPU
RAM:          $RAM
Disk(s):      $DISKS
Video:        $VIDEO
Host Address: $IP
Gateway IP:   $GW
DNS Server:   $DNS

System Status
-------------
Users Logged In:         $USERS
Disk Space:              $DISKFREE
Process Count:           $PROCS
Load Averages:           $LOAD
Listening Network Ports: $PORTS
UFW Status:              $UFW

REPORT
