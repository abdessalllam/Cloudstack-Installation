#!/bin/bash
#===========================================================================================
# CloudStack Installation Script
# Author: https://github.com/abdessalllam
#
#       ░███    ░██               ░██                                             ░██ ░██ ░██                            
#      ░██░██   ░██               ░██                                             ░██ ░██ ░██                            
#     ░██  ░██  ░████████   ░████████  ░███████   ░███████   ░███████   ░██████   ░██ ░██ ░██  ░██████   ░█████████████  
#    ░█████████ ░██    ░██ ░██    ░██ ░██    ░██ ░██        ░██              ░██  ░██ ░██ ░██       ░██  ░██   ░██   ░██ 
#    ░██    ░██ ░██    ░██ ░██    ░██ ░█████████  ░███████   ░███████   ░███████  ░██ ░██ ░██  ░███████  ░██   ░██   ░██ 
#    ░██    ░██ ░███   ░██ ░██   ░███ ░██               ░██        ░██ ░██   ░██  ░██ ░██ ░██ ░██   ░██  ░██   ░██   ░██ 
#    ░██    ░██ ░██░█████   ░█████░██  ░███████   ░███████   ░███████   ░█████░██ ░██ ░██ ░██  ░█████░██ ░██   ░██   ░██                                                                                                                
                                                                                                                                                                                                                            
                                                                                                                    
# This script automates the installation of Apache CloudStack on Ubuntu 22.04+
# this script does not go beyond step 7 in Manual Install Instructions: https://github.com/abdessalllam/Cloudstack-Installation/blob/main/Manual_Install.md
# It will prompt for important inputs and configure the system.
#===========================================================================================
# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# Exit if any command in a pipeline fails, not just the last one.
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
print_info "Starting CloudStack Installation. Please provide the following details."

read -p "Enter the desired hostname for this server (e.g., cloudstack-mgmt): " HOSTNAME
read -p "Enter the name for the CloudStack database (e.g., cloud): " DB_NAME
read -p "Enter the username for the CloudStack database user (e.g., cloud): " DB_USER
read -s -p "Enter the password for the CloudStack database user: " DB_PASS
echo
read -s -p "Confirm the password for the CloudStack database user: " DB_PASS_CONFIRM
echo
read -s -p "Enter a NEW password for the MariaDB 'root' user: " DB_ROOT_PASS
echo
read -s -p "Confirm the MariaDB 'root' password: " DB_ROOT_PASS_CONFIRM
echo
read -p "Are you installing the KVM hypervisor on this same server? (y/n): " INSTALL_KVM_LOCAL

# Validate passwords
if [ "$DB_PASS" != "$DB_PASS_CONFIRM" ]; then
    print_error "CloudStack user passwords do not match. Please run the script again."
fi
if [ "$DB_ROOT_PASS" != "$DB_ROOT_PASS_CONFIRM" ]; then
    print_error "MariaDB root passwords do not match. Please run the script again."
fi

#  Step 1: System Preparation 
print_info "Step 1: Preparing the system..."
apt update && apt upgrade -y
hostnamectl set-hostname "$HOSTNAME"
add-apt-repository -y universe
apt update
apt-get install -y dpkg-dev apt-utils software-properties-common debhelper openjdk-11-jdk libws-commons-util-java genisoimage libcommons-codec-java libcommons-httpclient-java liblog4j1.2-java maven
print_success "System preparation complete."

#  Step 2: Install & Configure MariaDB Server 
print_info "Step 2: Installing and configuring MariaDB..."
# Explicitly install mariadb-client to satisfy CloudStack dependencies
apt install -y mariadb-server mariadb-client

# Create a backup of the original config
cp /etc/mysql/mariadb.conf.d/50-server.cnf /etc/mysql/mariadb.conf.d/50-server.cnf.bak

# Configure MariaDB
cat > /etc/mysql/mariadb.conf.d/50-server.cnf <<EOF
[mysqld]
bind-address = 127.0.0.1
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
max_connections = 500
innodb_file_per_table = 1
innodb_file_format = Barracuda
innodb_large_prefix = 1
EOF

systemctl restart mariadb

# Verify MariaDB is running
if ! systemctl is-active --quiet mariadb; then
    print_error "MariaDB service failed to start."
fi

# Set MariaDB root password to enable password authentication
print_info "Setting MariaDB root password to enable password authentication..."
mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
FLUSH PRIVILEGES;
EOF
print_success "MariaDB root password set successfully."
print_success "MariaDB installation and configuration complete."

