#!/bin/bash
#!/usr/bin/env bash
#===============================================================================
#  Script Name   : init.sh
#  Description   : Automated offline Kubernetes control-plane setup with
#                  containerd, image preload, and Flannel CNI configuration.
#
#  Author        : Jeeva D
#  Created Date  : 2026-02-17
#  Last Modified : 2026-02-19
#  Version       : 1.1.0
#  Email         : jeeva.d87@gmail.com
#
#  Usage         : bash init.sh
#
#  Requirements  :
#    - Rocky Linux 9 / Centos stream 9/ RHEL 9 
#    - Root privileges
#    - Offline RPMs available
#    - Pre-downloaded container images (.tar)
#
#  Components Installed:
#    - containerd
#    - kubeadm, kubelet, kubectl
#    - Flannel CNI
#
#  Notes:
#    - Script is idempotent (safe to run multiple times)
#    - Skips already configured components
#    - Designed for production-ready offline environments
#
#  Exit Codes:
#    0  - Success
#    1  - General error
#    2  - Missing dependency
#
#===============================================================================
set -euo pipefail

echo "====================================================="
echo "    Installation of Kubernetes v1.29.15"
echo "====================================================="
echo "Current Hostname  : $(hostname -f)"
if [ -f /etc/redhat-release ];then
echo "OS version Runing : $(cat /etc/redhat-release)"
fi


if [ "${1:-}" = "-y" ]; then
    confirm="y"
else
    echo -n "Press Y to proceed, N to exit: "
    read confirm
fi

if [ "${confirm:-}" = "Y" ] || [ "${confirm:-}" = "y" ]; then
    echo "installation begins..."
else
    echo "installation aborted!"
    exit 1
fi

# Reset
RESET="\e[0m"

# Bold colors
BOLD_BLACK="\e[1;30m"
BOLD_RED="\e[1;31m"
BOLD_GREEN="\e[1;32m"
BOLD_YELLOW="\e[1;33m"
BOLD_BLUE="\e[1;34m"
BOLD_MAGENTA="\e[1;35m"
BOLD_CYAN="\e[1;36m"
BOLD_WHITE="\e[1;37m"


#----------------#
# Update system  #
#----------------#
#dnf update -y
#dnf install -y *.rpm

#-----------------------#
# Package installation  #
#-----------------------#

echo -e $BOLD_CYAN "=== Installing the dependency Packages ===" $RESET
SYS_RPM="tar wget vim-enhanced conntrack-tools.x86_64 container-selinux.noarch iproute-tc.x86_64 libnetfilter_cthelper.x86_64 libnetfilter_cttimeout.x86_64 libnetfilter_queue.x86_64 socat.x86_64"

if ! rpm -q $SYS_RPM &>/dev/null ; then
	
    yum install -y $SYS_RPM
    if [[ $? == "0" ]]
    then
        echo "System package installed successfully."
    else
        echo "System package installation failed !, aborting."
	rpm -q $SYS_RPM | grep "not install"
	exit 1
    fi
else
    echo "System package already installed."
fi


	

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPMS_DIR="$BASE_DIR/rpms"
IMAGES_DIR="$BASE_DIR/images"
YAML_DIR="$BASE_DIR/yaml"
GPG_DIR="$BASE_DIR/gpgkey"
#-------------------------------------#
# Phase 1 — Install packages offline  #
#-------------------------------------#
echo ""
echo -e $BOLD_MAGENTA"Phase 1: Install packages of Kubernetes and Containerd "$RESET
echo -e $BOLD_CYAN "=== Installing the Packages ===" $RESET

if grep -q "Linux release 9" /etc/redhat-release ; then
    yum install -y "$RPMS_DIR"/rh9/containerd.io*.rpm
elif grep -q "Stream release 9" /etc/redhat-release ; then
    yum install -y "$RPMS_DIR"/rh9/containerd.io*.rpm
