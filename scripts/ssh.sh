#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Script: ssh-hardening-v13.sh
# Purpose: Arch Linux SSH hardening (Production Grade)
# Theme: Professional Monochrome (Boxed Layout + Security Context)
# -----------------------------------------------------------------------------

set -eu -o pipefail

# Global State Variables (Initialized for Trap)
KEY_PATH=""
KEY_NAME=""
TARGET_HOME=""
TEMP_DIR=""
SERVER_PID=""
CUSTOM_CONF=""
ARCH_CONF=""
PAM_CONF=""
TIMESTAMP=""
SCRIPT_SUCCESS="false" # Default to failure until the very end

# ============================================
# Block: Style Definition (Monochrome)
# ============================================

# Strictly White (255) and Black (0) or Gray (244)
C_FG="255"       # White text (Primary)
C_DIM="244"      # Gray (Secondary/Info)
C_BG_SEL="255"   # White Background (Selection)
C_FG_SEL="0"     # Black Foreground (Selection)
C_BORDER="255"   # White Borders

# Function to ensure consistent Header on every screen
show_header() {
    clear
    gum style \
        --border double --border-foreground "$C_BORDER" \
        --padding "0 2" --margin "1" \
        --foreground "$C_FG" \
        -- \
        "Arch Linux SSH Hardening"
}

# Wrapper for the boxed info style
show_box() {
    gum style \
        --border normal --border-foreground "$C_BORDER" \
        --padding "1 2" --margin "1" \
        --foreground "$C_FG" \
        -- \
        "$@"
}

# ============================================
# Block: Root Check
# ============================================

LOCKFILE="/run/ssh-hardening.lock"

if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run with sudo." >&2
    exit 1
fi

# ============================================
# Block: Signal Trapping & Cleanup
# ============================================

LOCKFILE="/run/ssh-hardening.lock"

cleanup() {
    # 1. Always remove the lockfile
    rm -f "$LOCKFILE" 2>/dev/null

    # 2. Stop Background Processes (HTTP Server)
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" >/dev/null 2>&1 || true
    fi

    # 3. Cleanup Temporary Directories
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi

    # 4. Handle "Abort/Ctrl+C" Scenarios
    if [ "$SCRIPT_SUCCESS" != "true" ]; then
        # Only show the cleanup message if we actually have things to clean
        if [ -n "$KEY_NAME" ] || [ -n "$CUSTOM_CONF" ]; then
            echo ""
            gum style --foreground 196 ">> Interrupted. Cleaning up generated files..."
        fi

        # Remove generated keys (Private & Public)
        if [ -n "$KEY_PATH" ]; then
            rm -f "$KEY_PATH" "${KEY_PATH}.pub"
            # Remove authorized_keys entry if we just added it? 
            # (Complex to undo perfectly with sed, but strictly removing keys renders the entry useless)
        fi
        
        # Remove temporary copies in root/user home
        if [ -n "$TARGET_HOME" ] && [ -n "$KEY_NAME" ]; then
             rm -f "$TARGET_HOME/$KEY_NAME"
             rm -f "$TARGET_HOME/${KEY_NAME}.pub"
        fi

        # Remove applied configs
        if [ -n "$CUSTOM_CONF" ]; then
            rm -f "$CUSTOM_CONF"
        fi

        # Restore Backups (If variables are set and backups exist)
        if [ -n "$ARCH_CONF" ] && [ -n "$TIMESTAMP" ] && [ -f "${ARCH_CONF}.backup.${TIMESTAMP}" ]; then
            mv "${ARCH_CONF}.backup.${TIMESTAMP}" "$ARCH_CONF"
        fi

        if [ -n "$PAM_CONF" ] && [ -n "$TIMESTAMP" ] && [ -f "${PAM_CONF}.backup.${TIMESTAMP}" ]; then
            mv "${PAM_CONF}.backup.${TIMESTAMP}" "$PAM_CONF"
        fi
    fi
}

# Trap EXIT (Normal end), SIGINT (Ctrl+C), SIGTERM (Kill)
trap cleanup EXIT SIGINT SIGTERM

