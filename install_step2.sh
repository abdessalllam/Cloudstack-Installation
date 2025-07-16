#!/bin/bash
#===========================================================================================
# CloudStack Auto Installer Step2 for NFS, Templates, libvirtd.
# Author: https://github.com/abdessalllam
# Version: Version 1.0
#
#       ░███    ░██               ░██                                             ░██ ░██ ░██                            
#      ░██░██   ░██               ░██                                             ░██ ░██ ░██                            
#     ░██  ░██  ░████████   ░████████  ░███████   ░███████   ░███████   ░██████   ░██ ░██ ░██  ░██████   ░█████████████  
#    ░█████████ ░██    ░██ ░██    ░██ ░██    ░██ ░██        ░██              ░██  ░██ ░██ ░██       ░██  ░██   ░██   ░██ 
#    ░██    ░██ ░██    ░██ ░██    ░██ ░█████████  ░███████   ░███████   ░███████  ░██ ░██ ░██  ░███████  ░██   ░██   ░██ 
#    ░██    ░██ ░███   ░██ ░██   ░███ ░██               ░██        ░██ ░██   ░██  ░██ ░██ ░██ ░██   ░██  ░██   ░██   ░██ 
#    ░██    ░██ ░██░█████   ░█████░██  ░███████   ░███████   ░███████   ░█████░██ ░██ ░██ ░██  ░█████░██ ░██   ░██   ░██                                                                                                                
                                                                                                                                                                                                                            
                                                                                                                    
#===========================================================================================
# This script configures the local server as an NFS share, prepares KVM for
# management, and downloads the SystemVM template.
# Run this script AFTER the main CloudStack installation is complete.
# Added Fixes: Correctly uses systemd socket activation for libvirtd, 
# Cause this damn error drives me nuts. It's an easy fix.
#===========================================================================================
#  Script Configuration 
set -e
set -u
set -o pipefail

#  Functions for Colored Output 
print_info() {
    echo -e "\e[34mINFO: $1\e[0m"
}

print_success() {
    echo -e "\e[32mSUCCESS: $1\e[0m"
}

print_warning() {
    echo -e "\e[33mWARNING: $1\e[0m"
}

print_error() {
    echo -e "\e[31mERROR: $1\e[0m"
    exit 1
}

#  Check for Root Privileges 
if [ "$EUID" -ne 0 ]; then
  print_error "This script must be run as root. Please use sudo."
fi

#  User Inputs 
print_info "Starting CloudStack Post-Installation Setup."
read -p "Enter the full path for Primary Storage (e.g., /export/primary): " PRIMARY_STORAGE_PATH
read -p "Enter the full path for Secondary Storage (e.g., /export/secondary): " SECONDARY_STORAGE_PATH

# Assign default values if input is empty
PRIMARY_STORAGE_PATH=${PRIMARY_STORAGE_PATH:-/export/primary}
SECONDARY_STORAGE_PATH=${SECONDARY_STORAGE_PATH:-/export/secondary}

print_info "Using Primary Storage Path: $PRIMARY_STORAGE_PATH"
print_info "Using Secondary Storage Path: $SECONDARY_STORAGE_PATH"


#  Step 1: Install and Configure NFS Server 
print_info "Step 1: Installing and configuring NFS server..."
apt update
apt install -y nfs-kernel-server

print_info "Creating NFS export directories..."
mkdir -p "$PRIMARY_STORAGE_PATH"
mkdir -p "$SECONDARY_STORAGE_PATH"

# Use the parent directory of the primary/secondary storage for the export
NFS_EXPORT_PATH=$(dirname "$PRIMARY_STORAGE_PATH")
if [ "$(dirname "$SECONDARY_STORAGE_PATH")" != "$NFS_EXPORT_PATH" ]; then
    print_warning "Primary and Secondary storage paths do not share the same parent. Only exporting '$NFS_EXPORT_PATH'."
    print_warning "You may need to add an additional export for '$(dirname "$SECONDARY_STORAGE_PATH")' manually."
fi

# Configure /etc/exports
echo "$NFS_EXPORT_PATH *(rw,async,no_root_squash,no_subtree_check)" > /etc/exports
print_success "NFS export created for $NFS_EXPORT_PATH"

# Configure NFS ports for firewall
print_info "Configuring NFS static ports..."
touch /etc/default/nfs-kernel-server
sed -i '/^# Static ports for CloudStack/d;/^RPCNFSDCOUNT/d;/^RPCMOUNTDOPTS/d;/^STATDOPTS/d;/^RPCQUOTADOPTS/d' /etc/default/nfs-kernel-server
cat >> /etc/default/nfs-kernel-server <<EOF

