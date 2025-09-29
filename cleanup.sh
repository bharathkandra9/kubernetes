#!/bin/bash
# complete-k8s-cleanup.sh - Complete Kubernetes cleanup script for RHEL

set -x  # Print commands as they execute

echo "================================"
echo "Starting Complete Kubernetes Cleanup"
echo "================================"

# 1. Reset kubeadm (if it was initialized)
echo "Step 1: Resetting kubeadm..."
sudo kubeadm reset -f || true

# 2. Stop all Kubernetes services
echo "Step 2: Stopping Kubernetes services..."
sudo systemctl stop kubelet || true
sudo systemctl stop containerd || true
sudo systemctl stop docker || true

# 3. Remove Kubernetes packages and binaries
echo "Step 3: Removing Kubernetes binaries..."
sudo rm -f /usr/local/bin/kubeadm
sudo rm -f /usr/local/bin/kubelet
sudo rm -f /usr/local/bin/kubectl
sudo rm -f /usr/bin/kubeadm
sudo rm -f /usr/bin/kubelet
sudo rm -f /usr/bin/kubectl

# 4. Remove systemd service files
echo "Step 4: Removing systemd service files..."
sudo rm -f /etc/systemd/system/kubelet.service
sudo rm -rf /etc/systemd/system/kubelet.service.d
sudo rm -f /usr/lib/systemd/system/kubelet.service
sudo systemctl daemon-reload

# 5. Remove Kubernetes configuration and data
echo "Step 5: Removing Kubernetes configuration..."
sudo rm -rf /etc/kubernetes
sudo rm -rf ~/.kube
sudo rm -rf /root/.kube
sudo rm -rf /var/lib/kubelet
sudo rm -rf /var/lib/etcd
sudo rm -rf /var/lib/cni
sudo rm -rf /etc/cni

# 6. Remove containerd
echo "Step 6: Removing containerd..."
sudo systemctl stop containerd || true
sudo systemctl disable containerd || true
sudo rm -f /etc/systemd/system/containerd.service
sudo rm -rf /etc/containerd
sudo rm -rf /var/lib/containerd
sudo rm -f /usr/local/bin/containerd*
sudo rm -f /usr/local/bin/ctr
sudo rm -f /usr/local/sbin/runc

# 7. Remove CNI plugins
echo "Step 7: Removing CNI plugins..."
sudo rm -rf /opt/cni

# 8. Clean up network interfaces
echo "Step 8: Cleaning up network interfaces..."
sudo ip link delete cni0 2>/dev/null || true
sudo ip link delete flannel.1 2>/dev/null || true
sudo ip link delete kube-ipvs0 2>/dev/null || true
sudo ip link delete docker0 2>/dev/null || true

# Clean up all veth interfaces
for iface in $(ip -o link show | grep veth | awk -F': ' '{print $2}'); do
    sudo ip link delete "$iface" 2>/dev/null || true
done

# Clean up Calico interfaces
for iface in $(ip -o link show | grep cali | awk -F': ' '{print $2}'); do
    sudo ip link delete "$iface" 2>/dev/null || true
done

# 9. Clean up iptables rules
echo "Step 9: Cleaning up iptables rules..."
sudo iptables -F
sudo iptables -X
sudo iptables -t nat -F
sudo iptables -t nat -X
sudo iptables -t mangle -F
sudo iptables -t mangle -X
sudo iptables -P INPUT ACCEPT
sudo iptables -P FORWARD ACCEPT
sudo iptables -P OUTPUT ACCEPT

# Do the same for ip6tables
sudo ip6tables -F
sudo ip6tables -X
sudo ip6tables -t nat -F
sudo ip6tables -t nat -X
sudo ip6tables -t mangle -F
sudo ip6tables -t mangle -X
sudo ip6tables -P INPUT ACCEPT
sudo ip6tables -P FORWARD ACCEPT
sudo ip6tables -P OUTPUT ACCEPT

# 10. Clean up IPVS rules
echo "Step 10: Cleaning up IPVS rules..."
sudo ipvsadm -C 2>/dev/null || true

# 11. Remove kernel modules
echo "Step 11: Removing kernel modules..."
sudo modprobe -r ipip 2>/dev/null || true
sudo modprobe -r ip_vs 2>/dev/null || true
sudo modprobe -r ip_vs_rr 2>/dev/null || true
sudo modprobe -r ip_vs_wrr 2>/dev/null || true
sudo modprobe -r ip_vs_sh 2>/dev/null || true

# 12. Clean up system configurations
echo "Step 12: Cleaning up system configurations..."
sudo rm -f /etc/sysctl.d/k8s.conf
sudo rm -f /etc/modules-load.d/k8s.conf
sudo rm -f /etc/modules-load.d/containerd.conf

# 13. Remove any leftover mount points
echo "Step 13: Cleaning up mount points..."
sudo umount /var/lib/kubelet/pods/*/volumes/kubernetes.io~secret/* 2>/dev/null || true
sudo umount /var/lib/kubelet/pods/*/volumes/kubernetes.io~configmap/* 2>/dev/null || true
for mount in $(cat /proc/mounts | grep '/var/lib/kubelet' | awk '{print $2}'); do
    sudo umount "$mount" 2>/dev/null || true
done

# 14. Clean up process remnants
echo "Step 14: Killing any remaining Kubernetes processes..."
sudo pkill -f kubelet || true
sudo pkill -f kube-proxy || true
sudo pkill -f kube-apiserver || true
sudo pkill -f kube-controller || true
sudo pkill -f kube-scheduler || true
sudo pkill -f etcd || true

# 15. Remove log files
echo "Step 15: Removing log files..."
sudo rm -rf /var/log/pods
sudo rm -rf /var/log/containers

# 16. Clean yum/dnf cache (if installed via package manager)
echo "Step 16: Cleaning package manager cache..."
sudo yum remove -y kubeadm kubelet kubectl kubernetes-cni 2>/dev/null || true
sudo dnf remove -y kubeadm kubelet kubectl kubernetes-cni 2>/dev/null || true
sudo yum clean all || true
sudo dnf clean all || true

# 17. Reload sysctl
echo "Step 17: Reloading sysctl..."
sudo sysctl --system

# 18. Reload systemd
echo "Step 18: Reloading systemd..."
sudo systemctl daemon-reload
sudo systemctl reset-failed

# 19. Optional: Re-enable swap if you want
echo "Step 19: Re-enabling swap (optional)..."
# sudo sed -i '/swap/s/^#//' /etc/fstab
# sudo swapon -a

# 20. Optional: Re-enable SELinux
echo "Step 20: Checking SELinux status..."
# To re-enable SELinux (uncomment if needed):
# sudo sed -i 's/^SELINUX=permissive$/SELINUX=enforcing/' /etc/selinux/config
# sudo setenforce 1

# 21. Reboot recommendation
echo ""
echo "================================"
echo "Cleanup Complete!"
echo "================================"
echo ""
echo "IMPORTANT: It is HIGHLY RECOMMENDED to reboot the system now to ensures"
echo "all kernel modules, network configurations, and services are fully reset."
echo ""
#echo "Run: sudo reboot"
#echo ""
#echo "After reboot, verify cleanup with:"
echo "  - ps aux | grep kube"
echo "  - ip link show"
echo "  - sudo iptables -L"
echo "  - sudo crictl ps -a (should fail with connection error)"
echo ""