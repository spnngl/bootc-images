#!/usr/bin/env bash
# k3s for the kubeenv stage of every image: firewall, binaries and units of
# both roles (k3s server, k3s agent), all disabled. Run by the Containerfiles
# from a bind mount of this folder; never copied into the image. See K3S.md.
#
# The CNI is Cilium, installed on the cluster, hence no flannel, kube-proxy
# or network policy controller. The container runtime is CRI-O with crun
# (/run/crio/crio.sock, `crictl`), not k3s' embedded containerd, which k3s
# doesn't start when given a runtime endpoint. Its config:
# k3s/sysroot/etc/crio/crio.conf.d/20-k3s.conf.
# Requirements: https://docs.k3s.io/installation/requirements?os=rhel
# (kernel-modules-extra, needed on RHEL 10, is already in the AlmaLinux base
# image).
set -xeuo pipefail

# Kubernetes release (<major>.<minor>.<patch>), from the Containerfiles'
# ARG KUBERNETES_VERSION (CI passes it, .github/workflows/build.yml).
# k3s release, also the tag of its install script.
# https://github.com/k3s-io/k3s/releases
# Named after the install script's variable, which reads it from the
# environment: a K3S_* name would end up in the units' .env files, where
# the script copies every K3S_* variable.
export INSTALL_K3S_VERSION="v${KUBERNETES_VERSION:?}+k3s1"

# CRI-O, from its own repository: one per minor release, which must be
# Kubernetes' minor. The patch release follows the repository.
# https://github.com/cri-o/packaging#usage
# --repofrompath: the repository is only used here, no .repo file is left
# in the image.
# No weak dependencies: the package recommends kubernetes-cni (CNI plugins
# in /usr/libexec/cni), unused: CRI-O brings pods' loopback up itself and
# Cilium installs its own plugin. container-selinux, the other one, is
# already in the base images.
# The package's runtime is crun, its own copy (/usr/libexec/crio/crun,
# /etc/crio/crio.conf.d/10-crio.conf).
crio_repo="https://download.opensuse.org/repositories/isv:/cri-o:/stable:/v${KUBERNETES_VERSION%.*}/rpm/"
dnf -yq install --setopt=install_weak_deps=False \
    --repofrompath=cri-o,"${crio_repo}" \
    --setopt=cri-o.gpgcheck=1 --setopt=cri-o.gpgkey="${crio_repo}repodata/repomd.xml.key" \
    cri-o
# Enabled, unlike k3s: k3s waits for its socket but doesn't start it.
systemctl enable crio.service

# The package's registries.conf.d/crio.conf sorts after
# fedora/sysroot/etc/containers/registries.conf.d/99-myregistries.conf and
# would override its unqualified-search-registries, for podman too: keep
# ours the only one. Fail if the package no longer ships it.
rm /etc/containers/registries.conf.d/crio.conf

# Firewall
#
# Used ports
# - 6443: k3s supervisor and Kubernetes API server
# - 51871/udp: Cilium WireGuard tunnel between nodes.
# - 6081/udp: Cilium Geneve overlay (routing-mode tunnel, tunnel-protocol
#   geneve). Nodes sit on different providers with no shared L2, so native
#   routing is impossible (cilium Documentation/network/concepts/routing.rst,
#   "Requirements on the network"). Pod-to-pod Geneve runs inside WireGuard,
#   but node-to-node encryption opts control-plane nodes out, so Geneve
#   between a k3s server and an agent node (host <-> remote pod) is plain and
#   needs the port. 8472/udp (VXLAN) stays closed.
#   https://docs.cilium.io/en/stable/operations/system_requirements/#firewall-rules
# - 4240/tcp: cilium-health HTTP probes between nodes. Cilium uses ICMP *and*
#   TCP 4240; without the port every node reports its peers unreachable
#   ("HTTP to agent: no route to host"), the datapath itself still works.
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
firewall-offline-cmd --add-port=6443/tcp --add-port=10250/tcp --add-port=4240/tcp \
    --add-port=51871/udp --add-port=6081/udp
firewall-offline-cmd --zone=trusted --add-source=10.42.0.0/16 --add-source=10.43.0.0/16
firewall-offline-cmd --check-config

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
curl -sfLo /tmp/k3s-install.sh "https://raw.githubusercontent.com/k3s-io/k3s/${INSTALL_K3S_VERSION}/install.sh"
export INSTALL_K3S_SKIP_ENABLE=true INSTALL_K3S_SKIP_SELINUX_RPM=true \
    INSTALL_K3S_BIN_DIR=/usr/bin INSTALL_K3S_SYSTEMD_DIR=/usr/lib/systemd/system
#
# --container-runtime-endpoint, CRI-O, on both roles: in the units rather
# than in a /etc/rancher/k3s/config.yaml.d drop-in, so that it is updated
# with the image.
cri=--container-runtime-endpoint=unix:///run/crio/crio.sock
INSTALL_K3S_EXEC="server ${cri} --flannel-backend=none --disable-kube-proxy --disable-network-policy \
    --disable=coredns --disable=metrics-server --disable=runtimes --disable=servicelb --disable=traefik" \
    sh /tmp/k3s-install.sh
# The agent's server URL and token are machine-local, in
# /etc/rancher/k3s/config.yaml.
# See: https://docs.k3s.io/installation/configuration
INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_EXEC="agent ${cri}" sh /tmp/k3s-install.sh

# The uninstall scripts can't work: they delete k3s' data and config, then
# fail to remove the binaries from the read-only /usr. Uninstalling is
# switching to another image (bootc switch).
# k3s-killall.sh is for k3s' containerd: it kills its shims, then unmounts
# the pods' volumes and network namespaces, while CRI-O's containers still
# run. CRI-O's pods are stopped with crictl (K3S.md).
rm /usr/bin/k3s-uninstall.sh /usr/bin/k3s-agent-uninstall.sh /usr/bin/k3s-killall.sh

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
dnf -y autoremove
dnf clean all
# /var/lib/crio: from the package, CRI-O creates it at startup.
rm -rf /var/log/* /var/cache/* /var/lib/dnf /var/lib/crio /tmp/* /run/dnf*
