#!/bin/bash

# must be on the same network
# requires:
# pv (brew install pv)
# nc (netcat-openbsd)
# ssh (openssh)
# sha256sum (brew install coreutils)

# Useful functions
error_exit() { echo "$1"; exit 1; }

is_installed() { if ! command -v "$1" >/dev/null 2>&1; then error_exit "$1 is not installed. Please install it first."; fi; }

vprint() { if [ "$VERBOSE" = true ]; then echo "$1"; fi; }

# Pre-flight checks
is_installed pv
is_installed nc
is_installed ssh
is_installed sha256sum

# Help function
help() {
    echo "Copies a file to a remote server using netcat (wire transfer) for speed. The script uses ssh for authentication and shell access to the destination."
    echo ""
    echo "Usage: $0 [-v] -f <file> -i <ip> -p <port> -s <ssh> -d <folder> [-a]"
    echo "  -v : verbose mode"
    echo "  -f <file> : input file"
    echo "  -i <ip> : destination ip (recommended to be on the same network as the sender)"
    echo "  -p <port> : destination port (firewall for the port must be open on the destination)"
    echo "  -s <ssh> : destination ssh (user@ip, short name for ssh config, ...)"
    echo "  -d <folder> : destination folder (must exist on the destination and be accessible/writeable by the ssh user)"
    echo "  -a : perform sha256sum comparison (optional, default: false)"
    echo ""
    echo "Example: $0 -f /path/to/file -i 192.168.1.1 -p 2020 -s user@192.168.1.1 -d /path/to/destination/folder"
    echo "  will create /path/to/destination/folder/file on the destination"
    exit 1
}

# Arguments processing
DO_SHA=false
VERBOSE=false
while getopts ":f:i:p:s:d:av" opt; do
    case $opt in
        f)
            FILE=$OPTARG
            ;;
        i)
            DEST_IP=$OPTARG
            ;;
        p)
            DEST_PORT=$OPTARG
            ;;
        s)
            DEST_SSH=$OPTARG
            ;;
        d)
            DEST_FOLDER=$OPTARG
            ;;
        a)
            DO_SHA=true
            ;;
        v)
            VERBOSE=true
            ;;
        \?)
            help
            ;;
    esac
done

# Variables to configure
if [ -z "$FILE" ] || [ -z "$DEST_IP" ] || [ -z "$DEST_PORT" ] || [ -z "$DEST_SSH" ] || [ -z "$DEST_FOLDER" ]; then
    help
fi

# Detect local nc capabilities 
vprint "nc_wire: Detecting local nc capabilities..."
NC_SRC_OPTIONS="-q 0"
if nc -h 2>&1 | grep -q "\-N"; then
    vprint "nc_wire: Auto-detected local nc supports -N (OpenBSD style)"
    NC_SRC_OPTIONS="-N"
elif nc -h 2>&1 | grep -q "\-q"; then
    vprint "nc_wire: Auto-detected local nc supports -q (Traditional style)"
else
    vprint "nc_wire: Warning: Could not detect optimal local nc options, using defaults but might fail to close."
fi
vprint "nc_wire: Local nc options: $NC_SRC_OPTIONS"

# Pre-flight checks
vprint "nc_wire: Checking SSH connection to $DEST_SSH..."
if ! ssh -q "$DEST_SSH" exit; then error_exit "nc_wire: Error: Cannot connect to $DEST_SSH"; fi

vprint "nc_wire: Checking destination folder on remote..."
if ! ssh "$DEST_SSH" "test -d \"$DEST_FOLDER\" && test -w \"$DEST_FOLDER\""; then error_exit "nc_wire: Error: Destination folder \"$DEST_FOLDER\" does not exist or is not writable on $DEST_SSH"; fi

# Detect remote nc capabilities
vprint "nc_wire: Probing remote nc capabilities..."
NC_DEST_OPTIONS="-l -p"
REMOTE_NC_HELP=$(ssh "$DEST_SSH" "nc -h 2>&1")
if echo "$REMOTE_NC_HELP" | grep -q "\-N"; then
    vprint "nc_wire: Auto-detected remote nc supports -N (OpenBSD style)"
    NC_DEST_OPTIONS="-l"
elif echo "$REMOTE_NC_HELP" | grep -q "\-q"; then
    vprint "nc_wire: Auto-detected remote nc supports -q (Traditional style)"
else
    vprint "nc_wire: Warning: Could not detect optimal remote nc options."
fi
vprint "nc_wire: Remote nc options: $NC_DEST_OPTIONS"

# OUT_FILE is just the file name
OUT_FILE=$(basename "$FILE")
# IN_FILE is the full path
IN_FILE=$(readlink -f "$FILE")
# Clean up trailing slash
DEST_FOLDER=${DEST_FOLDER%/}

# Check if file exists
if [ ! -f "$IN_FILE" ]; then error_exit "File $IN_FILE does not exist."; fi

# if SHA256 is set, we will compute the sha256sum of the file and compare it with the one on the destination
if [ "$DO_SHA" = true ]; then
    vprint "nc_wire: Computing sha256sum of \"$IN_FILE\""
    SRC_SHA256=$(sha256sum "$IN_FILE" | awk '{print $1}')
    vprint "nc_wire: SHA256: \"$SRC_SHA256\""
fi

vprint "nc_wire: Transferring \"$IN_FILE\" to $DEST_SSH:\"$DEST_FOLDER\"/\"$OUT_FILE\""
vprint "nc_wire: Starting receiver on $DEST_SSH (will wait 3 seconds before starting sender)"
ssh $DEST_SSH "nc $NC_DEST_OPTIONS $DEST_PORT > \"$DEST_FOLDER\"/\"$OUT_FILE\"" &
sleep 3
vprint "nc_wire: Starting sender"
pv "$IN_FILE" | nc $NC_SRC_OPTIONS $DEST_IP $DEST_PORT

if [ "$DO_SHA" = true ]; then
    vprint "nc_wire: Computing sha256sum of \"$DEST_FOLDER\"/\"$OUT_FILE\""
    DEST_SHA256=$(ssh $DEST_SSH "sha256sum \"$DEST_FOLDER\"/\"$OUT_FILE\"" | awk '{print $1}')
    vprint "nc_wire: DEST_SHA256: \"$DEST_SHA256\""
    if [ "$SRC_SHA256" != "$DEST_SHA256" ]; then error_exit "nc_wire: SHA256 mismatch: \"$SRC_SHA256\" != \"$DEST_SHA256\""; fi
    vprint "nc_wire: SHA256 match: \"$SRC_SHA256\""
fi

exit 0
