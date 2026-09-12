# nc_wire

Copy files or a directory tree sequentially to a remote folder using SSH for control and Python TCP sockets for data transfer.

## Prerequisites

- Local: `ssh` and `python3`; individual-file mode also requires `pv` and `sha256sum`.
- Remote: `python3`.
- SSH access to the destination and an existing writable destination folder.
- TCP ports 49152–65535 on the destination must be reachable from the sender by default, or allow the specific port supplied with `-p`.

Python handles both sending and receiving, including explicit EOF shutdown. Netcat is not required on either host.

## Usage

```bash
nc_wire [-v] [-f] [-p <port>] -i <ip> -s <ssh> -d <folder> [--] <file> [file ...]
```

```bash
nc_wire -i 10.0.0.13 -s motoko \
  -d "/4TB/StabilityMatrix/Data/Models/DiffusionModels/Flux.1 D/" \
  ~/Downloads/reiq*.safetensors "$HOME/Downloads/another model.safetensors"
```

Use actual paths for quoted filenames; tilde expansion works only when the tilde is unquoted. For example, `"$HOME/Downloads/my model.safetensors"`.

In individual-file mode (without `-r`), supply files directly, including shell globs. Use `--` before filenames starting with a dash. All files go to the same folder under their original basenames; duplicate basenames are rejected before transfer. Existing files are compared using SHA256. Identical files are skipped, including with `-f`. Differing files are left untouched unless `-f` (force) is supplied. Refused files are reported, remaining files are processed, and the command exits nonzero if any overwrite was refused. Directories and symlinks are refused.

In individual-file mode, for each file, the Python receiver binds a fresh random port in 49152–65535, retrying up to 100 candidates if binding fails. The socket reserves the port immediately. The receiver reports its port over SSH once it is listening, and the sender waits for that readiness signal before connecting.

Files transfer sequentially. The command waits for the receiver to finish writing, checks byte counts, and always verifies each file's SHA256 before publishing it. Any transfer or checksum failure stops the command. Use `-v` to see the selected ports, or `-h` for help.

To use a firewall-approved port, add `-p 16432`. Valid ports are 1–65535. The same port is reused sequentially for all files and checked before each transfer. If occupied, the command fails instead of choosing another port.

## Directory copying

```bash
nc_wire -r -i 10.0.0.15 -s user@nas -d /volume1/backup /local/source
```

`-r` (or `--recursive`) accepts exactly one source directory. It copies the **contents** into the existing destination: `/local/source/path/file` becomes `/volume1/backup/path/file`. A trailing slash on the source does not change this mapping. Directories are created as their turn in the sequential transfer is reached, immediately before their contents are processed; inspecting a manifest batch does not create future folders. Empty directories are still preserved; extra destination files are left untouched. Hidden files are included.

Directory mode uses one SSH session to start a persistent Python receiver and one raw TCP connection for the whole tree. Control messages and binary data use separate typed, length-prefixed frames with exact reads and complete socket writes. Entries are processed in batches of 128, with sequential file writes and SHA256 calculated while streaming new files. It avoids per-file SSH startup and a second full read of newly copied files. A live progress line shows receiver-confirmed copied files, folders ready, verified/skipped and refused files, total bytes sent, overall average speed (`avg`), and the current file with bytes/size, percentage, and its own average speed (`file`). The overall average includes connection setup and verification time; file speed measures bytes handed to the sender transport since that file started, and resets for each file. It refreshes five times per second in a terminal, or every five seconds when redirected to a log. During retry checks it shows the verification phase. Counts of copied files advance when each batch is acknowledged; folders ready counts receiver-confirmed created or existing source subdirectories after each batch, excluding the destination root. `-p` selects a fixed port for the session; otherwise the receiver reserves a random port. The data connection uses IPv4 and is unencrypted, like individual-file mode.

### Optional colors

Add `--color` to enable colored progress and status output, for example:

