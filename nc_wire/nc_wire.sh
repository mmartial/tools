#!/bin/bash

# Preserve failures from commands in pipelines.
set -o pipefail

# must be on the same network
# requires:
# python3 (TCP transport and file verification)
# ssh (openssh)
# sha256sum is optional (--use-sha256sum)

# Useful functions
error_exit() { echo "$1"; exit 1; }

is_installed() { if ! command -v "$1" >/dev/null 2>&1; then error_exit "$1 is not installed. Please install it first."; fi; }

vprint() {
    if [ "$VERBOSE" = true ]; then
        if [ "$COLOR" = true ] && [ -t 1 ] && [ -z "${NO_COLOR+x}" ] && [ "${TERM:-}" != dumb ]; then
            printf '\033[36m%s\033[0m\n' "$1"
        else
            printf '%s\n' "$1"
        fi
    fi
}

# Quote a value for the remote POSIX shell, including embedded apostrophes.
shell_quote() { local value=${1//\'/\'\\\'\'}; printf "'%s'" "$value"; }

help() {
    echo "Usage: $0 [-r] [-v] [--color] [--dry-run] [-f] [-p <port>] -i <ip> -s <ssh> -d <folder> [--] <file> [file ...]"
    echo "Copies files sequentially to one remote folder using SSH and Python TCP sockets."
    echo "  -i <ip>     Destination IP for the data connection"
    echo "  -s <ssh>    SSH destination (user@host or SSH config alias)"
    echo "  -d <folder> Existing writable destination folder"
    echo "  -p <port>   Optional fixed destination port (default: random)"
    echo "  -r          Copy one source directory’s contents, preserving relative paths"
    echo "  -f          Force overwrite of differing files; identical files are skipped"
    echo "  -v          Verbose output, including selected ports. In Directory mode: per-file history and two-line live status"
    echo "  --dry-run   Preview changes using file sizes; do not write or hash files"
    echo "  --sync      Directory mode: delete destination-only entries after successful copying"
    echo "  --hide-skipped  Suppress per-file skip history (counts remain visible)"
    echo "  --use-sha256sum  Use sha256sum for whole-file hashes (default: Python)"
    echo "  --check-size-only  Skip completed files with matching sizes; retain partial chunk checks"
    echo "  --skip-verify  Directory mode: skip existing files with matching sizes, without SHA256"
    echo "  --color     Enable terminal colors (plain when redirected or NO_COLOR is set)"
    echo "  -h          Show help"
    echo "By default, a random free remote port in 49152-65535 is selected for each file."
    echo "Example: $0 -i 10.11.12.13 -s nas -d /NAS/backup ~/Downloads/*.safetensors"
}

SYNC=false
HIDE_SKIPPED=false
USE_SHA256SUM=false
CHECK_SIZE_ONLY=false
DRY_RUN=false
SKIP_VERIFY=false
COLOR=false
DIRECTORY=false
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
        -r|--recursive) DIRECTORY=true; shift ;;
        -f) FORCE=true; shift ;;
        -v) VERBOSE=true; shift ;;
        --color) COLOR=true; shift ;;
        --skip-verify) SKIP_VERIFY=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --sync) SYNC=true; shift ;;
        --hide-skipped|--do-not-show-skipped) HIDE_SKIPPED=true; shift ;;
        --use-sha256sum) USE_SHA256SUM=true; shift ;;
        --check-size-only) CHECK_SIZE_ONLY=true; SKIP_VERIFY=true; shift ;;
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

if [ "$SYNC" = true ] && [ "$DIRECTORY" != true ]; then
    error_exit "nc_wire: --sync requires directory mode (-r)."
fi

if [ "$SKIP_VERIFY" = true ] && [ "$DIRECTORY" != true ] && [ "$CHECK_SIZE_ONLY" != true ]; then
    error_exit "nc_wire: --skip-verify requires directory mode (-r)."
fi

