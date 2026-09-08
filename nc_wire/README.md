# nc_wire

Copy one or more files sequentially to a remote folder using SSH for control and netcat for data transfer.

## Prerequisites

- Local: `pv`, `nc`, `ssh`, `sha256sum`, and `python3`.
- Remote: `python3`, `nc`, `od`, and either `ss` or `lsof` to find free ports.
- SSH access to the destination and an existing writable destination folder.
- TCP ports 49152–65535 on the destination must be reachable from the sender by default, or allow the specific port supplied with `-p`.

Apple/macOS, OpenBSD, GNU (Homebrew), traditional netcat, and Ncat are detected independently on each host. For GNU and Apple netcat, a Python TCP sender flushes all bytes and half-closes the connection before waiting for the receiver. This avoids GNU `-c` resetting a connection with queued data and Apple’s timeout-based EOF handling. Remote reception still uses netcat.

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

Supply files directly, including shell globs. Use `--` before filenames starting with a dash. All files go to the same folder under their original basenames; duplicate basenames are rejected before transfer. Existing files are compared using SHA256. Identical files are skipped, including with `-f`. Differing files are left untouched unless `-f` (force) is supplied. Refused files are reported, remaining files are processed, and the command exits nonzero if any overwrite was refused. Directories and symlinks are refused.

By default, for each file, the command uses SSH to select a fresh random port in 49152–65535, skipping existing listeners and retrying up to 100 candidates. Selection is randomized on every invocation. The check reduces collisions but does not reserve the port between selection and starting netcat.

Files transfer sequentially. The command waits for the receiver to finish writing, checks byte counts, and always verifies each file's SHA256 before publishing it. Any transfer or checksum failure stops the command. Use `-v` to see the selected ports, or `-h` for help.

To use a firewall-approved port, add `-p 16432`. Valid ports are 1–65535. The same port is reused sequentially for all files and checked before each transfer. If occupied, the command fails instead of choosing another port.

## Automatic resume

Incoming bytes are written to `filename.part` in the destination folder. On retry, the hosts compare SHA256 hashes of 64 MiB chunks in the existing partial file. Only hashes cross SSH. Transfer resumes at the end of the matching prefix; any mismatching or incomplete tail is truncated and retransmitted. A complete matching final short chunk is also reusable.

The sender seeks directly to that offset and sends the remainder through one connection. No chunk files, assembly step, or second full-size copy are needed. The receiver flushes the file and verifies its full size and SHA256 before publishing the final name. Failures retain `.part` for the next invocation. A complete partial file can be finalized without opening a data connection.

With `-f`, a differing final file is renamed to `.part` and its matching prefix is reused. This sacrifices the old file rather than retaining a backup. If both final and `.part` already exist and differ from the source, the command refuses to choose between them; move one aside first. Matching final files still skip. Avoid simultaneous transfers to the same destination filename, and keep source files unchanged during transfers.
