# nc_wire

Copy one or more files sequentially to a remote folder using SSH for control and netcat for data transfer.

## Prerequisites

- Local: `pv`, `nc`, and `ssh`; also `python3` for GNU or Apple netcat senders.
- Remote: `nc`, `od`, and either `ss` or `lsof` to find free ports.
- Both hosts: `sha256sum` when using `-a`.
- SSH access to the destination and an existing writable destination folder.
- TCP ports 49152–65535 on the destination must be reachable from the sender by default, or allow the specific port supplied with `-p`.

Apple/macOS, OpenBSD, GNU (Homebrew), traditional netcat, and Ncat are detected independently on each host. For GNU and Apple netcat, a Python TCP sender flushes all bytes and half-closes the connection before waiting for the receiver. This avoids GNU `-c` resetting a connection with queued data and Apple’s timeout-based EOF handling. Remote reception still uses netcat.

## Usage

```bash
nc_wire [-v] [-a] [-p <port>] -i <ip> -s <ssh> -d <folder> [--] <file> [file ...]
```

```bash
nc_wire -i 10.0.0.13 -s motoko \
  -d "/4TB/StabilityMatrix/Data/Models/DiffusionModels/Flux.1 D/" \
  -a ~/Downloads/reiq*.safetensors "$HOME/Downloads/another model.safetensors"
```

Use actual paths for quoted filenames; tilde expansion works only when the tilde is unquoted. For example, `"$HOME/Downloads/my model.safetensors"`.

`-f` has been removed. Supply files directly, including shell globs. Use `--` before filenames starting with a dash. All files go to the same folder under their original basenames; duplicate basenames are rejected before transfer. Existing destination files are overwritten.

By default, for each file, the command uses SSH to select a fresh random port in 49152–65535, skipping existing listeners and retrying up to 100 candidates. Selection is randomized on every invocation. The check reduces collisions but does not reserve the port between selection and starting netcat.

Files transfer sequentially. The command waits for the receiver to finish writing, checks byte counts, and, with `-a`, verifies each file's SHA256 before proceeding. Any transfer or checksum failure stops the command. Use `-v` to see the selected ports, or `-h` for help.

To use a firewall-approved port, add `-p 16432`. Valid ports are 1–65535. The same port is reused sequentially for all files and checked before each transfer. If occupied, the command fails instead of choosing another port.