#  Step 3: Create the CloudStack Database 
print_info "Step 3: Creating the CloudStack databases and user..."
# Use the new root password to create the CloudStack databases and user
# This now includes the 'cloud_usage' database and PROCESS grant as per official docs.
mysql -u root -p"${DB_ROOT_PASS}" <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}_usage\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL ON \`${DB_NAME}_usage\`.* TO '${DB_USER}'@'localhost';
GRANT PROCESS ON *.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
print_success "Databases and user created successfully."

#  Step 4: Install CloudStack Management Server 
print_info "Step 4: Installing CloudStack Management Server..."
# Use modern GPG key handling instead of deprecated apt-key
install -m 0755 -d /etc/apt/keyrings
wget -qO- https://download.cloudstack.org/release.asc | gpg --dearmor -o /etc/apt/keyrings/cloudstack.gpg
echo "deb [signed-by=/etc/apt/keyrings/cloudstack.gpg] http://download.cloudstack.org/ubuntu jammy 4.20 main" | tee /etc/apt/sources.list.d/cloudstack.list > /dev/null

apt update
apt install -y cloudstack-management qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst
print_success "CloudStack Management Server installed."

#  Step 5: Initialize the CloudStack Database & Configure Sudoers 
print_info "Step 5: Initializing the CloudStack database..."
# Use the MariaDB root password for deployment
cloudstack-setup-databases "${DB_USER}:${DB_PASS}"@localhost --deploy-as=root:"${DB_ROOT_PASS}"

# Add sudoers rule if KVM is local, using the safe /etc/sudoers.d/ directory
if [[ "$INSTALL_KVM_LOCAL" =~ ^[Yy]$ ]]; then
    print_info "Adding sudoers rule for local KVM..."
    echo "Defaults:cloud !requiretty" > /etc/sudoers.d/99-cloudstack-cloud
    chmod 0440 /etc/sudoers.d/99-cloudstack-cloud
    print_success "Sudoers rule added safely."
fi
print_success "Database initialization complete."

# Step 6: Start the Management Server 
print_info "Step 6: Starting the CloudStack Management Server..."
systemctl enable --now cloudstack-management

# Verify CloudStack is running
if ! systemctl is-active --quiet cloudstack-management; then
    print_warning "CloudStack service is taking a moment to start... waiting 15 seconds."
    sleep 15
    if ! systemctl is-active --quiet cloudstack-management; then
        print_error "CloudStack Management service failed to start. Check logs with 'journalctl -u cloudstack-management'."
    fi
fi
print_success "CloudStack Management Server started and enabled on boot."

# Step 7: Post-Installation Tuning (Optional) 
if [[ "$INSTALL_KVM_LOCAL" =~ ^[Yy]$ ]]; then
    read -p "Do you want to apply kernel tuning for KVM to fix IOMMU and cgroup warnings? (y/n): " TUNE_KERNEL
    if [[ "$TUNE_KERNEL" =~ ^[Yy]$ ]]; then
        print_info "Applying kernel tuning..."
        
        # Check for CPU vendor
        IOMMU_PARAM=""
        if grep -q "vendor_id.*GenuineIntel" /proc/cpuinfo; then
            IOMMU_PARAM="intel_iommu=on"
        elif grep -q "vendor_id.*AuthenticAMD" /proc/cpuinfo; then
            IOMMU_PARAM="amd_iommu=on"
        fi

        # Backup grub config
        cp /etc/default/grub /etc/default/grub.bak

        # Modify grub config
        if [ -n "$IOMMU_PARAM" ]; then
            sed -i.bak 's/^\(GRUB_CMDLINE_LINUX_DEFAULT=".*\)"/\1 '"$IOMMU_PARAM"' systemd.unified_cgroup_hierarchy=0"/' /etc/default/grub
        else
             sed -i.bak 's/^\(GRUB_CMDLINE_LINUX_DEFAULT=".*\)"/\1 systemd.unified_cgroup_hierarchy=0"/' /etc/default/grub
        fi
        
        update-grub
        print_success "Kernel parameters updated."
        print_warning "A system reboot is required to apply the kernel changes."
    fi
fi

#  Final Instructions 
IP_ADDR=$(hostname -I | awk '{print $1}')
print_success "Installation Complete!"
print_info "You can now access the CloudStack UI at: http://${IP_ADDR}:8080/client"
print_warning "Remember to configure your firewall to allow access to port 8080."
print_warning "This Script does not go beyond step 7 in Manual Install Instructions: https://github.com/abdessalllam/Cloudstack-Installation/blob/main/Manual_Install.md"
