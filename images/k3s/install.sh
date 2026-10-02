#!/usr/bin/env bash
# k3s for the kubeenv stage of every image: firewall, binaries and units of
# both roles (k3s server, k3s agent), all disabled. Run by the Containerfiles
# from a bind mount of this folder; never copied into the image. See K3S.md.
#
# The CNI is Cilium, installed on the cluster, hence no flannel or network
# policy controller. k3s' kube-proxy stays: Cilium doesn't replace it
# (K3S.md). k3s' container runtime is its embedded
# containerd (/run/k3s/containerd, `k3s ctr`/`ctr`).
# Requirements: https://docs.k3s.io/installation/requirements?os=rhel
# (kernel-modules-extra, needed on RHEL 10, is already in the AlmaLinux base
# image).
set -xeuo pipefail

# k3s release, also the tag of its install script.
# https://github.com/k3s-io/k3s/releases
# Named after the install script's variable, which reads it from the
# environment: a K3S_* name would end up in the units' .env files, where
# the script copies every K3S_* variable.
export INSTALL_K3S_VERSION=v1.36.5+k3s1

# Firewall
#
# Used ports
# - 6443: k3s supervisor and Kubernetes API server
# - 51871/udp: Cilium WireGuard tunnel between nodes. In tunnel routing
#   mode VXLAN/Geneve runs inside it, so 8472/6081 stay closed. Cilium's
#   health checks use ICMP, which firewalld zones accept by default, so
#   4240/tcp stays closed too.
#   https://docs.cilium.io/en/stable/operations/system_requirements/#firewall-rules
# - 10250: kubelet, between all nodes (k3s requirements, for metrics-server,
#   deployed separately).
#   Cilium's node-to-node encryption doesn't cover it: it leaves out
#   control-plane nodes, which k3s servers are, so server <-> agent node
#   traffic doesn't go through WireGuard.
#   https://docs.cilium.io/en/stable/security/network/encryption-wireguard/#node-to-node-encryption-beta
#
# 2379-2380 (embedded etcd) stay closed: the datastore is k3s' default,
# SQLite through kine, on a single server.
#
# k3s requires firewalld to trust its pod and service CIDRs, k3s' defaults:
# 10.42.0.0/16 and 10.43.0.0/16. Cilium's pod CIDR is set to the same
# (K3S.md). Without it, the public zone rejects pod traffic to the host, and
# on AlmaLinux its geoblock policy drops it as private (geoblock-bogons).
firewall-offline-cmd --add-port=6443/tcp --add-port=10250/tcp --add-port=51871/udp
firewall-offline-cmd --zone=trusted --add-source=10.42.0.0/16 --add-source=10.43.0.0/16
firewall-offline-cmd --check-config

# Create k3s folders
mkdir -p /etc/rancher/k3s/config.yaml.d

# Install k3s with the install script of the same release, which checks the
# binary's sha256. Run twice, once per role, with the same binary:
# k3s.service runs `k3s server` (control-plane), k3s-agent.service
# `k3s agent`. The role is per host, so both stay disabled: see K3S.md.
# No SELinux RPM: SELinux is permissive (fedora/sysroot/etc/selinux/config).
#
# INSTALL_K3S_SKIP_ENABLE: the script's enable also runs
# `systemctl daemon-reload`, which fails without a running systemd.
# INSTALL_K3S_BIN_DIR: /usr/bin is read-only and updated with the image.
# The default, /usr/local/bin, is too only if the base image keeps
# /usr/local a directory, not a link to /var/usrlocal:
# https://bootc.dev/bootc/bootc-filesystem.7.html#usrlocal
# INSTALL_K3S_SYSTEMD_DIR: the units too, rather than /etc/systemd/system.
#
# Of k3s' packaged manifests (/var/lib/rancher/k3s/server/manifests), only
# ccm, local-storage and rolebindings are deployed; rolebindings can't be
# disabled, ccm has its own flag. CoreDNS, metrics-server, traefik and the
# runtime classes are deployed separately (K3S.md). --disable also deletes
# them from a server that already deployed them.
# servicelb, k3s' LoadBalancer controller (in the cloud controller, no
# manifest), is disabled too: LoadBalancer Services are up to the cluster.
#
# kube-proxy runs on every node, server and agents: both get
# --kube-proxy-arg=proxy-mode=nftables, over k3s' default (iptables). The
# host's firewall (firewalld) is nftables too, so kube-proxy writes its
# rules there directly, without the iptables-nft translation.
# https://kubernetes.io/docs/reference/networking/virtual-ips/#proxy-mode-nftables
kube_proxy_args="--kube-proxy-arg=proxy-mode=nftables"
curl -sfLo /tmp/k3s-install.sh "https://raw.githubusercontent.com/k3s-io/k3s/${INSTALL_K3S_VERSION}/install.sh"
export INSTALL_K3S_SKIP_ENABLE=true INSTALL_K3S_SKIP_SELINUX_RPM=true \
    INSTALL_K3S_BIN_DIR=/usr/bin INSTALL_K3S_SYSTEMD_DIR=/usr/lib/systemd/system
INSTALL_K3S_EXEC="server --flannel-backend=none --disable-network-policy \
    --disable=coredns --disable=metrics-server --disable=runtimes --disable=servicelb --disable=traefik \
    ${kube_proxy_args}" \
    sh /tmp/k3s-install.sh
# The agent's server URL and token are machine-local, in
# /etc/rancher/k3s/config.yaml.
# See: https://docs.k3s.io/installation/configuration
INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_EXEC="agent ${kube_proxy_args}" sh /tmp/k3s-install.sh

# The uninstall scripts can't work: they delete k3s' data and config, then
# fail to remove the binaries from the read-only /usr. Uninstalling is
# switching to another image (bootc switch).
rm /usr/bin/k3s-uninstall.sh /usr/bin/k3s-agent-uninstall.sh

# k3s-killall.sh only stops the units of /etc/systemd/system: point it to
# theirs. Fail if the script changed.
sed -i 's|/etc/systemd/system/k3s\*\.service|/usr/lib/systemd/system/k3s*.service|' /usr/bin/k3s-killall.sh
grep -q '^for service in /usr/lib/systemd/system/k3s\*\.service; do$' /usr/bin/k3s-killall.sh

# The script ends ExecStart with a dangling line continuation (` \` then a
# blank line): drop it, so that nothing added after the blank line joins
# the command. Fail if a unit still ends with one.
for unit in /usr/lib/systemd/system/k3s.service /usr/lib/systemd/system/k3s-agent.service; do
    sed -i -z 's/ \\\n\n*$/\n/' "${unit}"
    if [[ $(tail -n 1 "${unit}") == *\\ ]]; then
        echo "${unit}: ExecStart still ends with a line continuation" >&2
        exit 1
    fi
done

# Cleanup
rm -rf /var/log/* /var/cache/* /tmp/*