if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run with sudo." >&2
    exit 1
fi

exec 3>"$LOCKFILE"
if ! flock -n 3; then
    echo "Error: Another instance is already running." >&2
    exit 1
fi

# ============================================
# Block: Gum Bootstrap
# ============================================

clear
if ! pacman -Q gum &> /dev/null; then
    echo "Requirement: 'gum' is not installed."
    read -p "Install 'gum' now? [y/N] " response
    case $response in
    [yY]* )
	    echo "Installing 'gum'..."
	    if pacman -Sy --needed --noconfirm gum > /dev/null 2>&1; then
		    echo "'gum' installed successfully."
		    sleep 1
		else
			echo "'gum' installation failed. Please run 'sudo pacman -S --needed gum' manually to check errors."
			exit 1
		fi
    ;;
    [nN]* ) 
	    echo "Aborted. This script requires 'gum' to function."
	    exit 1
    ;;
    *) 
	    exit 1
    ;;
    esac
fi

# ============================================
# Block: System Update & Dependencies
# ============================================

show_header
show_box \
    "System Maintenance" \
    "" \
    "Context: Updating the system is critical to patch known vulnerabilities." \
    "Command: pacman -Syu"

if gum confirm --prompt.foreground="$C_FG" --selected.background="$C_BG_SEL" --selected.foreground="$C_FG_SEL" "Proceed with update?"; then
    echo "Updating system..."
    if pacman -Syu --noconfirm > /dev/null 2>&1; then
        echo "System updated."
        sleep 1
    else
        echo "Update failed. Please run 'sudo pacman -Syu' manually to fix errors."
        exit 1
    fi
else
    echo "Aborted. System update required."
    exit 1
fi

show_header
show_box \
    "Dependencies Check" \
    "" \
    "Context: These dependencies are essential for implementing Multi-Factor Authentication (MFA) and rendering QR codes for mobile pairing." \
    "Pkgs:    openssh, libpam-google-authenticator, qrencode, iproute2, python3"

if gum confirm --prompt.foreground="$C_FG" --selected.background="$C_BG_SEL" --selected.foreground="$C_FG_SEL" "Proceed with installation?"; then
	echo "Installing depedencies..."
	if pacman -S --needed --noconfirm openssh libpam-google-authenticator qrencode iproute2 python > /dev/null 2>&1; then
		echo "Dependencies installed successfully."
		sleep 1
	else
		echo "Dependencies installation failed. Please run 'sudo pacman -S --needed openssh libpam-google-authenticator qrencode iproute2 python' manually to fix errors."
		exit 1
	fi
else
    echo "Aborted. These tools are required to proceed."
    exit 1
fi

# ============================================
# Block: Configuration Check
# ============================================

show_header
if ! systemctl is-active --quiet sshd; then
    show_box \
        "Service Status" \
        "" \
        "Context: The daemon is currently inactive." \
        "Action:  Initialize sshd.service"
        
    if gum confirm --prompt.foreground="$C_FG" --selected.background="$C_BG_SEL" --selected.foreground="$C_FG_SEL" "Start service?"; then
echo "Starting SSH service..."
		if systemctl enable --now sshd > /dev/null 2>&1; then
			echo "The SSH service started successfully."
			sleep 1
		else
			echo "The SSH service start failed. Please run 'sudo systemctl status sshd' manually to fix errors."
			exit 1
		fi
	else
    echo "Aborted. The SSH must be running to proceed."
    exit 1
	fi
else
	# Port Detection
	if ss -tnlp | grep 'sshd' > /dev/null 2>&1; then
	CURRENT_PORT=$(ss -tnlp | grep 'sshd' | awk '{print $4}' | cut -d ':' -f 2 | head -n 1)
	else
		echo "The SSH service is active but not listening on any port. Please check your sshd_config or socket status."
		exit 1
	fi
fi

# Network & User Detection
echo "Analyzing network interfaces and user list..."

# Get the main outbound IP
CURRENT_IP=$(ip route get 1.1.1.1 | awk '{print $7}' | head -n 1)

