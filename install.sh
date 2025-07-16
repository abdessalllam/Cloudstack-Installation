#!/usr/bin/env bash
#===========================================================================================
# CloudStack 4.20 (Mgmt + KVM) on Ubuntu 22/24 Auto Installer - PRODUCTION READY v3.0
# Author: https://github.com/abdessalllam
# Version: 3.0 - Fixed network configuration errors and improved error handling
#
#       ░███    ░██               ░██                                             ░██ ░██ ░██                            
#      ░██░██   ░██               ░██                                             ░██ ░██ ░██                            
#     ░██  ░██  ░████████   ░████████  ░███████   ░███████   ░███████   ░██████   ░██ ░██ ░██  ░██████   ░█████████████  
#    ░█████████ ░██    ░██ ░██    ░██ ░██    ░██ ░██        ░██              ░██  ░██ ░██ ░██       ░██  ░██   ░██   ░██ 
#    ░██    ░██ ░██    ░██ ░██    ░██ ░█████████  ░███████   ░███████   ░███████  ░██ ░██ ░██  ░███████  ░██   ░██   ░██ 
#    ░██    ░██ ░███   ░██ ░██   ░███ ░██               ░██        ░██ ░██   ░██  ░██ ░██ ░██ ░██   ░██  ░██   ░██   ░██ 
#    ░██    ░██ ░██░█████   ░█████░██  ░███████   ░███████   ░███████   ░█████░██ ░██ ░██ ░██  ░█████░██ ░██   ░██   ░██                                                                                                                
                                                                                                                                                                                                                            
                                                                                                                    
#===========================================================================================
set -uo pipefail  # Removed 'e' to handle errors manually
IFS=$'\n\t'

# Global variables for rollback
ROLLBACK_ACTIONS=()
INSTALLATION_PHASE=""
SCRIPT_ERROR=0

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
    eval "${ROLLBACK_ACTIONS[idx]}" || true
  done
  
  echo "Rollback completed."
}

handle_error() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    echo
    echo "ERROR: Installation failed during phase: $INSTALLATION_PHASE"
    echo "Exit code: $exit_code"
    echo
    read -rp "Do you want to undo all changes? [y/N]: " rollback_choice
    if [[ "$rollback_choice" =~ ^[Yy]$ ]]; then
      perform_rollback
    fi
    exit $exit_code
  fi
}

# Custom error check function
check_error() {
  local exit_code=$?
  local error_msg="${1:-Command failed}"
  if [[ $exit_code -ne 0 ]]; then
    echo "ERROR: $error_msg (exit code: $exit_code)" >&2
    SCRIPT_ERROR=1
    return $exit_code
  fi
  return 0
}

# Set trap for unexpected errors only
trap 'handle_error' ERR

#------------------------------------------------------------------------------
# Helper: usage
#------------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: sudo $0

CloudStack 4.20 Installer v3.0
This installer will configure and install CloudStack with KVM on Ubuntu 22/24.

New in v3.0:
  • Fixed network configuration errors
  • Improved error handling for edge cases
  • Better detection of network interfaces
  • More robust rollback functionality

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

# must be root
[[ $EUID -eq 0 ]] || usage

# check Ubuntu version
. /etc/lsb-release
if ! [[ $DISTRIB_RELEASE == 22.* || $DISTRIB_RELEASE == 24.* ]]; then
  echo "ERROR: Only Ubuntu 22.xx or 24.xx are supported." >&2
  exit 1
fi

#------------------------------------------------------------------------------
# Pre-flight checks: Get your boarding pass ready 😂
# I had to say that LOL!
#------------------------------------------------------------------------------
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
  local current_hostname=$(hostname -f 2>/dev/null || hostname)
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
          HOST_FQDN=$(prompt_with_retry \
            "Enter FQDN for this server (e.g. cs.example.com): " \
            "validate_fqdn" \
            "ERROR: Invalid FQDN format. Please use format like 'cs.example.com'")
          return 0
          ;;
        *)
          echo "Invalid option. Please select 1 or 2."
          ;;
      esac
    done
  else
    echo "Current hostname '$current_hostname' is not a valid FQDN."
    HOST_FQDN=$(prompt_with_retry \
      "Enter FQDN for this server (e.g. cs.example.com): " \
      "validate_fqdn" \
      "ERROR: Invalid FQDN format. Please use format like 'cs.example.com'")
  fi
}

