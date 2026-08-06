#!/bin/bash
#
# lab3.sh
#
# Deploys configure-host.sh to server1 and server2, runs it there to set
# each server's hostname/IP and cross-hosts-entry, then applies the
# matching hosts entries locally on the desktop VM.
#
# Usage: lab3.sh [-verbose]

VERBOSE=""
if [ "$1" == "-verbose" ]; then
    VERBOSE="-verbose"
fi

SCRIPT="configure-host.sh"
REMOTE_USER="remoteadmin"

if [ ! -f "$SCRIPT" ]; then
    echo "ERROR: $SCRIPT not found in the current directory." >&2
    exit 1
fi

deploy_and_run() {
    local host="$1"
    shift
    local remote_args=("$@")

    echo "== Deploying to $host =="

    if ! scp "$SCRIPT" "${REMOTE_USER}@${host}:/root"; then
        echo "ERROR: Failed to copy $SCRIPT to $host." >&2
        return 1
    fi

    if ! ssh "${REMOTE_USER}@${host}" -- "/root/${SCRIPT}" "${remote_args[@]}" $VERBOSE; then
        echo "ERROR: $SCRIPT failed on $host." >&2
        return 1
    fi

    echo "== $host configured successfully =="
    return 0
}

STATUS=0

deploy_and_run server1-mgmt -name loghost -ip 192.168.16.3 -hostentry webhost 192.168.16.4 \
    || STATUS=1

deploy_and_run server2-mgmt -name webhost -ip 192.168.16.4 -hostentry loghost 192.168.16.3 \
    || STATUS=1

echo "== Updating local /etc/hosts on desktop VM =="

if ! sudo ./configure-host.sh -hostentry loghost 192.168.16.3 $VERBOSE; then
    echo "ERROR: Failed to add loghost entry locally." >&2
    STATUS=1
fi

if ! sudo ./configure-host.sh -hostentry webhost 192.168.16.4 $VERBOSE; then
    echo "ERROR: Failed to add webhost entry locally." >&2
    STATUS=1
fi

if [ "$STATUS" -eq 0 ]; then
    echo "lab3.sh completed successfully."
else
    echo "lab3.sh completed with errors." >&2
fi

exit $STATUS