if [ "$DIRECTORY" = true ] || [ "$DRY_RUN" = true ]; then
    [ "$DIRECTORY" != true ] || [ "${#FILES[@]}" -eq 1 ] || error_exit "nc_wire: Directory mode requires exactly one source directory."
    is_installed python3
    is_installed ssh
    DIRECTORY_HELPER=$(cat <<'DIRECTORY_PY'
"""Persistent directory transport; embedded in nc_wire.sh for single-file installs."""
import fcntl
import hashlib
import json
import os
import random
import select
import shlex
import signal
import socket
import stat
import subprocess
import sys
import time
import threading
import struct
import shutil

BLOCK = 1024 * 1024
BATCH = 128
CHUNK = 64 * 1024 * 1024
STATE = '.nc-wire-state'
USE_SHA256SUM = False


class Wire:
    """Typed, length-prefixed frames with explicit exact reads and sendall writes.

    Buffer small frames together without relying on a mixed read/write file object.
    Never flush queued data during exception cleanup (which could mask the cause).
    """
    HEADER = struct.Struct('!cI')
    MAX_FRAME = 4 * BLOCK

    def __init__(self, connection):
        self.connection = connection
        self.pending = bytearray()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.pending.clear()

    def flush(self):
        if self.pending:
            self.connection.sendall(self.pending)
            self.pending.clear()

    def write_frame(self, kind, data):
        if len(data) > self.MAX_FRAME:
            raise RuntimeError('Protocol frame exceeds size limit')
        self.pending.extend(self.HEADER.pack(kind, len(data)))
        self.pending.extend(data)
        if len(self.pending) >= BLOCK:
            self.flush()

    def exact(self, length):
        data = bytearray()
        while len(data) < length:
            chunk = self.connection.recv(length - len(data))
            if not chunk:
                raise RuntimeError('Connection ended mid-frame (%d/%d bytes)' % (len(data), length))
            data.extend(chunk)
        return bytes(data)

    def read_frame(self, expected):
        kind, length = self.HEADER.unpack(self.exact(self.HEADER.size))
        if kind != expected or length > self.MAX_FRAME:
            raise RuntimeError('Invalid protocol frame: expected %r, received %r, length %d' %
                               (expected, kind, length))
        return self.exact(length)


def send(stream, value, flush=True):
    stream.write_frame(b'J', json.dumps(value, ensure_ascii=True).encode('ascii'))
    if flush:
        stream.flush()


def receive(stream):
    try:
        value = json.loads(stream.read_frame(b'J'))
    except (UnicodeError, ValueError) as exc:
        raise RuntimeError('Invalid JSON control frame: ' + str(exc))
    if isinstance(value, dict) and 'error' in value:
        raise RuntimeError(value['error'])
    return value


def digest(path):
    if USE_SHA256SUM:
        with open(path, 'rb') as source:
            result = subprocess.run(['sha256sum'], stdin=source, stdout=subprocess.PIPE, check=True)
        value = result.stdout.split()[0].decode('ascii')
        if len(value) != 64 or any(c not in '0123456789abcdef' for c in value):
            raise RuntimeError('Invalid sha256sum output')
        return value
    h = hashlib.sha256()
    with open(path, 'rb') as stream:
        for data in iter(lambda: stream.read(BLOCK), b''):
            h.update(data)
    return h.hexdigest()


def chunk_hashes(path, size):
    """Hash a partial file in CHUNK-sized pieces, for cheap prefix matching on retry."""
    chunks = []
    with open(path, 'rb') as stream:
        remaining = min(os.fstat(stream.fileno()).st_size, size)
        while remaining:
            length = min(CHUNK, remaining)
            # Only reuse a short last chunk if it reaches the source EOF.
            if length < CHUNK and stream.tell() + length != size:
                break
            data = stream.read(length)
            if len(data) != length:
                break
            chunks.append([length, hashlib.sha256(data).hexdigest()])
            remaining -= length
    return chunks


def signature(info):
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def checked_path(root, relative, directory=False, create=True):
    parts = relative.split('/')
    if not relative or any(p in ('', '.', '..') for p in parts) or parts[0] == STATE:
        raise RuntimeError('Unsafe or reserved relative path: ' + repr(relative))
    current = root
    for index, part in enumerate(parts):
        current = os.path.join(current, part)
        is_dir = index < len(parts) - 1 or directory
        if is_dir and create:
            try:
                os.mkdir(current)
            except FileExistsError:
                pass
        if os.path.lexists(current):
            mode = os.lstat(current).st_mode
            if not (stat.S_ISDIR(mode) if is_dir else stat.S_ISREG(mode)):
                raise RuntimeError('Destination type conflict: ' + current)
    return current


def entries(root):
    def failed(exc):
        raise exc
    for folder, dirs, files in os.walk(root, followlinks=False, onerror=failed):
        dirs.sort()
        files.sort()
        names = set(files)
        for name in files:
            if name + '.part' in names:
                raise RuntimeError('Source contains a reserved ".part" sibling pair: ' +
                                    os.path.join(folder, name))
        # Announce a directory only on entering it, not while listing siblings.
        if folder != root:
            yield {'path': os.path.relpath(folder, root), 'kind': 'dir'}
        for name in dirs + files:
            path = os.path.join(folder, name)
            relative = os.path.relpath(path, root)
            if relative.split(os.sep)[0] == STATE:
                raise RuntimeError('Reserved source name: ' + STATE)
            info = os.lstat(path)
            if stat.S_ISDIR(info.st_mode):
                continue
            elif stat.S_ISREG(info.st_mode):
                yield {'path': relative, 'kind': 'file', 'size': info.st_size,
                       'mtime_ns': info.st_mtime_ns, 'signature': signature(info)}
            else:
                raise RuntimeError('Unsupported source type (symlink or special file): ' + path)


def extra_paths(root, expected):
    """Plan from the top down; an absent directory represents its entire subtree."""
    def walk(folder, prefix=''):
        with os.scandir(folder) as scan:
            children = sorted(scan, key=lambda entry: entry.name)
        for child in children:
            if not prefix and child.name == STATE:
                continue
            relative = prefix + child.name
            directory = child.is_dir(follow_symlinks=False)
            if relative not in expected:
                yield relative, directory
            elif directory:
                yield from walk(child.path, relative + '/')
    yield from walk(root)


def remove_extra(root, relative, directory):
    # Parent directories must still be real directories, never symlinks.
    parent = relative.rsplit('/', 1)[0] if '/' in relative else None
    if parent:
        checked_path(root, parent, directory=True, create=False)
    path = os.path.join(root, relative)
    if directory and not os.path.islink(path):
        shutil.rmtree(path)
    else:
        os.unlink(path)


def inspect_server(root, sync):
    if not os.path.isdir(root) or not os.access(root, os.W_OK):
        raise RuntimeError('Destination folder must exist and be writable: ' + root)
    root = os.path.realpath(root)
    expected = set()
    for line in sys.stdin.buffer:
        batch = json.loads(line)
        if batch == {'removals': True}:
            if not sync:
                raise RuntimeError('Sync preview not authorized')
            for relative, directory in extra_paths(root, expected):
                print(json.dumps({'remove': relative, 'directory': directory}), flush=True)
            print(json.dumps({'done': True}), flush=True)
            continue
        result = []
        for entry in batch:
            expected.add(entry['path'])
            try:
                path = checked_path(root, entry['path'], entry['kind'] == 'dir', create=False)
                result.append({'exists': os.path.exists(path),
                               'size': os.stat(path).st_size if os.path.isfile(path) else None})
            except (OSError, RuntimeError) as exc:
                result.append({'error': str(exc)})
        print(json.dumps(result), flush=True)


def preview(code, sources, root, host, force, skip_verify, directory, verbose, sync, hide_skipped):
    def source_entries():
        if directory:
            if len(sources) != 1 or os.path.islink(sources[0]) or not os.path.isdir(sources[0]):
                raise RuntimeError('Source must be one directory, not a symlink')
            yield from entries(os.path.abspath(sources[0]))
        else:
            names = set()
            for source in sources:
                info = os.lstat(source)
                name = os.path.basename(source)
                if not stat.S_ISREG(info.st_mode) or not os.access(source, os.R_OK):
                    raise RuntimeError('Not a readable regular file: ' + source)
                if name in names or name + '.part' in names or (name[:-5] if name.endswith('.part') else name) in names:
                    raise RuntimeError('Duplicate destination filename: ' + name)
                names.add(name)
                yield {'path': name, 'kind': 'file', 'size': info.st_size}
    command = 'python3 -u -c ' + shlex.quote(code) + ' --inspect ' + shlex.quote(root) + ' ' + str(sync).lower()
    counts = dict(copy=0, check=0, skip=0, refuse=0, conflict=0, folders=0, bytes=0)
    process = subprocess.Popen(['ssh', '-T', host, command], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        iterator = iter(source_entries())
        while True:
            batch = []
            for _ in range(BATCH):
                try:
                    batch.append(next(iterator))
                except StopIteration:
                    break
            if not batch:
                break
            process.stdin.write(json.dumps(batch).encode('ascii') + b'\n')
            process.stdin.flush()
            line = process.stdout.readline()
            if not line:
                raise RuntimeError('Remote inspection failed')
            states = json.loads(line)
            if len(states) != len(batch):
                raise RuntimeError('Invalid inspection response')
            for entry, state in zip(batch, states):
                if 'error' in state:
                    action = 'conflict'
                elif entry['kind'] == 'dir':
                    if state['exists']:
                        continue
                    action = 'folders'
                elif not state['exists']:
                    action = 'copy'
                elif state['size'] != entry['size']:
                    action = 'copy' if force else 'refuse'
                else:
                    action = 'skip' if skip_verify else 'check'
                counts[action] += 1
                if action == 'copy':
                    counts['bytes'] += entry['size']
                if (verbose and not (hide_skipped and action in ('skip', 'check'))) or action in ('refuse', 'conflict'):
                    print('nc_wire: Would %s: %s%s' % (action, ascii(entry['path']),
                          ' (' + state['error'] + ')' if 'error' in state else ''), flush=True)
        if sync:
            process.stdin.write(b'{"removals": true}\n')
            process.stdin.flush()
            removed = 0
            while True:
                line = process.stdout.readline()
                if not line:
                    raise RuntimeError('Remote removal preview failed')
                item = json.loads(line)
                if item == {'done': True}:
                    break
                removed += 1
                print('nc_wire: Would remove %s: %s' %
                      ('directory and all contents' if item['directory'] else 'file/link', ascii(item['remove'])), flush=True)
            print('nc_wire: %d destination-only entries would be removed after a successful copy.' % removed, flush=True)
            if counts['refuse'] or counts['conflict']:
                print('nc_wire: Known copy refusals/conflicts would prevent deletion on this run.', flush=True)
        process.stdin.close()
        if process.wait(timeout=30):
            raise RuntimeError('Remote inspection failed')
        print('nc_wire: Dry run: will copy %d files (%s); create %d folders; '
              '%d files already present, will check checksums on actual copy; '
              '%d size-matched files will be skipped; %d files would be refused; %d conflicts.' %
              (counts['copy'], human_size(counts['bytes']), counts['folders'], counts['check'],
               counts['skip'], counts['refuse'], counts['conflict']), flush=True)
        if counts['check']:
            print('nc_wire: After checksum checks, differing files will be ' +
                  ('replaced.' if force else 'refused unless -f is supplied.'), flush=True)
        return 1 if counts['refuse'] or counts['conflict'] else 0
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        if not process.stdin.closed:
            process.stdin.close()
        process.stdout.close()


def server(root, port, force, skip_verify, sync):
    if not os.path.isdir(root) or not os.access(root, os.W_OK):
        raise RuntimeError('Destination folder must exist and be writable: ' + root)
    root = os.path.realpath(root)
    state = os.path.join(root, STATE)
    try:
        os.mkdir(state, 0o700)
    except FileExistsError:
        pass
    if not stat.S_ISDIR(os.lstat(state).st_mode):
        raise RuntimeError('Unsafe transfer state directory')
    lock = os.open(os.path.join(state, 'lock'), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock, 'r+b') as lockfile:
        fcntl.flock(lockfile, fcntl.LOCK_EX | fcntl.LOCK_NB)
        token = os.urandom(32).hex()
        with socket.socket() as listener:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            for attempt in range(100):
                selected = int(port) if port else random.SystemRandom().randrange(49152, 65536)
                try:
                    listener.bind(('', selected))
                    break
                except OSError:
                    if port or attempt == 99:
                        raise
            listener.listen(1)
            listener.settimeout(30)
            print(json.dumps({'port': selected, 'token': token}), flush=True)
            connection, _ = listener.accept()
            with connection:
                connection.settimeout(30)
                with Wire(connection) as stream:
                    if receive(stream) != {'token': token}:
                        raise RuntimeError('Invalid transfer token')
                    connection.settimeout(None)
                    expected, rescanned = set(), set()
                    had_refusal = False
                    while True:
                        batch = receive(stream)
                        if isinstance(batch, dict) and 'sync_scan' in batch:
                            if not sync:
                                raise RuntimeError('Sync not authorized')
                            rescanned.update(tuple(item) for item in batch['sync_scan'])
                            send(stream, {'ok': True})
                            continue
                        if batch == {'sync_commit': True}:
                            if not sync or had_refusal or rescanned != expected:
                                raise RuntimeError('Source tree changed or copy incomplete; deletion aborted')
                            # Complete the traversal before the first deletion, so scan errors are non-destructive.
                            removals = list(extra_paths(root, {path for path, kind in expected}))
                            for relative, directory in removals:
                                remove_extra(root, relative, directory)
                                send(stream, {'removed': relative, 'directory': directory})
                            send(stream, {'sync_done': len(removals)})
                            continue
                        if batch == {'done': True}:
                            send(stream, {'done': True})
                            return
                        if not isinstance(batch, list) or len(batch) > BATCH:
                            raise RuntimeError('Invalid manifest batch')
                        paths, status = [], []
                        for entry in batch:
                            if sync:
                                expected.add((entry['path'], entry['kind']))
                            path = checked_path(root, entry['path'], entry['kind'] == 'dir', create=False)
                            paths.append(path)
                            part = path + '.part'
                            if entry['kind'] == 'dir':
                                status.append(None)
                            elif os.path.exists(path):
                                status.append({'size': os.stat(path).st_size} if skip_verify else {'sha256': digest(path)})
                            elif not skip_verify and os.path.lexists(part) and stat.S_ISREG(os.lstat(part).st_mode):
                                status.append({'chunks': chunk_hashes(part, entry['size'])})
                            else:
                                status.append({})
                        send(stream, status)
                        for entry, path, old in zip(batch, paths, status):
                            action = receive(stream)
                            if entry['kind'] == 'dir':
                                if action != {'action': 'mkdir'}:
                                    raise RuntimeError('Expected directory creation action')
                                checked_path(root, entry['path'], directory=True)
                                continue
                            if action['action'] in ('skip', 'refuse'):
                                had_refusal = had_refusal or action['action'] == 'refuse'
                                continue
                            resumable = bool(old) and 'chunks' in old
                            if action['action'] == 'resume' and not resumable:
                                raise RuntimeError('Resume not offered for: ' + entry['path'])
                            if action['action'] not in ('write', 'resume') or (old and not resumable and not force):
                                raise RuntimeError('Overwrite not authorized')
                            checked_path(root, entry['path'])
                            remaining = entry['size']
                            if not isinstance(remaining, int) or remaining < 0:
                                raise RuntimeError('Invalid file size')
                            part = path + '.part'
                            h = hashlib.sha256()
                            if action['action'] == 'resume':
                                offset = action.get('offset')
                                if not isinstance(offset, int) or offset <= 0 or offset > remaining:
                                    raise RuntimeError('Invalid resume offset: ' + entry['path'])
                                if not os.path.lexists(part) or not stat.S_ISREG(os.lstat(part).st_mode):
                                    raise RuntimeError('No resumable partial file: ' + entry['path'])
                                target = open(part, 'r+b')
                                if os.fstat(target.fileno()).st_size < offset:
                                    target.close()
                                    raise RuntimeError('Partial file shorter than requested resume offset: ' + entry['path'])
                                target.truncate(offset)
                                target.seek(0)
                                remaining_prefix = offset
                                while remaining_prefix:
                                    chunk = target.read(min(BLOCK, remaining_prefix))
                                    if not chunk:
                                        raise RuntimeError('Partial file shorter than requested resume offset: ' + entry['path'])
                                    h.update(chunk)
                                    remaining_prefix -= len(chunk)
                                remaining -= offset
                            else:
                                if os.path.lexists(part):
                                    if not stat.S_ISREG(os.lstat(part).st_mode):
                                        raise RuntimeError('Unsafe partial file: ' + entry['path'])
                                    os.unlink(part)
                                target = open(part, 'xb')
                            with target:
                                while remaining:
                                    data = stream.read_frame(b'D')
                                    if not data or len(data) > min(BLOCK, remaining):
                                        raise RuntimeError('Invalid data frame for file: ' + entry['path'])
                                    target.write(data)
                                    h.update(data)
                                    remaining -= len(data)
                            trailer = receive(stream)
                            if trailer != {'sha256': h.hexdigest()}:
                                raise RuntimeError('Checksum mismatch: ' + entry['path'])
                            os.utime(part, ns=(entry['mtime_ns'], entry['mtime_ns']))
                            # Recheck parent types before publishing. No concurrent writers supported.
                            checked_path(root, entry['path'])
                            if force:
                                os.replace(part, path)
                            else:
                                os.link(part, path)
                                os.unlink(part)
                        send(stream, {'ok': True})


def human_size(size):
    for unit in ('B', 'KiB', 'MiB', 'GiB', 'TiB'):
        if size < 1024 or unit == 'TiB':
            return ('%d %s' if unit == 'B' else '%.1f %s') % (size, unit)
        size /= 1024.0


class Progress:
    """Render independently of blocking socket writes and remote hash checks."""
    def __init__(self, color=False, verbose=False):
        self.verbose = verbose
        self.console_lock = threading.RLock()
        self.active_rows = False
        self.skip_label = 'verified/skipped'
        self.color = color
        self.folders = self.copied = self.skipped = self.refused = 0
        self.sent = self.pending = 0
        self.current = ('Connecting', '', 0, 0)
        self.started = time.monotonic()
        self.file_started = self.started
        self.rate_samples = [(self.started, 0)]
        self.stop = threading.Event()
        self.tty = sys.stderr.isatty()
        self.worker = threading.Thread(target=self.run, daemon=True)

    def paint(self, text, code, output=None):
        output = sys.stderr if output is None else output
        if self.color and output.isatty() and 'NO_COLOR' not in os.environ and os.environ.get('TERM') != 'dumb':
            return '\033[' + code + 'm' + text + '\033[0m'
        return text

    def line(self):
        phase, name, position, size = self.current
        elapsed = max(time.monotonic() - self.started, 0.001)
        text = ('Copied so far: %d files / %d folders ready | %d verified/skipped | '
                '%d refused | %s sent' %
                (self.copied, self.folders, self.skipped, self.refused,
                 human_size(self.sent)))
        if self.pending:
            text += ' | %d awaiting confirmation' % self.pending
        text += ' | ' + phase
        if name:
            # Escape newlines and terminal control characters in filenames.
            text += ' ' + ascii(name)
        if phase == 'Copying':
            percent = 100.0 if size == 0 else min(100.0, position * 100.0 / size)
            text += ' %s / %s (%.1f%%)' % (human_size(position), human_size(size), percent)
        text += ' | avg: %s/s' % human_size(self.sent / elapsed)
        if phase == 'Copying':
            file_elapsed = max(time.monotonic() - self.file_started, 0.001)
            text += ' | file: %s/s' % human_size(position / file_elapsed)
        return text.replace('verified/skipped', self.skip_label, 1)

    def start_file(self, name, size):
        with self.console_lock:
            self.file_started = time.monotonic()
            self.rate_samples = [(self.file_started, 0)]
            self.current = ('Copying', name, 0, size)

    def advance_file(self, name, position, size):
        with self.console_lock:
            now = time.monotonic()
            self.current = ('Copying', name, position, size)
            if now - self.rate_samples[-1][0] >= 0.2 or position == size:
                self.rate_samples.append((now, position))
                while len(self.rate_samples) > 2 and self.rate_samples[1][0] < now - 2:
                    self.rate_samples.pop(0)

    def file_text(self, prefix, details):
        # Shorten the filename before the bar/rates, so long paths do not hide them.
        if self.tty:
            width = max(10, shutil.get_terminal_size().columns - 1)
            available = max(0, width - len(details) - 1)
            if len(prefix) > available:
                prefix = (prefix[:max(0, available - 3)] + '...') if available >= 3 else ''
        return (prefix + ' ' if prefix else '') + details

    def file_line(self):
        phase, name, position, size = self.current
        text = phase + (' ' + ascii(name) if name else '')
        if phase != 'Copying':
            return text
        now = time.monotonic()
        elapsed = max(now - self.file_started, 0.001)
        percent = min(100.0, position * 100.0 / size) if size else 100.0
        with self.console_lock:
            samples = list(self.rate_samples)
        anchor_time, anchor_bytes = samples[0]
        recent = max(0, position - anchor_bytes) / max(now - anchor_time, 0.001)
        if now - samples[-1][0] > 2:
            recent = 0
        width = 12
        bar = '[' + '#' * int(width * percent / 100) + '-' * (width - int(width * percent / 100)) + ']'
        rates = 'now: %s/s | avg: %s/s' % (human_size(recent), human_size(position / elapsed))
        details = '%s %s / %s (%.1f%%) | %s' % (
            bar, human_size(position), human_size(size), percent, rates)
        if self.tty and len(details) + 16 >= shutil.get_terminal_size().columns:
            details = '%s %.1f%% | %s' % (bar, percent, rates)
        return self.file_text(text, details)

    def sent_line(self, name, size):
        elapsed = max(time.monotonic() - self.file_started, 0.001)
        return self.file_text('Sent: ' + ascii(name),
                             '%s (100%%) | avg: %s/s | pending verification' %
                             (human_size(size), human_size(size / elapsed)))

    def global_line(self):
        elapsed = max(time.monotonic() - self.started, 0.001)
        return ('Total: %d copied / %d folders | %d %s | %d refused | '
                '%s sent | avg: %s/s | %d awaiting confirmation' %
                (self.copied, self.folders, self.skipped, self.skip_label, self.refused,
                 human_size(self.sent), human_size(self.sent / elapsed), self.pending))

    def fit(self, text):
        if not self.tty:
            return text
        width = max(10, shutil.get_terminal_size().columns - 1)
        if len(text) > width:
            left = (width - 3) // 2
            return text[:left] + '...' + text[-(width - left - 3):]
        return text

    def clear_rows(self):
        if self.tty and self.active_rows:
            print('\r\033[1A\033[J', end='', file=sys.stderr)
            self.active_rows = False

    def draw_rows(self):
        self.clear_rows()
        print(self.paint(self.fit(self.file_line()), '36'), file=sys.stderr)
        print(self.paint(self.fit(self.global_line()), '32'),
              end='' if self.tty else '\n', file=sys.stderr, flush=True)
        self.active_rows = self.tty

    def record(self, text, code='36'):
        if not self.verbose:
            return
        with self.console_lock:
            self.clear_rows()
            print(self.paint(self.fit(text), code), file=sys.stderr, flush=True)
            if self.tty:
                self.draw_rows()

    def render(self):
        with self.console_lock:
            if self.verbose:
                self.draw_rows()
            else:
                self.render_compact()

    def render_compact(self):
        prefix = '\r\033[2K' if self.tty else ''
        line = self.line()
        if self.tty:
            width = max(10, shutil.get_terminal_size().columns - 1)
            if len(line) > width:
                left = (width - 3) // 2
                line = line[:left] + '...' + line[-(width - left - 3):]
        # Color after shortening so escape sequences do not count toward width.
        sections = line.split(' | ')
        line = ' | '.join(self.paint(section, '32' if index == 0 else '36' if index == len(sections) - 1 else '33' if 'refused' in section or 'awaiting' in section else '37')
                          for index, section in enumerate(sections))
        print(prefix + line, end='' if self.tty else '\n', file=sys.stderr, flush=True)

    def run(self):
        while not self.stop.wait(0.2 if self.tty else 5.0):
            self.render()

    def finish(self, outcome):
        self.stop.set()
        self.worker.join()
        self.render()
        if self.tty:
            print(file=sys.stderr)
        elapsed = time.monotonic() - self.started
        summary = ('nc_wire: %s: %d copied, %d verified/skipped, %d refused; '
              '%d folders ready; %s sent in %.1fs; %d awaiting confirmation.' %
              (outcome, self.copied, self.skipped, self.refused,
               self.folders, human_size(self.sent), elapsed, self.pending))
        code = '32' if outcome == 'Directory complete' and not self.refused else '33'
        summary = summary.replace('verified/skipped', self.skip_label, 1)
        print(self.paint(summary, code, sys.stdout), flush=True)


def client(code, source, root, host, ip, port, force, verbose, color, skip_verify, use_sha256sum, sync, hide_skipped):
    if os.path.islink(source) or not os.path.isdir(source):
        raise RuntimeError('Source must be a directory, not a symlink')
    source = os.path.abspath(source)
    command = 'python3 -u -c ' + shlex.quote(code) + ' ' + ' '.join(
        shlex.quote(x) for x in ('--receiver', root, port, force, skip_verify, use_sha256sum, sync))
    process = subprocess.Popen(['ssh', '-T', host, command], stdout=subprocess.PIPE)
    progress = Progress(color == 'true', verbose == 'true')
    progress.skip_label = 'size-matched/skipped' if skip_verify == 'true' else 'verified/skipped'
    progress.worker.start()
    outcome = 'Stopped before completion'
    try:
        if not select.select([process.stdout], [], [], 60)[0]:
            raise RuntimeError('Timed out waiting for remote receiver')
        ready = json.loads(process.stdout.readline(4096))
        progress.record('nc_wire: Receiver ready on port %s' % ready['port'])
        with socket.create_connection((ip, ready['port']), timeout=30) as connection:
            connection.settimeout(None)
            with Wire(connection) as stream:
                send(stream, {'token': ready['token']})
                iterator = iter(entries(source))
                while True:
                    progress.current = ('Scanning source', '', 0, 0)
                    batch = []
                    for _ in range(BATCH):
                        try:
                            batch.append(next(iterator))
                        except StopIteration:
                            break
                    if not batch:
                        break
                    send(stream, batch)
                    progress.current = ('Checking destination batch', '', 0, 0)
                    status = receive(stream)
                    if not isinstance(status, list) or len(status) != len(batch):
                        raise RuntimeError('Invalid receiver manifest response')
                    batch_folders = 0
                    for entry, old in zip(batch, status):
                        if entry['kind'] == 'dir':
                            send(stream, {'action': 'mkdir'}, flush=False)
                            batch_folders += 1
                            continue
                        resuming = bool(old) and 'chunks' in old
                        existing = bool(old) and not resuming
                        progress.current = (('Checking size' if skip_verify == 'true' else 'Verifying') if existing else 'Preparing', entry['path'], 0, entry['size'])
                        path = os.path.join(source, entry['path'])
                        if signature(os.stat(path, follow_symlinks=False)) != tuple(entry['signature']):
                            raise RuntimeError('Source changed: ' + path)
                        local_hash = digest(path) if existing and skip_verify != 'true' else None
                        if existing and signature(os.stat(path, follow_symlinks=False)) != tuple(entry['signature']):
                            raise RuntimeError('Source changed while hashing: ' + path)
                        if existing and (old['size'] == entry['size'] if skip_verify == 'true' else local_hash == old['sha256']):
                            send(stream, {'action': 'skip'}, flush=False)
                            progress.skipped += 1
                            if hide_skipped != 'true':
                                progress.record('Skipped (%s): %s' % (progress.skip_label, ascii(entry['path'])), '32')
                            continue
                        if existing and force != 'true':
                            send(stream, {'action': 'refuse'}, flush=False)
                            progress.refused += 1
                            message = 'nc_wire: Refusing differing file (use -f): ' + ascii(entry['path'])
                            if progress.verbose:
                                progress.record(message, '33')
                            else:
                                print(progress.paint(message, '33'), file=sys.stderr)
                            continue
                        offset = 0
                        if resuming:
                            with open(path, 'rb') as probe:
                                for length, expected_hash in old['chunks']:
                                    chunk = probe.read(length)
                                    if len(chunk) != length or hashlib.sha256(chunk).hexdigest() != expected_hash:
                                        break
                                    offset += length
                        with open(path, 'rb') as source_file:
                            if signature(os.fstat(source_file.fileno())) != tuple(entry['signature']):
                                raise RuntimeError('Source changed: ' + path)
                            h = hashlib.sha256()
                            if offset:
                                remaining = offset
                                while remaining:
                                    data = source_file.read(min(BLOCK, remaining))
                                    if not data:
                                        raise RuntimeError('Source shortened: ' + path)
                                    h.update(data)
                                    remaining -= len(data)
                                send(stream, {'action': 'resume', 'offset': offset}, flush=False)
                            else:
                                send(stream, {'action': 'write'}, flush=False)
                            remaining = entry['size'] - offset
                            progress.start_file(entry['path'], entry['size'])
                            progress.advance_file(entry['path'], offset, entry['size'])
                            while remaining:
                                data = source_file.read(min(BLOCK, remaining))
                                if not data:
                                    raise RuntimeError('Source shortened: ' + path)
                                stream.write_frame(b'D', data)
                                h.update(data)
                                progress.sent += len(data)
                                remaining -= len(data)
                                progress.advance_file(entry['path'], entry['size'] - remaining, entry['size'])
                            if signature(os.fstat(source_file.fileno())) != tuple(entry['signature']):
                                raise RuntimeError('Source changed during transfer: ' + path)
                            send(stream, {'sha256': h.hexdigest()}, flush=False)
                        progress.pending += 1
                        progress.record(progress.sent_line(entry['path'], entry['size']))
                    progress.current = ('Waiting for receiver verification', '', 0, 0)
                    stream.flush()
                    if receive(stream) != {'ok': True}:
                        raise RuntimeError('Missing batch acknowledgement')
                    progress.record('Receiver confirmed %d copied files in this batch.' % progress.pending, '32')
                    progress.folders += batch_folders
                    progress.copied += progress.pending
                    progress.pending = 0
                if sync == 'true' and not progress.refused:
                    progress.current = ('Rescanning source before deletion', '', 0, 0)
                    paths = []
                    for entry in entries(source):
                        paths.append([entry['path'], entry['kind']])
                        if len(paths) == BATCH:
                            send(stream, {'sync_scan': paths})
                            if receive(stream) != {'ok': True}:
                                raise RuntimeError('Source rescan not acknowledged')
                            paths = []
                    if paths:
                        send(stream, {'sync_scan': paths})
                        if receive(stream) != {'ok': True}:
                            raise RuntimeError('Source rescan not acknowledged')
                    progress.current = ('Removing destination-only entries', '', 0, 0)
                    send(stream, {'sync_commit': True})
                    while True:
                        result = receive(stream)
                        if 'sync_done' in result:
                            print('nc_wire: Sync removed %d destination-only entries.' % result['sync_done'], flush=True)
                            break
                        message = 'Removed %s: %s' % ('directory and contents' if result['directory'] else 'file/link', ascii(result['removed']))
                        if progress.verbose:
                            progress.record(message, '33')
                        else:
                            print('nc_wire: ' + message, flush=True)
                elif sync == 'true':
                    print('nc_wire: Deletion skipped because some files were refused.', flush=True)
                send(stream, {'done': True})
                if receive(stream) != {'done': True}:
                    raise RuntimeError('Missing completion acknowledgement')
        if process.wait(timeout=30):
            raise RuntimeError('Remote receiver failed')
        outcome = 'Directory complete'
        progress.current = ('Finished', '', 0, 0)
        return 1 if progress.refused else 0
    except KeyboardInterrupt:
        outcome = 'Cancelled'
        raise
    finally:
        progress.finish(outcome)
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        process.stdout.close()


def interrupted(signum, frame):
    raise KeyboardInterrupt


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, interrupted)
    try:
        if sys.argv[1] == '--inspect':
            inspect_server(sys.argv[2], sys.argv[3] == 'true')
            result = 0
        elif sys.argv[1] == '--preview':
            result = preview(sys.argv[2], sys.argv[11:], sys.argv[3], sys.argv[4],
                             sys.argv[5] == 'true', sys.argv[6] == 'true',
                             sys.argv[7] == 'true', sys.argv[8] == 'true',
                             sys.argv[9] == 'true', sys.argv[10] == 'true')
        elif sys.argv[1] == '--receiver':
            USE_SHA256SUM = sys.argv[6] == 'true'
            server(sys.argv[2], sys.argv[3], sys.argv[4] == 'true', sys.argv[5] == 'true', sys.argv[7] == 'true')
            result = 0
        else:
            USE_SHA256SUM = sys.argv[-3] == 'true'
            result = client(*sys.argv[1:])
        sys.exit(result)
    except KeyboardInterrupt:
        print('nc_wire: Cancelled. Rerun the same command to verify completed files and retry.', file=sys.stderr)
        sys.exit(130)
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        print('nc_wire: ' + str(exc), file=sys.stderr)
        sys.exit(1)
DIRECTORY_PY
)
    if [ "$DRY_RUN" = true ]; then
        exec python3 -c "$DIRECTORY_HELPER" --preview "$DIRECTORY_HELPER" "$DEST_FOLDER" "$DEST_SSH" "$FORCE" "$SKIP_VERIFY" "$DIRECTORY" "$VERBOSE" "$SYNC" "$HIDE_SKIPPED" "${FILES[@]}"
    fi
    exec python3 -c "$DIRECTORY_HELPER" "$DIRECTORY_HELPER" "${FILES[0]}" "$DEST_FOLDER" "$DEST_SSH" "$DEST_IP" "$FIXED_PORT" "$FORCE" "$VERBOSE" "$COLOR" "$SKIP_VERIFY" "$USE_SHA256SUM" "$SYNC" "$HIDE_SKIPPED"
