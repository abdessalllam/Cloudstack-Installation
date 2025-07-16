# CloudStack 4.20 Installation Guide

Hey there! 👋 This is mainly for me but what the heck, feel free to use and edit. This installer will get you up and running with a  "sort of" LOL production-ready CloudStack deployment faster than you can say "virtual machine". But lets be honest if you use this cause your installation kept failing, probably you should hire a freelancer ;p.  
## For Manual Install
See the Instructions here: [Manual Installation Instractions](https://github.com/abdessalllam/Cloudstack-Installation/blob/main/Manual_Install.md)

## What This Thing Does

This script is basically your CloudStack installation buddy. It'll handle all the boring stuff like:
- Setting up KVM hypervisor
- Configuring MariaDB database (properly tuned, not just the defaults)
- Installing CloudStack management server
- Creating NFS storage for your VMs
- Setting up networking with bridges (because VMs need to talk to the world)
- Configuring all the security bits

## Before You Start
- You may or may not run `./safe_network_test.sh` before running the main Installer to check if your network is bridgeable (Not even sure if that a word. Hahhh). It's not required. So, Anyway, You do you.
  
### Hardware Requirements
Listen, don't try to run this on a potato. You'll need:
- **CPU**: Something with VT-x (Intel) or AMD-V (AMD) - basically any decent server CPU from the last decade
- **RAM**: 8GB minimum, but honestly 64GB+ is better if you want to run multiple actual VMs
- **Storage**: 
  - At least 50GB for the OS and CloudStack
  - A separate disk for secondary storage (this is where VM templates live) but not a requirement.
- **Network**: A proper network interface (not WiFi, please Hahhhh)

### Software Requirements
- Ubuntu 22.04 LTS or 24.04 LTS (fresh install recommended)
- Root access (you'll need `sudo`) for this script*
- Internet connection (the script downloads stuff), I got time to kill by writing this nonsense.

## Getting Started

### Step 1: Download and Prepare

First, grab the installer:
```bash
git clone https://github.com/abdessalllam/Cloudstack-Installation
cd Cloudstack-Installation
chmod +x install.sh
```

### Step 2: Gather Your Information

Before running the script, have these ready:
- **FQDN**: Something like `cloudstack.yourdomain.com` (make sure DNS points to your server)
- **Database name**: Usually just `cloud` works fine
- **Database user**: Pick something like `cloudstack_user`
- **Passwords**: Strong ones! At least 8 characters, mix of letters/numbers/symbols
- **Secondary storage disk**: Like `/dev/sdb` - this will be wiped clean!

### Step 3: Run the Installer

Time for the magic:
```bash
sudo ./install.sh
```

The script will ask you questions like:
```
Enter FQDN for this server (e.g. cs.example.com): cloudstack.mydomain.com
CloudStack DB name [cloud]: cloud
CloudStack DB user: cloudstack_user
CloudStack DB user password: [your strong password]
MySQL root password: [another strong password]
Block device for Secondary storage (e.g. /dev/sdb): /dev/sdb
```

### Step 4: Grab a Coffee ☕

The installation takes about 10-15 minutes depending on your internet speed. The script will:
- Check if your system is compatible
- Configure networking (creates a bridge interface)
- Install all the packages
- Set up the database
- Configure storage
- Start all services

### Step 5: Reboot (Important!)

After the script finishes, **you must reboot**:
```bash
sudo reboot
```

This activates the IOMMU and cgroup settings needed for virtualization.

## Post-Installation
### **NEW** Now proceed to step 2 (Optional)
Required if you are using the same server for hosting VM's and/or Storage.
Step 2 Installer is from 8 Step in [Manual Installation Instractions](https://github.com/abdessalllam/Cloudstack-Installation/blob/main/Manual_Install.md).
```bash
chmod +x install.sh
sudo ./install.sh
```
After this, You may verify if everything works with the next step and then you may skip the rest.

### Verify Everything Works

After reboot, check if virtualization is properly configured:
```bash
sudo virt-host-validate
```

You should see all "PASS" messages. If you see "FAIL" messages, something went wrong.

Check your services:
```bash
sudo systemctl status cloudstack-management
sudo systemctl status mysql
sudo systemctl status libvirtd
sudo systemctl status nfs-kernel-server
```

### Access the Web Interface

Open your browser and go to:
```
http://your-server-ip:8080/client/
```

Default login:
- **Username**: admin
- **Password**: password

**Change this password immediately!**

### Initial Setup Wizard

CloudStack will walk you through the initial setup:

1. **Change Admin Password**: First thing to do
2. **Configure Zone**: This is like your datacenter
3. **Set up Pod**: Think of this as a rack in your datacenter
4. **Create Cluster**: Group of hypervisor hosts
5. **Add Host**: Your server (the one you just installed)
6. **Configure Storage**: 
   - Primary: `/export/primary` (for VM disks)
   - Secondary: `/export/secondary` (for templates/ISOs)

### Adding Your First Host

When adding the host in the wizard:
- **Host Name**: Your server's FQDN
- **Username**: root
- **Authentication**: SSH Key (recommended) or Password

If using SSH key, the installer already set this up for you. The CloudStack public key is in `/var/lib/cloudstack/management/.ssh/id_rsa.pub` and has been added to root's authorized_keys.

## Troubleshooting

### Common Issues

**"Bridge not working"**: 
- Check if your network interface is up: `ip link show`
- Verify bridge has correct IP: `ip addr show br0`

**"Can't connect to database"**:
- Check MySQL is running: `systemctl status mysql`
- Verify database exists: `mysql -u root -p -e "SHOW DATABASES;"`

**"VMs won't start"**:
- Run `virt-host-validate` to check virtualization
- Make sure you rebooted after installation
- Check if IOMMU is enabled: `dmesg | grep -i iommu`

**"NFS issues"**:
- Check exports: `showmount -e localhost`
- Verify permissions: `ls -la /export/`

### Log Files

When things go wrong, check these logs:
- CloudStack: `/var/log/cloudstack/management/`
- MySQL: `/var/log/mysql/`
- System: `journalctl -u cloudstack-management`

## Network Configuration Details

The installer creates a bridge (`br0`) that:
- Takes over your main network interface
- Allows VMs to get IP addresses from your network
- Maintains connectivity to your server

Your network config will look something like:
```
Physical NIC → Bridge (br0) → VMs
```

## Storage Layout

After installation, you'll have:
- **Primary Storage**: `/export/primary` (NFS) - VM disks live here
- **Secondary Storage**: `/export/secondary` (NFS) - Templates and ISOs

Both are exported via NFS so CloudStack can manage them.

## Security Notes

The installer configures:
- UFW firewall with only necessary ports open
- MySQL with secure settings
- SSH keys for host managment
- NFS with proper access controls

But remember to:
- Change default passwords
- Keep your system updated
- Monitor access logs
- Consider additional security measures for production

## What's Next?

Now that CloudStack is running, you can:
1. Download some VM templates (CentOS, Ubuntu, etc.)
2. Create networks for your VMs
3. Set up service offerings (VM sizes)
4. Start creating virtual machines!

Check out the [CloudStack documentation](https://docs.cloudstack.org/) for more advanced configuration.

## Getting Help

If you run into issues:
- Check the CloudStack community forums
- Look at the official documentation
- Review the log files mentioned above
- Make sure you followed all the steps (especially the reboot!)

Remember, this is a complex system with many moving parts. Don't panic if something doesn't work immediately - troubleshooting is part of the fun! 😄

## Final Tips

- **Backup your configuration**: Once everything is working, backup your database and config files
- **Monitor resources**: Keep an eye on CPU, memory, and disk usage
- **Plan your network**: Think about how VMs will communicate before creating a bunch of them
- **Start small**: Create a test VM first before going crazy with deployments

Good luck with your CloudStack jurney! 🚀