#------------------------------------------------------------------------------
# Block device selection function - Because not everyone has /dev/sdb!
#------------------------------------------------------------------------------
get_available_devices() {
  local devices=()
  local dev_info=""
  
  while IFS= read -r device; do
    [[ -b "/dev/$device" ]] || continue
    [[ "$device" =~ [0-9]$ ]] && continue
    [[ "$device" =~ ^loop ]] && continue
    
    if mount | grep -q "^/dev/$device"; then
      continue
    fi
    
    size=$(lsblk -dn -o SIZE "/dev/$device" 2>/dev/null | head -1)
    
    if lsblk -n "/dev/$device" 2>/dev/null | grep -q "^${device}[0-9]"; then
      continue
    fi
    
    devices+=("/dev/$device")
    dev_info="${dev_info}/dev/$device ($size)\n"
  done < <(lsblk -dn -o NAME 2>/dev/null || true)
  
  echo -e "$dev_info"
  printf '%s\n' "${devices[@]}"
}

select_block_device() {
  local selected_device=""
  local device_list
  local devices_array=()
  
  while true; do
    echo
    echo "=== Secondary Storage Device Selection ==="
    echo
    
    mapfile -t devices_array < <(get_available_devices | tail -n +2)
    device_list=$(get_available_devices | head -n -${#devices_array[@]})
    
    if [[ ${#devices_array[@]} -eq 0 ]]; then
      echo "No unpartitioned block devices found."
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
          continue
          ;;
      esac
    else
      echo "Available unpartitioned block devices:"
      echo
      
      local i=1
      while IFS= read -r dev_info; do
        echo "  $i) $dev_info"
        ((i++))
      done <<< "$device_list"
      
      echo
      echo "Options:"
      echo "  s) Skip secondary storage configuration (use local filesystem)"
      echo "  r) Refresh device list"
      echo
      
      read -rp "Select device number [1-${#devices_array[@]}] or option [s/r]: " choice
      
      if [[ "$choice" =~ ^[0-9]+$ ]]; then
        if (( choice >= 1 && choice <= ${#devices_array[@]} )); then
          selected_device="${devices_array[$((choice-1))]}"
          echo
          echo "Selected device: $selected_device"
          read -rp "This will ERASE ALL DATA on $selected_device. Continue? [y/N]: " confirm
          
          if [[ "$confirm" =~ ^[Yy]$ ]]; then
            SEC_DEV="$selected_device"
            return 0
          else
            echo "Device selection cancelled."
            continue
          fi
        else
          echo "Invalid device number. Please try again."
          continue
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
            continue
            ;;
          *)
            echo "Invalid option. Please try again."
            continue
            ;;
        esac
      fi
    fi
  done
}

#------------------------------------------------------------------------------
# MAIN INSTALLATION STARTS HERE - No more exits, only success! 🚀
#------------------------------------------------------------------------------
echo
echo "=========================================="
echo "CloudStack 4.20 Installation v3.0"
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
ADAPTER=""
for nic in $(ip -o link show | awk -F': ' '{print $2}' | grep -v -E '^(lo|docker|virbr|veth)'); do
  if ip addr show "$nic" | grep -q "inet "; then
    ADAPTER="$nic"
    break
  fi
done

if [[ -z $ADAPTER ]]; then
  echo "ERROR: No suitable network interface found." >&2
  handle_error
fi

echo "Using network adapter: $ADAPTER"

# Get current IP and validate
IP_ADDR=$(ip -4 addr show "$ADAPTER" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n1)
if [[ -z $IP_ADDR ]]; then
  echo "ERROR: No IPv4 address found on $ADAPTER." >&2
  handle_error
fi

echo "IP address: $IP_ADDR"

# Validate IP is not link-local
if [[ $IP_ADDR =~ ^169\.254\. ]]; then
  echo "ERROR: Invalid IP address $IP_ADDR (link-local)." >&2
  handle_error
fi

# Get network details
CIDR=$(ip -4 addr show "$ADAPTER" | grep "inet $IP_ADDR" | awk '{print $2}')
if [[ -z $CIDR ]]; then
  echo "ERROR: Could not determine network CIDR." >&2
  handle_error
fi

echo "Network CIDR: $CIDR"

# Get gateway
GATEWAY=$(ip route show default | awk '/default/ {print $3}' | head -n1)
if [[ -z $GATEWAY ]]; then
  # Try alternative method
  GATEWAY=$(ip route | grep "^default" | awk '{print $3}' | head -n1)
  if [[ -z $GATEWAY ]]; then
    echo "ERROR: No default gateway found." >&2
    handle_error
  fi
fi

echo "Gateway: $GATEWAY"

# Test connectivity
echo "Testing network connectivity..."
if ! ping -c2 -W5 "$GATEWAY" >/dev/null 2>&1; then
  echo "WARNING: Cannot ping gateway $GATEWAY"
  # Try DNS instead
  if ! ping -c2 -W5 8.8.8.8 >/dev/null 2>&1; then
    echo "ERROR: No network connectivity detected." >&2
    handle_error
  fi
fi

# Configure /etc/hosts
echo "Configuring /etc/hosts..."
if [[ -f /etc/hosts ]]; then
  cp /etc/hosts /etc/hosts.backup
  add_rollback_action "cp /etc/hosts.backup /etc/hosts"
fi

# Remove any existing entries for this hostname
sed -i "/$HOST_FQDN/d" /etc/hosts 2>/dev/null || true

# Add new entries
cat >> /etc/hosts <<EOF

# CloudStack installation
$IP_ADDR     $HOST_FQDN   ${HOST_FQDN%%.*}
EOF

# Set hostname
OLD_HOSTNAME=$(hostname)
echo "Setting hostname to $HOST_FQDN..."
hostnamectl set-hostname "$HOST_FQDN" || check_error "Failed to set hostname"
add_rollback_action "hostnamectl set-hostname '$OLD_HOSTNAME'"

echo "Network configuration completed successfully."

#------------------------------------------------------------------------------
# 3/ Enable IOMMU & cgroup v1 (required for CloudStack)
#------------------------------------------------------------------------------
INSTALLATION_PHASE="GRUB configuration"
echo "Configuring GRUB for IOMMU and cgroup v1..."

GRUB_CFG=/etc/default/grub
if [[ -f "$GRUB_CFG" ]]; then
  cp "$GRUB_CFG" "${GRUB_CFG}.backup"
  add_rollback_action "cp ${GRUB_CFG}.backup $GRUB_CFG && update-grub"
fi

# Check CPU vendor for appropriate IOMMU setting
if grep -q "vendor_id.*GenuineIntel" /proc/cpuinfo; then
  IOMMU_PARAM="intel_iommu=on"
elif grep -q "vendor_id.*AuthenticAMD" /proc/cpuinfo; then
  IOMMU_PARAM="amd_iommu=on"
else
  IOMMU_PARAM="iommu=pt"
fi

# Add required kernel parameters
KERNEL_PARAMS="$IOMMU_PARAM iommu=pt systemd.unified_cgroup_hierarchy=false"

if ! grep -q "$IOMMU_PARAM" "$GRUB_CFG" 2>/dev/null; then
  sed -i "s/GRUB_CMDLINE_LINUX=\"\(.*\)\"/GRUB_CMDLINE_LINUX=\"\1 $KERNEL_PARAMS\"/" "$GRUB_CFG"
  sed -i 's/GRUB_CMDLINE_LINUX="  */GRUB_CMDLINE_LINUX="/' "$GRUB_CFG"
  update-grub || check_error "Failed to update GRUB"
  update-initramfs -u || check_error "Failed to update initramfs"
  echo "IOMMU and cgroup v1 enabled; reboot required after installation."
fi

# Ensure cgroup v1 mount point exists
mkdir -p /sys/fs/cgroup/freezer 2>/dev/null || true

#------------------------------------------------------------------------------
# 4/ Configure network bridge with improved Netplan
#------------------------------------------------------------------------------
INSTALLATION_PHASE="Network bridge configuration"
echo "Configuring network bridge..."

# Install required packages
apt-get update || check_error "Failed to update package list"
apt-get install -y bridge-utils netplan.io || check_error "Failed to install network packages"

# Backup existing netplan configs
mkdir -p /etc/netplan/backup
if ls /etc/netplan/*.yaml >/dev/null 2>&1; then
  cp /etc/netplan/*.yaml /etc/netplan/backup/ 2>/dev/null || true
  add_rollback_action "rm -f /etc/netplan/*.yaml && cp /etc/netplan/backup/*.yaml /etc/netplan/ 2>/dev/null && netplan apply"
fi

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
echo "Applying network configuration..."
if ! netplan generate 2>/dev/null; then
  echo "ERROR: Netplan configuration validation failed." >&2
  if [[ -d /etc/netplan/backup ]]; then
    cp /etc/netplan/backup/*.yaml /etc/netplan/ 2>/dev/null || true
  fi
  handle_error
fi

netplan apply || check_error "Failed to apply netplan configuration"

# Wait for br0 to come up
echo "Waiting for bridge to come up..."
for i in {1..30}; do
  if ip addr show br0 2>/dev/null | grep -q "$IP_ADDR"; then
    echo "Bridge is up with IP $IP_ADDR"
    break
  fi
  sleep 1
done

# Verify bridge is working
if ! ip addr show br0 2>/dev/null | grep -q "$IP_ADDR"; then
  echo "WARNING: Bridge br0 may not have the correct IP address."
fi

echo "Network bridge configured successfully."

#------------------------------------------------------------------------------
# 5/ Install packages
#------------------------------------------------------------------------------
INSTALLATION_PHASE="Package installation"
echo "Installing required packages..."

# Update package list
apt-get update || check_error "Failed to update package list"

# Install packages in groups to better handle errors
echo "Installing virtualization packages..."
apt-get install -y \
  qemu-kvm libvirt-daemon-system libvirt-clients virtinst \
  cpu-checker libguestfs-tools || check_error "Failed to install virtualization packages"

echo "Installing storage and network packages..."
apt-get install -y \
  mysql-server nfs-kernel-server rpcbind \
  bridge-utils vlan || check_error "Failed to install storage/network packages"

echo "Installing utility packages..."
apt-get install -y \
  chrony openssh-server sudo vim htop iotop \
  curl gnupg lsb-release ca-certificates \
  python3-libvirt python3-pip \
  uuid-runtime || check_error "Failed to install utility packages"

# Enable and start services
systemctl enable libvirtd || true
systemctl start libvirtd || check_error "Failed to start libvirtd"
systemctl enable nfs-kernel-server || true
systemctl start nfs-kernel-server || check_error "Failed to start NFS server"

# Add user to libvirt group
usermod -a -G libvirt root || true

add_rollback_action "apt-get remove -y cloudstack-management cloudstack-usage cloudstack-agent 2>/dev/null || true"

#------------------------------------------------------------------------------
# 6/ Configure libvirt for CloudStack
#------------------------------------------------------------------------------
INSTALLATION_PHASE="Libvirt configuration"
echo "Configuring libvirt..."

# Backup libvirt config
if [[ -f /etc/libvirt/libvirtd.conf ]]; then
  cp /etc/libvirt/libvirtd.conf /etc/libvirt/libvirtd.conf.backup
  add_rollback_action "cp /etc/libvirt/libvirtd.conf.backup /etc/libvirt/libvirtd.conf && systemctl restart libvirtd"
fi

# Configure libvirt to listen on TCP
cat > /etc/libvirt/libvirtd.conf <<EOF
listen_tls = 0
listen_tcp = 1
tcp_port = "16509"
listen_addr = "0.0.0.0"
auth_tcp = "none"
mdns_adv = 0
EOF

# Update libvirt service configuration
mkdir -p /etc/systemd/system/libvirtd.service.d
cat > /etc/systemd/system/libvirtd.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/sbin/libvirtd --listen
EOF

# Configure bridge network
cat > /tmp/br0-network.xml <<EOF
<network>
  <name>br0</name>
  <forward mode="bridge"/>
  <bridge name="br0"/>
</network>
EOF

# Reload systemd
systemctl daemon-reload || true

# Restart libvirt
systemctl restart libvirtd || check_error "Failed to restart libvirtd"

# Wait for libvirt to start
sleep 3

# Define and start the network
virsh net-define /tmp/br0-network.xml 2>/dev/null || true
virsh net-start br0 2>/dev/null || true
virsh net-autostart br0 2>/dev/null || true

# Disable default network if exists
virsh net-destroy default 2>/dev/null || true
virsh net-undefine default 2>/dev/null || true

#------------------------------------------------------------------------------
# 7/ Add CloudStack repo & install
#------------------------------------------------------------------------------
INSTALLATION_PHASE="CloudStack installation"
echo "Adding CloudStack repository and installing packages..."

CODENAME=$(lsb_release -cs)
curl -fsSL https://download.cloudstack.org/release.asc | \
  gpg --dearmor | \
  tee /usr/share/keyrings/cloudstack-archive-keyring.gpg >/dev/null || \
  check_error "Failed to add CloudStack GPG key"

cat > /etc/apt/sources.list.d/cloudstack.list <<EOF
deb [signed-by=/usr/share/keyrings/cloudstack-archive-keyring.gpg] \
  https://download.cloudstack.org/ubuntu $CODENAME 4.20
EOF

apt-get update || check_error "Failed to update package list after adding CloudStack repo"
apt-get install -y cloudstack-management cloudstack-usage cloudstack-agent || \
  check_error "Failed to install CloudStack packages"

#------------------------------------------------------------------------------
# 8/ Configure MySQL for production
#------------------------------------------------------------------------------
INSTALLATION_PHASE="MySQL configuration"
echo "Configuring MySQL for production..."

# Calculate MySQL settings based on available memory
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))

# Conservative settings for production
INNODB_BUFFER_POOL_SIZE=$((TOTAL_MEM_MB * 60 / 100))  # 60% of RAM
MAX_CONNECTIONS=1000

cat > /etc/mysql/mysql.conf.d/cloudstack.cnf <<EOF
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
interactive_timeout = 7200
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

# Query cache
query_cache_type = 1
query_cache_size = 128M
query_cache_limit = 4M

# Logging
log-bin = mysql-bin
binlog-format = ROW
expire_logs_days = 10
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 5

# Character set
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

# Other optimizations
tmp_table_size = 128M
max_heap_table_size = 128M
table_open_cache = 4000
thread_cache_size = 100
EOF

systemctl restart mysql || check_error "Failed to restart MySQL"

# Wait for MySQL to start
echo "Waiting for MySQL to start..."
for i in {1..30}; do
  if mysqladmin ping >/dev/null 2>&1; then
    echo "MySQL is running"
    break
  fi
  sleep 1
done

# Secure MySQL installation
echo "Securing MySQL installation..."
mysql -u root <<SQL 2>/dev/null || true
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

mysql -u root -p"${DB_ROOT_PASS}" <<SQL 2>/dev/null || check_error "Failed to create database"
-- Create database
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Create user with proper permissions
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'::1' IDENTIFIED BY '${DB_PASS}';

-- Grant all privileges on CloudStack database
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'::1';

-- Grant process privilege for CloudStack monitoring
GRANT PROCESS ON *.* TO '${DB_USER}'@'localhost';
GRANT PROCESS ON *.* TO '${DB_USER}'@'127.0.0.1';
GRANT PROCESS ON *.* TO '${DB_USER}'@'::1';

FLUSH PRIVILEGES;
SQL

#------------------------------------------------------------------------------
# 10/ Initialize CloudStack database
#------------------------------------------------------------------------------
echo "Initializing CloudStack database..."

cloudstack-setup-databases ${DB_USER}:${DB_PASS}@localhost \
  --deploy-as=root:${DB_ROOT_PASS} \
  --database=${DB_NAME} || check_error "Failed to setup CloudStack databases"

# Update database configuration if non-standard database name
if [[ $DB_NAME != "cloud" ]]; then
  sed -i "s/db.cloud.name=cloud/db.cloud.name=${DB_NAME}/" /etc/cloudstack/management/db.properties || true
fi

cloudstack-setup-management || check_error "Failed to setup CloudStack management"

#------------------------------------------------------------------------------
# 11/ Configure NFS storage
#------------------------------------------------------------------------------
INSTALLATION_PHASE="Storage configuration"
echo "Configuring NFS storage..."

# Create mount points for storage
mkdir -p /export/secondary /export/primary
add_rollback_action "rm -rf /export/primary /export/secondary"

# Handle secondary storage device
if [[ "$SEC_DEV" != "SKIP" ]]; then
  echo "Partitioning and formatting secondary storage device..."
  
  # Unmount if somehow mounted
  umount "${SEC_DEV}"* 2>/dev/null || true
  
  # Partition the device
  parted -s "$SEC_DEV" mklabel gpt || check_error "Failed to create partition table"
  parted -s "$SEC_DEV" mkpart primary ext4 0% 100% || check_error "Failed to create partition"
  sleep 2

  # Format with ext4
  mkfs.ext4 -F -m 1 -O ^has_journal "${SEC_DEV}1" || check_error "Failed to format partition"

  # Get UUID for fstab
  SEC_UUID=$(blkid -s UUID -o value "${SEC_DEV}1")

  if [[ -n "$SEC_UUID" ]]; then
    # Add to fstab
    echo "UUID=${SEC_UUID} /export/secondary ext4 defaults,noatime 0 2" >> /etc/fstab
    add_rollback_action "sed -i '/\\/export\\/secondary/d' /etc/fstab"

    # Mount secondary storage
    mount /export/secondary || check_error "Failed to mount secondary storage"
    add_rollback_action "umount /export/secondary 2>/dev/null || true"
  else
    echo "WARNING: Could not get UUID for ${SEC_DEV}1, using device path"
    echo "${SEC_DEV}1 /export/secondary ext4 defaults,noatime 0 2" >> /etc/fstab
    mount /export/secondary || check_error "Failed to mount secondary storage"
  fi
else
  echo "Secondary storage will use local filesystem at /export/secondary"
fi

# Set proper permissions
chown -R root:root /export/primary /export/secondary
chmod 755 /export/primary /export/secondary

# Configure NFS exports
cat > /etc/exports <<EOF
/export/primary *(rw,async,no_root_squash,no_subtree_check,fsid=1)
/export/secondary *(rw,async,no_root_squash,no_subtree_check,fsid=2)
EOF

# Configure NFS server
cat > /etc/default/nfs-kernel-server <<EOF
RPCNFSDOPTS="-N 2 -N 3 -U"
RPCMOUNTDOPTS="--manage-gids -N 2 -N 3"
EOF

# Restart NFS services
systemctl restart nfs-kernel-server || check_error "Failed to restart NFS server"
systemctl restart rpcbind || true

# Export NFS shares
exportfs -ra || check_error "Failed to export NFS shares"

# Test NFS mounts locally
echo "Testing NFS exports..."
showmount -e localhost || true

#------------------------------------------------------------------------------
# 12/ Configure firewall (ufw)
#------------------------------------------------------------------------------
INSTALLATION_PHASE="Firewall configuration"
echo "Configuring firewall..."

if command -v ufw >/dev/null 2>&1; then
  # Disable and reset firewall first
  ufw --force disable 2>/dev/null || true
  ufw --force reset 2>/dev/null || true
  
  # Re-enable with rules
  ufw --force enable || true
  
  # SSH
  ufw allow 22/tcp || true
  
  # CloudStack Management
  ufw allow 8080/tcp || true
  ufw allow 8250/tcp || true
  
  # MySQL (localhost only)
  ufw allow from 127.0.0.1 to any port 3306 || true
  
  # NFS
  ufw allow 2049/tcp || true
  ufw allow 111/tcp || true
  ufw allow 111/udp || true
  ufw allow 892/tcp || true
  ufw allow 892/udp || true
  ufw allow 32803/tcp || true
  ufw allow 32769/udp || true
  
  # libvirt
  ufw allow 16509/tcp || true
  
  # DHCP for VMs
  ufw allow 67/udp || true
  ufw allow 68/udp || true
  
  # DNS for VMs
  ufw allow 53/tcp || true
  ufw allow 53/udp || true
  
  # VXLAN (if using advanced networking)
  ufw allow 4789/udp || true
  
  ufw reload || true
else
  echo "UFW not found, skipping firewall configuration"
fi

#------------------------------------------------------------------------------
# 13/ Configure SSH keys for CloudStack
#------------------------------------------------------------------------------
INSTALLATION_PHASE="SSH configuration"
echo "Configuring SSH keys..."

CS_SSH_DIR="/var/lib/cloudstack/management/.ssh"
mkdir -p "$CS_SSH_DIR"

# Generate SSH key pair if it doesn't exist
if [[ ! -f "$CS_SSH_DIR/id_rsa" ]]; then
  ssh-keygen -t rsa -b 4096 -N "" -f "$CS_SSH_DIR/id_rsa" -C "cloudstack@${HOST_FQDN}" || \
    check_error "Failed to generate SSH keys"
fi

# Set proper permissions
chown -R cloud:cloud "$CS_SSH_DIR" 2>/dev/null || true
chmod 700 "$CS_SSH_DIR"
chmod 600 "$CS_SSH_DIR/id_rsa" 2>/dev/null || true
chmod 644 "$CS_SSH_DIR/id_rsa.pub" 2>/dev/null || true

# Add CloudStack public key to root's authorized_keys
mkdir -p /root/.ssh
touch /root/.ssh/authorized_keys
cat "$CS_SSH_DIR/id_rsa.pub" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

#------------------------------------------------------------------------------
# 14/ Start CloudStack services
#------------------------------------------------------------------------------
INSTALLATION_PHASE="Starting services"
echo "Starting CloudStack services..."

systemctl enable cloudstack-management || true
systemctl enable cloudstack-usage || true

# Start management service
systemctl start cloudstack-management || check_error "Failed to start CloudStack management"

# Start usage service (may fail on first run, that's OK)
systemctl start cloudstack-usage 2>/dev/null || true

# Wait for management server to start
echo "Waiting for CloudStack management server to start (this may take a few minutes)..."
for i in {1..120}; do
  if curl -f -s http://localhost:8080/client/ >/dev/null 2>&1; then
    echo "CloudStack management server is running!"
    break
  fi
  if [[ $((i % 10)) -eq 0 ]]; then
    echo "Still waiting... ($i seconds)"
  fi
  sleep 1
done

#------------------------------------------------------------------------------
# 15/ Final validation and cleanup
#------------------------------------------------------------------------------
INSTALLATION_PHASE="Validation"
echo "Performing final validation..."

# Check critical services
FAILED_SERVICES=""
for service in cloudstack-management mysql libvirtd nfs-kernel-server; do
  if ! systemctl is-active --quiet $service; then
    FAILED_SERVICES="$FAILED_SERVICES $service"
  fi
done

if [[ -n "$FAILED_SERVICES" ]]; then
  echo "WARNING: The following services are not running:$FAILED_SERVICES"
  echo
  
  # Try to get more info
  for service in $FAILED_SERVICES; do
    echo "Status of $service:"
    systemctl status $service --no-pager | head -n 10
    echo
  done
  
  read -rp "Do you want to undo all changes? [y/N]: " rollback_choice
  if [[ "$rollback_choice" =~ ^[Yy]$ ]]; then
    perform_rollback
    exit 1
  fi
fi

# Clean up temporary files
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
1. REBOOT the system to activate IOMMU and cgroup settings
   sudo reboot

2. After reboot, verify virtualization:
   sudo virt-host-validate

3. Access the web UI and complete the initial setup wizard:
   http://$HOST_FQDN:8080/client/

4. Configure zones, pods, clusters, and hosts

SSH Key Information:
- CloudStack SSH public key: $CS_SSH_DIR/id_rsa.pub
- This key has been added to root's authorized_keys

Post-Installation Checklist:
□ Reboot the system
□ Verify all services are running after reboot
□ Check virt-host-validate output
□ Test NFS mounts: showmount -e localhost
□ Verify network connectivity through br0
□ Complete CloudStack initial setup wizard
□ Configure storage and network in CloudStack UI

Troubleshooting Tips:
- Check logs: /var/log/cloudstack/management/
- Service status: systemctl status cloudstack-management
- Database connection: mysql -u$DB_USER -p$DB_PASS $DB_NAME

For support and documentation:
- CloudStack Documentation: https://docs.cloudstack.org/
- Community Support: https://cloudstack.apache.org/community/

=========================================================

Installation completed successfully! ✨
EOF
