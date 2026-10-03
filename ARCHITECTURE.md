# Architecture

This repository builds [bootc](https://bootc.dev/bootc/) images: bootable
operating systems shipped as OCI container images. A bootc host boots from
an image and updates by pulling a newer one (`bootc upgrade`), the same way
a container is updated.

There are two stages:

1. **Container image**: `podman build` on `images/<name>/Containerfile`.
   This is what hosts boot and update from.
2. **Disk image**: [image-builder](https://github.com/osbuild/image-builder)
   turns the container image into a qcow2 used for the first install. Later
   updates come from the container image, not from a new disk image.

## Layout

```
.
├── .github/
│   ├── dependabot.yml          # Saturday updates of the workflow's actions
│   └── workflows/build.yml     # CI: lint, build, push every image to ghcr.io
├── .hadolint.yaml              # hadolint config for every Containerfile
├── images/                     # shared build context for every image
│   ├── .containerignore        # keeps every Containerfile out of `COPY . /`
│   ├── k3s/                    # shared by every kubeenv stage (not an image)
│   │   ├── install.sh          # k3s and CRI-O install
│   │   └── sysroot/...         # CRI-O configuration, kube.slice
│   └── <name>/                 # one folder per image
│       ├── Containerfile
│       └── sysroot/...         # files copied as is into the image root
├── scripts/
│   ├── build.sh [name]         # container image, then output/<name>/<name>.qcow2
│   └── run.sh [name]           # boot the qcow2 in QEMU (macOS Apple Silicon)
├── config.example.toml         # template for config.toml (git-ignored)
├── K3S.md                      # setting up k3s hosts (-k3s images)
└── output/                     # build results (git-ignored)
```

## Images

### `images/fedora`

An image derived from `quay.io/fedora/fedora-bootc:44`, with either
Docker or k3s. Stages:

- `base`: the host system, shared by the two images below. Not an image
  on its own.
- `dockerenv` (`FROM base`, the last stage, so the default target and
  what `build.sh` builds): adds Docker. Tag `<name>:<version>`.
- `kubeenv` (`FROM base`, `podman build --target kubeenv`): adds k3s, no
  Docker. Tag `<name>:<version>-k3s`. Every image's `kubeenv` runs the
  same `images/k3s/install.sh`, bind-mounted rather than copied (buildah
  still keys its cache on the script's content). k3s is pinned there
  (`INSTALL_K3S_VERSION`), in `/usr`, with a unit per role, both
  disabled: each host picks its role by hand. The Kubernetes release is
  the stage's `ARG KUBERNETES_VERSION`, set by CI like `BASE_VERSION`.
  The container runtime is CRI-O (same minor release, with crun),
  configured by `images/k3s/sysroot/`, copied after the script, which
  also puts k3s and CRI-O in `kube.slice`, out of `system.slice`. Cilium
  is the CNI. Setup and firewall: [K3S.md](K3S.md); the reasons are in
  the script, next to each step.

Both images end with `bootc container lint`. The host system:

- Installs `htop`, `vim`, `git` and what the configuration below needs, then
  empties `/var/log`, `/var/cache`, `/var/lib/dnf`, `/tmp` and `/run/dnf*`.
- `usr/lib/bootc/kargs.d/10-console.toml`: serial console kernel
  arguments, x86_64 only.
- `usr/lib/bootc/install/50-rootfs.toml`: default root filesystem `btrfs`.
  The Fedora base image sets none, so without this file both
  `bootc install to-disk` and image-builder would need a filesystem flag.
- System configuration that bootc disk images don't accept from the
  blueprint: hostname, timezone, locale, NTP servers (chrony), DNS
  (systemd-resolved drop-in; `etc/systemd/network/wired.network` ignores
  the DHCP servers' DNS), sshd on port 42022 (SELinux port label and firewalld port),
  enabled and masked services. `config.toml` only holds the user.
- Registry authentication: one pull secret, `/etc/ostree/auth.json`
  (0640 root:wheel), machine-local and never in the container image. It
  can be added to the disk image by `config.toml`.
  bootc reads it directly. `usr/lib/tmpfiles.d/container-auth.conf` links
  root's `~/.docker/config.json` to it, which podman and docker both read.
- Image signature verification: `ghcr.io/spnngl/bootc-images/*` must be
  signed by CI's key. See "Signing" below.
- Firewall: `public` zone opens 80/443/42022, then drops `ssh` (22) and
  `cockpit` from it (sshd only listens on 42022, and cockpit isn't
  installed). See "Firewalld" below for the `firewall-offline-cmd` option
  this needs.

### `images/almalinux`

An image derived from `quay.io/almalinuxorg/almalinux-bootc:10.2`,
close to `images/fedora` (Docker, firewalld, the same TZ and chrony setup),
plus country geo-blocking and threat-feed blocklists on the public
zone. Same stages, `dockerenv` and `kubeenv`, as `images/fedora`.

Geo-blocking and blocklists:

- Two firewalld policies sit on the `public` zone: `geoblock`
  (priority -10000) drops private/link-local sources (the static,
  committed ipset `geoblock-bogons`) and sources in a blocked
  country (Afghanistan, Azerbaijan, Bangladesh, Brazil, China, Iran,
  Iraq, North Korea, Pakistan, Russia, Turkey: the list is the `ADD`s of
  the Containerfile); `blocklist` (priority -9000) then drops sources
  listed by 10 public threat feeds. Both `target=CONTINUE`, so traffic
  that isn't dropped still goes through the existing `public` zone rules
  unchanged.
- IPv4 only, like the rest of both images: IPv6 is disabled by
  `images/fedora/sysroot/etc/sysctl.d/990-disable-ipv6.conf`. IPv6
  entries in the threat feeds are skipped.
- The country and blocklist data is baked in at build time, not fetched
  at runtime. A build-only stage, `geoblock`, downloads the ipdeny lists
  and the feeds with `ADD`, then `images/almalinux/geoblock.nu` turns
  them into firewalld ipsets. The stage is the `ghcr.io/nushell/nushell`
  image with nushell as its `SHELL`: its `RUN` is nushell code.
  Feed entries inside a blocked country are left out: the `blocklist`
  policy never sees that traffic, so they can never match. Nothing from
  that stage reaches the final image except the generated ipsets and the
  raw files (`/usr/share/geoblock`, kept so a blocked IP can be traced to
  its country or feed).
- A blocklist fails closed: corrupt country data blocks legitimate
  traffic, possibly the admin's. `geoblock.nu` fails the build on any
  invalid entry, on an empty country file and on a country network that
  overlaps a bogon range (which `0.0.0.0/0` would).
- Refresh means rebuild: there is no timer and no cron job. `ADD` keys its
  cache on the fetched content's digest, so a build only reruns the steps
  that changed.
- `firewall-offline-cmd --check-config` does not validate ipset entries,
  so `geoblock.nu` is the only thing that does. Its tests
  (`images/almalinux/test_geoblock.nu`) run before it processes the real
  data, on every build.
- A reverse proxy such as Caddy must run with `network_mode: host`:
  Docker publishes ports (`-p`) by DNATing before firewalld's policies
  run, so published ports bypass both. Its backends are published on
  loopback only. Consequence: ACME must use the DNS-01 challenge, since
  Let's Encrypt validates HTTP-01 from several regions.
- Kill switch: copy a policy file to `/etc/firewalld/policies/`, add
  `<disable/>`, `firewall-cmd --reload`. Disable `geoblock` and
  `blocklist` together, not just one.
- Two x86_64 builds, like the base image: `linux/amd64` targets
  x86-64-v3, the AlmaLinux 10 baseline, and its glibc aborts with `CPU
  does not support x86-64-v3` on older CPUs such as the Intel Atom C2338.
  `linux/amd64/v2` (`x86_64_v2` RPMs, EPEL from AlmaLinux's AltArch
  rebuild) runs on those. containers/image (podman, bootc) doesn't
  detect x86-64 levels: on amd64 it always picks the entry without a
  variant, so v2 is only used when asked for (`podman run --platform
  linux/amd64/v2`). bootc has no such option: `bootc upgrade` and
  `bootc switch` always fetch `linux/amd64`. See "Known limits".

### Firewalld (both images)

- **`firewall-offline-cmd`'s zone-scoped removal option is
  `--remove-service-from-zone=<service>`.** Not `--remove-service`: that
  looks similar but is a separate, mutually exclusive legacy "lokkit"
  option ("Can't use lokkit options with other options"). Not
  `--delete-service` either: that deletes the global service
  *definition*, which fails for built-in services (`BUILTIN_SERVICE`)
  such as `ssh` or `cockpit`. The equivalent for a policy is
  `--remove-service-from-policy`.
- **`--check-config` validates zone/policy/ipset wiring, not ipset
  entries.** A policy referencing a missing ipset is caught
  (`INVALID_IPSET`); an invalid address in an ipset is silently ignored,
  and overlapping or empty ipsets are accepted. Anything that loads
  ipset entries from external data has to validate them itself; see
  `images/almalinux/geoblock.nu`.

## Design decisions

- **The build context is the shared `images/` folder, not each image's
  own folder.** `scripts/build.sh` passes `-f images/<name>/Containerfile`
  with context `images/`. This is what lets
  `images/almalinux/Containerfile` do `COPY --link ./fedora/sysroot/ /`
  to reuse fedora's base configuration instead of duplicating it. Each
  image's own files live in `images/<name>/sysroot/`, which mirrors the
  root filesystem. One `.containerignore` at `images/` (buildah only
  reads it from the context root, or through `--ignorefile`) keeps every
  `Containerfile` out of `COPY . /`; there is no need for a copy per
  image folder.
- **`COPY` rather than `ADD`.** `ADD` also downloads URLs and unpacks
  archives, which we don't want for plain files. Exception:
  `images/almalinux`'s build-only `geoblock` stage uses `ADD <url>` on
  purpose, for its content-digest build cache.
- **Content goes in `/usr`, `/var` stays empty.** When deployed, `/usr` is
  read-only and replaced on every update. `/etc` is merged three ways on
  update. `/var` is machine-local state, copied from the image only at the
  first install, so anything left there in the image never updates.
  Packages and static config therefore go in `/usr`, `/etc` only when the
  config must be machine-local, and nothing in `/var`.
- **`COPY` comes after the package install.** Editing config files doesn't
  force dnf to run again on rebuild.
- **The base image is pinned to a major release, `ARG BASE_VERSION`
  (`44`).** `latest` would jump to the next Fedora release without
  warning. The same value is the image's own tag, so a host tracking
  `bootc-images/fedora:44` gets every rebuild through `bootc upgrade`, and only
  moves to the next release with `bootc switch`. The Containerfile default
  is for local builds; CI passes it from its matrix.
- **`bootc container lint` without `--fatal-warnings`.** Errors fail the
  build, warnings are only printed.
- **hadolint on every Containerfile** (`.hadolint.yaml`). DL3041 (pin
  dnf package versions) is ignored: packages follow the pinned base
  release, like the base image does.
- **One `RUN <<EORUN` heredoc with `set -xeuo pipefail`.** It gives one
  layer without `&& \` chains. `-e` is required because a heredoc `RUN`
  only fails on the exit status of its last command. Heredocs need
  buildah 1.33 or later.

## Disk images: image-builder

`scripts/build.sh` runs `ghcr.io/osbuild/image-builder-cli:latest` (which
includes the former bootc-image-builder) with:

- **`--privileged` and `--security-opt label=type:unconfined_t`:**
  image-builder relabels files for SELinux and sets up loop devices. A
  confined container fails with `chcon: ... Permission denied`.
- **`-v /var/lib/containers/storage:/var/lib/containers/storage`:**
  image-builder never pulls the bootc image. It reads it from the host's
  rootful storage. Without this mount it tries to pull the tag from
  ghcr.io instead of using the image just built.
- **Rootful podman:** image-builder checks for it. On macOS use
  `podman machine set --rootful`. The podman client then talks to the
  rootful machine, so `sudo` isn't used.
- **`--blueprint /config.toml`:** user accounts and SSH keys are added only
  to the disk image, never baked into the container image. The file is an
  [osbuild blueprint](https://osbuild.org/docs/user-guide/blueprint-reference/)
  (check each option's bootc tab). It holds credentials, so it is
  git-ignored and `config.example.toml` is the template.
- **`--output-dir <name> --output-name <name>`:** gives a fixed path,
  `output/<name>/<name>.qcow2`. The default name depends on the distro and
  architecture.

Images are tagged `ghcr.io/spnngl/bootc-images/<name>:<version>`,
`<version>` being the Containerfile's `ARG BASE_VERSION` default: the
same name CI pushes for the default target, so an installed host upgrades
from CI's images. `build.sh` only builds the default target
(`dockerenv`) and never pushes.

## CI: `.github/workflows/build.yml`

Runs hadolint on each Containerfile (findings uploaded to code scanning as
SARIF), then builds each image of its matrix (`name`, `version`,
and for a multi-stage Containerfile `target` and tag `suffix`) for every
platform, and pushes it to
`ghcr.io/spnngl/bootc-images/<name>:<version><suffix>`, one manifest list
for all platforms,
authenticated with the job's `GITHUB_TOKEN` (`packages: write`).
Container images only: disk images need `config.toml`.

- **Triggers:** push to `main`, every Sunday 07:00 Europe/Paris (base
  image and package updates, fresh almalinux geo-blocking data) and
  manual dispatch all push. Pull requests only lint and build.
- **The matrix is the list of images**, each with its base version,
  passed as `--build-arg BASE_VERSION`. A new image or a version bump
  goes there too. The `push` job reuses it through a YAML anchor.
- **Jobs run on `ubuntu-26.04` and `ubuntu-26.04-arm`, not
  `ubuntu-latest`.** They ship Podman
  5.7 / Buildah 1.42; `ubuntu-latest` (24.04) has buildah 1.33, and the
  Containerfiles use `COPY --link` (buildah 1.41+). Builds use the
  runner's rootless podman, where `build.sh` uses rootful podman.
- **Same `podman build` flags as `build.sh`** (`--format=docker`, context
  `images/`), plus an `org.opencontainers.image.source` label that links
  the ghcr.io package to the repository, and `--platform` set to the
  runner's own.
- **Each platform builds natively, on its own runner:** no QEMU, so
  arm64 builds as fast as amd64, in parallel. Each build downloads
  almalinux's geo-blocking data itself, so the data can differ slightly
  between platforms.
- **A `push` job per image merges its platforms:** each build job saves
  its image as a `docker-archive` (`oci-archive` would drop `SHELL`)
  artifact, kept one day. The `push` job adds every platform's archive to
  one manifest list, and fails if one is missing rather than push a
  partial list. It runs even when another image's build failed, so one
  broken image doesn't hold back the others. Pull requests build every
  platform but upload nothing.
- **Pushed images are signed**, then pulled back with the image's own
  `policy.json` to check the signature. See "Signing".

## Signing

CI signs every image it pushes with a cosign key pair; hosts refuse
`ghcr.io/spnngl/bootc-images/*` images without that signature. Local
builds are not signed: `build.sh` never pushes, and a host installed from
a local build upgrades from CI's signed images.

- **Keys:** the private key is the `COSIGN_PRIVATE_KEY` repository secret,
  never in git. It has no passphrase (CI passes an empty one).
  With one, add a secret and write it to the `--sign-passphrase-file`. The public key is
  `images/fedora/sysroot/usr/share/pki/containers/spnngl-bootc-images.pub`,
  in `/usr` so that it updates with the image.
- **`podman push --sign-by-sigstore-private-key`, not `cosign sign`.**
  bootc verifies through containers/image (skopeo), which reads sigstore
  signatures as `sha256-<digest>.sig` attachments only. cosign 3 stores
  them by default as a sigstore bundle behind OCI referrers, which
  containers/image can't see. podman writes the attachment format and
  takes cosign keys (`ENCRYPTED SIGSTORE PRIVATE KEY`). No Rekor
  transparency log entry is made; the policy doesn't ask for one.
- **`etc/containers/registries.d/spnngl-bootc-images.yaml`** turns on
  `use-sigstore-attachments` for our namespace: needed to read the
  signatures on hosts, and to write them in CI.
- **`etc/containers/policy.json`, one per image** (almalinux's overrides
  fedora's): the base image's file, plus a `sigstoreSigned` requirement
  for `ghcr.io/spnngl/bootc-images`. It replaces the file shipped by
  `containers-common`, since `policy.json` has no drop-in directory.
  When a base image changes its `policy.json`, port the change.
- **`"default": reject`** is what `enforce-container-sigpolicy = true`
  (`usr/lib/bootc/install/50-rootfs.toml`) requires: bootc refuses to pull
  when the default is `insecureAcceptAnything`. Every transport, and every
  other registry, still accepts anything as before, so podman keeps working
  (`containers-storage` is also how image-builder installs a local build).
- **Rotating the key:** ship the new public key alongside the old one
  (`keyPaths`), let hosts upgrade, then switch the CI secret.
- **Build provenance, on top:** `actions/attest-build-provenance`
  attests which workflow, commit and run built each manifest list. It is
  a sigstore bundle behind OCI referrers, like cosign 3's, so hosts
  don't read it: the signature above is what they check. Check it with
  `gh attestation verify oci://ghcr.io/spnngl/bootc-images/<name>:<tag> -R spnngl/bootc-images`.
  The action only reads Docker's credential file, so CI logs podman in
  with `REGISTRY_AUTH_FILE=~/.docker/config.json`.

## Running: `scripts/run.sh`

QEMU with HVF acceleration, the `virt` machine and the Homebrew aarch64 UEFI
firmware. The serial console is in the terminal (`Ctrl-a x` quits) and SSH
is forwarded from `localhost:${SSH_PORT:-2222}` to the guest sshd port
42022, set by `images/fedora`. `-snapshot` throws away
disk changes on exit.

It only supports macOS on Apple Silicon, and says so when run anywhere else.

## Known limits

- `run.sh` only supports macOS on Apple Silicon.
- Only qcow2 is built. For other formats, change the image type in
  `build.sh` (for example `anaconda-iso`, `raw`, `vmdk`).
- `build.sh` builds for the host architecture only. Building for x86_64
  on an arm Mac needs `podman build --platform linux/amd64` and a target
  architecture option for image-builder. This is experimental and
  emulated, so slow.
- **almalinux on x86-64-v2 CPUs (e.g. Intel Atom C2338):** install with
  `podman run --platform linux/amd64/v2 ...`. `bootc upgrade` then
  fetches `linux/amd64`, the x86-64-v3 build, and the new deployment
  won't boot (pick the previous one in GRUB, or `bootc rollback`).
  Upgrades on such hosts need a tag that points at the v2 build only.

## References

- bootc docs: <https://bootc.dev/bootc/> (source: `bootc-dev/bootc`, `docs/src`)
- Fedora bootc examples: <https://gitlab.com/fedora/bootc/examples>
- image-builder: <https://github.com/osbuild/image-builder>
  (bootc-image-builder now lives in `bootc-image-builder/` there)
- Build config: <https://github.com/osbuild/image-builder/blob/main/bootc-image-builder/README.md#-build-config>