fi

is_installed ssh
is_installed python3

RECEIVER_PID=""
READY_FILE=""
SSH_CONTROL_PATH=$(mktemp -u /tmp/nc_wire-ssh.XXXXXX) || error_exit "nc_wire: Cannot allocate SSH control socket path."
# Reuse one multiplexed SSH connection for every per-file control call instead of
# paying a fresh handshake each time (prepare/receive/finish run once per file).
ssh() { command ssh -o ControlMaster=auto -o ControlPath="$SSH_CONTROL_PATH" -o ControlPersist=60s "$@"; }
cleanup_receiver() {
    if [ -n "$RECEIVER_PID" ]; then
        kill "$RECEIVER_PID" 2>/dev/null || true
        wait "$RECEIVER_PID" 2>/dev/null || true
    fi
    [ -z "$READY_FILE" ] || rm -f "$READY_FILE"
    if [ -S "$SSH_CONTROL_PATH" ]; then
        command ssh -o ControlPath="$SSH_CONTROL_PATH" -O exit "$DEST_SSH" >/dev/null 2>&1 || true
    fi
}
trap cleanup_receiver EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
import socket, sys, time
token = sys.argv[3].encode("ascii")
source = open(sys.argv[4], "rb") if len(sys.argv) > 4 else sys.stdin.buffer
offset = int(sys.argv[5]) if len(sys.argv) > 5 else 0
total = int(sys.argv[6]) if len(sys.argv) > 6 else None
if offset:
    source.seek(offset)
