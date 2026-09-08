#!/bin/bash

# Preserve failures from pv and checksum commands in pipelines.
set -o pipefail

# must be on the same network
# requires:
# pv (brew install pv)
# nc (Apple, OpenBSD, GNU, traditional netcat, or Ncat)
# ssh (openssh)
# sha256sum (brew install coreutils)

# Useful functions
error_exit() { echo "$1"; exit 1; }

is_installed() { if ! command -v "$1" >/dev/null 2>&1; then error_exit "$1 is not installed. Please install it first."; fi; }

vprint() { if [ "$VERBOSE" = true ]; then echo "$1"; fi; }

# Quote a value for the remote POSIX shell, including embedded apostrophes.
shell_quote() { local value=${1//\'/\'\\\'\'}; printf "'%s'" "$value"; }

help() {
    echo "Usage: $0 [-v] [-a] [-f] [-p <port>] -i <ip> -s <ssh> -d <folder> [--] <file> [file ...]"
    echo "Copies files sequentially to one remote folder using SSH and netcat."
    echo "  -i <ip>     Destination IP for the data connection"
    echo "  -s <ssh>    SSH destination (user@host or SSH config alias)"
    echo "  -d <folder> Existing writable destination folder"
    echo "  -p <port>   Optional fixed destination port (default: random)"
    echo "  -a          Verify SHA256 after each copy"
    echo "  -f          Force overwrite of differing files; identical files are skipped"
    echo "  -v          Verbose output, including selected ports"
    echo "  -h          Show help"
    echo "By default, a random free remote port in 49152-65535 is selected for each file."
    echo "Example: $0 -i 10.0.0.13 -s motoko -d /4TB -a ~/Downloads/*.safetensors"
}

FORCE=false
DO_SHA=false
VERBOSE=false
FIXED_PORT=""
FILES=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -i|-s|-d|-p)
            [ "$#" -ge 2 ] || error_exit "nc_wire: Missing value for $1."
            case "$1" in
                -i) DEST_IP=$2 ;;
                -s) DEST_SSH=$2 ;;
                -d) DEST_FOLDER=$2 ;;
                -p)
                    case "$2" in ''|*[!0-9]*) error_exit "nc_wire: Port must be an integer from 1 to 65535." ;; esac
                    [ "${#2}" -le 5 ] || error_exit "nc_wire: Port must be an integer from 1 to 65535."
                    FIXED_PORT=$((10#$2))
                    [ "$FIXED_PORT" -ge 1 ] && [ "$FIXED_PORT" -le 65535 ] || error_exit "nc_wire: Port must be an integer from 1 to 65535."
                    ;;
            esac
            shift 2 ;;
        -f) FORCE=true; shift ;;
        -a) DO_SHA=true; shift ;;
        -v) VERBOSE=true; shift ;;
        -h|--help) help; exit 0 ;;
        --) shift; FILES+=("$@"); break ;;
        -*) error_exit "nc_wire: Unknown option $1. Use -h for usage; files are positional." ;;
        *) FILES+=("$1"); shift ;;
    esac
done
if [ "${#FILES[@]}" -eq 0 ] || [ -z "$DEST_IP" ] || [ -z "$DEST_SSH" ] || [ -z "$DEST_FOLDER" ]; then
    help
    exit 1
fi

is_installed pv
is_installed nc
is_installed ssh
is_installed sha256sum

# Validate every input before starting any transfer. Duplicate basenames would
# overwrite each other in the shared destination folder.
NAMES=()
for FILE in "${FILES[@]}"; do
    [ -f "$FILE" ] && [ -r "$FILE" ] || error_exit "nc_wire: Not a readable file: $FILE"
    NAME=${FILE##*/}
    for PREVIOUS in "${NAMES[@]}"; do
        [ "$NAME" != "$PREVIOUS" ] || error_exit "nc_wire: Duplicate destination filename: $NAME"
    done
    NAMES+=("$NAME")
done

# Options with the same name can mean different things across nc variants.
# Set sender and listener options together, using the help from each host.
detect_nc() {
    local nc_help="$1"
    NC_SEND=()
    NC_LISTEN=""
    NC_VARIANT=""
    case "$nc_help" in
        *--apple-*|*'tcp adaptive write timeout'*)
            NC_VARIANT="Apple netcat"
            # Apple nc has no EOF shutdown flag. Bound the final read wait.
            NC_SEND=(-w 3)
            NC_LISTEN="-l"
            ;;
        *'GNU netcat'*)
            NC_VARIANT="GNU netcat"
            NC_SEND=(-c)
            NC_LISTEN="-l -p"
            ;;
        *Ncat*)
            NC_VARIANT="Ncat"
            NC_SEND=(--send-only)
            NC_LISTEN="-l"
            ;;
        *)
            if printf '%s\n' "$nc_help" | grep -Eiq -- '^[[:space:]]*-N[[:space:]]+.*shutdown'; then
                NC_VARIANT="OpenBSD netcat"
                NC_SEND=(-N)
                NC_LISTEN="-l"
            elif printf '%s\n' "$nc_help" | grep -Eq -- '^[[:space:]]*-q[[:space:]]'; then
                NC_VARIANT="netcat with EOF quit support"
                NC_SEND=(-q 0)
                NC_LISTEN="-l -p"
            else
                return 1
            fi
            ;;
    esac
}