# Get all bindable IPs (excluding localhost)
ACTIVE_IPS=($(ip -4 addr show | grep 'inet' | awk '{print $2}' | cut -d '/' -f 1 | grep -v '127.0.0.1'))

# Get valid users (UID >= 1000, filtering out nologin shells)
USERS_LIST=($(awk -F: '$3 >= 1000 && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd
))
sleep 1

echo "Configuration check complete."
sleep 1

# ============================================
# Block: Interactive Setup
# ============================================

# --- Network ---
show_header
show_box \
    "Network Binding" \
    "" \
    "Context: Restricts SSH to a specific interface." \
    "Why:     Prevents exposure on public/untrusted interfaces."

gum style --foreground "$C_FG" "Select Listen Interface:"
BIND_IP=$(gum choose --header="" --cursor.foreground="$C_DIM" --selected.foreground="$C_FG_SEL" --selected.background="$C_BG_SEL" "${ACTIVE_IPS[@]}")

# --- User & Group ---
while true; do
    show_header
    show_box \
        "Access Control Lists (ACL)" \
        "" \
        "Context: Dedicate a specific UNIX group for SSH access." \
        "Why:     Enforces 'AllowGroups', rejecting all others."

    gum style --foreground "$C_FG" "Define Access Group:"
    SSH_GROUP=$(gum input --cursor.foreground="$C_DIM" --placeholder "e.g., sshusers")
    
    if [[ ! "$SSH_GROUP" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        gum style --foreground "$C_FG" "Error: Invalid group format."
        sleep 2
        continue
    fi
    
    if ! getent group "$SSH_GROUP" >/dev/null; then
        groupadd "$SSH_GROUP"
        gum style --foreground "$C_FG" "Group '$SSH_GROUP' created."
        break
    else
        if gum confirm --prompt.foreground="$C_FG" --selected.background="$C_BG_SEL" --selected.foreground="$C_FG_SEL" "Group '$SSH_GROUP' already exists. Use it?"; then
            break
        else
            continue
        fi
    fi
done

show_header
show_box \
    "Identity Management" \
    "" \
    "Context: Select the primary user for remote operations." \
    "Why:     Root login will be disabled (Least Privilege)."

gum style --foreground "$C_FG" "Select Authorized User:"
TARGET_USER=$(gum choose --header="" --cursor.foreground="$C_DIM" --selected.foreground="$C_FG_SEL" --selected.background="$C_BG_SEL" "${USERS_LIST[@]}")
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d ':' -f 6)
usermod -aG "$SSH_GROUP" "$TARGET_USER"

# --- Port ---
while true; do
    show_header
    show_box \
        "Port Obfuscation" \
        "" \
        "Context: Change default port (22) to custom range." \
        "Why:     Drastically reduces noise from automated botnets." \
        "Current Port: $CURRENT_PORT"
    
    gum style --foreground "$C_FG" "Assign New Port (1024-65535):"
    SSH_PORT=$(gum input --cursor.foreground="$C_DIM" --placeholder "e.g., 2222")

    if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && [ "$SSH_PORT" -ge 1024 ] && [ "$SSH_PORT" -le 65535 ]; then
        break
    else
        gum style --foreground "$C_FG" "Error: Invalid port range."
        sleep 2
    fi
done

# --- Keys & Auth ---
while true; do
    show_header
    show_box \
        "Cryptography Setup" \
        "" \
        "Context: Generating Ed25519 Elliptic Curve keys." \
        "Why:     Ed25519 offers superior security/speed over RSA."
    
    gum style --foreground "$C_FG" "Input Private Key Filename:"
    KEY_NAME=$(gum input --cursor.foreground="$C_DIM" --placeholder "e.g., id_$TARGET_USER")
    
    if [[ ! "$KEY_NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        gum style --foreground "$C_FG" "Error: Invalid filename string."
        sleep 2
        continue
    fi

    FULL_KEY_PATH="$TARGET_HOME/.ssh/$KEY_NAME"
    
    if [ -f "$FULL_KEY_PATH" ]; then
        gum style --foreground "$C_FG" "Conflict: File exists."
        ACTION=$(gum choose --header="" --cursor.foreground="$C_DIM" --selected.foreground="$C_FG_SEL" --selected.background="$C_BG_SEL" "Overwrite existing key" "Choose a different name")
        if [[ "$ACTION" == "Overwrite existing key" ]]; then
            rm -f "$FULL_KEY_PATH" "${FULL_KEY_PATH}.pub"
            break
        else
            continue 
        fi
    else
        break
    fi
done

show_header
show_box \
    "Key Security" \
    "" \
    "Context: Encrypting the private key at rest." \
    "Why:     Prevents key usage if the local file is stolen."

if gum confirm --prompt.foreground="$C_FG" --selected.background="$C_BG_SEL" --selected.foreground="$C_FG_SEL" "Set key passphrase?"; then
    HAS_PASSPHRASE="yes"
else
    HAS_PASSPHRASE="no"
fi

show_header
show_box \
    "Multi-Factor Authentication" \
    "" \
    "Context: Time-Based One-Time Password (TOTP)." \
    "Why:     Mitigates credential stuffing and phishing attacks."

if gum confirm --prompt.foreground="$C_FG" --selected.background="$C_BG_SEL" --selected.foreground="$C_FG_SEL" "Enable Google Authenticator?"; then
    ENABLE_2FA="yes"
else
    ENABLE_2FA="no"
fi

if [[ "$ENABLE_2FA" == "yes" ]]; then
    show_header
    show_box \
        "Authentication Logic" \
        "" \
        "Context: Define the chain of trust required to log in." \
        "Why:     'Full Stack' provides maximum security depth."

    gum style --foreground "$C_FG" "Select Auth Combination:"
    AUTH_CHOICE=$(gum choose --header="" --cursor.foreground="$C_DIM" --selected.foreground="$C_FG_SEL" --selected.background="$C_BG_SEL" \
        "Key + Password + OTP" \
        "Key + OTP" \
        "Password + OTP")
    
    case "$AUTH_CHOICE" in
        "Key + Password + OTP")
            AUTH_METHODS="publickey,keyboard-interactive"; PASS_VAL="no"; KBD_VAL="yes" PAM_TYPE="full_stack" ;;
        "Key + OTP")
            AUTH_METHODS="publickey,keyboard-interactive"; PASS_VAL="no"; KBD_VAL="yes"; PAM_TYPE="code_only" ;;
        "Password + OTP")
            AUTH_METHODS="keyboard-interactive"; PASS_VAL="no"; KBD_VAL="yes"; PAM_TYPE="full_stack" ;;
    esac
