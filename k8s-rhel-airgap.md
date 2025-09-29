# Kubernetes Air-Gapped Installation on RHEL - Complete Guide

This guide covers setting up Kubernetes v1.31.1 on RHEL 8/9 without internet access.

## Phase 1: Preparation (On Internet-Connected RHEL System)

### 1.1 System Requirements
- RHEL 8 or RHEL 9
- Minimum 2 CPU cores
- Minimum 2GB RAM
- 20GB disk space
- Root or sudo access

### 1.2 Download Kubernetes Binaries

```bash
# Set version
K8S_VERSION="1.31.1"
ARCH="amd64"

# Create download directory
mkdir -p ~/k8s-offline/{binaries,images,rpms,configs}
cd ~/k8s-offline

# Download Kubernetes binaries
curl -LO "https://dl.k8s.io/release/v${K8S_VERSION}/bin/linux/${ARCH}/kubeadm"
curl -LO "https://dl.k8s.io/release/v${K8S_VERSION}/bin/linux/${ARCH}/kubelet"
curl -LO "https://dl.k8s.io/release/v${K8S_VERSION}/bin/linux/${ARCH}/kubectl"

# Download kubelet systemd service file
curl -sSL "https://raw.githubusercontent.com/kubernetes/release/v0.16.2/cmd/krel/templates/latest/kubelet/kubelet.service" -o kubelet.service
curl -sSL "https://raw.githubusercontent.com/kubernetes/release/v0.16.2/cmd/krel/templates/latest/kubeadm/10-kubeadm.conf" -o 10-kubeadm.conf

# Make binaries executable
chmod +x kubeadm kubelet kubectl

# Move to binaries folder
mv kubeadm kubelet kubectl binaries/
mv kubelet.service 10-kubeadm.conf configs/
```

### 1.3 Download Container Runtime (containerd)

```bash
# Download containerd
CONTAINERD_VERSION="1.7.13"
curl -LO "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"

# Download runc
RUNC_VERSION="1.1.12"
curl -LO "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64"

# Download CNI plugins
CNI_VERSION="1.4.0"
curl -LO "https://github.com/containernetworking/plugins/releases/download/v${CNI_VERSION}/cni-plugins-linux-amd64-v${CNI_VERSION}.tgz"

# Download containerd systemd service
curl -LO "https://raw.githubusercontent.com/containerd/containerd/main/containerd.service"

mv containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz binaries/
mv runc.amd64 binaries/
mv cni-plugins-linux-amd64-v${CNI_VERSION}.tgz binaries/
mv containerd.service configs/
```

### 1.4 Download Required RPM Packages

```bash
cd ~/k8s-offline/rpms

# Download dependencies
yum install --downloadonly --downloaddir=. \
  socat \
  conntrack \
  ipset \
  iproute-tc \
  ebtables \
  ethtool \
  iptables \
  libseccomp \
  yum-utils \
  device-mapper-persistent-data \
  lvm2

# Also download any updates for existing packages
yum update --downloadonly --downloaddir=.
```

### 1.5 Pull and Save Container Images

```bash
cd ~/k8s-offline/images

# Install containerd temporarily to pull images (if not already installed)
# Or use Docker if available

# List all required images
cat > required-images.txt <<EOF
registry.k8s.io/kube-apiserver:v1.31.1
registry.k8s.io/kube-controller-manager:v1.31.1
registry.k8s.io/kube-scheduler:v1.31.1
registry.k8s.io/kube-proxy:v1.31.1
registry.k8s.io/coredns/coredns:v1.11.1
registry.k8s.io/pause:3.10
registry.k8s.io/etcd:3.5.15-0
quay.io/calico/cni:v3.27.0
quay.io/calico/node:v3.27.0
quay.io/calico/kube-controllers:v3.27.0
quay.io/calico/typha:v3.27.0
EOF

# Pull all images
while IFS= read -r image; do
  echo "Pulling $image..."
  ctr image pull $image || docker pull $image
done < required-images.txt

# Save images to tar file
ctr images export k8s-core-images.tar \
  registry.k8s.io/kube-apiserver:v1.31.1 \
  registry.k8s.io/kube-controller-manager:v1.31.1 \
  registry.k8s.io/kube-scheduler:v1.31.1 \
  registry.k8s.io/kube-proxy:v1.31.1 \
  registry.k8s.io/coredns/coredns:v1.11.1 \
  registry.k8s.io/pause:3.10 \
  registry.k8s.io/etcd:3.5.15-0

# Save CNI images
ctr images export calico-images.tar \
  quay.io/calico/cni:v3.27.0 \
  quay.io/calico/node:v3.27.0 \
  quay.io/calico/kube-controllers:v3.27.0 \
  quay.io/calico/typha:v3.27.0

# Alternative with Docker:
# docker save -o k8s-core-images.tar registry.k8s.io/kube-apiserver:v1.31.1 ...
# docker save -o calico-images.tar quay.io/calico/cni:v3.27.0 ...
```

