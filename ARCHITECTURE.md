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
├── images/
│   └── <name>/                 # one folder per image, also its build context
│       ├── Containerfile
│       ├── .containerignore    # keeps build files out of `COPY . /`
│       └── usr/...             # files copied as is into the image root
├── scripts/
│   ├── build.sh [name]         # container image, then output/<name>/<name>.qcow2
│   └── run.sh [name]           # boot the qcow2 in QEMU (macOS Apple Silicon)
├── config.example.toml         # template for config.toml (git-ignored)
└── output/                     # build results (git-ignored)
```

## Images

### `images/fedora`

A minimal image derived from `quay.io/fedora/fedora-bootc:44`:

- Installs `tmux` and `htop`, then empties `/var/log`, `/var/cache`,
  `/var/lib/dnf`, `/tmp` and `/run/dnf*`.
- `usr/lib/bootc/kargs.d/10-console.toml`: serial console kernel
  arguments, x86_64 only.
- `usr/lib/bootc/install/50-rootfs.toml`: default root filesystem `xfs`.
  The Fedora base image sets none, so without this file both
  `bootc install to-disk` and image-builder would need a filesystem flag.
- Ends with `bootc container lint --fatal-warnings`.

## Design decisions

- **The build context is the image folder, which mirrors the root
  filesystem.** `COPY . /` puts every file at the path it has in the
  folder. The Containerfile and `.containerignore` are excluded through
  `.containerignore`. buildah only reads that file from the build context
  root (or through `--ignorefile`), so each image folder has its own copy.
- **`COPY` rather than `ADD`.** `ADD` also downloads URLs and unpacks
  archives, which we don't want for plain files.
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
is forwarded from `localhost:${SSH_PORT:-2222}`. `-snapshot` throws away
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