vprint "nc_wire: Detecting local nc capabilities..."
LOCAL_NC_HELP=$(nc -h 2>&1)
if ! detect_nc "$LOCAL_NC_HELP"; then
    error_exit "nc_wire: Unsupported local nc implementation. Check nc -h."
fi
NC_SRC_OPTIONS=("${NC_SEND[@]}")
# GNU -c can reset the socket while data is still queued. Apple nc only
# offers a timeout. Use an explicit TCP half-close for these senders.
USE_PYTHON_SENDER=false
case "$NC_VARIANT" in
    "GNU netcat"|"Apple netcat")
        is_installed python3
        USE_PYTHON_SENDER=true ;;
esac
vprint "nc_wire: Local $NC_VARIANT; Python TCP sender: $USE_PYTHON_SENDER"

send_file() {
    if [ "$USE_PYTHON_SENDER" = true ]; then
        python3 -c '
import socket
import sys
try:
    with socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=30) as sock:
        sock.settimeout(None)
        while True:
            data = sys.stdin.buffer.read(1024 * 1024)
            if not data:
                break
            sock.sendall(data)
        sock.shutdown(socket.SHUT_WR)
        while sock.recv(65536):
            pass
except (OSError, ValueError) as exc:
    print("nc_wire: TCP sender failed: " + str(exc), file=sys.stderr)
    sys.exit(1)
' "$DEST_IP" "$DEST_PORT"
    else
        nc "${NC_SRC_OPTIONS[@]}" "$DEST_IP" "$DEST_PORT"
    fi
}

# Pre-flight checks
vprint "nc_wire: Checking SSH connection to $DEST_SSH..."
if ! ssh -q "$DEST_SSH" exit; then error_exit "nc_wire: Error: Cannot connect to $DEST_SSH"; fi

vprint "nc_wire: Checking destination folder on remote..."
REMOTE_FOLDER=$(shell_quote "$DEST_FOLDER")
if ! ssh -n "$DEST_SSH" "test -d $REMOTE_FOLDER && test -w $REMOTE_FOLDER"; then error_exit "nc_wire: Error: Destination folder \"$DEST_FOLDER\" does not exist or is not writable on $DEST_SSH"; fi

# Detect remote nc capabilities
vprint "nc_wire: Probing remote nc capabilities..."
REMOTE_NC_HELP=$(ssh "$DEST_SSH" "nc -h 2>&1")
if ! detect_nc "$REMOTE_NC_HELP"; then
    error_exit "nc_wire: Unsupported remote nc implementation on $DEST_SSH. Check nc -h there."
fi
NC_DEST_OPTIONS=$NC_LISTEN
vprint "nc_wire: Remote $NC_VARIANT options: $NC_DEST_OPTIONS"

# Selection happens on the SSH host; no probe connection is made to nc,
# since that would consume its one allowed connection.
select_remote_port() {
    ssh -n "$DEST_SSH" "requested_port='$FIXED_PORT';"' # nc_wire: select free port
        if command -v ss >/dev/null 2>&1; then
            checker=ss
        elif command -v lsof >/dev/null 2>&1; then
            checker=lsof
        else
            echo "nc_wire: Install ss or lsof on the destination." >&2
            exit 1
        fi
        attempt=0
        while [ "$attempt" -lt 100 ]; do
            attempt=$((attempt + 1))
            if [ -n "$requested_port" ]; then
                port=$requested_port
            else
                random=$(od -An -N2 -tu2 /dev/urandom) || exit 1
                port=$((49152 + random % 16384))
            fi
            if [ "$checker" = ss ]; then
                listeners=$(ss -H -ltn "sport = :$port") || exit 1
            else
                listeners=$(lsof -nP -iTCP:$port -sTCP:LISTEN 2>/dev/null)
                status=$?
                [ "$status" -le 1 ] || exit 1
            fi
            if [ -z "$listeners" ]; then
                echo "$port"
                exit 0
            fi
            if [ -n "$requested_port" ]; then
                echo "nc_wire: Requested port $requested_port is occupied." >&2
                exit 1
            fi
        done
        echo "nc_wire: No free random port found after 100 attempts." >&2
        exit 1
    '
}

RECEIVER_PID=""
cleanup_receiver() {
    if [ -n "$RECEIVER_PID" ]; then
        kill "$RECEIVER_PID" 2>/dev/null || true
        wait "$RECEIVER_PID" 2>/dev/null || true
    fi
}
trap cleanup_receiver EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