### 1.6 Download CNI Manifests

```bash
cd ~/k8s-offline/configs

# Download Calico manifests
CALICO_VERSION="v3.27.0"
curl -LO "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

# Or download Flannel if preferred
# curl -LO "https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml"
```

### 1.7 Create Installation Scripts

```bash
cd ~/k8s-offline

cat > install-containerd.sh <<'SCRIPT'
#!/bin/bash
set -e

echo "Installing containerd..."

# Extract containerd
tar Cxzvf /usr/local containerd-*-linux-amd64.tar.gz

# Install runc
install -m 755 runc.amd64 /usr/local/sbin/runc

# Install CNI plugins
mkdir -p /opt/cni/bin
tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-*.tgz

# Create containerd config directory
mkdir -p /etc/containerd

# Generate default config
containerd config default > /etc/containerd/config.toml

# Enable systemd cgroup driver
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Install systemd service
cp containerd.service /etc/systemd/system/

# Enable and start containerd
systemctl daemon-reload
systemctl enable --now containerd

echo "Containerd installed successfully"
SCRIPT

cat > install-kubernetes.sh <<'SCRIPT'
#!/bin/bash
set -e

echo "Installing Kubernetes components..."

# Install binaries
install -m 755 kubeadm kubectl kubelet /usr/local/bin/

# Setup kubelet systemd service
mkdir -p /etc/systemd/system/kubelet.service.d
cp kubelet.service /etc/systemd/system/
cp 10-kubeadm.conf /etc/systemd/system/kubelet.service.d/

# Update service file to use correct binary path
sed -i 's|/usr/bin/kubelet|/usr/local/bin/kubelet|g' /etc/systemd/system/kubelet.service

# Enable kubelet
systemctl daemon-reload
systemctl enable kubelet

echo "Kubernetes components installed successfully"
SCRIPT

cat > system-setup.sh <<'SCRIPT'
#!/bin/bash
set -e

echo "Configuring system for Kubernetes..."

# Disable SELinux (or set to permissive)
setenforce 0
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

# Disable firewall (or configure ports)
systemctl stop firewalld
systemctl disable firewalld

# Disable swap
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# Load required kernel modules
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Set required sysctl params
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

echo "System configured successfully"
SCRIPT

chmod +x install-containerd.sh install-kubernetes.sh system-setup.sh
```

### 1.8 Package Everything

```bash
cd ~
tar -czf k8s-offline-rhel.tar.gz k8s-offline/

echo "Package created: k8s-offline-rhel.tar.gz"
echo "Transfer this file to your air-gapped RHEL systems"
```

---

## Phase 2: Installation (On Air-Gapped RHEL System)

### 2.1 Transfer and Extract

```bash
# Transfer k8s-offline-rhel.tar.gz to the air-gapped system
# Then extract it

tar -xzf k8s-offline-rhel.tar.gz
cd k8s-offline
```

### 2.2 Install RPM Dependencies

```bash
cd rpms
sudo yum localinstall -y *.rpm
cd ..
```

### 2.3 Configure System

```bash
cd ~/k8s-offline
sudo ./system-setup.sh
```

### 2.4 Install containerd

```bash
cd ~/k8s-offline/binaries
sudo ../install-containerd.sh

# Verify containerd is running
sudo systemctl status containerd
```

### 2.5 Load Container Images

```bash
cd ~/k8s-offline/images

# Import images into containerd
sudo ctr -n k8s.io images import k8s-core-images.tar
sudo ctr -n k8s.io images import calico-images.tar

# Verify images are loaded
sudo crictl images
```

### 2.6 Install Kubernetes Binaries

```bash
cd ~/k8s-offline/binaries
sudo ../install-kubernetes.sh

# Verify installation
kubeadm version
kubectl version --client
```

---

## Phase 3: Initialize Kubernetes Cluster (Master Node)

### 3.1 Create kubeadm Configuration

```bash
cd ~/k8s-offline/configs

cat > kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v1.31.1
networking:
  podSubnet: 192.168.0.0/16
  serviceSubnet: 10.96.0.0/12
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  taints: []
EOF
```

### 3.2 Initialize Cluster

```bash
sudo kubeadm init --config kubeadm-config.yaml --upload-certs

# Setup kubeconfig for current user
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Verify cluster
kubectl get nodes
kubectl get pods -A
```