else
    show_header
    show_box \
        "Authentication Logic" \
        "" \
        "Context: Standard key-based authentication."
    
    AUTH_CHOICE=$(gum choose --header="" --cursor.foreground="$C_DIM" --selected.foreground="$C_FG_SEL" --selected.background="$C_BG_SEL" \
        "Key Only" \
        "Key + System Password")
        
    case "$AUTH_CHOICE" in
        "Key Only") AUTH_METHODS="publickey"; PASS_VAL="no"; KBD_VAL="no" ;;
        "Key + System Password") AUTH_METHODS="publickey,password"; PASS_VAL="yes"; KBD_VAL="no" ;;
    esac
fi

# ============================================
# Block: Key Generation
# ============================================

KEY_PATH="$TARGET_HOME/.ssh/$KEY_NAME"
KEY_PASS=""

if [[ "$HAS_PASSPHRASE" == "yes" ]]; then
    while true; do
        show_header
        # Re-display box for context even in loop
        show_box \
            "Credential Setup" \
            "" \
            "Action: Define a strong passphrase for the key."
            
        USER_PASS=$(gum input --password --cursor.foreground="$C_DIM" --placeholder "Input Passphrase")
        
        if [ -z "$USER_PASS" ]; then
             echo "Error: Passphrase required."
             sleep 1
             continue
        fi
        
        show_header
        show_box \
            "Credential Setup" \
            "" \
            "Action: Passphrase verification."
            
        USER_PASS_CONFIRM=$(gum input --password --cursor.foreground="$C_DIM" --placeholder "Confirm Passphrase")

        if [[ "$USER_PASS" == "$USER_PASS_CONFIRM" ]]; then
            KEY_PASS="$USER_PASS"
            break
        else
            echo "Error: Mismatch."
            sleep 1
        fi
    done
