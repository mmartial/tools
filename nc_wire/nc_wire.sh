#!/bin/bash

# Preserve failures from pv and checksum commands in pipelines.
set -o pipefail

# must be on the same network
# requires:
# pv (brew install pv)
# python3 (TCP transport and file verification)
# ssh (openssh)
# sha256sum (brew install coreutils)

# Useful functions
error_exit() { echo "$1"; exit 1; }

is_installed() { if ! command -v "$1" >/dev/null 2>&1; then error_exit "$1 is not installed. Please install it first."; fi; }

vprint() { if [ "$VERBOSE" = true ]; then echo "$1"; fi; }

# Quote a value for the remote POSIX shell, including embedded apostrophes.
shell_quote() { local value=${1//\'/\'\\\'\'}; printf "'%s'" "$value"; }

help() {
    echo "Usage: $0 [-v] [-f] [-p <port>] -i <ip> -s <ssh> -d <folder> [--] <file> [file ...]"
    echo "Copies files sequentially to one remote folder using SSH and Python TCP sockets."
    echo "  -i <ip>     Destination IP for the data connection"
    echo "  -s <ssh>    SSH destination (user@host or SSH config alias)"
    echo "  -d <folder> Existing writable destination folder"
    echo "  -p <port>   Optional fixed destination port (default: random)"
    echo "  -f          Force overwrite of differing files; identical files are skipped"
    echo "  -v          Verbose output, including selected ports"
    echo "  -h          Show help"
    echo "By default, a random free remote port in 49152-65535 is selected for each file."
    echo "Example: $0 -i 10.0.0.13 -s motoko -d /4TB ~/Downloads/*.safetensors"
}

FORCE=false
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
is_installed ssh
is_installed sha256sum
is_installed python3

# Validate every input before starting any transfer. Duplicate basenames would
# overwrite each other in the shared destination folder.
NAMES=()
for FILE in "${FILES[@]}"; do
    [ -f "$FILE" ] && [ -r "$FILE" ] || error_exit "nc_wire: Not a readable file: $FILE"
    NAME=${FILE##*/}
    for PREVIOUS in "${NAMES[@]}"; do
        [ "$NAME" != "$PREVIOUS" ] && [ "$NAME" != "$PREVIOUS.part" ] && [ "$NAME.part" != "$PREVIOUS" ] || error_exit "nc_wire: Duplicate destination filename: $NAME"
    done
    NAMES+=("$NAME")
done

send_file() {
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
}

# Pre-flight checks
vprint "nc_wire: Checking SSH connection to $DEST_SSH..."
if ! ssh -q "$DEST_SSH" exit; then error_exit "nc_wire: Error: Cannot connect to $DEST_SSH"; fi

vprint "nc_wire: Checking destination folder on remote..."
REMOTE_FOLDER=$(shell_quote "$DEST_FOLDER")
if ! ssh -n "$DEST_SSH" "test -d $REMOTE_FOLDER && test -w $REMOTE_FOLDER"; then error_exit "nc_wire: Error: Destination folder \"$DEST_FOLDER\" does not exist or is not writable on $DEST_SSH"; fi

RECEIVER_PID=""
READY_FILE=""
cleanup_receiver() {
    if [ -n "$RECEIVER_PID" ]; then
        kill "$RECEIVER_PID" 2>/dev/null || true
        wait "$RECEIVER_PID" 2>/dev/null || true
    fi
    [ -z "$READY_FILE" ] || rm -f "$READY_FILE"
}
trap cleanup_receiver EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Embedded so the installed command remains a single file. Both hosts need Python 3.
REMOTE_HELPER=$(cat <<'PY'
import fcntl
import hashlib
import json
import os
import stat
import random
import socket
import sys

CHUNK = 64 * 1024 * 1024

def regular(path):
    if os.path.lexists(path) and not stat.S_ISREG(os.lstat(path).st_mode):
        raise RuntimeError("Not a regular file: " + path)

def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(data)
    return h.hexdigest()

mode, final = sys.argv[1:3]
part = final + ".part"
try:
    regular(final)
    regular(part)
    if mode == "prepare":
        expected, size, force = sys.argv[3:6]
        size = int(size)
        if os.path.exists(final):
            if digest(final) == expected:
                print(json.dumps({"state": "skip"}))
                sys.exit(0)
            if force != "true":
                print(json.dumps({"state": "refuse"}))
                sys.exit(0)
            if os.path.exists(part):
                raise RuntimeError("Both final and .part exist; move one aside before forcing replacement")
            os.rename(final, part)
        chunks = []
        if os.path.exists(part):
            with open(part, "rb") as stream:
                remaining = min(os.fstat(stream.fileno()).st_size, size)
                while remaining:
                    length = min(CHUNK, remaining)
                    # Only reuse a short last chunk if it reaches the source EOF.
                    if length < CHUNK and stream.tell() + length != size:
                        break
                    data = stream.read(length)
                    if len(data) != length:
                        raise RuntimeError("Partial file changed while hashing")
                    chunks.append([length, hashlib.sha256(data).hexdigest()])
                    remaining -= length
        print(json.dumps({"state": "resume", "chunks": chunks}))
    elif mode == "receive":
        offset = int(sys.argv[3])
        with open(part, "a+b") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if os.fstat(stream.fileno()).st_size < offset:
                raise RuntimeError("Partial file became shorter than verified prefix")
            stream.truncate(offset)
            stream.seek(offset)
            if sys.argv[4] != "complete":
                requested = int(sys.argv[4]) if sys.argv[4] else None
                with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
                    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    for attempt in range(100):
                        port = requested or random.SystemRandom().randrange(49152, 65536)
                        try:
                            listener.bind(("", port))
                            break
                        except OSError:
                            if requested or attempt == 99:
                                raise
                    listener.listen(1)
                    listener.settimeout(30)
                    print(port, flush=True)
                    connection, _ = listener.accept()
                    with connection:
                        while True:
                            data = connection.recv(1024 * 1024)
                            if not data:
                                break
                            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
    elif mode == "finish":
        expected, size = sys.argv[3:5]
        with open(part, "r+b") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            # A verified full source prefix can have extra stale bytes after it.
            if os.fstat(stream.fileno()).st_size != int(size):
                raise RuntimeError("Size mismatch; partial file retained for retry")
            if digest(part) != expected:
                raise RuntimeError("SHA256 mismatch; partial file retained for retry")
            stream.flush()
            os.fsync(stream.fileno())
            # Publish without replacing a file created by another process.
            os.link(part, final)
            os.unlink(part)
        print("nc_wire: Verified and completed " + final)
    else:
        raise RuntimeError("Unknown operation")
except (OSError, RuntimeError, ValueError) as exc:
    print("nc_wire: " + str(exc), file=sys.stderr)
    sys.exit(1)
PY
)
build_remote_command() {
    local command="python3 -c $(shell_quote "$REMOTE_HELPER")"
    local argument
    for argument in "$@"; do command="$command $(shell_quote "$argument")"; done
    REMOTE_COMMAND=$command
}
remote_operation() {
    build_remote_command "$@"
    ssh -n "$DEST_SSH" "$REMOTE_COMMAND"
}

TRANSFER_STATUS=0
for FILE in "${FILES[@]}"; do
    case "$FILE" in /*) IN_FILE=$FILE ;; *) IN_FILE="$PWD/$FILE" ;; esac
    OUT_FILE=${FILE##*/}
    DEST_FILE="${DEST_FOLDER%/}/$OUT_FILE"
    SRC_SIZE=$(wc -c < "$IN_FILE") || error_exit "nc_wire: Cannot read source size."
    SRC_SHA256=$(sha256sum "$IN_FILE" | awk '{print $1}') || error_exit "nc_wire: Cannot checksum source file."
    vprint "nc_wire: Checking existing file and partial chunks for $OUT_FILE..."
    MANIFEST=$(remote_operation prepare "$DEST_FILE" "$SRC_SHA256" "$SRC_SIZE" "$FORCE") || error_exit "nc_wire: Cannot prepare destination."
    RESUME=$(printf '%s' "$MANIFEST" | python3 -c '
import hashlib, json, sys
manifest = json.load(sys.stdin)
if manifest["state"] != "resume":
    print(manifest["state"])
else:
    offset = 0
    with open(sys.argv[1], "rb") as stream:
        for length, expected in manifest["chunks"]:
            data = stream.read(length)
            if len(data) != length or hashlib.sha256(data).hexdigest() != expected:
                break
            offset += length
    print(offset)
' "$IN_FILE") || error_exit "nc_wire: Cannot verify partial chunks."
    case "$RESUME" in
        skip) echo "nc_wire: Skipping $OUT_FILE (SHA256 matches)."; continue ;;
        refuse)
            echo "nc_wire: Refusing to overwrite $OUT_FILE (SHA256 differs). Use -f to overwrite."
            TRANSFER_STATUS=1
            continue ;;
        ''|*[!0-9]*) error_exit "nc_wire: Invalid resume offset." ;;
    esac
    echo "nc_wire: $OUT_FILE: resuming at byte $RESUME of $SRC_SIZE."
    if [ "$RESUME" -lt "$SRC_SIZE" ]; then
        READY_FILE=$(mktemp) || error_exit "nc_wire: Cannot create receiver readiness file."
        build_remote_command receive "$DEST_FILE" "$RESUME" "$FIXED_PORT"
        ssh -n "$DEST_SSH" "$REMOTE_COMMAND" > "$READY_FILE" &
        RECEIVER_PID=$!
        # The listener publishes its port only after binding and listening.
        for ((attempt=0; attempt<300; attempt++)); do
            [ ! -s "$READY_FILE" ] || break
            kill -0 "$RECEIVER_PID" 2>/dev/null || break
            sleep 0.1
        done
        read -r DEST_PORT < "$READY_FILE"
        rm -f "$READY_FILE"
        READY_FILE=""
        case "$DEST_PORT" in ''|*[!0-9]*) error_exit "nc_wire: Receiver failed to become ready." ;; esac
        [ "${#DEST_PORT}" -le 5 ] && [ "$DEST_PORT" -ge 1 ] && [ "$DEST_PORT" -le 65535 ] || error_exit "nc_wire: Invalid port returned by remote host."
        vprint "nc_wire: Receiver ready on port $DEST_PORT"
        if ! python3 -c '
import shutil, sys
with open(sys.argv[1], "rb") as stream:
    stream.seek(int(sys.argv[2]))
    shutil.copyfileobj(stream, sys.stdout.buffer, 1024 * 1024)
' "$IN_FILE" "$RESUME" | pv -s "$((SRC_SIZE - RESUME))" | send_file; then
            error_exit "nc_wire: Sender failed; .part retained for retry."
        fi
        wait "$RECEIVER_PID"
        RECEIVER_STATUS=$?
        RECEIVER_PID=""
        [ "$RECEIVER_STATUS" -eq 0 ] || error_exit "nc_wire: Receiver failed; .part retained for retry."
    else
        # Empty files and already complete partial files need no data connection.
        remote_operation receive "$DEST_FILE" "$RESUME" complete || error_exit "nc_wire: Cannot prepare complete partial file."
    fi
    remote_operation finish "$DEST_FILE" "$SRC_SHA256" "$SRC_SIZE" || error_exit "nc_wire: Verification failed; .part retained for retry."
done

exit "$TRANSFER_STATUS"
