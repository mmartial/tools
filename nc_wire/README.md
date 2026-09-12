# nc_wire

Build as a way to do some simple "rsync"-like copies (is not designed as a replacement for the more feature complete rsync, but simplifies some as-fast-as-the-wire [does not encrypt the data copied over] will allow copies to run a remote copy without the need to configure an rsync server)

Copy files or a directory tree sequentially to a remote folder using SSH for control and Python TCP sockets for data transfer.

## Prerequisites

- Local: Bash, `ssh`, and `python3`. No `pv` or `sha256sum` is required by default.
- Remote: `python3`.
- SSH access to the destination and an existing writable destination folder.
- TCP ports 49152–65535 on the destination must be reachable from the sender by default, or allow the specific port supplied with `-p`.

Python handles both sending and receiving, including explicit EOF shutdown. Netcat is not required on either host.

## Usage

```bash
nc_wire [-v] [-f] [-p <port>] -i <ip> -s <ssh> -d <folder> [--] <file> [file ...]
```

```bash
nc_wire -i 10.11.22.13 -s host \
  -d "/StabilityMatrix/Data/Models/DiffusionModels/Flux.1 D/" \
  ~/Downloads/modelname*.safetensors "$HOME/Downloads/another modelname.safetensors"
```

Use actual paths for quoted filenames; tilde expansion works only when the tilde is unquoted. For example, `"$HOME/Downloads/my model.safetensors"`.

In individual-file mode (without `-r`), supply files directly, including shell globs. Use `--` before filenames starting with a dash. All files go to the same folder under their original basenames; duplicate basenames are rejected before transfer. Existing files are compared using SHA256. Identical files are skipped, including with `-f`. Differing files are left untouched unless `-f` (force) is supplied. Refused files are reported, remaining files are processed, and the command exits nonzero if any overwrite was refused. Directories and symlinks are refused.

