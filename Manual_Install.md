# CloudStack Management Server Installation on Ubuntu 22.04+

This guide provides step-by-step instructions for installing the CloudStack Management Server on an Ubuntu 22.04 (Jammy) system.

---

## ⚙️ Step 1: System Preparation

First, **update your system** packages and **set a unique hostname**.

```bash
sudo apt update && sudo apt upgrade -y
sudo hostnamectl set-hostname cloudstack-mgmt
```

Next, **enable the `universe` repository**, which contains software maintained by the community.

```bash
sudo add-apt-repository universe
sudo apt update
sudo apt-get install dpkg-dev apt-utils
sudo apt-get install software-properties-common
sudo apt-get install debhelper openjdk-11-jdk libws-commons-util-java genisoimage libcommons-codec-java libcommons-httpclient-java liblog4j1.2-java maven
```

---

## ⚙️ Step 2: Install & Configure MariaDB Server

CloudStack requires a database to store its state. We'll use **MariaDB**.

```bash
sudo apt install mariadb-server -y
```

Now, **configure MariaDB** for CloudStack. Open the configuration file:

```bash
sudo nano /etc/mysql/mariadb.conf.d/50-server.cnf
```

Add or update the following lines under the `[mysqld]` section. This optimizes the database for CloudStack's requirements.

```ini
[mysqld]
bind-address = 127.0.0.1
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
max_connections = 500
innodb_file_per_table = 1
innodb_file_format = Barracuda
innodb_large_prefix = 1
```
Don't be lazy and just copy-paste, First verify. Cause some of these lines are uncommented by default in the file.

**Restart the MariaDB service** to apply the new configuration.

```bash
sudo systemctl restart mariadb
```

---

## 🗃️ Step 3: Create the CloudStack Database

Log in to the MariaDB shell. You may be prompted for your sudo password.

```bash
sudo mysql -u root -p
```

Run the following SQL commands to **create a dedicated database and user** for CloudStack.

```sql
CREATE DATABASE cloud CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON cloud.* TO 'cloud'@'localhost' IDENTIFIED BY 'cloudpass';
FLUSH PRIVILEGES;
EXIT;
```
You may change DB Name or Password 'Cloudpass' to anything you like.
---

## ☁️ Step 4: Install CloudStack Management Server

**Add the official CloudStack 4.20 repository** to your system.

```bash
echo "deb http://download.cloudstack.org/ubuntu jammy 4.20 main" | sudo tee /etc/apt/sources.list.d/cloudstack.list
wget -O - https://download.cloudstack.org/release.asc | sudo apt-key add -
```

Update your package list and **install the `cloudstack-management` package**.

```bash
sudo apt update
sudo apt install cloudstack-management -y
sudo apt install qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst
```

---

## 🧱 Step 5: Initialize the CloudStack Database

Run the setup script to **initialize the database schema**. This command uses the credentials (`cloud:cloudpass`) you created in Step 3.

```bash
sudo cloudstack-setup-databases cloud:cloudpass@localhost --deploy-as=root
```
**For Noobs:** Make sure the password has no special characters or wrap credentials in single quotes like 'cloud:cloudpass&!' otherwise, It will keep exiting in error db not found or similar. 

If you are running the KVM hypervisor on the same machine with the Management Server, edit /etc/sudoers and add the following line:
```bash
Defaults:cloud !requiretty
```

### 🧱 Step 5.1: Verify that all services are up and running
```bash
sudo virt-host-validate
```
Confirm libvirt sees your host as KVM
```bash
virsh list --all
```
---

## 🚀 Step 6: Start the Management Server

**Enable the CloudStack service** to start on boot and then start it immediately.

```bash
sudo apt-get install cloudstack-agent
sudo systemctl enable cloudstack-management
sudo systemctl start cloudstack-management
```
Now, you need to change the hostname `host` in `agent.properties`, otherwise the agent wont run.
```bash
# Look foor host= then change it to the severs Public IP.
nano /etc/cloudstack/agent/agent.properties
# Now, check if it has been reflected.
grep "host=" /etc/cloudstack/agent/agent.properties
```
Don't forget `guid=`
I like adding at like:
```bash
# For dummies: This is a commmand. Run it in the terminal ;p
GUID=$(uuidgen)
echo "Generated GUID: $GUID"
```
Then I add `$GUID` so it'll be like `guid=$GUID` in agent.properties
You might also need to generate new certs so that they can match.