# Static ports for CloudStack
RPCNFSDCOUNT="-N 4 4"
RPCMOUNTDOPTS="-p 892"
STATDOPTS="-p 662"
RPCQUOTADOPTS="-p 875"
EOF

exportfs -ra
systemctl restart nfs-kernel-server
systemctl enable nfs-kernel-server
print_success "NFS server installed and configured."

#  Step 2: Configure Libvirt for Network Access 
print_info "Step 2: Configuring KVM (libvirt) for network access..."
# Backup original configs
cp /etc/libvirt/libvirtd.conf /etc/libvirt/libvirtd.conf.bak
cp /etc/default/libvirtd /etc/default/libvirtd.bak

# Comment out existing settings in libvirtd.conf to avoid conflicts
sed -i -E 's/^(#\s*)?(listen_tls\s*=.*)/#\2/' /etc/libvirt/libvirtd.conf
sed -i -E 's/^(#\s*)?(listen_tcp\s*=.*)/#\2/' /etc/libvirt/libvirtd.conf
sed -i -E 's/^(#\s*)?(auth_tcp\s*=.*)/#\2/' /etc/libvirt/libvirtd.conf

# Append correct settings to libvirtd.conf
echo "listen_tls = 0" >> /etc/libvirt/libvirtd.conf
echo "listen_tcp = 1" >> /etc/libvirt/libvirtd.conf
echo "auth_tcp = \"none\"" >> /etc/libvirt/libvirtd.conf

# Remove the --listen flag from /etc/default/libvirtd
sed -i -E 's/^(#\s*)?(LIBVIRTD_ARGS\s*=.*)/#\2/' /etc/default/libvirtd

# Enable and start the systemd sockets
systemctl enable --now libvirtd.socket
systemctl restart libvirtd.service

print_success "KVM (libvirt) configured for network access via systemd sockets."

#  Step 3: Configure Firewall with UFW 
print_info "Step 3: Configuring firewall with UFW..."
NETWORK_INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
LOCAL_SUBNET=$(ip -o -4 addr show dev "$NETWORK_INTERFACE" | awk '{print $4}')
print_info "Detected primary network interface: $NETWORK_INTERFACE"
print_info "Detected local subnet: $LOCAL_SUBNET"

if ! command -v ufw &> /dev/null; then
    apt install -y ufw
fi

ufw allow ssh

print_info "Adding NFS firewall rules for subnet $LOCAL_SUBNET..."
ufw allow from "$LOCAL_SUBNET" to any port 111,2049,892,875,662 proto tcp
ufw allow from "$LOCAL_SUBNET" to any port 111,2049,892,875,662 proto udp

print_info "Adding KVM host firewall rules for subnet $LOCAL_SUBNET..."
ufw allow from "$LOCAL_SUBNET" to any port 16509 proto tcp
ufw allow from "$LOCAL_SUBNET" to any port 5900:6100 proto tcp

ufw --force enable
print_success "Firewall configured and enabled."

#  Step 4: Prepare System VM Template 
print_info "Step 4: Downloading KVM SystemVM Template..."
/usr/share/cloudstack-common/scripts/storage/secondary/cloud-install-sys-tmplt \
  -m "$SECONDARY_STORAGE_PATH" \
  -u http://download.cloudstack.org/systemvm/4.20/systemvmtemplate-4.20.1-x86_64-kvm.qcow2.bz2 \
  -h kvm -F
print_success "SystemVM Template downloaded successfully."

#  Step 5: Restart CloudStack Management Server 
print_info "Step 5: Restarting CloudStack Management Server to apply changes..."
systemctl restart cloudstack-management

if ! systemctl is-active --quiet cloudstack-management; then
    print_warning "CloudStack service is taking a moment to start... waiting 15 seconds."
    sleep 15
    if ! systemctl is-active --quiet cloudstack-management; then
        print_error "CloudStack Management service failed to start. Check logs with 'journalctl -u cloudstack-management'."
    fi
fi
print_success "CloudStack Management Server restarted."

#  Final Instructions 
print_success "Configuration setup is complete!"
print_info "Your server is now configured for NFS and as a KVM host."
print_warning "If you haven't already, please reboot the system to apply any pending kernel changes from the main installer."
print_warning "Now Be a champ and smash that Star button, LOL"
print_warning "https://github.com/abdessalllam/Cloudstack-Installation"
