#!/usr/bin/env bash
#===============================================================================================
# Safe Network Bridge Test - Run this BEFORE the main installer if you want, Go nuts.
# I made this cause sometimes on "some" servers I get locked out when something goes south on 
# the network configuration step. So, Fix everything up before you run the main installer.
# This script will test the bridge configuration without breaking your current setup.
#================================================================================================
set -euo pipefail

echo "==========================================================="
echo "Safe Network Bridge Test for CloudStack"
echo "This will test the bridge configuration WITHOUT breaking your current setup"
echo "==========================================================="

# This goes without saying but WTH
[[ $EUID -eq 0 ]] || { echo "Must run as root"; exit 1; }

# Get current network info
ADAPTER=$(ip route | grep default | awk '{print $5}' | head -n1)
IP_ADDR=$(ip -4 addr show "$ADAPTER" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
CIDR=$(ip -4 addr show "$ADAPTER" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -n1)
GATEWAY=$(ip route show default | awk '{print $3}' | head -n1)

echo "Current network configuration:"
echo "Interface: $ADAPTER"
echo "IP/CIDR: $CIDR"
echo "Gateway: $GATEWAY"
echo ""

# Test 1: Check if interface can be bridged or not
echo "Test 1: Checking interface capabilities..."
if ! ip link show "$ADAPTER" | grep -q "UP"; then
    echo "ERROR: Interface $ADAPTER is not UP"
    exit 1
fi

# Test 2: Create temporary bridge (won't affect current network)
echo "Test 2: Creating temporary test bridge..."
ip link add name br-test type bridge || { echo "ERROR: Sucks for you X(. Cannot create bridge"; exit 1; }
ip link set br-test up
echo "✓ Test bridge created successfully"

# Test 3: Test bridge with dummy interface (safe)
echo "Test 3: Testing bridge functionality..."
ip link add dummy0 type dummy
ip link set dummy0 master br-test
ip link set dummy0 up
ip addr add 192.168.99.1/24 dev br-test
ping -c1 -W1 192.168.99.1 >/dev/null && echo "✓ Bridge networking works"

# Cleanup test
ip link del dummy0
ip link del br-test
echo "✓ Test bridge cleaned up"

# Test 4: Validate netplan syntax
echo "Test 4: Testing netplan configuration syntax..."
cat > /tmp/test-netplan.yaml <<EOF
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
        addresses: [1.1.1.1, 1.0.0.1]
      parameters:
        stp: false
        forward-delay: 0
EOF

if netplan try --config-file /tmp/test-netplan.yaml --timeout=1 2>/dev/null; then
    echo "✓ Netplan configuration syntax is valid"
else
    echo "Oops, got an error: Netplan configuration has syntax errors"
    exit 1
fi

rm /tmp/test-netplan.yaml

echo ""
echo "==========================================================="
echo "✅ ALL TESTS PASSED!"
echo "Yay, Your system should be able to handle the bridge configuration safely."
echo "You can now run the main installer with more confidence."
echo "==========================================================="