sent = 0
started = last = time.monotonic()
def progress(final=False):
    if total is None:
        return
    elapsed = max(time.monotonic() - started, 0.001)
    fraction = min(1, (offset + sent) / total) if total else 1
    bar = "[" + "#" * int(20 * fraction) + "-" * (20 - int(20 * fraction)) + "]"
    text = "nc_wire: %s %.1f%% | %d / %d bytes | %.1f MiB/s average" % (bar, fraction * 100, offset + sent, total, sent / elapsed / 1048576)
    print(("\r\033[2K" if sys.stderr.isatty() else "") + text,
          end="\n" if final or not sys.stderr.isatty() else "", file=sys.stderr, flush=True)
try:
    with socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=30) as sock:
        sock.settimeout(None)
        sock.sendall(token)
        progress()
        while True:
            data = source.read(min(1024 * 1024, total - offset - sent) if total is not None else 1024 * 1024)
            if not data:
                break
            sock.sendall(data)
            sent += len(data)
            now = time.monotonic()
            if now - last >= (0.2 if sys.stderr.isatty() else 5):
                progress()
                last = now
        if total is not None and offset + sent != total:
            raise RuntimeError("Source shortened during transfer")
        sock.shutdown(socket.SHUT_WR)
        while sock.recv(65536):
            pass
