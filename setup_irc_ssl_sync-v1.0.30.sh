#!/usr/bin/env bash
# /root/setup_irc_ssl_sync.sh
# Master setup script for 2600net IRC SSL distribution.
# Must be run as root on the hub server.

set -euo pipefail

# ========================================================
# --- Configuration Variables (Edit these for your network) ---
# ========================================================
VERSION="1.0.30-OSS"
DOMAIN="example.com"             # Your network's base domain
HUB="hubserver"                  # The hostname of your hub
IRC_USER="irc"                   # The unprivileged user running the ircd
SSH_KEY_PATH="/home/${IRC_USER}/.ssh/id_ed25519_cert_sync"

# Hub Paths & Names
HUB_ETC_DIR="/usr/local/ircd/etc"
HUB_PID_FILE="/usr/local/ircd/var/run/ircd.pid"
HUB_TARGET_CERT="${HUB}.${DOMAIN}.pem"
HUB_TARGET_KEY="${HUB}.${DOMAIN}.key"

# Leaf Target Names
LEAF_TARGET_CERT="leaf.${DOMAIN}.pem"
LEAF_TARGET_KEY="leaf.${DOMAIN}.key"

# ========================================================

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root." 
   exit 1
fi

echo "========================================================"
echo " 2600net IRC SSL Synchronization Setup (v${VERSION})"
echo "========================================================"

# --- Helper Functions for Idempotency ---
deploy_local_script() {
    local tmp_file="$1"
    local target_file="$2"
    local owner="$3"
    local perms="$4"
    if [[ -f "$target_file" ]] && cmp -s "$target_file" "$tmp_file"; then
        echo "    - $target_file [Unchanged]"
        rm -f "$tmp_file"
    else
        mv -f "$tmp_file" "$target_file"
        chown "$owner" "$target_file"
        chmod "$perms" "$target_file"
        echo "    - $target_file [UPDATED]"
    fi
}

deploy_remote_script() {
    local tmp_file="$1"
    local leaf="$2"
    local target_file="$3"
    
    local local_md5
    local_md5=$(md5sum "$tmp_file" | awk '{print $1}')
    
    local remote_md5
    remote_md5=$(su - "${IRC_USER}" -c "ssh -q -o BatchMode=yes -i ${SSH_KEY_PATH} ${IRC_USER}@${leaf} 'md5sum $target_file 2>/dev/null || echo missing'" || echo "missing_ssh")
    remote_md5=$(echo "$remote_md5" | awk '{print $1}')
    
    if [[ "$local_md5" == "$remote_md5" ]]; then
        echo "    - $target_file [Unchanged]"
    else
        su - "${IRC_USER}" -c "scp -q -i ${SSH_KEY_PATH} $tmp_file ${IRC_USER}@${leaf}:$target_file" || true
        su - "${IRC_USER}" -c "ssh -q -i ${SSH_KEY_PATH} ${IRC_USER}@${leaf} 'chmod +x $target_file'" || true
        echo "    - $target_file [UPDATED]"
    fi
}

# --- 1. Path & FQDN Configuration Phase ---
echo "[*] Phase 1: Leaf Configuration"
read -p "Enter the FQDNs of the leaf nodes separated by spaces (e.g., leaf1.${DOMAIN} leaf2.${DOMAIN}): " -a LEAFS