### 3.3 Install CNI Plugin (Calico)

```bash
# Apply Calico manifest
kubectl apply -f calico.yaml

# Wait for all pods to be running
kubectl get pods -n kube-system -w
```

### 3.4 Verify Cluster

```bash
# Check node status
kubectl get nodes

# Check all pods
kubectl get pods -A

# Check cluster info
kubectl cluster-info

# Node should show as Ready
# All system pods should be Running
```

---

## Phase 4: Join Worker Nodes (Optional)

### 4.1 On Worker Nodes

Repeat Phase 2 (steps 2.1-2.6) on each worker node.

### 4.2 Get Join Command from Master

```bash
# On master node
sudo kubeadm token create --print-join-command
```

### 4.3 Join Worker to Cluster

```bash
# On worker node, run the join command from above
sudo kubeadm join <master-ip>:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --cri-socket unix:///run/containerd/containerd.sock
```

### 4.4 Verify Worker Joined

```bash
# On master node
kubectl get nodes

# All nodes should show as Ready
```

---

## Phase 5: Post-Installation

### 5.1 Test Deployment

```bash
# Create a test deployment
kubectl create deployment nginx --image=nginx:latest --replicas=2

# This will fail without internet - you need to pre-load nginx image
# Better test with a local image or pre-loaded image

# Delete test
kubectl delete deployment nginx
```

### 5.2 Deploy Sample Application (Using Pre-loaded Images)

```bash
cat > test-pod.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
spec:
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.10
EOF

kubectl apply -f test-pod.yaml
kubectl get pods
```

### 5.3 Enable kubectl Autocomplete

```bash
echo 'source <(kubectl completion bash)' >>~/.bashrc
echo 'alias k=kubectl' >>~/.bashrc
echo 'complete -o default -F __start_kubectl k' >>~/.bashrc
source ~/.bashrc
```

---

## Troubleshooting

### Check Logs

```bash
# Check kubelet logs
sudo journalctl -xeu kubelet

# Check containerd logs
sudo journalctl -xeu containerd

# Check pod logs
kubectl logs <pod-name> -n <namespace>
```

### Common Issues

**Issue: Kubelet not starting**
```bash
# Check kubelet status
sudo systemctl status kubelet

# Check kubelet config
cat /var/lib/kubelet/config.yaml

# Restart kubelet
sudo systemctl restart kubelet
```

**Issue: Pods stuck in Pending**
```bash
# Check node resources
kubectl describe nodes

# Check pod events
kubectl describe pod <pod-name>
```

**Issue: CoreDNS not working**
```bash
# Check CoreDNS pods
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Check CoreDNS logs
kubectl logs -n kube-system -l k8s-app=kube-dns
```

### Reset Cluster (if needed)

```bash
# Reset kubeadm
sudo kubeadm reset

# Clean up
sudo rm -rf /etc/kubernetes/
sudo rm -rf ~/.kube/
sudo rm -rf /var/lib/etcd/
sudo rm -rf /var/lib/kubelet/

# Restart containerd
sudo systemctl restart containerd
```

---

## Security Considerations

1. **Enable SELinux** (after testing): Set `SELINUX=enforcing` in `/etc/selinux/config`
2. **Configure Firewall**: Open required ports instead of disabling firewall
   - Master: 6443, 2379-2380, 10250-10252
   - Worker: 10250, 30000-32767
3. **Enable RBAC**: Already enabled by default in Kubernetes 1.31
4. **Network Policies**: Configure Calico network policies
5. **Pod Security**: Enable Pod Security Standards

---

## Maintenance

### Backing Up

```bash
# Backup etcd
sudo ETCDCTL_API=3 etcdctl snapshot save snapshot.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Backup certificates
sudo tar -czf k8s-pki-backup.tar.gz /etc/kubernetes/pki/

# Backup kubeadm-config
kubectl get cm -n kube-system kubeadm-config -o yaml > kubeadm-config-backup.yaml
```

### Certificate Renewal

```bash
# Check certificate expiration
sudo kubeadm certs check-expiration

# Renew all certificates
sudo kubeadm certs renew all

# Restart control plane
sudo systemctl restart kubelet
```

---


## Summary

You now have a fully functional air-gapped Kubernetes cluster on RHEL! The cluster is running:
- Kubernetes v1.31.1
- containerd runtime
- Calico CNI
- All components isolated from the internet

For production use, consider:
- Setting up a private container registry
- Implementing proper backup strategies
- Configuring monitoring and logging
- Hardening security settings
- Planning upgrade procedures