fi

# Directory Setup
sudo -u "$TARGET_USER" mkdir -p "$TARGET_HOME/.ssh"
sudo -u "$TARGET_USER" chmod 700 "$TARGET_HOME/.ssh"

# Generate Key
show_header
show_box "Key Generation" "" "Status: Generating Ed25519 pairs..."
sudo -u "$TARGET_USER" ssh-keygen -t ed25519 -f "$KEY_PATH" -N "$KEY_PASS" -C "$TARGET_USER@$(hostname)" > /dev/null

# Authorize Key
if [ ! -f "$TARGET_HOME/.ssh/authorized_keys" ]; then
    sudo -u "$TARGET_USER" touch "$TARGET_HOME/.ssh/authorized_keys"
    sudo -u "$TARGET_USER" chmod 600 "$TARGET_HOME/.ssh/authorized_keys"
fi

cat "${KEY_PATH}.pub" >> "$TARGET_HOME/.ssh/authorized_keys"

# Final Permission Enforcement
chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.ssh/authorized_keys"
chmod 600 "$TARGET_HOME/.ssh/authorized_keys"

unset USER_PASS
unset USER_PASS_CONFIRM
unset KEY_PASS

# Final Confirmation
show_header
if [ -f "$KEY_PATH" ]; then
    show_box \
        "Deployment Successful" \
        "" \
        "Identity: $KEY_NAME" \
        "Account:  $TARGET_USER" \
        "Path:     $TARGET_HOME/.ssh/$KEY_NAME"
    sleep 2
else
    echo "Critical Error: Key generation failed."
    exit 1
fi

if [[ "$ENABLE_2FA" == "yes" ]]; then
    show_header
    show_box \
        "MFA Registration" \
        "" \
        "Context: Scan the QR code below immediately." \
        "App:     Google Authenticator / Authy / Ente"
        
    # Pause briefly to let user read the box before QR floods screen
    sleep 2
    sudo -u "$TARGET_USER" google-authenticator -t -d -f -Q utf8 -r 3 -R 30 -w 3
fi

# ============================================
# Block: Key Retrieval (HTTP or SCP)
# ============================================

show_header
show_box \
    "Access Recovery" \
    "" \
    "Context: The SSH service is still active on the OLD configuration." \
    "Risk:    Reloading SSH before retrieving the private key will lock you out." \
    "Current IP and Port: $CURRENT_IP:$CURRENT_PORT"

gum style --foreground "$C_FG" "Select retrieval method:"
RETRIEVAL=$(gum choose --header="" --cursor.foreground="$C_DIM" --selected.foreground="$C_FG_SEL" --selected.background="$C_BG_SEL" \
    "Manual SCP Command      (Encrypted/Secure)" \
    "Temporary Web Server    (Unencrypted/Fast)")

if [[ "$RETRIEVAL" == *"Web Server"* ]]; then
    # Setup temp dir
    HTTP_PORT="8888"
    TEMP_DIR=$(mktemp -d)
    
    # We copy the key to a temp dir to avoid exposing the whole home directory
    cp "$TARGET_HOME/.ssh/$KEY_NAME" "$TEMP_DIR/"
    chmod 644 "$TEMP_DIR/$KEY_NAME"
    
    # Start Python Server SILENTLY (No logs to stdout/stderr)
    pushd "$TEMP_DIR" >/dev/null
    python3 -m http.server "$HTTP_PORT" >/dev/null 2>&1 &
    SERVER_PID=$!
    popd >/dev/null
    
    DOWNLOAD_URL="http://$CURRENT_IP:$HTTP_PORT/$KEY_NAME"
    
    show_header
    show_box \
        "Data Exfiltration (Temporary)" \
        "" \
        "Context: Offering file via ephemeral HTTP server." \
        "Warning: This transfer is unencrypted (Cleartext)." \
        "URL:     $DOWNLOAD_URL"
    
    echo ""
    gum style --foreground "$C_FG" "Scan QR to download:"
    # QR Encode to stdout
    qrencode -t ANSIUTF8 "$DOWNLOAD_URL"
    echo ""
    
    if ! gum confirm --prompt.foreground="$C_FG" --selected.background="$C_BG_SEL" --selected.foreground="$C_FG_SEL" "File retrieved successfully?"; then
        # Cleanup on failure/cancel
        kill "$SERVER_PID" || true
        rm -rf "$TEMP_DIR"
        echo "Operation aborted. System configuration remains unchanged."
        exit 0
    fi
    
    # Cleanup on success
    kill "$SERVER_PID" || true
    rm -rf "$TEMP_DIR"

