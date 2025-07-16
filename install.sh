#!/usr/bin/env bash
#===========================================================================================
# CloudStack 4.20 (Mgmt + KVM) on Ubuntu 22/24 Auto Installer - "Kind of" PRODUCTION READY
# Author: https://github.com/abdessalllam
# Modified: With improved input handling and retry logic
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

#------------------------------------------------------------------------------
# Helper: usage
#------------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: sudo $0
This installer will prompt you for:
  • FQDN hostname (e.g. cs.example.com)
  • CloudStack DB name [cloud]
  • CloudStack DB user & pass
  • MySQL root password
  • Block device for secondary storage (optional)

It then configures networking, installs, tunes and deploys:
  – KVM/QEMU & libvirt
  – MySQL 8 (tuned for CloudStack)
  – CloudStack management & usage
  – NFS primary (/export/primary) & secondary (/export/secondary)
  – GRUB IOMMU, cgroup v1, Netplan bridge
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
#------------------------------------------------------------------------------
check_virtualization() {
  if ! grep -qE 'vmx|svm' /proc/cpuinfo; then
    echo "ERROR: CPU virtualization not supported or not enabled in BIOS." >&2
    exit 1
  fi
}

check_memory() {
  local mem_gb=$(($(free -m | awk '/^Mem:/{print $2}') / 1024))
  if [[ $mem_gb -lt 8 ]]; then
    echo "WARNING: Less than 8GB RAM detected. CloudStack may not perform well." >&2
    read -rp "Continue anyway? (y/N): " continue_install
    [[ $continue_install == [Yy] ]] || exit 1
  fi
}

check_disk_space() {
  local root_space=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
  if [[ $root_space -lt 20 ]]; then
    echo "ERROR: Less than 20GB free space on root filesystem." >&2
    exit 1
  fi
}

echo "Performing pre-flight checks..."
check_virtualization
check_memory
check_disk_space

#------------------------------------------------------------------------------
# Validator functions
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
# Retry wrapper for any input prompt
#------------------------------------------------------------------------------
prompt_with_retry() {
  local prompt="$1"
  local validator="$2"
  local error_msg="$3"
  local result=""
  
  while true; do
    read -rp "$prompt" result
    
    # If validator function exists, use it
    if [[ -n "$validator" ]]; then
      if $validator "$result"; then
        echo "$result"
        return 0
      else
        echo "$error_msg" >&2
      fi
    else
      # No validator, just ensure non-empty
      if [[ -n "$result" ]]; then
        echo "$result"
        return 0
      else
        echo "Input cannot be empty. Please try again." >&2
      fi
    fi
  done
}

#------------------------------------------------------------------------------
# Password prompt with retry
#------------------------------------------------------------------------------
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
# Function to get available unpartitioned block devices
#------------------------------------------------------------------------------
get_available_devices() {
  local devices=()
  local dev_info=""
  
  # Find all block devices that are disks (not partitions) and not mounted
  while IFS= read -r device; do
    # Skip if device doesn't exist
    [[ -b "/dev/$device" ]] || continue
    
    # Skip if it's a partition (has a number at the end)
    [[ "$device" =~ [0-9]$ ]] && continue
    
    # Skip loop devices
    [[ "$device" =~ ^loop ]] && continue
    
    # Skip if any partition of this device is mounted
    if mount | grep -q "^/dev/$device"; then
      continue
    fi
    
    # Get device size
    size=$(lsblk -dn -o SIZE "/dev/$device" 2>/dev/null | head -1)
    
    # Check if device has partitions
    if lsblk -n "/dev/$device" | grep -q "^${device}[0-9]"; then
      # Has partitions, skip
      continue
    fi
    
    devices+=("/dev/$device")
    dev_info="${dev_info}/dev/$device ($size)\n"
  done < <(lsblk -dn -o NAME)
  
  echo -e "$dev_info"
  printf '%s\n' "${devices[@]}"
}

