#!/usr/bin/env bash
#===========================================================================================
# CloudStack 4.20 (Mgmt + KVM) on Ubuntu 22/24 Auto Installer - PRODUCTION READY v2.1
# Author: https://github.com/abdessalllam
# Version: 2.1 (Fixed & Improved) - Now with non-destructive configs and better logic!
#
#       ░███    ░██               ░██                                             ░██ ░██ ░██                            
#      ░██░██   ░██               ░██                                             ░██ ░██ ░██                            
#     ░██  ░██  ░████████   ░████████  ░███████   ░███████   ░███████   ░██████   ░██ ░██ ░██  ░██████   ░█████████████  
#    ░█████████ ░██    ░██ ░██    ░██ ░██    ░██ ░██        ░██              ░██  ░██ ░██ ░██       ░██  ░██   ░██   ░██ 
#    ░██    ░██ ░██    ░██ ░██    ░██ ░█████████  ░███████   ░███████   ░███████  ░██ ░██ ░██  ░███████  ░██   ░██   ░██ 
#    ░██    ░██ ░███   ░██ ░██   ░███ ░██               ░██        ░██ ░██   ░██  ░██ ░██ ░██ ░██   ░██  ░██   ░██   ░██ 
#    ░██    ░██ ░██░█████   ░█████░██  ░███████   ░███████   ░███████   ░█████░██ ░██ ░██ ░██  ░█████░██ ░██   ░██   ░██                                                                                                                
                                                                                                                                                                                                                            
                                                                                                                    
#===========================================================================================
set -euo pipefail
IFS=$'\n\t'

# Global variables for rollback
ROLLBACK_ACTIONS=()
INSTALLATION_PHASE=""

#------------------------------------------------------------------------------
# Rollback functions - Because we all make mistakes 😅
#------------------------------------------------------------------------------
add_rollback_action() {
  ROLLBACK_ACTIONS+=("$1")
}