else
    # Manual SCP
    # Constructing the precise command for the user
    SCP_CMD="scp -P $CURRENT_PORT $TARGET_USER@$CURRENT_IP:$TARGET_HOME/.ssh/$KEY_NAME ./"

    show_header
    show_box \
        "Secure Copy Protocol" \
        "" \
        "Context: Use the existing encrypted SSH tunnel to fetch the key." \
        "Command: See below."

    echo ""
    gum style --padding "1 2" --margin "1" --border normal --foreground "$C_FG" -- "$SCP_CMD"
    echo ""
    
    if ! gum confirm --prompt.foreground="$C_FG" --selected.background="$C_BG_SEL" --selected.foreground="$C_FG_SEL" "File retrieved successfully?"; then
        echo "Operation aborted. System configuration remains unchanged."
        exit 0
    fi
fi

# ============================================
# Block: Configuration Application
# ============================================

TIMESTAMP=$(date +%Y%m%d-%H%M%S)

MAIN_SSH_CONF="/etc/ssh/sshd_config"
CUSTOM_CONF="/etc/ssh/sshd_config.d/99-hardening.conf"
ARCH_CONF="/etc/ssh/sshd_config.d/99-archlinux.conf"
PAM_CONF="/etc/pam.d/sshd"

show_header
show_box \
    "Configuration & Backups" \
    "" \
    "Context:  Applying hardening rules and patching vendor defaults." \
    "BackupID: $TIMESTAMP"

# Ensure Include exists in main config
# Arch Linux SSHD config usually includes this by default, but we enforce it.
if ! grep -q "^Include /etc/ssh/sshd_config.d/\*.conf" "$MAIN_SSH_CONF"; then
    # Create backup with timestamp
    cp "$MAIN_SSH_CONF" "${MAIN_SSH_CONF}.backup.${TIMESTAMP}"
    sed -i '1s/^/Include \/etc\/ssh\/sshd_config.d\/*.conf\n/' "$MAIN_SSH_CONF"
fi

# Handle 99-archlinux.conf
if [ -f "$ARCH_CONF" ]; then
    cp "$ARCH_CONF" "${ARCH_CONF}.backup.${TIMESTAMP}"
    
    # Replace existing line or append if missing to avoid conflicts
    if grep -q "KbdInteractiveAuthentication" "$ARCH_CONF"; then
        sed -i "s/^KbdInteractiveAuthentication.*/KbdInteractiveAuthentication $KBD_VAL/" "$ARCH_CONF"
    else
        echo "KbdInteractiveAuthentication $KBD_VAL" >> "$ARCH_CONF"
    fi
fi

# 3. Create our Hardening Drop-in
cat > "$CUSTOM_CONF" << EOF
# Hardened SSH Configuration (ssh-hardening)
# Generated on: $(date)

# Network & Protocol
Port $SSH_PORT
ListenAddress $BIND_IP
Protocol 2

# Session Management
LoginGraceTime 30
MaxAuthTries 3
MaxSessions 5
ClientAliveInterval 300
ClientAliveCountMax 2

# Access Control
PermitRootLogin no
PermitEmptyPasswords no
PasswordAuthentication $PASS_VAL
KbdInteractiveAuthentication $KBD_VAL
AuthenticationMethods $AUTH_METHODS
AllowGroups $SSH_GROUP

