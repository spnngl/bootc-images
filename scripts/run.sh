#!/usr/bin/env bash
# Boot output/<name>/<name>.qcow2, built by scripts/build.sh, in QEMU.
# Supports macOS on Apple Silicon only (HVF acceleration, Homebrew qemu).
#
# Usage: [SSH_PORT=2222] scripts/run.sh [name]    (default: fedora)
#
# Console: this terminal, quit with Ctrl-a x.
# SSH:     ssh -p 2222 <user from config.toml>@localhost
# Disk changes are discarded on exit (-snapshot).
set -euo pipefail

name="${1:-fedora}"
ssh_port="${SSH_PORT:-2222}"
cd "$(dirname "$0")/.."

die() { echo "error: $*" >&2; exit 1; }

disk="output/${name}/${name}.qcow2"
[[ -f "${disk}" ]] || die "${disk} not found, run: scripts/build.sh ${name}"
[[ "$(uname -s)/$(uname -m)" == Darwin/arm64 ]] || die "only macOS on Apple Silicon is supported"

firmware="$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd"
[[ -f "${firmware}" ]] || die "${firmware} not found, run: brew install qemu"

exec qemu-system-aarch64 \
  -machine virt,accel=hvf -cpu host -smp 2 -m 4096 \
  -bios "${firmware}" \
  -drive "file=${disk},if=virtio,format=qcow2" -snapshot \
  -netdev "user,id=n0,hostfwd=tcp::${ssh_port}-:22" -device virtio-net-pci,netdev=n0 \
  -nographic