In individual-file mode, for each file, the Python receiver binds a fresh random port in 49152–65535, retrying up to 100 candidates if binding fails. The socket reserves the port immediately. The receiver reports its port and a random per-file transfer token over SSH once it is listening, and the sender waits for that readiness signal before connecting. The sender presents the token as the first bytes on the data connection; the receiver rejects any connection that does not present it, so a third party racing to connect to the open port cannot inject or receive data. SSH connections for the control channel (the connectivity check, destination check, and each file's prepare/receive/finish calls) are multiplexed over one shared SSH master connection for the lifetime of the command, avoiding a fresh handshake per call.

Files transfer sequentially. The command waits for the receiver to finish writing, checks byte counts, and always verifies each file's SHA256 before publishing it. Any transfer or checksum failure stops the command. Use `-v` to see the selected ports, or `-h` for help.

To use a firewall-approved port, add `-p 16432`. Valid ports are 1–65535. The same port is reused sequentially for all files and checked before each transfer. If occupied, the command fails instead of choosing another port.

## Directory copying

```bash
nc_wire -r -i 10.11.12.15 -s user@nas -d /volume1/backup /local/source
```

`-r` (or `--recursive`) accepts exactly one source directory. It copies the **contents** into the existing destination: `/local/source/path/file` becomes `/volume1/backup/path/file`. A trailing slash on the source does not change this mapping. Directories are created as their turn in the sequential transfer is reached, immediately before their contents are processed; inspecting a manifest batch does not create future folders. Empty directories are still preserved; extra destination files are left untouched unless `--sync` is supplied. Hidden files are included.

Directory mode uses one SSH session to start a persistent Python receiver and one raw TCP connection for the whole tree. Control messages and binary data use separate typed, length-prefixed frames with exact reads and complete socket writes. Entries are processed in batches of 128, with sequential file writes and SHA256 calculated while streaming new files. It avoids per-file SSH startup and a second full read of newly copied files. A live progress line shows receiver-confirmed copied files, folders ready, verified/skipped and refused files, total bytes sent, overall average speed (`avg`), and the current file with bytes/size, percentage, and its own average speed (`file`). The overall average includes connection setup and verification time; file speed measures bytes handed to the sender transport since that file started, and resets for each file. It refreshes five times per second in a terminal, or every five seconds when redirected to a log. During retry checks it shows the verification phase. Counts of copied files advance when each batch is acknowledged; folders ready counts receiver-confirmed created or existing source subdirectories after each batch, excluding the destination root. `-p` selects a fixed port for the session; otherwise the receiver reserves a random port. The sender authenticates the single data connection with a random token exchanged over SSH before any manifest or file data is sent, so a third party connecting to the open port first is rejected. The data connection uses IPv4 and is unencrypted, like individual-file mode.

### Synchronizing destination contents

Add `--sync` with `-r` to remove destination files and folders that have no corresponding source path:

Warning: sync is a destructive operation on the remote. If source has folder1 and destination has folder1 and folder2, folder2 will be removed as part of this operation, as such use with caution and perform a dry-run first to understand the impact the copy might have (recommanded add `--dry-run --check-size-only --hide-skipped`)

```bash
nc_wire -r --sync --dry-run --hide-skipped -i 10.11.12.15 -s user@nas -d /volume1/backup /local/source
```

Remove `--dry-run` to perform the copy and deletions. Sync still uses the existing overwrite rules: differing files require `-f` to replace, and `--check-size-only` changes how existing files are skipped.

Deletion runs only after all copy batches succeed and no files are refused. The source is scanned again; if the source path/type set has changed or a scan fails, deletion is aborted. Failed or cancelled copies do not start deletion. Keep both trees stable during the run; the scan is not a filesystem snapshot. If cancellation or an error happens during deletion itself, earlier deletions remain applied and a retry can finish the sync.

The destination is examined from the top down. An absent folder is removed with its entire subtree and appears as one `directory and all contents` entry. A folder that exists in the source is retained while its children are inspected individually. Symlinks that are extra are unlinked, never followed into their targets. The destination root and the reserved `.nc-wire-state` directory are always retained. An empty source therefore removes all other destination entries.

Dry runs always list candidate removals, even without `-v` or with `--hide-skipped`. They never delete anything or create transfer state. The list is conditional on a successful copy; known refusals/conflicts are reported as preventing deletion. Without `--sync`, extra destination entries remain untouched.

### Hiding skipped-file history

Use `--hide-skipped` (alias `--do-not-show-skipped`) with verbose mode to omit per-file skip messages while retaining skip totals, copied-file history, refusals, and removal messages. In dry runs it also hides the repetitive per-file entries for existing files awaiting checksum checks; their totals remain in the summary. It does not disable checksum checks or change copying decisions.

### Preview without copying

Add `--dry-run` to inspect what a command would do. It works with directory mode or an individual file list:

```bash
nc_wire -r --dry-run -i 10.11.12.15 -s user@nas -d /volume1/backup /local/source
```

The preview uses a single SSH session and reads file metadata only. It does not hash file contents, open a data listener, create directories or transfer state, or modify existing files or partial transfers. The destination root must already exist and be writable, as for an actual copy.

It reports missing files to copy, missing folders to create, existing same-size files that need checksum checks on the actual run, size mismatches that would be replaced with `-f` or refused without it, and path/type conflicts. With `--skip-verify`, same-size files are reported as skips instead. `-v` lists individual planned actions. Known refusals or conflicts return a nonzero exit status.

The preview cannot determine content equality from size alone. Its copy-byte total counts full sizes of files known to need copying; it excludes decisions pending checksum checks and does not estimate partial-prefix reuse. A real run checks the filesystem again.

### Verbose two-line status

With `-v`, terminal progress uses two live rows: the current filename, progress bar, size/percentage, recent speed (`now`, sampled over roughly two seconds), and per-file average (`avg`) on the first row; global counts, bytes and average speed on the second. The saved `Sent` line includes the final per-file average speed. Rates measure sender-side progress, not durable NAS writes; recent speed drops to zero during a stall. Narrow terminals shorten paths and may omit byte sizes to keep the bar and rates visible. Python renders the display directly; neither transfer mode needs `pv`. When a file has been sent, its status remains in the terminal history and the next file takes over the live row. Skipped and refused files also get history entries.

A sent file is labeled **awaiting batch verification** until the receiver acknowledges its batch; a separate confirmation entry then records the batch's copied count. This retains batched transfer throughput without treating unconfirmed sends as completed copies. Redirected output uses ordinary lines without cursor movement. Without `-v`, the compact single-line display remains available. Verbose mode emits one history entry per file, so large trees produce large logs.

### Optional colors

Add `--color` to enable colored progress and status output, for example:

```bash
nc_wire -r -v --color -i 10.11.12.15 -s user@nas -d /volume1/backup /local/source
```

Green highlights copy counts and successful completion, cyan highlights the current operation and verbose status, and yellow highlights refusals or pending confirmation. Colors are off by default and disabled for redirected output, `TERM=dumb`, or when `NO_COLOR` is set. Individual-file mode also colors its verbose status messages. Colors never enter the transfer protocol.

### Cancelling and retrying a directory copy

Cancel with Ctrl-C and rerun the same command. A final summary reports confirmed copies, verified/skipped and refused files, folders ready, bytes sent (including incomplete transfers), elapsed time, and files still awaiting batch confirmation. Those unconfirmed files may already exist remotely and will be checked on retry. Every expected file encountered on retry is checked: existing files are compared using full SHA256 hashes, matching files are skipped, and missing files are copied. This reads existing files on both hosts, so verifying a large tree takes disk time even when no bytes need transferring.

An incomplete file is kept as `<name>.part` next to its destination path and is **resumed** on retry: the receiver hashes the partial file in 64 MiB chunks, the sender replays the same chunk hashes against its local source, and only the unmatched tail is resent (falling back to a full retransmit if no prefix matches, e.g. after corruption). Completed files retain their final names. A file is published only after its entire stream passes its checksum. A transfer error exits nonzero; the next run checks the tree again. The reserved state directory `.nc-wire-state` remains between runs and contains only the lock that prevents simultaneous directory transfers into the same destination. Because `<name>.part` is reserved per entry, a source tree must not contain both `<name>` and `<name>.part` as sibling files.

If an existing file differs, the command reports it, continues with other files, and exits nonzero. Use `-f` to replace differing files; directory mode keeps the old file until its verified replacement is ready. Files corrupted by an interrupted machine or disk write are detected on retry and also require `-f` to replace.

Writes are buffered by the operating system; directory mode does not force a disk sync for every file. Completion means data was received, hashed, and written successfully, not a power-loss durability guarantee. Retrying checks actual file contents rather than trusting saved completion records.

### Hashing options in both modes

Python SHA256 is the default. Add `--use-sha256sum` to use an installed `sha256sum` for whole-file hashes on the local and remote hosts. The override covers existing-file comparisons, single-file source hashing, and single-file final verification. Chunk hashing and directory streaming checksums remain in Python; the external command is not started for each chunk. A required external hashing command that is missing or fails stops the transfer rather than silently falling back. Dry runs never hash files.

Add `--check-size-only` to skip an existing completed file when its size matches the source, without hashing either file. This applies to individual-file and directory modes and works with `--dry-run`. Matching-size contents can differ or be corrupt; use the default checksum comparison when content equality matters.

For individual-file mode, a differing size follows the normal `-f` overwrite rules. Existing `.part` files and forced replacements still undergo the same 64 MiB chunk hash checks before resuming. Newly transferred files still receive full SHA256 verification before publication. Directory mode resumes `.part` files the same way (64 MiB chunk hashes, resent tail only) unless `--skip-verify`/`--check-size-only` is set, in which case it retains its size-only restart behavior and retransmits interrupted files from the beginning. `--skip-verify` remains a directory-only alias for size-only checks.

Individual-file progress is now rendered by the Python sender: a bar, percentage, total bytes including the resumed prefix, and average speed for bytes sent during this attempt. It seeks directly to the verified resume offset without a `pv` pipeline.

### Faster retries with size-only checks

Add `--skip-verify` in directory mode to skip existing files whose byte size matches the source, without reading and hashing their contents on either host:

```bash
nc_wire -r -v --color --skip-verify -i 10.11.12.15 -s user@nas -d /volume1/backup /local/source
```

The display labels these files `size-matched/skipped`. Missing files are copied; size mismatches are reported and require `-f` to replace, as with normal directory copying. Newly transferred files still get streaming SHA256 verification before publication. An incomplete temporary file is retransmitted as usual.

Size-only checks cannot detect changed or corrupted contents of the same size. Omit `--skip-verify` whenever you want full content verification. The option is only supported with `-r`.

### Scope

Directory mode preserves file contents, relative paths, and modification times of newly copied files. It does not replicate ownership, permissions, ACLs, extended attributes, directory timestamps, or hard-link relationships. Symlinks and special files are rejected, including destination symlinks in the mapped paths. Keep the source stable and avoid other writers to the destination during a run. The name `.nc-wire-state` is reserved at the source and destination root; destination files and the state directory must be on the same filesystem.

## Automatic resume for individual files

Incoming bytes are written to `filename.part` in the destination folder. On retry, the hosts compare SHA256 hashes of 64 MiB chunks in the existing partial file. Only hashes cross SSH. Transfer resumes at the end of the matching prefix; any mismatching or incomplete tail is truncated and retransmitted. A complete matching final short chunk is also reusable.

The sender seeks directly to that offset and sends the remainder through one connection. No chunk files, assembly step, or second full-size copy are needed. The receiver flushes the file and verifies its full size and SHA256 before publishing the final name. Failures retain `.part` for the next invocation. A complete partial file can be finalized without opening a data connection.

With `-f`, a differing final file is renamed to `.part` and its matching prefix is reused. This sacrifices the old file rather than retaining a backup. If both final and `.part` already exist and differ from the source, the command refuses to choose between them; move one aside first. Matching final files still skip. Avoid simultaneous transfers to the same destination filename, and keep source files unchanged during transfers.