except (OSError, ValueError, RuntimeError) as exc:
    print("nc_wire: TCP sender failed: " + str(exc), file=sys.stderr)
    sys.exit(1)
finally:
    progress(final=True)
    if source is not sys.stdin.buffer:
        source.close()
' "$DEST_IP" "$DEST_PORT" "$DEST_TOKEN" "$@"
}

# Pre-flight checks
vprint "nc_wire: Checking SSH connection to $DEST_SSH..."
if ! ssh -q "$DEST_SSH" exit; then error_exit "nc_wire: Error: Cannot connect to $DEST_SSH"; fi

vprint "nc_wire: Checking destination folder on remote..."
REMOTE_FOLDER=$(shell_quote "$DEST_FOLDER")
if ! ssh -n "$DEST_SSH" "test -d $REMOTE_FOLDER && test -w $REMOTE_FOLDER"; then error_exit "nc_wire: Error: Destination folder \"$DEST_FOLDER\" does not exist or is not writable on $DEST_SSH"; fi

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

import subprocess
USE_SHA256SUM = sys.argv.pop(1) == 'true'
CHUNK = 64 * 1024 * 1024

def regular(path):
    if os.path.lexists(path) and not stat.S_ISREG(os.lstat(path).st_mode):
        raise RuntimeError("Not a regular file: " + path)

