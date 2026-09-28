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
├── images/                     # shared build context for every image
│   ├── .containerignore        # keeps every Containerfile out of `COPY . /`
│   └── <name>/                 # one folder per image
│       ├── Containerfile
│       └── sysroot/...         # files copied as is into the image root
├── scripts/
│   ├── build.sh [name]         # container image, then output/<name>/<name>.qcow2
│   └── run.sh [name]           # boot the qcow2 in QEMU (macOS Apple Silicon)
├── config.example.toml         # template for config.toml (git-ignored)
└── output/                     # build results (git-ignored)
```

## Images

### `images/fedora`

A minimal image derived from `quay.io/fedora/fedora-bootc:44`:

- Installs `tmux`, `htop` and what the configuration below needs, then
  empties `/var/log`, `/var/cache`, `/var/lib/dnf`, `/tmp` and `/run/dnf*`.
- `usr/lib/bootc/kargs.d/10-console.toml`: serial console kernel
  arguments, x86_64 only.
- `usr/lib/bootc/install/50-rootfs.toml`: default root filesystem `btrfs`.
  The Fedora base image sets none, so without this file both
  `bootc install to-disk` and image-builder would need a filesystem flag.
- System configuration that bootc disk images don't accept from the
  blueprint: hostname, timezone, locale, NTP servers (chrony), DNS
  (systemd-resolved drop-in), sshd on port 42022 (SELinux port label and firewalld port),
  enabled and masked services. `config.toml` only holds the user.
- Firewall: `public` zone opens 80/443/42022, then drops `ssh` (22) and
  `cockpit` from it (sshd only listens on 42022, and cockpit isn't
  installed). See "Firewalld" below for the `firewall-offline-cmd` option
  this needs.
- Ends with `bootc container lint --fatal-warnings`.

### `images/almalinux`

A minimal image derived from `quay.io/almalinuxorg/almalinux-bootc:10.2`,
close to `images/fedora` (Docker, firewalld, the same TZ and chrony setup),
plus France-only geo-blocking and threat-feed blocklists on the public
zone. See `PLAN.geoblock.md` for the full design, the risks and the
verification still to do; summary:

- Two firewalld policies sit on the `public` zone: `geoblock`
  (priority -10000) drops everything except French and
  private/link-local sources (the static, committed ipsets
  `geoblock-bogons-v{4,6}`); `blocklist` (priority -9000) then drops
  sources listed by 10 public threat feeds. Both `target=CONTINUE`, so
  traffic that isn't dropped still goes through the existing `public`
  zone rules unchanged.
- The France and blocklist data is baked in at build time, not fetched at
  runtime. A build-only stage, `geoblock`, downloads the ipdeny lists and
  the feeds with `ADD`, then `images/almalinux/geoblock_ipsets.py` turns
  them into firewalld ipsets. Only feed entries that overlap a French
  network are kept: the `blocklist` policy never sees non-French traffic,
  so the rest can never match. Nothing from that stage reaches the final
  image except the generated ipsets and the raw feed files
  (`/usr/share/geoblock`, kept so a blocked IP can be traced to its feed).
- Refresh means rebuild: there is no timer and no cron job. `ADD` keys its
  cache on the fetched content's digest, so a build only reruns the steps
  that changed.
- `firewall-offline-cmd --check-config` does not validate ipset entries,
  so `geoblock_ipsets.py` is the only thing that does. Its tests
  (`images/almalinux/test_geoblock_ipsets.py`) run before it processes
  the real data, on every build.
- A reverse proxy such as Caddy must run with `network_mode: host`:
  Docker publishes ports (`-p`) by DNATing before firewalld's policies
  run, so published ports bypass both. Its backends are published on
  loopback only. Consequence: ACME must use the DNS-01 challenge, since
  Let's Encrypt validates HTTP-01 from several regions.
- Kill switch: copy a policy file to `/etc/firewalld/policies/`, add
  `<disable/>`, `firewall-cmd --reload`. Disable `geoblock` and
  `blocklist` together, not just one.

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
  `images/almalinux/geoblock_ipsets.py` and `PLAN.geoblock.md`.

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
  purpose, for its content-digest build cache (see `PLAN.geoblock.md`).
- **Content goes in `/usr`, `/var` stays empty.** When deployed, `/usr` is
  read-only and replaced on every update. `/etc` is merged three ways on
  update. `/var` is machine-local state, copied from the image only at the
  first install, so anything left there in the image never updates.
  Packages and static config therefore go in `/usr`, `/etc` only when the
  config must be machine-local, and nothing in `/var`.
- **`COPY` comes after the package install.** Editing config files doesn't
  force dnf to run again on rebuild.
- **The base image is pinned to a major release (`:44`).** `latest` would
  jump to the next Fedora release without warning.
- **Lint with `--fatal-warnings`.** Mistakes like leftover log files fail
  the build instead of only printing a warning.
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
  rootful storage. Without this mount it tries to pull `localhost/...` from
  a registry and fails.
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

Images are tagged `localhost/<name>-bootc:latest`.

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
- Images match the host architecture. Building for x86_64 on an arm Mac
  needs `podman build --platform linux/amd64` and a target architecture
  option for image-builder. This is experimental and emulated, so slow.

## References

- bootc docs: <https://bootc.dev/bootc/> (source: `bootc-dev/bootc`, `docs/src`)
- Fedora bootc examples: <https://gitlab.com/fedora/bootc/examples>
- image-builder: <https://github.com/osbuild/image-builder>
  (bootc-image-builder now lives in `bootc-image-builder/` there)
- Build config: <https://github.com/osbuild/image-builder/blob/main/bootc-image-builder/README.md#-build-config>