Change your cluster name in agent.properties as well. it's named `default` by dafault 😂. So, You'll need to either name the cluster `default` in the wizard or change that in agent.properties.

Add the following and change ens9 to yours.
```bash
libvirt.uri=qemu:///system
hypervisor.type=kvm
private.network.device=eth0
guest.network.device=eth0
public.network.device=eth0
```
---

## 🌐 Step 7: Access the CloudStack UI

The management server is now running! You can access the web interface by navigating to the following URL in your browser.

**Note:** Replace `<your-server-ip>` with your server's public or private IP address.

`http://<your-server-ip>:8080/client`
Make sure you setup the firewall properly, Please check cloudtsack documenation for that.

##  Step 8: Using the Management Server as the NFS Server

```bash
apt install nfs-kernel-server
# Create New Folders on the server
mkdir -p /export/primary
mkdir -p /export/secondary
```
To configure the new directories as NFS exports, edit /etc/exports. Export the NFS share(s) with rw,async,no_root_squash,no_subtree_check. For example: Open `nano /etc/exports` and add:
```bash 
/export  *(rw,async,no_root_squash,no_subtree_check)
```
Now export the folder
```bash
exportfs -a
```
Now open `/etc/sysconfig/nfs` and Add/Uncomment the following:
```bash
LOCKD_TCPPORT=32803
LOCKD_UDPPORT=32769
MOUNTD_PORT=892
RQUOTAD_PORT=875
STATD_PORT=662
STATD_OUTGOING_PORT=2020
```

Now  next `nano /etc/sysconfig/iptables` and add:

```bash
# Change ens9 to the network you are using.
-A INPUT -s ens9 -m state --state NEW -p udp --dport 111 -j ACCEPT
-A INPUT -s ens9 -m state --state NEW -p tcp --dport 111 -j ACCEPT
-A INPUT -s ens9 -m state --state NEW -p tcp --dport 2049 -j ACCEPT
-A INPUT -s ens9 -m state --state NEW -p tcp --dport 32803 -j ACCEPT
-A INPUT -s ens9 -m state --state NEW -p udp --dport 32769 -j ACCEPT
-A INPUT -s ens9 -m state --state NEW -p tcp --dport 892 -j ACCEPT
-A INPUT -s ens9 -m state --state NEW -p udp --dport 892 -j ACCEPT
-A INPUT -s ens9 -m state --state NEW -p tcp --dport 875 -j ACCEPT
-A INPUT -s ens9 -m state --state NEW -p udp --dport 875 -j ACCEPT
-A INPUT -s ens9 -m state --state NEW -p tcp --dport 662 -j ACCEPT
-A INPUT -s ens9 -m state --state NEW -p udp --dport 662 -j ACCEPT
```
Then
```bash
service iptables restart
service iptables save
```
Now Check if everything is setup:
```bash
service rpcbind start
service nfs start
chkconfig nfs on
chkconfig rpcbind on
reboot
```
## 9: Prepare the System VM Template
For Instance I am planning on using KMV, the setup would be as follows:
```bash
/usr/share/cloudstack-common/scripts/storage/secondary/cloud-install-sys-tmplt -m /mnt/secondary -u http://download.cloudstack.org/systemvm/4.20/systemvmtemplate-4.20.1-x86_64-kvm.qcow2.bz2 -h kvm -F
```

if you set encryption in DB to web, then add thsi to the end of the above command: `-s <optional-management-server-secret-key>` before `-F`.
### Now Restart Cloudstack.
```bash
sudo systemctl restart cloudstack-management
```

### Adding Your First Host

When adding the host in the wizard:
- **Host Name**: Your server's FQDN
- **Username**: root
- **Authentication**: SSH Key (recommended) or Password

If using SSH key, the installer already set this up for you. The CloudStack public key is in `/var/lib/cloudstack/management/.ssh/id_rsa.pub` and has been added to root's authorized_keys.

# Now you are done, See documentation for more Info if you'd Like.
# Leave a start if this was helpful so others can see it github@abdessalllam
