# k3s

The `<name>:<version>-k3s` images (`kubeenv` stage, which runs
`images/k3s/install.sh`) ship k3s for both roles, with the same binary:

- `k3s.service`: `k3s server`, the control-plane. One per cluster: the
  datastore is k3s' default, SQLite.
- `k3s-agent.service`: `k3s agent`, the workers. Any number.

Both are disabled in the image: each host picks its role once, by hand.
`k3s`, `kubectl` and `crictl` are in `/usr/bin`, the units in
`/usr/lib/systemd/system`: read-only and updated with the image. No
uninstall script: switch to
another image (`bootc switch`), then remove k3s' state: `/etc/rancher`,
`/var/lib/rancher`, `/var/lib/kubelet`, `/var/lib/crio`, `/var/opt/cni`.

The container runtime is CRI-O (`crio.service`, enabled), with crun, not
k3s' containerd: no `ctr`, no `k3s-killall.sh`. Stopping k3s leaves the
pods running; to stop them too:

```sh
systemctl stop k3s   # or k3s-agent
crictl rmp --all --force
```

k3s (with its kubelet) and CRI-O run in `kube.slice`, out of
`system.slice` (`images/k3s/sysroot/usr/lib/systemd/system/`), without
resource limits. The kubelet puts pods in `kubepods.slice`, next to it,
and CRI-O each container's conmon in its pod's cgroup.

CRI-O pulls with the host's pull secret, `/etc/ostree/auth.json`, and its
own signature policy, `/etc/crio/policy.json` (accepts anything), not
`/etc/containers/policy.json`. Its default capabilities have no
`NET_RAW`: `ping` fails in pods that don't add it.

## Control-plane

```sh
systemctl enable --now k3s
cat /var/lib/rancher/k3s/server/node-token   # the agents' token
```

`kubectl` works as root, with `/etc/rancher/k3s/k3s.yaml`.

## Agents

The server URL and the token are machine-local, never in the image:

```sh
cat > /etc/rancher/k3s/config.yaml <<EOF
server: https://<control-plane IP>:6443
token: <node-token>
EOF
chmod 0600 /etc/rancher/k3s/config.yaml
systemctl enable --now k3s-agent
```

Then, on the control-plane, `kubectl get nodes` lists it.

## Cilium

k3s runs without flannel, kube-proxy or network policy controller: nodes
stay `NotReady` until Cilium is installed. From the
control-plane, with
[cilium-cli](https://docs.cilium.io/en/stable/installation/k3s/):

```sh
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
cilium install \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost=<control-plane IP> \
    --set k8sServicePort=6443 \
    --set encryption.enabled=true \
    --set encryption.type=wireguard \
    --set encryption.nodeEncryption=true \
    --set ipam.operator.clusterPoolIPv4PodCIDRList=10.42.0.0/16 \
    --set cni.binPath=/var/opt/cni/bin
```

The image's firewall expects these, and Cilium's default tunnel routing
mode. The pod CIDR is k3s' own, rather than Cilium's default
`10.0.0.0/8`, which holds k3s' service CIDR (`10.43.0.0/16`).
`cni.binPath`: Cilium's default, `/opt/cni/bin`, is read-only on bootc;
CRI-O looks for CNI plugins in `/var/opt/cni/bin`
(`images/k3s/sysroot/etc/crio/crio.conf.d/20-k3s.conf`). The CNI
configuration stays in both defaults, `/etc/cni/net.d`, and CRI-O picks
it up without a restart.

## Add-ons

Of k3s' packaged manifests, the server only deploys the cloud controller,
local-storage and its RBAC rolebindings. Deploy the others yourself:

- DNS: CoreDNS, its Service on `10.43.0.10` (k3s' `--cluster-dns`),
  domain `cluster.local`, and NodeLocal DNSCache on every node, listening
  on `169.254.25.10`: the kubelets point pods to it, not to CoreDNS
  (`images/fedora/sysroot/var/lib/rancher/k3s/agent/etc/kubelet.conf.d/50-cluster-dns.conf`).
  Until it runs, pods have no DNS.
- metrics-server, an ingress controller, runtime classes: as needed.
- LoadBalancer Services: k3s' ServiceLB is disabled, use e.g. Cilium's
  LB IPAM.

## Firewall

Open on the `public` zone, see `images/k3s/install.sh` for why:

| Port      | For                                            |
|-----------|------------------------------------------------|
| 6443/tcp  | API server, on the control-plane               |
| 10250/tcp | kubelet, between all nodes                     |
| 51871/udp | Cilium WireGuard, between all nodes            |

`10.42.0.0/16` (pods) and `10.43.0.0/16` (services) are sources of the
`trusted` zone.