```bash
nc_wire -r -v --color -i 10.0.0.15 -s user@nas -d /volume1/backup /local/source
```

Green highlights copy counts and successful completion, cyan highlights the current operation and verbose status, and yellow highlights refusals or pending confirmation. Colors are off by default and disabled for redirected output, `TERM=dumb`, or when `NO_COLOR` is set. Individual-file mode also colors its verbose status messages. Colors never enter the transfer protocol.

### Cancelling and retrying a directory copy

Cancel with Ctrl-C and rerun the same command. A final summary reports confirmed copies, verified/skipped and refused files, folders ready, bytes sent (including incomplete transfers), elapsed time, and files still awaiting batch confirmation. Those unconfirmed files may already exist remotely and will be checked on retry. Every expected file encountered on retry is checked: existing files are compared using full SHA256 hashes, matching files are skipped, and missing files are copied. This reads existing files on both hosts, so verifying a large tree takes disk time even when no bytes need transferring.

An incomplete file is kept separately under the reserved destination directory `.nc-wire-state`, and is **retransmitted from the beginning** on retry. Completed files retain their final names. Directory mode does not yet reuse partial-file prefixes. A file is published only after its entire stream passes its checksum. A transfer error exits nonzero; the next run checks the tree again. The reserved state directory remains between runs and contains a lock to prevent simultaneous directory transfers into the same destination.

If an existing file differs, the command reports it, continues with other files, and exits nonzero. Use `-f` to replace differing files; directory mode keeps the old file until its verified replacement is ready. Files corrupted by an interrupted machine or disk write are detected on retry and also require `-f` to replace.

Writes are buffered by the operating system; directory mode does not force a disk sync for every file. Completion means data was received, hashed, and written successfully, not a power-loss durability guarantee. Retrying checks actual file contents rather than trusting saved completion records.

### Faster retries with size-only checks

Add `--skip-verify` in directory mode to skip existing files whose byte size matches the source, without reading and hashing their contents on either host:

```bash
nc_wire -r -v --color --skip-verify -i 10.0.0.15 -s user@nas -d /volume1/backup /local/source
```

The display labels these files `size-matched/skipped`. Missing files are copied; size mismatches are reported and require `-f` to replace, as with normal directory copying. Newly transferred files still get streaming SHA256 verification before publication. An incomplete temporary file is retransmitted as usual.

Size-only checks cannot detect changed or corrupted contents of the same size. Omit `--skip-verify` whenever you want full content verification. The option is only supported with `-r`.

### Scope

Directory mode preserves file contents, relative paths, and modification times of newly copied files. It does not replicate ownership, permissions, ACLs, extended attributes, directory timestamps, or hard-link relationships. Symlinks and special files are rejected, including destination symlinks in the mapped paths. Keep the source stable and avoid other writers to the destination during a run. The name `.nc-wire-state` is reserved at the source and destination root; destination files and the state directory must be on the same filesystem.

## Automatic resume for individual files

Incoming bytes are written to `filename.part` in the destination folder. On retry, the hosts compare SHA256 hashes of 64 MiB chunks in the existing partial file. Only hashes cross SSH. Transfer resumes at the end of the matching prefix; any mismatching or incomplete tail is truncated and retransmitted. A complete matching final short chunk is also reusable.

The sender seeks directly to that offset and sends the remainder through one connection. No chunk files, assembly step, or second full-size copy are needed. The receiver flushes the file and verifies its full size and SHA256 before publishing the final name. Failures retain `.part` for the next invocation. A complete partial file can be finalized without opening a data connection.

With `-f`, a differing final file is renamed to `.part` and its matching prefix is reused. This sacrifices the old file rather than retaining a backup. If both final and `.part` already exist and differ from the source, the command refuses to choose between them; move one aside first. Matching final files still skip. Avoid simultaneous transfers to the same destination filename, and keep source files unchanged during transfers.