#------------------------------------------------------------------------------
# Block device selection with retry logic
#------------------------------------------------------------------------------
select_block_device() {
  local selected_device=""
  local device_list
  local devices_array=()
  
  while true; do
    echo
    echo "=== Secondary Storage Device Selection ==="
    echo
    
    # Get available devices
    mapfile -t devices_array < <(get_available_devices | tail -n +2)
    device_list=$(get_available_devices | head -n -${#devices_array[@]})
    
    if [[ ${#devices_array[@]} -eq 0 ]]; then
      echo "No unpartitioned block devices found."
      echo
      echo "Options:"
      echo "  s) Skip secondary storage configuration"
      echo "  r) Refresh device list"
      echo "  q) Quit installation"
      echo
      read -rp "Select option [s/r/q]: " choice
      
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
        q|Q)
          echo "Installation cancelled by user."
          exit 0
          ;;
        *)
          echo "Invalid option. Please try again."
          continue
          ;;
      esac
    else
      echo "Available unpartitioned block devices:"
      echo
      
      # Display devices with numbers
      local i=1
      while IFS= read -r dev_info; do
        echo "  $i) $dev_info"
        ((i++))
      done <<< "$device_list"
      
      echo
      echo "Options:"
      echo "  s) Skip secondary storage configuration"
      echo "  r) Refresh device list"
      echo "  q) Quit installation"
      echo
      read -rp "Select device number or option [1-${#devices_array[@]}/s/r/q]: " choice
      
      # Check if it's a number
      if [[ "$choice" =~ ^[0-9]+$ ]]; then
        if (( choice >= 1 && choice <= ${#devices_array[@]} )); then
          selected_device="${devices_array[$((choice-1))]}"
          
          # Confirm selection
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
          q|Q)
            echo "Installation cancelled by user."
            exit 0
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
# 1/ Prompt for inputs with validation and retry
#------------------------------------------------------------------------------
echo
echo "=== CloudStack Installation Configuration ==="
echo

# FQDN prompt with retry
HOST_FQDN=$(prompt_with_retry \
  "Enter FQDN for this server (e.g. cs.example.com): " \
  "validate_fqdn" \
  "ERROR: Invalid FQDN format. Please use format like 'cs.example.com'")

# Database name with default and validation
while true; do
  read -rp "CloudStack DB name [cloud]: " DB_NAME
  DB_NAME=${DB_NAME:-cloud}
  if validate_db_name "$DB_NAME"; then
    break
  else
    echo "ERROR: Database name must start with a letter and contain only letters, numbers, and underscores." >&2
  fi
done

# Database user
DB_USER=$(prompt_with_retry \
  "CloudStack DB user: " \
  "validate_username" \
  "ERROR: Username must start with a letter and contain only letters, numbers, and underscores.")

# Passwords
DB_PASS=$(prompt_password_with_retry "CloudStack DB user password: " 8)
DB_ROOT_PASS=$(prompt_password_with_retry "MySQL root password: " 8)

# Block device selection
select_block_device

#------------------------------------------------------------------------------
# 2/ Network discovery & hostname
#------------------------------------------------------------------------------
# pick first real NIC (improved detection)
ADAPTER=$(ip link show | grep -E '^[0-9]+: ' | grep -v 'lo:' | grep -v 'docker' | grep -v 'virbr' | head -n1 | cut -d: -f2 | tr -d ' ')
if [[ -z $ADAPTER ]]; then
  echo "ERROR: No suitable network interface found." >&2
  exit 1
fi

# Get current IP and validate it's not link-local
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

# Test connectivity before proceeding
ping -c2 -W5 "$GATEWAY" >/dev/null || {
  echo "ERROR: Cannot ping gateway $GATEWAY." >&2
  exit 1
}

# Backup existing hosts file
cp /etc/hosts /etc/hosts.backup

# /etc/hosts
grep -q "$HOST_FQDN" /etc/hosts || cat > /etc/hosts <<EOF
127.0.0.1    localhost
$IP_ADDR     $HOST_FQDN   ${HOST_FQDN%%.*}

# The following lines are desirable for IPv6 capable hosts
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

# set system hostname
hostnamectl set-hostname "$HOST_FQDN"

#------------------------------------------------------------------------------
# 3/ Enable IOMMU & cgroup v1 (required for CloudStack)
#------------------------------------------------------------------------------
echo "Configuring GRUB for IOMMU and cgroup v1..."

# 3a) IOMMU and cgroup v1 in GRUB
GRUB_CFG=/etc/default/grub
GRUB_BACKUP="${GRUB_CFG}.backup"
cp "$GRUB_CFG" "$GRUB_BACKUP"

# Check CPU vendor for appropriate IOMMU setting
if grep -q "vendor_id.*GenuineIntel" /proc/cpu