TRANSFER_STATUS=0
for FILE in "${FILES[@]}"; do
    # Prefix relative paths so files beginning with '-' are passed as filenames.
    case "$FILE" in /*) IN_FILE=$FILE ;; *) IN_FILE="$PWD/$FILE" ;; esac
    OUT_FILE=${FILE##*/}
    REMOTE_FILE=$(shell_quote "${DEST_FOLDER%/}/$OUT_FILE")
    SRC_SHA256=""
    ALLOW_OVERWRITE=false
    DEST_STATE=$(ssh -n "$DEST_SSH" "if test -L $REMOTE_FILE; then echo other; elif test -f $REMOTE_FILE; then echo file; elif test -e $REMOTE_FILE; then echo other; else echo missing; fi") || error_exit "nc_wire: Cannot inspect destination file."
    case "$DEST_STATE" in
        file)
            SRC_SHA256=$(sha256sum "$IN_FILE" | awk '{print $1}') || error_exit "nc_wire: Cannot checksum source file."
            DEST_SHA256=$(ssh -n "$DEST_SSH" "sha256sum $REMOTE_FILE" | awk '{print $1}') || error_exit "nc_wire: Cannot checksum destination file."
            if [ "$SRC_SHA256" = "$DEST_SHA256" ]; then
                echo "nc_wire: Skipping $OUT_FILE (SHA256 matches)."
                continue
            fi
            if [ "$FORCE" != true ]; then
                echo "nc_wire: Refusing to overwrite $OUT_FILE (SHA256 differs). Use -f to overwrite."
                TRANSFER_STATUS=1
                continue
            fi
            ALLOW_OVERWRITE=true
            ;;
        missing) ;;
        other) error_exit "nc_wire: Destination is not a regular file: $OUT_FILE" ;;
        *) error_exit "nc_wire: Invalid destination file status." ;;
    esac
    SRC_SIZE=$(wc -c < "$IN_FILE") || error_exit "nc_wire: Cannot read source size."
    if [ "$DO_SHA" = true ] && [ -z "$SRC_SHA256" ]; then
        SRC_SHA256=$(sha256sum "$IN_FILE" | awk '{print $1}') || error_exit "nc_wire: Cannot checksum source file."
    fi
    DEST_PORT=$(select_remote_port) || error_exit "nc_wire: Cannot select a free destination port."
    case "$DEST_PORT" in ''|*[!0-9]*) error_exit "nc_wire: Invalid port returned by remote host." ;; esac
    [ "${#DEST_PORT}" -le 5 ] && [ "$DEST_PORT" -ge 1 ] && [ "$DEST_PORT" -le 65535 ] || error_exit "nc_wire: Invalid port returned by remote host."
    vprint "nc_wire: Transferring $IN_FILE to $DEST_SSH:$DEST_FOLDER/$OUT_FILE on port $DEST_PORT"

    vprint "nc_wire: Starting receiver on $DEST_SSH (will wait 3 seconds before starting sender)"
    # Do not clobber a file created since the initial absence check.
    REMOTE_GUARD="set -C;"
    if [ "$ALLOW_OVERWRITE" = true ]; then REMOTE_GUARD=""; fi
    ssh -n "$DEST_SSH" "$REMOTE_GUARD nc $NC_DEST_OPTIONS $DEST_PORT > $REMOTE_FILE" &
    RECEIVER_PID=$!
    sleep 3
    vprint "nc_wire: Starting sender"
    if ! pv "$IN_FILE" | send_file; then
        error_exit "nc_wire: Sender failed; destination file may be incomplete."
    fi

    # Sender EOF only means the bytes were handed to the network. The receiver
    # must finish writing and close the file before we report success or hash it.
    vprint "nc_wire: Waiting for receiver to finish writing..."
    wait "$RECEIVER_PID"
    RECEIVER_STATUS=$?
    RECEIVER_PID=""
    if [ "$RECEIVER_STATUS" -ne 0 ]; then
        error_exit "nc_wire: Receiver failed (status $RECEIVER_STATUS); destination file may be incomplete."
    fi

    DEST_SIZE=$(ssh -n "$DEST_SSH" "wc -c < $REMOTE_FILE") || error_exit "nc_wire: Cannot read destination size."
    if [ "$SRC_SIZE" -ne "$DEST_SIZE" ]; then
        error_exit "nc_wire: Size mismatch: source $SRC_SIZE bytes; destination $DEST_SIZE bytes."
    fi

    if [ "$DO_SHA" = true ]; then
        vprint "nc_wire: Computing sha256sum of \"$DEST_FOLDER\"/\"$OUT_FILE\""
        DEST_SHA256=$(ssh "$DEST_SSH" "sha256sum $REMOTE_FILE" | awk '{print $1}') || error_exit "nc_wire: Cannot checksum destination file."
        vprint "nc_wire: DEST_SHA256: \"$DEST_SHA256\""
        if [ "$SRC_SHA256" != "$DEST_SHA256" ]; then error_exit "nc_wire: SHA256 mismatch: \"$SRC_SHA256\" != \"$DEST_SHA256\""; fi
        vprint "nc_wire: SHA256 match: \"$SRC_SHA256\""
    fi

done

exit "$TRANSFER_STATUS"