if [[ ${#LEAFS[@]} -eq 0 ]]; then
    echo "ERROR: No leaf nodes provided."
    exit 1
fi

echo " -> Verifying leaf FQDNs..."
for leaf in "${LEAFS[@]}"; do
    if ! getent hosts "$leaf" >/dev/null 2>&1 && ! ping -c 1 -W 1 "$leaf" >/dev/null 2>&1; then
        echo " -> [ERROR] Could not resolve or reach FQDN: $leaf"
        exit 1
    fi
    echo " -> [OK] $leaf resolved successfully."
done

echo ""
echo "Where does the ircd reside on the leaf nodes?"
echo "  [1] /usr/local/ircd/ (Default)"
echo "  [2] /home/${IRC_USER}/Private/ircd/ (Encrypted Directory)"
echo "  [3] Custom Path"
read -p "Select option [1, 2, or 3]: " LEAF_OPT

if [[ "$LEAF_OPT" == "2" ]]; then
    LEAF_BASE="/home/${IRC_USER}/Private/ircd"
elif [[ "$LEAF_OPT" == "3" ]]; then
    read -p "Enter the full base path to the leaf ircd: " CUSTOM_PATH
    LEAF_BASE="${CUSTOM_PATH%/}"
else
    LEAF_BASE="/usr/local/ircd"
fi

LEAF_ETC_DIR="${LEAF_BASE}/etc"
LEAF_PID_FILE="${LEAF_BASE}/var/run/ircd.pid"

# --- 2. Connection, Authentication & Auto-Unjail Phase ---
echo ""
echo "[*] Phase 2: Authentication & Connection Testing"

if [ ! -f "$SSH_KEY_PATH" ]; then
    echo " -> Generating dedicated SSH key for ${IRC_USER}..."
    su - "${IRC_USER}" -c "ssh-keygen -t ed25519 -f ${SSH_KEY_PATH} -C 'cert-sync@${HUB}' -N ''" >/dev/null 2>&1
else
    echo " -> Dedicated SSH key [OK]"
fi

PUB_KEY=$(cat "${SSH_KEY_PATH}.pub")

for leaf in "${LEAFS[@]}"; do
    echo " -> Checking trust with ${leaf}..."
    set +e
    TEST_OUT=$(su - "${IRC_USER}" -c "ssh -q -o BatchMode=yes -o ConnectTimeout=5 -i ${SSH_KEY_PATH} ${IRC_USER}@${leaf} 'echo 1' 2>&1")
    TEST_CODE=$?
    set -e

    if [[ $TEST_CODE -eq 0 ]]; then
        echo "    [OK] Trust is established and key is open."
    elif [[ $TEST_CODE -eq 1 ]] || [[ "$TEST_OUT" == *"Rejected"* ]] || [[ "$TEST_OUT" == *"Interactive shell access denied"* ]]; then
        echo "    [!] Security wrapper detected. The key is currently jailed."
        echo "    -> Temporarily un-jailing the key to allow deployments..."
        
        echo "    Please enter the password for ${IRC_USER}@$leaf to unlock the environment:"
        su - "${IRC_USER}" -c "ssh ${IRC_USER}@${leaf} \"sed -i 's/^restrict,command=\\\"[^\\\"]*\\\" \?//' ~/.ssh/authorized_keys\"" || true
        
        if su - "${IRC_USER}" -c "ssh -q -o BatchMode=yes -o ConnectTimeout=5 -i ${SSH_KEY_PATH} ${IRC_USER}@${leaf} 'echo 1'" >/dev/null 2>&1; then
            echo "    [OK] Environment unlocked successfully."
        else
            echo "    [ERROR] Failed to unlock environment. Aborting."
            exit 1
        fi
    else
        echo "--------------------------------------------------------"
        echo " [ACTION REQUIRED] SSH Trust Not Established"
        echo "--------------------------------------------------------"
        echo "We need to push the sync key to $leaf."
        echo "Please open a NEW terminal window on $HUB and run:"
        echo ""
        echo "  su - ${IRC_USER}"
        echo "  ssh-copy-id -i ${SSH_KEY_PATH}.pub ${IRC_USER}@${leaf}"
        echo ""
        echo "Verify the fingerprint and enter the password when prompted."
        echo "--------------------------------------------------------"
        
        while true; do
            read -p "Type 'done' and press Enter after you have successfully copied the key: " WAIT_ANS
            if [[ "$WAIT_ANS" == "done" ]]; then
                if su - "${IRC_USER}" -c "ssh -q -o BatchMode=yes -o ConnectTimeout=5 -i ${SSH_KEY_PATH} ${IRC_USER}@${leaf} 'echo 1'" >/dev/null 2>&1; then
                    echo "    [OK] Trust successfully verified!"
                    break
                else
                    echo "    [!] Connection still failing. Please try again or check the terminal output."
                fi
            fi
        done
    fi
done

# --- 3. Verification & Options ---
echo ""
echo "[*] Phase 3: Deployment Options"
read -p "Do you want to apply the SSH security wrapper on the leaf nodes to prevent lateral execution? (y/n): " INSTALL_WRAPPER

echo ""
echo "Comparing existing configurations against v${VERSION}..."

# --- 4. Local Deployment (Hub) ---
echo ""
echo "[*] Phase 4: Deploying Local Configurations on Hub"

su - "${IRC_USER}" -c "mkdir -p ~/ssl-staging ~/logs && chmod 700 ~/ssl-staging"

LEAF_LIST=""
for l in "${LEAFS[@]}"; do LEAF_LIST+="\"$l\" "; done

TMP_PUSH="/tmp/push_certs.tmp"
cat << EOF > "$TMP_PUSH"
#!/usr/bin/env bash
set -euo pipefail
SERVERS=("localhost" $LEAF_LIST)
STAGING_DIR="/home/${IRC_USER}/ssl-staging"
CERT_FILE="bundle.pem"
KEY_FILE="privkey.pem"
SSH_KEY="/home/${IRC_USER}/.ssh/id_ed25519_cert_sync"
for server in "\${SERVERS[@]}"; do
    if [[ "\$server" == "localhost" ]]; then continue; fi
    su - ${IRC_USER} -c "scp -q -i \$SSH_KEY -p \$STAGING_DIR/\$CERT_FILE ${IRC_USER}@\$server:\$STAGING_DIR/\${CERT_FILE}.tmp"
    su - ${IRC_USER} -c "scp -q -i \$SSH_KEY -p \$STAGING_DIR/\$KEY_FILE ${IRC_USER}@\$server:\$STAGING_DIR/\${KEY_FILE}.tmp"
    su - ${IRC_USER} -c "ssh -q -i \$SSH_KEY ${IRC_USER}@\$server 'mv \$STAGING_DIR/\${CERT_FILE}.tmp \$STAGING_DIR/\$CERT_FILE && mv \$STAGING_DIR/\${KEY_FILE}.tmp \$STAGING_DIR/\$KEY_FILE'"
done
EOF
deploy_local_script "$TMP_PUSH" "/root/push_certs.sh" "root:root" "750"

TMP_APPLY="/tmp/apply_certs.tmp"
cat << EOF > "$TMP_APPLY"
#!/usr/bin/env bash
set -euo pipefail
IRCD_ETC_DIR="${HUB_ETC_DIR}"
PID_FILE="${HUB_PID_FILE}"
TARGET_CERT="${HUB_TARGET_CERT}"
TARGET_KEY="${HUB_TARGET_KEY}"
STAGING_DIR="/home/${IRC_USER}/ssl-staging"
if [[ ! -f "\$STAGING_DIR/bundle.pem" ]]; then exit 0; fi
if [[ "\$STAGING_DIR/bundle.pem" -nt "\$IRCD_ETC_DIR/\$TARGET_CERT" ]] || [[ ! -f "\$IRCD_ETC_DIR/\$TARGET_CERT" ]]; then
    if [[ -f "\$IRCD_ETC_DIR/\${TARGET_CERT}.bak" ]]; then
        chmod 600 "\$IRCD_ETC_DIR/\${TARGET_CERT}.bak.old" "\$IRCD_ETC_DIR/\${TARGET_KEY}.bak.old" 2>/dev/null || true
        cp -f "\$IRCD_ETC_DIR/\${TARGET_CERT}.bak" "\$IRCD_ETC_DIR/\${TARGET_CERT}.bak.old" 2>/dev/null || true
        cp -f "\$IRCD_ETC_DIR/\${TARGET_KEY}.bak" "\$IRCD_ETC_DIR/\${TARGET_KEY}.bak.old" 2>/dev/null || true
    fi
    if [[ -f "\$IRCD_ETC_DIR/\$TARGET_CERT" ]]; then
        chmod 600 "\$IRCD_ETC_DIR/\${TARGET_CERT}.bak" "\$IRCD_ETC_DIR/\${TARGET_KEY}.bak" 2>/dev/null || true
        cp -f "\$IRCD_ETC_DIR/\$TARGET_CERT" "\$IRCD_ETC_DIR/\${TARGET_CERT}.bak" 2>/dev/null || true
        cp -f "\$IRCD_ETC_DIR/\$TARGET_KEY" "\$IRCD_ETC_DIR/\${TARGET_KEY}.bak" 2>/dev/null || true
    fi
    chmod 600 "\$IRCD_ETC_DIR/\$TARGET_CERT" "\$IRCD_ETC_DIR/\$TARGET_KEY" 2>/dev/null || true
    cp -f "\$STAGING_DIR/bundle.pem" "\$IRCD_ETC_DIR/\$TARGET_CERT"
    cp -f "\$STAGING_DIR/privkey.pem" "\$IRCD_ETC_DIR/\$TARGET_KEY"
    chown ${IRC_USER}:${IRC_USER} "\$IRCD_ETC_DIR/\$TARGET_CERT" "\$IRCD_ETC_DIR/\$TARGET_KEY"
    chmod 400 "\$IRCD_ETC_DIR/\$TARGET_CERT" "\$IRCD_ETC_DIR/\$TARGET_KEY"
    if [[ -f "\$PID_FILE" ]]; then kill -HUP "\$(cat "\$PID_FILE")"; fi
fi
EOF
deploy_local_script "$TMP_APPLY" "/root/apply_certs.sh" "root:root" "750"

TMP_DEPLOY="/tmp/acme_irc_deploy.tmp"
cat << EOF > "$TMP_DEPLOY"
#!/usr/bin/env bash
set -euo pipefail
STAGING_DIR="/home/${IRC_USER}/ssl-staging"
ACME_DIR="/root/.acme.sh/${DOMAIN}_ecc"
cat "\$ACME_DIR/${DOMAIN}.cer" > "\$STAGING_DIR/bundle.pem"
cat "\$ACME_DIR/ca.cer" >> "\$STAGING_DIR/bundle.pem"
cp "\$ACME_DIR/${DOMAIN}.key" "\$STAGING_DIR/privkey.pem"
chown ${IRC_USER}:${IRC_USER} "\$STAGING_DIR/"*.pem
chmod 600 "\$STAGING_DIR/"*.pem
/root/push_certs.sh
EOF
deploy_local_script "$TMP_DEPLOY" "/root/acme_irc_deploy.sh" "root:root" "750"

(crontab -l 2>/dev/null | grep -v 'apply_certs.sh'; echo '*/15 * * * * /root/apply_certs.sh >> /dev/null 2>&1') | crontab -

# --- 5. Remote Deployment Preparation (Leafs) ---
echo ""
echo "[*] Phase 5: Deploying Remote Configurations on Leafs"

LEAF_APPLY_TMP="/tmp/leaf_apply_certs.tmp"
cat << EOF > "$LEAF_APPLY_TMP"
#!/usr/bin/env bash
set -euo pipefail
IRCD_ETC_DIR="${LEAF_ETC_DIR}"
PID_FILE="${LEAF_PID_FILE}"
TARGET_CERT="${LEAF_TARGET_CERT}"
TARGET_KEY="${LEAF_TARGET_KEY}"
STAGING_DIR="/home/${IRC_USER}/ssl-staging"
if [[ ! -d "\$IRCD_ETC_DIR" ]]; then exit 1; fi
if [[ ! -f "\$STAGING_DIR/bundle.pem" ]]; then exit 0; fi

if [[ "\$STAGING_DIR/bundle.pem" -nt "\$IRCD_ETC_DIR/\$TARGET_CERT" ]] || [[ ! -f "\$IRCD_ETC_DIR/\$TARGET_CERT" ]]; then
    if [[ -f "\$IRCD_ETC_DIR/\${TARGET_CERT}.bak" ]]; then
        chmod 600 "\$IRCD_ETC_DIR/\${TARGET_CERT}.bak.old" "\$IRCD_ETC_DIR/\${TARGET_KEY}.bak.old" 2>/dev/null || true
        cp -f "\$IRCD_ETC_DIR/\${TARGET_CERT}.bak" "\$IRCD_ETC_DIR/\${TARGET_CERT}.bak.old" 2>/dev/null || true
        cp -f "\$IRCD_ETC_DIR/\${TARGET_KEY}.bak" "\$IRCD_ETC_DIR/\${TARGET_KEY}.bak.old" 2>/dev/null || true
    fi
    if [[ -f "\$IRCD_ETC_DIR/\$TARGET_CERT" ]]; then
        chmod 600 "\$IRCD_ETC_DIR/\${TARGET_CERT}.bak" "\$IRCD_ETC_DIR/\${TARGET_KEY}.bak" 2>/dev/null || true
        cp -f "\$IRCD_ETC_DIR/\$TARGET_CERT" "\$IRCD_ETC_DIR/\${TARGET_CERT}.bak" 2>/dev/null || true
        cp -f "\$IRCD_ETC_DIR/\$TARGET_KEY" "\$IRCD_ETC_DIR/\${TARGET_KEY}.bak" 2>/dev/null || true
    fi
    chmod 600 "\$IRCD_ETC_DIR/\$TARGET_CERT" "\$IRCD_ETC_DIR/\$TARGET_KEY" 2>/dev/null || true
    cp -f "\$STAGING_DIR/bundle.pem" "\$IRCD_ETC_DIR/\$TARGET_CERT"
    cp -f "\$STAGING_DIR/privkey.pem" "\$IRCD_ETC_DIR/\$TARGET_KEY"
    chmod 400 "\$IRCD_ETC_DIR/\$TARGET_CERT" "\$IRCD_ETC_DIR/\$TARGET_KEY"
    if [[ -f "\$PID_FILE" ]]; then kill -HUP "\$(cat "\$PID_FILE")"; fi
fi
EOF

LEAF_WRAPPER_TMP="/tmp/leaf_wrapper.tmp"
cat << EOF > "$LEAF_WRAPPER_TMP"
#!/usr/bin/env bash
if [[ -z "\$SSH_ORIGINAL_COMMAND" ]]; then echo 'Interactive shell access denied.'; exit 1; fi
EXPECTED_RENAME_CMD="mv /home/${IRC_USER}/ssl-staging/bundle.pem.tmp /home/${IRC_USER}/ssl-staging/bundle.pem && mv /home/${IRC_USER}/ssl-staging/privkey.pem.tmp /home/${IRC_USER}/ssl-staging/privkey.pem"
case "\$SSH_ORIGINAL_COMMAND" in
    scp\ -p\ -t\ /home/${IRC_USER}/ssl-staging/bundle.pem.tmp|scp\ -p\ -t\ /home/${IRC_USER}/ssl-staging/privkey.pem.tmp|*"sftp-server"*|"\$EXPECTED_RENAME_CMD")
        eval "\$SSH_ORIGINAL_COMMAND"
        ;;
    *)
        echo "[\$(date)] Rejected command: \$SSH_ORIGINAL_COMMAND" >> /home/${IRC_USER}/logs/rejected_ssh.log
        exit 1
        ;;
esac
EOF

for leaf in "${LEAFS[@]}"; do
    echo " -> Checking ${leaf}..."
    su - "${IRC_USER}" -c "ssh -q -i ${SSH_KEY_PATH} ${IRC_USER}@${leaf} 'mkdir -p ~/ssl-staging ~/logs && chmod 700 ~/ssl-staging'" || true
    
    deploy_remote_script "$LEAF_APPLY_TMP" "$leaf" "/home/${IRC_USER}/apply_certs.sh"
    
    if [[ "$INSTALL_WRAPPER" == "y" || "$INSTALL_WRAPPER" == "Y" ]]; then
        deploy_remote_script "$LEAF_WRAPPER_TMP" "$leaf" "/home/${IRC_USER}/ssh_cert_wrapper.sh"
        su - "${IRC_USER}" -c "ssh -q -i ${SSH_KEY_PATH} ${IRC_USER}@${leaf} \"sed -i '/cert-sync@${HUB}/d' ~/.ssh/authorized_keys 2>/dev/null || true\"" || true
        su - "${IRC_USER}" -c "ssh -q -i ${SSH_KEY_PATH} ${IRC_USER}@${leaf} \"echo 'restrict,command=\\\"/home/${IRC_USER}/ssh_cert_wrapper.sh\\\" ${PUB_KEY}' >> ~/.ssh/authorized_keys\"" || true
        echo "    - authorized_keys [Configured and Jailed]"
    else
        echo "    - authorized_keys [Skipped (Unrestricted)]"
    fi

    su - "${IRC_USER}" -c "ssh -q -i ${SSH_KEY_PATH} ${IRC_USER}@${leaf} \"(crontab -l 2>/dev/null | grep -v 'apply_certs.sh'; echo '*/15 * * * * /home/${IRC_USER}/apply_certs.sh >> /dev/null 2>&1') | crontab -\"" || true
    echo "    - crontab [Configured]"
done

rm -f "$LEAF_APPLY_TMP" "$LEAF_WRAPPER_TMP"

# --- Final Instructions ---
echo ""
echo "========================================================"
echo " 2600net SSL SYNCHRONIZATION: SETUP COMPLETE "
echo "========================================================"
echo ""
echo "1. ONE-TIME CONFIGURATION (Connect acme.sh to hook):"
echo "   Run this ONCE on ${HUB} to link the deployment hook:"
echo ""
echo "   /root/.acme.sh/acme.sh --install-cert -d ${DOMAIN} --ecc \\"
echo "       --reloadcmd \"/root/acme_irc_deploy.sh\""
echo ""
echo "2. IMMEDIATE FORCE-DEPLOY (Skip the cronjob and update NOW):"
echo "   Run this to instantly compile, push, and SIGHUP the network:"
echo ""
echo "   /root/acme_irc_deploy.sh && /root/apply_certs.sh && \\"
for leaf in "${LEAFS[@]}"; do
echo -n "   su - ${IRC_USER} -c \"ssh $leaf '/home/${IRC_USER}/apply_certs.sh'\" && "
done
echo "echo 'Deployment Complete'"
echo "========================================================"