perform_rollback() {
  echo
  echo "=== Performing Rollback ==="
  echo "Rolling back changes..."
  
  # Execute rollback actions in reverse order
  for (( idx=${#ROLLBACK_ACTIONS[@]}-1 ; idx>=0 ; idx-- )); do
    echo "Executing: ${ROLLBACK_ACTIONS[idx]}"
    eval "${ROLLBACK_ACTIONS[idx]}" || true # Using '|| true' to continue even if a rollback command fails
  done
  
  echo "Rollback completed."
}

handle_error() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    echo
    echo "ERROR: Installation failed during phase: $INSTALLATION_PHASE"
    echo
    read -rp "Do you want to undo all changes? [y/N]: " rollback_choice
    if [[ "$rollback_choice" =~ ^[Yy]$ ]]; then
      perform_rollback
    fi
    exit $exit_code
  fi
}

# Set trap for errors
trap handle_error ERR

#------------------------------------------------------------------------------
# Helper: usage
#------------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: sudo $0

CloudStack 4.20 Installer v2.1
This installer will configure and install CloudStack with KVM on Ubuntu 22/24.

New in v2.1:
  • Corrected execution logic (it actually runs now!)
  • Safe, non-destructive config changes for /etc/hosts and libvirtd.conf
  • More efficient device discovery logic
  • Added missing MySQL config rollback action

The installer will prompt you for:
  • FQDN hostname (auto-detected if available)
  • CloudStack DB configuration
  • MySQL root password
  • Block device for secondary storage (optional)

It then configures:
  – KVM/QEMU & libvirt
  – MySQL 8 (tuned for CloudStack)
  – CloudStack management & usage
  – NFS primary & secondary storage
  – Network bridge (br0)
  – GRUB IOMMU & cgroup v1
EOF
  exit 1
}

#------------------------------------------------------------------------------
# Pre-flight checks: Get your boarding pass ready 😂
# I had to say that LOL! Kinda stupid though, right? preflight happens at home.
#------------------------------------------------------------------------------
run_preflight_checks() {
    INSTALLATION_PHASE="Pre-flight checks"
    echo "Performing pre-flight checks..."

    check_virtualization() {
      if ! grep -qE 'vmx|svm' /proc/cpuinfo; then
        echo "WARNING: CPU virtualization not detected. CloudStack may not work properly."
        echo "Please enable VT-x/AMD-V in BIOS if available."
        read -rp "Continue anyway? [y/N]: " continue_install
        [[ $continue_install == [Yy] ]] || exit 1
      fi
    }

    check_memory() {
      local mem_gb=$(($(free -m | awk '/^Mem:/{print $2}') / 1024))
      if [[ $mem_gb -lt 8 ]]; then
        echo "WARNING: Less than 8GB RAM detected ($mem_gb GB). CloudStack may not perform well."
        read -rp "Continue anyway? [y/N]: " continue_install
        [[ $continue_install == [Yy] ]] || exit 1
      fi
    }

    check_disk_space() {
      local root_space=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
      if [[ $root_space -lt 20 ]]; then
        echo "WARNING: Less than 20GB free space on root filesystem ($root_space GB)."
        read -rp "Continue anyway? [y/N]: " continue_install
        [[ $continue_install == [Yy] ]] || exit 1
      fi
    }

    check_virtualization
    check_memory
    check_disk_space
}

#------------------------------------------------------------------------------
# Input validation functions
#------------------------------------------------------------------------------
validate_fqdn() {
  local fqdn="$1"
  [[ $fqdn =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]
}

validate_db_name() {
  local name="$1"
  [[ $name =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]] && [[ ${#name} -le 64 ]]
}

validate_username() {
  local user="$1"
  [[ -n "$user" ]] && [[ ${#user} -le 32 ]] && [[ $user =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]]
}

#------------------------------------------------------------------------------
# Input prompt functions with retry logic
#------------------------------------------------------------------------------
prompt_with_retry() {
  local prompt="$1"
  local validator="$2"
  local error_msg="$3"
  local result=""
  
  while true; do
    read -rp "$prompt" result
    if [[ -n "$validator" ]]; then
      if $validator "$result"; then
        echo "$result"
        return 0
      else
        echo "$error_msg" >&2
      fi
    else
      if [[ -n "$result" ]]; then
        echo "$result"
        return 0
      else
        echo "Input cannot be empty. Please try again." >&2
      fi
    fi
  done
}

prompt_password_with_retry() {
  local prompt="$1"
  local min_length="${2:-8}"
  local result=""
  
  while true; do
    read -rsp "$prompt" result
    echo
    if [[ ${#result} -lt $min_length ]]; then
      echo "Password must be at least $min_length characters. Please try again." >&2
    else
      echo "$result"
      return 0
    fi
  done
}

#------------------------------------------------------------------------------
# Hostname selection function - Now with auto-detection!
#------------------------------------------------------------------------------
select_hostname() {
  local current_hostname
  current_hostname=$(hostname -f 2>/dev/null || hostname)
  local choice
  
  echo
  echo "=== Hostname Configuration ==="
  echo
  
  # Check if current hostname is already an FQDN
  if validate_fqdn "$current_hostname" && [[ "$current_hostname" == *.* ]]; then
    echo "Current hostname detected: $current_hostname"
    echo
    echo "Options:"
    echo "  1) Use current hostname: $current_hostname"
    echo "  2) Enter a new hostname"
    echo
    
    while true; do
      read -rp "Select option [1-2]: " choice
      case $choice in
        1)
          HOST_FQDN="$current_hostname"
          echo "Using hostname: $HOST_FQDN"
          return 0
          ;;
        2)
          break # Break to prompt for new hostname
          ;;
        *)
          echo "Invalid option. Please select 1 or 2."
          ;;
      esac
    done
  else
    echo "Current hostname '$current_hostname' is not a valid FQDN."
  fi
  
  HOST_FQDN=$(prompt_with_retry \
    "Enter FQDN for this server (e.g. cs.example.com): " \
    "validate_fqdn" \
    "ERROR: Invalid FQDN format. Please use format like 'cs.example.com'")
}

#------------------------------------------------------------------------------
# Block device selection function - Because not everyone has /dev/sdb!
#------------------------------------------------------------------------------
# (Refactored for efficiency)
get_available_devices() {
  while IFS= read -r device; do
    # Skip devices that are not block devices, have partitions, are mounted, or are loop devices
    [[ -b "/dev/$device" ]] || continue
    [[ "$device" =~ [0-9]$ ]] && continue
    [[ "$device" =~ ^loop ]] && continue
    mount | grep -q "^/dev/$device" && continue
    lsblk -n "/dev/$device" 2>/dev/null | grep -q "^${device}[0-9]" && continue
    
    local size
    size=$(lsblk -dn -o SIZE "/dev/$device" 2>/dev/null | head -1)
    echo "/dev/$device $size" # Output format: /dev/sdb 100G
  done < <(lsblk -dn -o NAME 2>/dev/null || true)
}

select_block_device() {
  local choice
  
  while true; do
    echo
    echo "=== Secondary Storage Device Selection ==="
    echo
    
    local devices_array=()
    mapfile -t devices_array < <(get_available_devices)
    
    if [[ ${#devices_array[@]} -eq 0 ]]; then
      echo "No unpartitioned, unmounted block devices found."
      echo
      echo "Options:"
      echo "  s) Skip secondary storage configuration (use local filesystem)"
      echo "  r) Refresh device list"
      echo
      read -rp "Select option [s/r]: " choice
      case $choice in
        s|S)
          echo "Skipping secondary storage configuration..."
          SEC_DEV="SKIP"
          return 0
          ;;
        r|R)
          echo "Refreshing device list..."
          sleep 1
          continue
          ;;
        *)
          echo "Invalid option. Please try again."
          ;;
      esac
    else
      echo "Available unpartitioned block devices:"
      echo
      local i=1
      for dev_info in "${devices_array[@]}"; do
        # dev_info is in format "/dev/sdx 100G"
        printf "  %s) %s (%s)\n" "$i" "$(echo "$dev_info" | cut -d' ' -f1)" "$(echo "$dev_info" | cut -d' ' -f2-)"
        ((i++))
      done
      echo
      echo "Options:"
      echo "  s) Skip secondary storage configuration (use local filesystem)"
      echo "  r) Refresh device list"
      echo
      
      read -rp "Select device number [1-${#devices_array[@]}] or option [s/r]: " choice
      
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#devices_array[@]} )); then
        local selected_device_info="${devices_array[$((choice-1))]}"
        local selected_device
        selected_device=$(echo "$selected_device_info" | cut -d' ' -f1)
        
        echo
        echo "Selected device: $selected_device"
        read -rp "This will ERASE ALL DATA on $selected_device. Continue? [y/N]: " confirm
        
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
          SEC_DEV="$selected_device"
          return 0
        else
          echo "Device selection cancelled."
        fi
      else
        case $choice in
          s|S)
            echo "Skipping secondary storage configuration..."
            SEC_DEV="SKIP"
            return 0
            ;;
          r|R)
            echo "Refreshing device list..."
            sleep 1
            ;;
          *)
            echo "Invalid option. Please try again."
            ;;
        esac
      fi
    fi
  done
}

#==============================================================================
# MAIN INSTALLATION STARTS HERE - No more exits, only success! 🚀
#==============================================================================
main() {
  # must be root
  [[ $EUID -eq 0 ]] || usage

  # check Ubuntu version
  . /etc/lsb-release
  if ! [[ $DISTRIB_RELEASE == 22.* || $DISTRIB_RELEASE == 24.* ]]; then
    echo "ERROR: Only Ubuntu 22.xx or 24.xx are supported." >&2
    exit 1
  fi
  
  run_preflight_checks

  echo
  echo "=========================================="
  echo "CloudStack 4.20 Installation v2.1"
  echo "=========================================="
  echo

  #------------------------------------------------------------------------------
  # 1/ Collect all inputs with proper validation
  #------------------------------------------------------------------------------
  INSTALLATION_PHASE="Input collection"

  # Hostname selection
  select_hostname

  # Database configuration
  while true; do
    read -rp "CloudStack DB name [cloud]: " DB_NAME
    DB_NAME=${DB_NAME:-cloud}
    if validate_db_name "$DB_NAME"; then
      break
    else
      echo "ERROR: Database name must start with a letter and contain only letters, numbers, and underscores." >&2
    fi
  done

  DB_USER=$(prompt_with_retry \
    "CloudStack DB user: " \
    "validate_username" \
    "ERROR: Username must start with a letter and contain only letters, numbers, and underscores.")

  DB_PASS=$(prompt_password_with_retry "CloudStack DB user password: " 8)
  DB_ROOT_PASS=$(prompt_password_with_retry "MySQL root password: " 8)

  # Block device selection
  select_block_device

  echo
  echo "=== Configuration Summary ==="
  echo "Hostname: $HOST_FQDN"
  echo "Database: $DB_NAME"
  echo "DB User: $DB_USER"
  echo "Secondary Storage: ${SEC_DEV}"
  echo "============================="
  echo
  read -rp "Proceed with installation? [Y/n]: " proceed
  [[ "$proceed" =~ ^[Nn]$ ]] && exit 0

  #------------------------------------------------------------------------------
  # 2/ Network discovery & hostname configuration
  #------------------------------------------------------------------------------
  INSTALLATION_PHASE="Network configuration"
  echo
  echo "Configuring network and hostname..."

  # Pick first real NIC (improved detection)
  ADAPTER=$(ip -o link show | awk -F': ' '!/lo|docker|virbr/ {print $2; exit}')
  if [[ -z $ADAPTER ]]; then
    echo "ERROR: No suitable network interface found." >&2
    exit 1
  fi

  # Get current IP and validate
  IP_ADDR=$(ip -4 addr show "$ADAPTER" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
  if [[ -z $IP_ADDR ]]; then
    echo "ERROR: No IPv4 address found on $ADAPTER." >&2
    exit 1
  fi

  # Validate IP is not link-local or loopback
  if [[ $IP_ADDR =~ ^169\.254\. ]] || [[ $IP_ADDR =~ ^127\. ]]; then
    echo "ERROR: Invalid IP address $IP_ADDR (link-local or loopback)." >&2
    exit 1
  fi

  # Get network details
  CIDR=$(ip -4 addr show "$ADAPTER" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -n1)
  GATEWAY=$(ip route show default | awk '/default/ {print $3}' | head -n1)

  if [[ -z $GATEWAY ]]; then
    echo "ERROR: No default gateway found." >&2
    exit 1
  fi

  # Test connectivity
  ping -c2 -W5 "$GATEWAY" >/dev/null || {
    echo "ERROR: Cannot ping gateway $GATEWAY." >&2
    exit 1
  }

  # Configure /etc/hosts (safely!)
  cp /etc/hosts /etc/hosts.backup
  add_rollback_action "cp /etc/hosts.backup /etc/hosts"
  # Remove any old entries for this IP or hostname to avoid duplicates
  sed -i -e "/\s${HOST_FQDN}\s/d" -e "/\s${HOST_FQDN%%.*}\s/d" -e "/^${IP_ADDR}\s/d" /etc/hosts
  # Add the new, correct entry to the top
  sed -i "1s/^/$IP_ADDR\t$HOST_FQDN ${HOST_FQDN%%.*}\n/" /etc/hosts

  # Set hostname
  OLD_HOSTNAME=$(hostname)
  hostnamectl set-hostname "$HOST_FQDN"
  add_rollback_action "hostnamectl set-hostname '$OLD_HOSTNAME'"

  #------------------------------------------------------------------------------
  # 3/ Enable IOMMU & cgroup v1 (required for CloudStack)
  #------------------------------------------------------------------------------
  INSTALLATION_PHASE="GRUB configuration"
  echo "Configuring GRUB for IOMMU and cgroup v1..."

  GRUB_CFG=/etc/default/grub
  GRUB_BACKUP="${GRUB_CFG}.backup"
  cp "$GRUB_CFG" "$GRUB_BACKUP"
  add_rollback_action "cp ${GRUB_BACKUP} $GRUB_CFG && update-grub"

  # Check CPU vendor for appropriate IOMMU setting
  if grep -q "vendor_id.*GenuineIntel" /proc/cpuinfo; then
    IOMMU_PARAM="intel_iommu=on"
  elif grep -q "vendor_id.*AuthenticAMD" /proc/cpuinfo; then
    IOMMU_PARAM="amd_iommu=on"
  else
    IOMMU_PARAM="iommu=pt" # A sensible default
  fi

  # Add required kernel parameters if they don't exist
  KERNEL_PARAMS="$IOMMU_PARAM systemd.unified_cgroup_hierarchy=false"
  if ! grep -q "GRUB_CMDLINE_LINUX=.*$IOMMU_PARAM" "$GRUB_CFG"; then
    sed -i "s/GRUB_CMDLINE_LINUX=\"\(.*\)\"/GRUB_CMDLINE_LINUX=\"\1 $KERNEL_PARAMS\"/" "$GRUB_CFG"
    sed -i 's/GRUB_CMDLINE_LINUX="  */GRUB_CMDLINE_LINUX="/' "$GRUB_CFG" # Tidy up spaces
    update-grub
    update-initramfs -u
    echo "IOMMU and cgroup v1 enabled; reboot required after installation."
  else
    echo "GRUB already configured for IOMMU and cgroup v1."
  fi

  # Ensure cgroup v1 is properly configured
  mkdir -p /sys/fs/cgroup/freezer
  if ! mountpoint -q /sys/fs/cgroup/freezer 2>/dev/null; then
    if ! grep -q "freezer /sys/fs/cgroup/freezer" /etc/fstab; then
      cp /etc/fstab /etc/fstab.backup-cgroup
      add_rollback_action "cp /etc/fstab.backup-cgroup /etc/fstab"
      echo "freezer /sys/fs/cgroup/freezer cgroup freezer 0 0" >> /etc/fstab
    fi
  fi

  #------------------------------------------------------------------------------
  # 4/ Configure network bridge with improved Netplan
  #------------------------------------------------------------------------------
  INSTALLATION_PHASE="Network bridge configuration"
  echo "Configuring network bridge..."

  apt update
  apt install -y bridge-utils netplan.io

  # Backup existing netplan configs
  mkdir -p /etc/netplan/backup
  cp /etc/netplan/*.yaml /etc/netplan/backup/ 2>/dev/null || true
  add_rollback_action "rm -f /etc/netplan/*.yaml && cp /etc/netplan/backup/*.yaml /etc/netplan/ 2>/dev/null && netplan apply"

  # Remove existing netplan configs
  rm -f /etc/netplan/*.yaml

  NETPLAN_FILE="/etc/netplan/01-cloudstack-bridge.yaml"
  cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $ADAPTER:
      dhcp4: no
      dhcp6: no
  bridges:
    br0:
      interfaces: [$ADAPTER]
      dhcp4: no
      dhcp6: no
      addresses: [$CIDR]
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses: [1.1.1.1, 1.0.0.1, 8.8.8.8]
      parameters:
        stp: false
        forward-delay: 0
EOF

  # Validate and apply netplan configuration
  if ! netplan try --timeout=30; then
    echo "ERROR: Netplan configuration failed. Rolling back netplan changes." >&2
    rm -f /etc/netplan/*.yaml && cp /etc/netplan/backup/*.yaml /etc/netplan/ 2>/dev/null
    netplan apply
    exit 1
  fi
  netplan apply

  # Wait for br0 to come up and verify
  echo "Waiting for bridge to come up..."
  for i in {1..30}; do
    if ip addr show br0 | grep -q "$IP_ADDR"; then
      break
    fi
    sleep 1
  done

  if ! ip addr show br0 | grep -q "$IP_ADDR"; then
    echo "ERROR: Bridge br0 did not receive correct IP address." >&2
    exit 1
  fi

  ping -c2 -W5 "$GATEWAY" >/dev/null || {
    echo "ERROR: Cannot ping gateway through bridge." >&2
    exit 1
  }
  echo "Network bridge configured successfully."

  #------------------------------------------------------------------------------
  # 5/ Install packages
  #------------------------------------------------------------------------------
  INSTALLATION_PHASE="Package installation"
  echo "Installing required packages..."

  apt-get update
  apt-get install -y \
    qemu-kvm libvirt-daemon-system libvirt-clients virtinst \
    mysql-server nfs-kernel-server rpcbind \
    chrony openssh-server sudo vim htop iotop \
    curl gnupg lsb-release ca-certificates \
    python3-libvirt python3-pip \
    cpu-checker libguestfs-tools \
    bridge-utils vlan \
    uuid-runtime

  # Enable and start services
  systemctl enable --now libvirtd
  systemctl enable --now nfs-kernel-server

  # Add user to libvirt group for management
  usermod -a -G libvirt root

  add_rollback_action "apt-get remove -y cloudstack-management cloudstack-usage cloudstack-agent 2>/dev/null || true"

  #------------------------------------------------------------------------------
  # 6/ Configure libvirt for CloudStack (safely!)
  #------------------------------------------------------------------------------
  INSTALLATION_PHASE="Libvirt configuration"
  echo "Configuring libvirt..."

  # Backup libvirt config
  LIBVIRTD_CONF="/etc/libvirt/libvirtd.conf"
  cp "$LIBVIRTD_CONF" "${LIBVIRTD_CONF}.backup"
  add_rollback_action "cp ${LIBVIRTD_CONF}.backup $LIBVIRTD_CONF && systemctl restart libvirtd"

  # Configure libvirt to listen on TCP (required for CloudStack) using sed for safety
  sed -i -E 's/^#?listen_tls = .*/listen_tls = 0/' "$LIBVIRTD_CONF"
  sed -i -E 's/^#?listen_tcp = .*/listen_tcp = 1/' "$LIBVIRTD_CONF"
  sed -i -E 's/^#?tcp_port = .*/tcp_port = "16509"/' "$LIBVIRTD_CONF"
  sed -i -E 's/^#?listen_addr = .*/listen_addr = "0.0.0.0"/' "$LIBVIRTD_CONF"
  sed -i -E 's/^#?auth_tcp = .*/auth_tcp = "none"/' "$LIBVIRTD_CONF"
  sed -i -E 's/^#?mdns_adv = .*/mdns_adv = 0/' "$LIBVIRTD_CONF"

  # Update libvirt service configuration
  mkdir -p /etc/systemd/system/libvirtd.service.d
  add_rollback_action "rm -rf /etc/systemd/system/libvirtd.service.d"
  cat > /etc/systemd/system/libvirtd.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/sbin/libvirtd --listen
EOF

  # Configure default libvirt network to use br0
  cat > /tmp/br0-network.xml <<EOF
<network>
  <name>br0</name>
  <forward mode="bridge"/>
  <bridge name="br0"/>
</network>
EOF
  add_rollback_action "virsh net-destroy br0 2>/dev/null || true; virsh net-undefine br0 2>/dev/null || true"

  # Define and start the network
  virsh net-destroy default 2>/dev/null || true
  virsh net-undefine default 2>/dev/null || true
  virsh net-define /tmp/br0-network.xml
  virsh net-start br0
  virsh net-autostart br0

  systemctl daemon-reload
  systemctl restart libvirtd

  #------------------------------------------------------------------------------
  # 7/ Add CloudStack repo & install
  #------------------------------------------------------------------------------
  INSTALLATION_PHASE="CloudStack installation"
  echo "Adding CloudStack repository and installing packages..."

  CODENAME=$(lsb_release -cs)
  curl -fsSL https://download.cloudstack.org/release.asc \
    | gpg --dearmor \
    | tee /usr/share/keyrings/cloudstack-archive-keyring.gpg >/dev/null

  add_rollback_action "rm -f /etc/apt/sources.list.d/cloudstack.list /usr/share/keyrings/cloudstack-archive-keyring.gpg"
  cat > /etc/apt/sources.list.d/cloudstack.list <<EOF
deb [signed-by=/usr/share/keyrings/cloudstack-archive-keyring.gpg] \
  https://download.cloudstack.org/ubuntu $CODENAME 4.20
EOF

  apt-get update
  apt-get install -y cloudstack-management cloudstack-usage cloudstack-agent

  #------------------------------------------------------------------------------
  # 8/ Configure MySQL for production
  #------------------------------------------------------------------------------
  INSTALLATION_PHASE="MySQL configuration"
  echo "Configuring MySQL for production..."

  # Backup original MySQL config
  cp /etc/mysql/mysql.conf.d/mysqld.cnf /etc/mysql/mysql.conf.d/mysqld.cnf.backup

  # Calculate MySQL settings based on available memory
  TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
  INNODB_BUFFER_POOL_SIZE=$((TOTAL_MEM_MB * 60 / 100))  # 60% of RAM
  MAX_CONNECTIONS=1000

  MYSQL_CNF_FILE="/etc/mysql/mysql.conf.d/cloudstack.cnf"
  add_rollback_action "rm -f $MYSQL_CNF_FILE && systemctl restart mysql"

  cat > "$MYSQL_CNF_FILE" <<EOF
[mysqld]
# Basic settings
server-id = 1
bind-address = 127.0.0.1
port = 3306
# SQL Mode
sql-mode = "STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ZERO_DATE,NO_ZERO_IN_DATE,NO_ENGINE_SUBSTITUTION"
# Connection settings
max_connections = $MAX_CONNECTIONS
max_user_connections = 500
connect_timeout = 60
wait_timeout = 7200
# InnoDB settings
innodb_buffer_pool_size = ${INNODB_BUFFER_POOL_SIZE}M
innodb_log_file_size = 256M
innodb_log_buffer_size = 16M
innodb_flush_log_at_trx_commit = 1
innodb_lock_wait_timeout = 600
innodb_rollback_on_timeout = 1
innodb_flush_method = O_DIRECT
innodb_file_per_table = 1
# Logging
log-bin = mysql-bin
binlog-format = ROW
# Character set
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
EOF

  systemctl restart mysql
  echo "Waiting for MySQL to restart..."
  sleep 10

  # Secure MySQL installation
  mysql -u root <<SQL
-- Set root password
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${DB_ROOT_PASS}';
-- Remove anonymous users
DELETE FROM mysql.user WHERE User='';
-- Remove remote root access
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
-- Remove test database
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
-- Reload privileges
FLUSH PRIVILEGES;
SQL

  #------------------------------------------------------------------------------
  # 9/ Create CloudStack database and user
  #------------------------------------------------------------------------------
  INSTALLATION_PHASE="Database setup"
  echo "Creating CloudStack database and user..."
  add_rollback_action "mysql -u root -p'${DB_ROOT_PASS}' -e 'DROP DATABASE IF EXISTS \`${DB_NAME}\`; DROP USER IF EXISTS \'${DB_USER}\'@\'localhost\';'"

  mysql -u root -p"${DB_ROOT_PASS}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
GRANT PROCESS ON *.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

  #------------------------------------------------------------------------------
  # 10/ Initialize CloudStack database
  #------------------------------------------------------------------------------
  echo "Initializing CloudStack database..."

  cloudstack-setup-databases "${DB_USER}:${DB_PASS}@localhost" \
    --deploy-as="root:${DB_ROOT_PASS}" \
    --database="${DB_NAME}"

  # Update database configuration if non-standard database name
  if [[ $DB_NAME != "cloud" ]]; then
    DB_PROPERTIES="/etc/cloudstack/management/db.properties"
    cp "$DB_PROPERTIES" "${DB_PROPERTIES}.backup"
    add_rollback_action "cp ${DB_PROPERTIES}.backup $DB_PROPERTIES"
    sed -i "s/db.cloud.name=cloud/db.cloud.name=${DB_NAME}/" "$DB_PROPERTIES"
  fi

  cloudstack-setup-management

  #------------------------------------------------------------------------------
  # 11/ Configure NFS storage
  #------------------------------------------------------------------------------
  INSTALLATION_PHASE="Storage configuration"
  echo "Configuring NFS storage..."

  mkdir -p /export/secondary /export/primary
  add_rollback_action "rm -rf /export/primary /export/secondary"

  if [[ "$SEC_DEV" != "SKIP" ]]; then
    echo "Partitioning and formatting secondary storage device..."
    parted -s "$SEC_DEV" mklabel gpt
    parted -s "$SEC_DEV" mkpart primary ext4 0% 100%
    sleep 2
    mkfs.ext4 -F -m 1 -O ^has_journal "${SEC_DEV}1"
    
    SEC_UUID=$(blkid -s UUID -o value "${SEC_DEV}1")
    
    cp /etc/fstab /etc/fstab.backup-nfs
    add_rollback_action "cp /etc/fstab.backup-nfs /etc/fstab"
    echo "UUID=${SEC_UUID} /export/secondary ext4 defaults,noatime 0 2" >> /etc/fstab

    mount /export/secondary
    add_rollback_action "umount /export/secondary 2>/dev/null || true"
  else
    echo "Secondary storage will use local filesystem at /export/secondary"
  fi

  chown -R root:root /export/primary /export/secondary
  chmod 755 /export/primary /export/secondary

  add_rollback_action "printf '' > /etc/exports && exportfs -ra"
  cat > /etc/exports <<EOF
/export/primary *(rw,async,no_root_squash,no_subtree_check)
/export/secondary *(rw,async,no_root_squash,no_subtree_check)
EOF

  exportfs -ra
  systemctl restart nfs-kernel-server

  #------------------------------------------------------------------------------
  # 12/ Configure firewall (ufw)
  #------------------------------------------------------------------------------
  INSTALLATION_PHASE="Firewall configuration"
  echo "Configuring firewall..."
  if command -v ufw >/dev/null; then
    ufw --force reset # Reset to default to ensure a clean slate
    ufw allow 22/tcp # SSH
    ufw allow 8080/tcp # CloudStack UI
    ufw allow 8250/tcp # CloudStack Console Proxy
    ufw allow from 127.0.0.1 to any port 3306 proto tcp # MySQL
    ufw allow 2049/tcp # NFS
    ufw allow 111/tcp # RPCBind
    ufw allow 111/udp
    ufw allow 16509/tcp # Libvirt
    ufw allow 4789/udp # VXLAN
    ufw --force enable
    add_rollback_action "ufw --force reset && ufw --force disable"
  fi

  #------------------------------------------------------------------------------
  # 13/ Configure SSH keys for CloudStack
  #------------------------------------------------------------------------------
  INSTALLATION_PHASE="SSH configuration"
  echo "Configuring SSH keys..."

  CS_SSH_DIR="/var/lib/cloudstack/management/.ssh"
  mkdir -p "$CS_SSH_DIR"
  add_rollback_action "rm -rf /var/lib/cloudstack/management"

  if [[ ! -f "$CS_SSH_DIR/id_rsa" ]]; then
    ssh-keygen -t rsa -b 4096 -N "" -f "$CS_SSH_DIR/id_rsa" -C "cloudstack@${HOST_FQDN}"
  fi

  chown -R cloud:cloud "$CS_SSH_DIR"
  chmod 700 "$CS_SSH_DIR"
  chmod 600 "$CS_SSH_DIR/id_rsa"
  chmod 644 "$CS_SSH_DIR/id_rsa.pub"

  mkdir -p /root/.ssh
  cat "$CS_SSH_DIR/id_rsa.pub" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys

  #------------------------------------------------------------------------------
  # 14/ Start CloudStack services
  #------------------------------------------------------------------------------
  INSTALLATION_PHASE="Starting services"
  echo "Starting CloudStack services..."

  systemctl enable --now cloudstack-management
  systemctl enable --now cloudstack-usage

  echo "Waiting for CloudStack management server to start (this may take a few minutes)..."
  for i in {1..60}; do
    if curl -f -s http://localhost:8080/client/ >/dev/null 2>&1; then
      break
    fi
    echo -n "."
    sleep 5
  done
  echo

  #------------------------------------------------------------------------------
  # 15/ Final validation and cleanup
  #------------------------------------------------------------------------------
  INSTALLATION_PHASE="Validation"
  echo "Performing final validation..."

  if ! curl -f -s http://localhost:8080/client/ >/dev/null 2>&1; then
     echo "ERROR: CloudStack Management UI is not accessible."
     handle_error # Trigger rollback prompt
     exit 1
  fi
  
  FAILED_SERVICES=""
  for service in cloudstack-management mysql libvirtd nfs-kernel-server; do
    if ! systemctl is-active --quiet "$service"; then
      FAILED_SERVICES="$FAILED_SERVICES $service"
    fi
  done

  if [[ -n "$FAILED_SERVICES" ]]; then
    echo "WARNING: The following services are not running:$FAILED_SERVICES"
    handle_error # Trigger rollback prompt
    exit 1
  fi

  rm -f /tmp/br0-network.xml

  #------------------------------------------------------------------------------
  # 16/ Final message & next steps - Success! 🎉
  #------------------------------------------------------------------------------
  cat <<EOF

=========================================================
CloudStack 4.20 Production Installation Complete! 🎉

Management UI: http://$HOST_FQDN:8080/client/
Default credentials: admin / password

System Information:
- Hostname: $HOST_FQDN
- Bridge Interface: br0 ($IP_ADDR)
- Primary Storage: /export/primary (NFS)
- Secondary Storage: /export/secondary $([ "$SEC_DEV" != "SKIP" ] && echo "(${SEC_DEV}1, NFS)" || echo "(local filesystem)")
- Database: $DB_NAME (user: $DB_USER)

Next Steps:
1. **REBOOT** the system to activate IOMMU and cgroup settings.
   This is a **required** step!
2. After reboot, run: sudo virt-host-validate
3. Access the web UI and complete the initial setup wizard.
4. Configure zones, pods, clusters, and hosts.

SSH Key Information:
- CloudStack SSH public key: $CS_SSH_DIR/id_rsa.pub
- This key has been added to root's authorized_keys.

Post-Installation Checklist:
□ Verify all services are running after reboot
□ Check virt-host-validate output
□ Test NFS mounts: showmount -e localhost
□ Verify network connectivity through br0
□ Complete CloudStack initial setup wizard
□ Configure storage and network in CloudStack UI

For support and documentation:
- You may leave a star on github if you'd like @abdessalllam
- CloudStack Documentation: https://docs.cloudstack.org/
- Community Support: https://cloudstack.apache.org/community/

To reboot now, run: sudo reboot

=========================================================

Installation completed successfully! ✨
EOF
}

# This is the new entry point that calls the main function.
# Without this, the script does nothing!
main "$@"