elif grep -q "Linux release 8" /etc/redhat-release ; then
    yum install -y "$RPMS_DIR"/rh8/containerd.io*.rpm
elif grep -q "Stream release 8" /etc/redhat-release ; then
    yum install -y "$RPMS_DIR"/rh8/containerd.io*.rpm
else
    echo "The OS version is not supported, Supported OS versions are ROCKY 9, ROCKY8, RHEL 9 and RHEL 8"
    exit 1
fi

for gpg_key in "$GPG_DIR"/*{gpg,key}; do
    [ -f "$gpg_key" ] || continue
    KEY_FINGERPRINT=$(gpg --with-colons --import-options show-only --import "$gpg_key" 2>/dev/null\
                        | awk -F: '/fpr/ {print $10; exit}')
    if ! rpm -q gpg-pubkey-"$(echo "$KEY_FINGERPRINT" | tr -d '[:upper:]')" &>/dev/null; then
        rpm --import "$gpg_key" 2>/dev/null
    fi
done

RPM_FILE_TO_INSTALL=""
for rpm_file in "$RPMS_DIR"/*.rpm; do
    pkg_name=$(rpm -qp --queryformat '%{NAME}' "$rpm_file")
    if ! rpm -q "$pkg_name" &>/dev/null; then
        RPM_FILE_TO_INSTALL+=" $rpm_file"
    fi
done

if [ -n "$RPM_FILE_TO_INSTALL" ]; then
    dnf install -y $RPM_FILE_TO_INSTALL
else
    echo "All RPMs are already installed."
fi

#--------------------------------#
# Phase 2 starting the services  #
#--------------------------------#
echo ""
echo -e $BOLD_MAGENTA"Phase 2: starting the services"$RESET
echo -e $BOLD_CYAN "=== Starting the services ===" $RESET

SERVICES=("containerd" "kubelet")

for svc in "${SERVICES[@]}"; do
    # Check if service is enabled
    if systemctl is-enabled "$svc" &>/dev/null; then
        echo "Service '$svc' is already enabled."
    else
        echo "Enabling service '$svc'..."
        systemctl enable "$svc"
    fi

    # Check if service is active (running)
    if systemctl is-active "$svc" &>/dev/null; then
        echo "Service '$svc' is already running."
    else
        echo "Starting service '$svc'..."
        systemctl start "$svc"
    fi
done



#--------------------------------------------#
# Phase 3 — Configure containerd (CRITICAL)  #
#--------------------------------------------#
echo ""
echo -e $BOLD_MAGENTA"Phase 3: Configure of containerd "$RESET
echo -e $BOLD_CYAN "=== Configure containerd ===" $RESET

CONFIG_FILE="/etc/containerd/config.toml"
TMP_FILE=$(mktemp)

# Generate default config
containerd config default > "$TMP_FILE"

# Ensure SystemdCgroup = true
if grep -q 'SystemdCgroup' "$TMP_FILE"; then
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "$TMP_FILE"
else
    # Add the required section if missing
    cat >> "$TMP_FILE" <<EOF

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true
EOF
fi

# Replace existing config only if different
if [ -f "$CONFIG_FILE" ] && cmp -s "$CONFIG_FILE" "$TMP_FILE"; then
    echo "Containerd config is already up-to-date. Skipping update and restart."
    rm "$TMP_FILE"
else
    echo "Updating containerd config at $CONFIG_FILE..."
    mv "$TMP_FILE" "$CONFIG_FILE"
    echo "Restarting containerd service to apply changes..."
    systemctl restart containerd
fi

# Wait for containerd socket with timeout
echo "Waiting for containerd to be ready..."

MAX_WAIT=120   # total wait time in seconds (2 minutes)
INTERVAL=2     # check interval
ELAPSED=0

until [ -S /run/containerd/containerd.sock ]; do
    if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
        echo "ERROR: containerd socket not found after ${MAX_WAIT}s. Aborting."
        exit 2
    fi

    echo "containerd not ready yet... (${ELAPSED}s elapsed)"
    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))
done

echo "containerd ready."


#------------------------------------------------------#
# Phase 4 — Disable swap, kernel settings & Firewalld #
#------------------------------------------------------#
echo ""
echo -e $BOLD_MAGENTA"Phase 4: Disable swap, kernel settings & Firewalld"$RESET
echo -e $BOLD_CYAN "=== Swap configuration ===" $RESET
# Turn off swap only if it is on
if swapon --summary | grep -q '^'; then
    echo "Disabling swap..."
    swapoff -a
else
    echo "Swap is already off. Skipping."
fi

# Remove swap entries from /etc/fstab only if present
if grep -q 'swap' /etc/fstab; then
    echo "Removing swap entries from /etc/fstab..."
    sed -i '/swap/d' /etc/fstab
else
    echo "No swap entries in /etc/fstab. Skipping."
fi

# Kernel modules
echo ""
echo -e $BOLD_CYAN "=== Kernel modules configuration ===" $RESET
MODULES_FILE="/etc/modules-load.d/k8s.conf"

for module in overlay br_netfilter; do
    # Load module if not already loaded
    if ! lsmod | grep -q "^$module"; then
        echo "Loading kernel module: $module"
        modprobe "$module"
    else
        echo "Kernel module $module already loaded. Skipping."
    fi
done

# Ensure modules are present in modules-load file
mkdir -p "$(dirname "$MODULES_FILE")"
for module in overlay br_netfilter; do
    if ! grep -qx "$module" "$MODULES_FILE" 2>/dev/null; then
        echo "$module" >> "$MODULES_FILE"
        echo "Added $module to $MODULES_FILE"
    fi
done

# Sysctl settings
echo ""
echo -e $BOLD_CYAN "=== Sysctl configuration ===" $RESET
SYSCTL_FILE="/etc/sysctl.d/k8s.conf"

declare -A SYSCTL_SETTINGS=(
    [net.bridge.bridge-nf-call-iptables]=1
    [net.bridge.bridge-nf-call-ip6tables]=1
    [net.ipv4.ip_forward]=1
)

INSERT_SYS="0"
mkdir -p "$(dirname "$SYSCTL_FILE")"
for key in "${!SYSCTL_SETTINGS[@]}"; do
    desired_value="${SYSCTL_SETTINGS[$key]}"
    current_value=$(sysctl -n "$key" 2>/dev/null || echo "unset")

    if [ "$current_value" != "$desired_value" ]; then
        echo "$key = $desired_value" >> "$SYSCTL_FILE"
        echo "Setting $key = $desired_value in $SYSCTL_FILE"
	INSERT_SYS="1"
    fi
done

if [[ $INSERT_SYS == "1" ]]
then
    # Apply sysctl settings
    echo "Apply sysctl settings"
    sysctl --system
else
    echo "Sysctl configuration is already set. Skipping."
fi

# Firewalld
echo ""
echo -e $BOLD_CYAN "=== Firewalld configuration ===" $RESET
FIREWALLD_P="0"
if systemctl is-active --quiet firewalld; then
    PORTS=("6443/tcp" "10250/tcp")
    for port in "${PORTS[@]}"; do
        if ! firewall-cmd --list-ports | grep -qw "$port"; then
            echo "Adding firewall port $port"
            firewall-cmd --permanent --add-port="$port"
            FIREWALLD_P="1"
        fi
    done
    if [[ $FIREWALLD_P == "1" ]]; then
        echo "Reloading firewalld to apply changes..."
        firewall-cmd --reload
    else
        echo "Firewall ports already configured. Skipping."
    fi
else
    echo "Firewalld is not active. Skipping configuration."
fi

#-----------------------------------------#
# Phase 5 — Initialize Kubernetes master  #
#-----------------------------------------#
echo ""
echo -e $BOLD_MAGENTA"Phase 5: Initialize Kubernetes master "$RESET

echo -e "${BOLD_CYAN} === Import images of Kubernetes ===${RESET}"

IMAGES_TAR=(
    "$IMAGES_DIR/k8s-control-plane.tar"
    "$IMAGES_DIR/flannel.tar"
)

IMPORT_SUCCESS=true

for TAR_FILE in "${IMAGES_TAR[@]}"; do
    echo  "Checking images in $TAR_FILE"

    # Extract index.json from the tar
    TMP_INDEX=$(mktemp)
    tar -xf "$TAR_FILE" index.json -O > "$TMP_INDEX"

    # Read image names inside tar
    # For containerd OCI tars:
    IMAGES_IN_TAR=$(jq -r '.manifests[].annotations."io.containerd.image.name"' "$TMP_INDEX")

    MISSING=false
    for img in $IMAGES_IN_TAR; do
        if ! ctr -n k8s.io images list | awk '{print $1}' | grep -Fxq "$img"; then
            MISSING=true
        fi
    done

    # Import tar if any image is missing
    if [ "$MISSING" = true ]; then
        echo "   Importing tar $TAR_FILE ..."
        if ctr -n k8s.io images import "$TAR_FILE"; then
            echo "   Imported $TAR_FILE successfully."
        else
            echo -e "${BOLD_RED}   Failed to import $TAR_FILE${RESET}"
            IMPORT_SUCCESS=false
        fi
    else
        echo "   All images in $TAR_FILE already exist. Skipping import."
    fi

    rm -f "$TMP_INDEX"
done

# Initialize Kubernetes cluster if all images imported
echo ""
echo -e "${BOLD_CYAN} === Initialize Kubernetes cluster ===${RESET}"
if [ "$IMPORT_SUCCESS" = true ]; then
    KUBE_ADMIN_CONF="/etc/kubernetes/admin.conf"
    if [ -f "$KUBE_ADMIN_CONF" ]; then
        echo "Kubernetes cluster is already initialized. Skipping 'kubeadm init'."
    else
        echo "Initializing Kubernetes cluster..."
        kubeadm init --pod-network-cidr=10.244.0.0/16 --cri-socket=unix:///run/containerd/containerd.sock

        # Setup kubeconfig for root user
        mkdir -p $HOME/.kube
        cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
        chown $(id -u):$(id -g) $HOME/.kube/config

        echo "Kubernetes cluster initialized successfully."
    fi
else
    echo -e "${BOLD_RED}One or more images failed to import. Cluster initialization skipped.${RESET}"
fi

echo -e "${BOLD_CYAN} === Applying Flannel network plugin ===${RESET}"
FLANNEL_NAMESPACE="kube-flannel"
FLANNEL_DAEMONSET="kube-flannel-ds"
FLANNEL_YAML="$YAML_DIR/kube-flannel.yml"

echo "Waiting for API server to be ready..."

MAX_WAIT=180   # total wait time in seconds (3 minutes)
INTERVAL=5     # check interval
ELAPSED=0

until kubectl get --raw='/healthz' &>/dev/null; do
    if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
        echo "ERROR: API server did not become ready within ${MAX_WAIT}s. Aborting."
        exit 2
    fi

    echo "API server not ready yet... (${ELAPSED}s elapsed)"
    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))
done

echo "API server is ready!"


echo -e "${BOLD_CYAN}Applying Flannel network plugin${RESET}"

# Check if Flannel DaemonSet exists in the correct namespace
if kubectl get daemonset -n kube-flannel "$FLANNEL_DAEMONSET" &>/dev/null; then
    echo "Flannel is already applied in namespace $FLANNEL_NAMESPACE. Skipping $FLANNEL_YAML."
else
    echo "Applying $FLANNEL_YAML..."
    kubectl apply -f "$FLANNEL_YAML"
    echo "Flannel applied successfully."
fi

echo ""
echo "==============================================================="
echo " Kubernetes master Status:  $(kubectl get --raw='/readyz')"
echo "==============================================================="
kubectl get --raw='/version'
echo "====================================================="
echo ""
exit 0