def digest(path):
    if USE_SHA256SUM:
        with open(path, 'rb') as source:
            result = subprocess.run(['sha256sum'], stdin=source, stdout=subprocess.PIPE, check=True)
        value = result.stdout.split()[0].decode('ascii')
        if len(value) != 64 or any(c not in '0123456789abcdef' for c in value):
            raise RuntimeError('Invalid sha256sum output')
        return value
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
    if mode == "size-check":
        print("skip" if os.path.exists(final) and os.path.getsize(final) == int(sys.argv[3]) else "continue")
    elif mode == "prepare":
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
                token = os.urandom(32).hex()
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
                    print(port, token, flush=True)
                    connection, _ = listener.accept()
                    with connection:
                        connection.settimeout(30)
                        expected_token = token.encode("ascii")
                        received_token = b""
                        while len(received_token) < len(expected_token):
                            chunk = connection.recv(len(expected_token) - len(received_token))
                            if not chunk:
                                raise RuntimeError("Connection closed before authentication")
                            received_token += chunk
                        if received_token != expected_token:
                            raise RuntimeError("Invalid transfer token")
                        connection.settimeout(None)
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
except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as exc:
    print("nc_wire: " + str(exc), file=sys.stderr)
    sys.exit(1)
PY
)
build_remote_command() {
    local command="python3 -c $(shell_quote "$REMOTE_HELPER") $(shell_quote "$USE_SHA256SUM")"
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
    if [ "$CHECK_SIZE_ONLY" = true ]; then
        SIZE_STATE=$(remote_operation size-check "$DEST_FILE" "$SRC_SIZE") || error_exit "nc_wire: Cannot check destination size."
        if [ "$SIZE_STATE" = skip ]; then
            [ "$HIDE_SKIPPED" = true ] || echo "nc_wire: Skipping $OUT_FILE (size matches; contents not verified)."
            continue
        fi
    fi
    SRC_SHA256=$(python3 -c '
import hashlib, subprocess, sys
with open(sys.argv[1], "rb") as source:
    if sys.argv[2] == "true":
        result = subprocess.run(["sha256sum"], stdin=source, stdout=subprocess.PIPE, check=True)
        value = result.stdout.split()[0].decode("ascii")
        if len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
            raise RuntimeError("Invalid sha256sum output")
        print(value)
    else:
        h = hashlib.sha256()
        for data in iter(lambda: source.read(1024 * 1024), b""):
            h.update(data)
        print(h.hexdigest())
' "$IN_FILE" "$USE_SHA256SUM") || error_exit "nc_wire: Cannot checksum source file."
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
        skip) [ "$HIDE_SKIPPED" = true ] || echo "nc_wire: Skipping $OUT_FILE (SHA256 matches)."; continue ;;
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
        read -r DEST_PORT DEST_TOKEN < "$READY_FILE"
        rm -f "$READY_FILE"
        READY_FILE=""
        case "$DEST_PORT" in ''|*[!0-9]*) error_exit "nc_wire: Receiver failed to become ready." ;; esac
        [ "${#DEST_PORT}" -le 5 ] && [ "$DEST_PORT" -ge 1 ] && [ "$DEST_PORT" -le 65535 ] || error_exit "nc_wire: Invalid port returned by remote host."
        case "$DEST_TOKEN" in ''|*[!0-9a-f]*) error_exit "nc_wire: Receiver did not return a valid transfer token." ;; esac
        [ "${#DEST_TOKEN}" -eq 64 ] || error_exit "nc_wire: Receiver did not return a valid transfer token."
        vprint "nc_wire: Receiver ready on port $DEST_PORT"
        if ! send_file "$IN_FILE" "$RESUME" "$SRC_SIZE"; then
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
