# nc_wire

`nc_wire` is a script that facilitates fast file transfers between computers using `netcat` (nc) and `ssh`. 
It leverages `ssh` for authentication and secure control channel establishment, while using `netcat` for the high-speed data transfer.

## Prerequisites

Ensure the following tools are installed on both the source and destination systems (where applicable):

-   `pv` (Pipe Viewer) - Used for monitoring the progress of data through a pipe.
-   `nc` (Netcat) - The networking utility for reading from and writing to network connections.
    - the port used for communication should be open on the remote server.
-   `ssh` (OpenSSH) - For secure remote login and command execution.
    - pre-established access to the remote server and an ssh-agent with the private key, to avoid the need for ssh handhsake and password prompts.
-   `sha256sum` (Coreutils) - For computing and verifying SHA256 file checksums (optional but recommended).

## Usage

For a complete list of available options and flags, run the script without any arguments:

```bash
./nc_wire.sh
```

### Example

Transfer a file to a remote server:

```bash
./nc_wire.sh -f /path/to/my_large_file.safetensors -i 192.168.1.50 -p 9000 -s user@192.168.1.50 -d /home/user/models -a
```

The command will:
-   Transfer `/path/to/my_large_file.safetensors`.
-   Send it to the IP `192.168.1.50` on port `9000`.
-   Use `user@192.168.1.50` for SSH authentication.
-   Save the file in `/home/user/models` on the remote machine.
-   (`-a`) Verify the integrity of the transferred file using SHA256 checksums.