# PAM Integration
UsePAM yes

# Cryptographic Hardening (Mozilla Modern / SSH-Audit Compliant)
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com

# Feature Reduction (Attack Surface Reduction)
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
Compression no
LogLevel VERBOSE
EOF

sleep 2

# 4. Handle PAM Configuration
if [[ "$ENABLE_2FA" == "yes" ]]; then
    
    show_header
    show_box \
        "PAM Reconfiguration" \
        "" \
        "Context: Injecting Google Authenticator module into authentication stack." \
        "File:    $PAM_CONF"
        
    cp "$PAM_CONF" "${PAM_CONF}.backup.${TIMESTAMP}"
    
    if [[ "$PAM_TYPE" == "code_only" ]]; then
        # Configuration for Key + TOTP (No Password)
        cat > "$PAM_CONF" << PAMEOF
#%PAM-1.0
auth required pam_google_authenticator.so nullok
account required pam_nologin.so
account include system-auth
session include system-auth
password include system-auth
PAMEOF

    else
        # Configuration for Key + Password + TOTP (Full Stack)
        cat > "$PAM_CONF" << PAMEOF
#%PAM-1.0
auth required pam_unix.so try_first_pass
auth required pam_google_authenticator.so nullok
account required pam_nologin.so
account include system-auth
session include system-auth
password include system-auth
PAMEOF
    fi
fi

sleep 2

# ============================================
# Block: Restart & Validation
# ============================================

show_header
show_box \
    "Syntax Validation" \
    "" \
    "Action: Executing 'sshd -t' to verify configuration integrity."

if sshd -t; then
    
    # Apply Changes
    systemctl restart sshd
    
    # Security Cleanup
    # Remove any temporary private key copies left in the user root (keep only .ssh/)
    rm -f "$TARGET_HOME/$KEY_NAME"
    rm -f "$TARGET_HOME/${KEY_NAME}.pub"

    # 3. Final Summary
    show_header
    show_box \
        "Hardening Complete" \
        "" \
        "Status:  Service restarted successfully." \
        "Cleanup: Temporary key files removed from filesystem." \
        "Changes: Applied to the following files:"

    # List modified files clearly
    gum style --foreground "$C_DIM" \
        "  -> $CUSTOM_CONF" \
        "  -> $ARCH_CONF" \
        "  -> $PAM_CONF"
        
    sleep 2
    
    echo ""
    
    # 4. Connection Instructions
    show_box \
        "New Connection Command" \
        "" \
        "Copy and save the command below:"

    echo ""
    gum style \
        --border normal \
        --border-foreground "$C_BORDER" \
        --padding "1 2" \
        --margin "1"
        --foreground "$C_FG" \
        --bold \
        "ssh -i $KEY_NAME -p $SSH_PORT $TARGET_USER@$BIND_IP"
    echo ""
    
    # Mark as success so the trap does not delete the new config/keys
    SCRIPT_SUCCESS="true"
    
    # Close the lock file descriptor before exit (optional but good practice)
    exec 3>&-
    
    exit 0

else
    # ============================================
    # Failure Branch: Auto-Rollback
    # ============================================
    
    gum style --foreground "$C_FG" "Validation Failed. Initiating rollback..."
    
    # Remove the new custom config
    rm -f "$CUSTOM_CONF"
    
    # Restore Arch Linux config if backed up
    if [ -f "${ARCH_CONF}.backup.${TIMESTAMP}" ]; then
        mv "${ARCH_CONF}.backup.${TIMESTAMP}" "$ARCH_CONF"
    fi
    
    # Restore PAM config if backed up
    if [ -f "${PAM_CONF}.backup.${TIMESTAMP}" ]; then
        mv "${PAM_CONF}.backup.${TIMESTAMP}" "$PAM_CONF"
    fi
    
    show_header
    show_box \
        "Critical Error" \
        "" \
        "Status:   Configuration invalid. SSHD did not restart." \
        "Action:   Changes have been reverted." \
        "Backups:  Restored from timestamp $TIMESTAMP."
    
    exit 1
fi
