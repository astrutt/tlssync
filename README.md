# 2600net IRC SSL Synchronizer

An automated, secure, hub-and-spoke SSL certificate distribution system designed for multi-node IRC networks. 

Built and maintained by the administrative team at **2600net**, this infrastructure automates the deployment of Let's Encrypt certificates (via `acme.sh`) across a network of IRC servers without dropping active client connections. It was specifically engineered to handle the strict `SIGHUP` file parsing requirements of traditional IRC daemons (like `ircd-hybrid`).

## Features

* **Zero-Downtime Reloads:** Uses `kill -HUP` to seamlessly reload the SSL block in memory, ensuring users never disconnect during a certificate rotation.
* **Custom Certificate Bundling:** Automatically strips and compiles Let's Encrypt's output into the exact `Leaf + CA` concatenated format required by IRC daemons to correctly serve intermediate chains during a live rehash.
* **Cascading Backups:** Implements a two-tier safety net (`.bak` and `.bak.old`). If a bad certificate deploys, you have two full rotation cycles to instantly rollback to known-good production files.
* **Jailed Remote Execution:** Pushes files from the hub to leaf nodes using an unprivileged user (e.g., `irc`). Remote SSH commands are restricted by a strict `authorized_keys` wrapper script, preventing lateral movement or arbitrary code execution even if the hub is compromised.
* **Idempotent Execution:** Cronjobs verify file hashes (MD5) and timestamps (`-nt`) before triggering copies or SIGHUPs, preventing unnecessary disk I/O and daemon signaling.

## Architecture

1. **The Hub (Master):** Runs `acme.sh` to negotiate the wildcard or SAN certificates with Let's Encrypt.
2. **The Hook:** An `acme.sh` post-deployment hook compiles the raw `.cer` files into the required bundle format and pushes them securely to `~/ssl-staging` on all leaf nodes.
3. **The Leafs:** A local cronjob on each leaf detects the new staged files, gracefully manages file permissions (`chmod 600/400`), backs up the active production files, overwrites them, and fires the `SIGHUP` to the IRC daemon process.

## Prerequisites

* **OS:** Linux (Tested on Ubuntu/Debian).
* **Network:** One Hub server and one or more Leaf nodes.
* **User:** A dedicated, non-root user that runs the IRC daemon on all nodes (e.g., `irc`).
* **ACME:** `acme.sh` installed and configured on the Hub server.
* **SSH:** Port 22 open between the Hub and Leaf nodes.

## Installation & Setup

### 1. Configure the Master Script
Download `setup_irc_ssl_sync.sh` and open it in your preferred editor. Update the Configuration Variables at the very top to match your network:

\`\`\`bash
# --- Configuration Variables ---
DOMAIN="example.com"             # Your network's base domain
HUB="hubserver"                  # The hostname of your hub
IRC_USER="irc"                   # The unprivileged user running the ircd
\`\`\`

### 2. Run the Deployment Script
Run the script as `root` on your Hub server. It will prompt you for the FQDNs of your leaf nodes and guide you through establishing SSH trust.

\`\`\`bash
sudo ./setup_irc_ssl_sync.sh
\`\`\`

### 3. Link acme.sh to the Hook (One-Time)
Once the setup script finishes, it generates a custom deployment hook at `/root/acme_irc_deploy.sh`. Bind this hook to your existing `acme.sh` installation so it triggers automatically upon renewal:

\`\`\`bash
/root/.acme.sh/acme.sh --install-cert -d example.com --ecc \
    --reloadcmd "/root/acme_irc_deploy.sh"
\`\`\`

### 4. Force Initial Deployment
To immediately push your current certificates to the network and verify the SIGHUP reload, execute the hook manually, followed by the local apply scripts:

\`\`\`bash
/root/acme_irc_deploy.sh
/root/apply_certs.sh
su - irc -c "ssh leaf.example.com '/home/irc/apply_certs.sh'"
\`\`\`

## Security & SSH Jailing

During setup, you will be asked if you want to apply the SSH security wrapper. It is **highly recommended** you select `y`. 

This configures the `authorized_keys` file on your leaf nodes to strictly enforce the `SSH_ORIGINAL_COMMAND`. It guarantees that the dedicated SSH key generated on the hub can *only* be used to SCP the specific certificate files into the staging directory. Attempting to pass an interactive shell or run arbitrary commands will result in an immediate rejection, logged to `~/logs/rejected_ssh.log`.

## Contributing

Pull requests and bug reports are welcome. Please ensure any changes to the deployment logic maintain idempotency and respect the unprivileged user boundaries.

