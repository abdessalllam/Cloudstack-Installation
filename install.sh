#!/usr/bin/env bash
#===========================================================================================
# CloudStack 4.20 (Mgmt + KVM) on Ubuntu 22/24 Auto Installer - "Kind of" PRODUCTION READY
# Author: https://github.com/abdessalllam
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
  • Block device for secondary storage (e.g. /dev/sdb)

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
# I had to say that LOL!
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
# 1/ Prompt for inputs with validation
#------------------------------------------------------------------------------
read -rp "Enter FQDN for this server (e.g. cs.example.com): " HOST_FQDN
if [[ ! $HOST_FQDN =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
  echo "ERROR: Invalid FQDN format." >&2
  exit 1
fi

read -rp "CloudStack DB name [cloud]: " DB_NAME
DB_NAME=${DB_NAME:-cloud}

read -rp "CloudStack DB user: " DB_USER
if [[ -z $DB_USER ]]; then
  echo "ERROR: Database user cannot be empty." >&2
  exit 1
fi

read -rsp "CloudStack DB user password: " DB_PASS; echo
if [[ ${#DB_PASS} -lt 8 ]]; then
  echo "ERROR: Database password must be at least 8 characters." >&2
  exit 1
fi

read -rsp "MySQL root password: " DB_ROOT_PASS; echo
if [[ ${#DB_ROOT_PASS} -lt 8 ]]; then
  echo "ERROR: MySQL root password must be at least 8 characters." >&2
  exit 1
fi

read -rp "Block device for Secondary storage (e.g. /dev/sdb): " SEC_DEV
if [[ ! -b $SEC_DEV ]]; then
  echo "ERROR: $SEC_DEV is not a valid block device." >&2
  exit 1
fi

# Check if device is already mounted
if mount | grep -q "$SEC_DEV"; then
  echo "ERROR: $SEC_DEV is already mounted." >&2
  exit 1
fi

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
if grep -q "vendor_id.*GenuineIntel" /proc/cpuinfo; then
  IOMMU_PARAM="intel_iommu=on"
elif grep -q "vendor_id.*AuthenticAMD" /proc/cpuinfo; then
  IOMMU_PARAM="amd_iommu=on"
else
  IOMMU_PARAM="iommu=pt"
fi

# Add required kernel parameters
KERNEL_PARAMS="$IOMMU_PARAM iommu=pt systemd.unified_cgroup_hierarchy=false"

if ! grep -q "$IOMMU_PARAM" "$GRUB_CFG"; then
  sed -i "s/GRUB_CMDLINE_LINUX=\"\(.*\)\"/GRUB_CMDLINE_LINUX=\"\1 $KERNEL_PARAMS\"/" "$GRUB_CFG"
  sed -i 's/GRUB_CMDLINE_LINUX="  */GRUB_CMDLINE_LINUX="/' "$GRUB_CFG"
  update-grub
  update-initramfs -u
  echo "IOMMU and cgroup v1 enabled; reboot required."
fi

# 3b) Ensure cgroup v1 is properly configured
mkdir -p /sys/fs/cgroup/freezer
if ! mountpoint -q /sys/fs/cgroup/freezer 2>/dev/null; then
  if ! grep -q "freezer /sys/fs/cgroup/freezer" /etc/fstab; then
    echo "freezer /sys/fs/cgroup/freezer cgroup freezer 0 0" >> /etc/fstab
  fi
fi

#------------------------------------------------------------------------------
# 4/ Configure network bridge with improved Netplan
#------------------------------------------------------------------------------
echo "Configuring network bridge..."

apt update
apt install -y bridge-utils netplan.io

# Backup existing netplan configs
mkdir -p /etc/netplan/backup
cp /etc/netplan/*.yaml /etc/netplan/backup/ 2>/dev/null || true

# Remove existing netplan configs
rm -f /etc/netplan/*.yaml

NETPLAN_FILE="/etc/netplan/01-cloudstack-bridge.yaml"

# Extract network prefix for proper subnet configuration
NETWORK_PREFIX=$(echo "$CIDR" | cut -d/ -f2)

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

# Validate netplan configuration
if ! netplan try --timeout=30; then
  echo "ERROR: Netplan configuration failed." >&2
  cp /etc/netplan/backup/*.yaml /etc/netplan/ 2>/dev/null || true
  exit 1
fi

# Apply configuration
netplan apply

# Wait for br0 to come up and verify
echo "Waiting for bridge to come up..."
for i in {1..30}; do
  if ip addr show br0 | grep -q "$IP_ADDR"; then
    break
  fi
  sleep 1
done

# Verify bridge is working
if ! ip addr show br0 | grep -q "$IP_ADDR"; then
  echo "ERROR: Bridge br0 did not receive correct IP address." >&2
  exit 1
fi

# Test connectivity through bridge
ping -c2 -W5 "$GATEWAY" >/dev/null || {
  echo "ERROR: Cannot ping gateway through bridge." >&2
  exit 1
}

echo "Network bridge configured successfully."

#------------------------------------------------------------------------------
# 5/ Install packages
#------------------------------------------------------------------------------
echo "Installing required packages..."

apt update
apt install -y \
  qemu-kvm libvirt-daemon-system libvirt-clients virtinst \
  mysql-server nfs-kernel-server rpcbind \
  chrony openssh-server sudo vim htop iotop \
  curl gnupg lsb-release ca-certificates \
  python3-libvirt python3-pip \
  cpu-checker libguestfs-tools \
  bridge-utils vlan \
  uuid-runtime

# Enable and start services
systemctl enable libvirtd
systemctl start libvirtd
systemctl enable nfs-kernel-server
systemctl start nfs-kernel-server

# Add user to libvirt group for management
usermod -a -G libvirt root

#------------------------------------------------------------------------------
# 6/ Configure libvirt for CloudStack
#------------------------------------------------------------------------------
echo "Configuring libvirt..."

# Configure libvirt to listen on TCP (required for CloudStack)
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

# Configure default libvirt network to use br0
cat > /tmp/br0-network.xml <<EOF
<network>
  <name>br0</name>
  <forward mode="bridge"/>
  <bridge name="br0"/>
</network>
EOF

# Define and start the network
virsh net-define /tmp/br0-network.xml
virsh net-start br0
virsh net-autostart br0

# Set default network to br0
virsh net-destroy default 2>/dev/null || true
virsh net-undefine default 2>/dev/null || true

systemctl daemon-reload
systemctl restart libvirtd

#------------------------------------------------------------------------------
# 7/ Add CloudStack repo & install
#------------------------------------------------------------------------------
echo "Adding CloudStack repository and installing packages..."

CODENAME=$(lsb_release -cs)
curl -fsSL https://download.cloudstack.org/release.asc \
  | gpg --dearmor \
  | tee /usr/share/keyrings/cloudstack-archive-keyring.gpg >/dev/null

cat > /etc/apt/sources.list.d/cloudstack.list <<EOF
deb [signed-by=/usr/share/keyrings/cloudstack-archive-keyring.gpg] \
  https://download.cloudstack.org/ubuntu $CODENAME 4.20
EOF

apt update
apt install -y cloudstack-management cloudstack-usage cloudstack-agent

#------------------------------------------------------------------------------
# 8/ Configure MySQL for production
#------------------------------------------------------------------------------
echo "Configuring MySQL for production..."

# Backup original MySQL config
cp /etc/mysql/mysql.conf.d/mysqld.cnf /etc/mysql/mysql.conf.d/mysqld.cnf.backup

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

systemctl restart mysql

# Wait for MySQL to start
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
echo "Creating CloudStack database and user..."

mysql -u root -p"${DB_ROOT_PASS}" <<SQL
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
  --database=${DB_NAME}

# Update database configuration if non-standard database name
if [[ $DB_NAME != "cloud" ]]; then
  sed -i "s/db.cloud.name=cloud/db.cloud.name=${DB_NAME}/" /etc/cloudstack/management/db.properties
fi

cloudstack-setup-management

#------------------------------------------------------------------------------
# 11/ Configure NFS storage
#------------------------------------------------------------------------------
echo "Configuring NFS storage..."

# Create mount point for secondary storage
mkdir -p /export/secondary
mkdir -p /export/primary

# Partition and format secondary storage device
echo "Partitioning and formatting secondary storage device..."
parted -s "$SEC_DEV" mklabel gpt
parted -s "$SEC_DEV" mkpart primary ext4 0% 100%
sleep 2

# Format with ext4 and optimizations
mkfs.ext4 -F -m 1 -O ^has_journal "${SEC_DEV}1"

# Get UUID for fstab
SEC_UUID=$(blkid -s UUID -o value "${SEC_DEV}1")

# Add to fstab
echo "UUID=${SEC_UUID} /export/secondary ext4 defaults,noatime 0 2" >> /etc/fstab

# Mount secondary storage
mount /export/secondary

# Set proper permissions
chown -R root:root /export/primary /export/secondary
chmod 755 /export/primary /export/secondary

# Configure NFS exports with proper security
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
systemctl restart nfs-kernel-server
systemctl restart rpcbind

# Export NFS shares
exportfs -ra

# Test NFS mounts locally
showmount -e localhost

#------------------------------------------------------------------------------
# 12/ Configure firewall (ufw)
#------------------------------------------------------------------------------
echo "Configuring firewall..."

if command -v ufw >/dev/null; then
  ufw --force enable
  
  # SSH
  ufw allow 22/tcp
  
  # CloudStack Management
  ufw allow 8080/tcp
  ufw allow 8250/tcp
  
  # MySQL (localhost only)
  ufw allow from 127.0.0.1 to any port 3306
  
  # NFS
  ufw allow 2049/tcp
  ufw allow 111/tcp
  ufw allow 111/udp
  ufw allow 892/tcp
  ufw allow 892/udp
  ufw allow 32803/tcp
  ufw allow 32769/udp
  
  # libvirt
  ufw allow 16509/tcp
  
  # DHCP for VMs
  ufw allow 67/udp
  ufw allow 68/udp
  
  # DNS for VMs
  ufw allow 53/tcp
  ufw allow 53/udp
  
  # VXLAN (if using advanced networking)
  ufw allow 4789/udp
  
  ufw reload
fi

#------------------------------------------------------------------------------
# 13/ Configure SSH keys for CloudStack
#------------------------------------------------------------------------------
echo "Configuring SSH keys..."

CS_SSH_DIR="/var/lib/cloudstack/management/.ssh"
mkdir -p "$CS_SSH_DIR"

# Generate SSH key pair if it doesn't exist
if [[ ! -f "$CS_SSH_DIR/id_rsa" ]]; then
  ssh-keygen -t rsa -b 4096 -N "" -f "$CS_SSH_DIR/id_rsa" -C "cloudstack@${HOST_FQDN}"
fi

# Set proper permissions
chown -R cloud:cloud "$CS_SSH_DIR"
chmod 700 "$CS_SSH_DIR"
chmod 600 "$CS_SSH_DIR/id_rsa"
chmod 644 "$CS_SSH_DIR/id_rsa.pub"

# Add CloudStack public key to root's authorized_keys
mkdir -p /root/.ssh
cat "$CS_SSH_DIR/id_rsa.pub" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

#------------------------------------------------------------------------------
# 14/ Start CloudStack services
#------------------------------------------------------------------------------
echo "Starting CloudStack services..."

systemctl enable cloudstack-management
systemctl enable cloudstack-usage
systemctl start cloudstack-management
systemctl start cloudstack-usage

# Wait for management server to start
echo "Waiting for CloudStack management server to start..."
for i in {1..60}; do
  if curl -f -s http://localhost:8080/client/ >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

#------------------------------------------------------------------------------
# 15/ Final validation and cleanup
#------------------------------------------------------------------------------
echo "Performing final validation..."

# Check if services are running
if ! systemctl is-active --quiet cloudstack-management; then
  echo "ERROR: CloudStack management service is not running." >&2
  exit 1
fi

if ! systemctl is-active --quiet mysql; then
  echo "ERROR: MySQL service is not running." >&2
  exit 1
fi

if ! systemctl is-active --quiet libvirtd; then
  echo "ERROR: libvirtd service is not running." >&2
  exit 1
fi

if ! systemctl is-active --quiet nfs-kernel-server; then
  echo "ERROR: NFS service is not running." >&2
  exit 1
fi

# Clean up temporary files
rm -f /tmp/br0-network.xml

#------------------------------------------------------------------------------
# 16/ Final message & next steps
#------------------------------------------------------------------------------
cat <<EOF

=========================================================
CloudStack 4.20 Production Installation Complete!

Management UI: http://$HOST_FQDN:8080/client/
Default credentials: admin / password

System Information:
- Hostname: $HOST_FQDN
- Bridge Interface: br0 ($IP_ADDR)
- Primary Storage: /export/primary (NFS)
- Secondary Storage: /export/secondary (${SEC_DEV}1, NFS)
- Database: $DB_NAME (user: $DB_USER)

Next Steps:
1. REBOOT the system to activate IOMMU and cgroup settings
2. After reboot, run: sudo virt-host-validate
3. Access the web UI and complete the initial setup wizard
4. Configure zones, pods, clusters, and hosts

SSH Key Information:
- CloudStack SSH public key: $CS_SSH_DIR/id_rsa.pub
- This key has been added to root's authorized_keys

Post-Installation Checklist:
□ Verify all services are running after reboot
□ Check virt-host-validate output
□ Test NFS mounts: showmount -e localhost
□ Verify network connectivity through br0
□ Complete CloudStack initial setup wizard
□ Configure storage and network in CloudStack UI

For support and documentation:
- CloudStack Documentation: https://docs.cloudstack.org/
- Community Support: https://cloudstack.apache.org/community/

=========================================================

EOF

echo "Installation completed successfully. Please reboot the system now."
