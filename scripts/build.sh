#!/usr/bin/env bash
# Build the bootc container image from images/<name>/, then turn it into a
# qcow2 disk image with image-builder.
#
# Usage: scripts/build.sh [name]    (default: fedora)
# Image:  ghcr.io/spnngl/bootc-images/<name>-bootc:<version>, <version> being
#         the Containerfile's ARG BASE_VERSION default: the same name CI
#         pushes (.github/workflows/build.yml). Not pushed.
# Output: output/<name>/<name>.qcow2
#
# Requirements:
#   - rootful podman: image-builder reads the image from the rootful storage.
#     On macOS: podman machine stop; podman machine set --rootful; podman machine start
#   - ./config.toml: image-builder blueprint with at least one user
#     (cp config.example.toml config.toml, then edit it).
set -euo pipefail

name="${1:-fedora}"
cd "$(dirname "$0")/.."

die() {
    echo "error: $*" >&2
    exit 1
}

containerfile="images/${name}/Containerfile"
[[ -f ${containerfile} ]] || die "${containerfile} not found"
version="$(sed -n -E 's/^ARG BASE_VERSION=([^[:space:]]+).*/\1/p' "${containerfile}")"
[[ -n ${version} ]] || die "${containerfile} has no ARG BASE_VERSION=<version>"
tag="ghcr.io/spnngl/bootc-images/${name}-bootc:${version}"
[[ -f config.toml ]] || die "config.toml not found, start from: cp config.example.toml config.toml"
[[ "$(podman info --format '{{.Host.Security.Rootless}}')" == false ]] ||
    die "podman is rootless, on macOS run: podman machine stop; podman machine set --rootful; podman machine start"

podman build --format=docker -f "${containerfile}" -t "${tag}" "images/"

# --privileged and label=type:unconfined_t: image-builder relabels files and
# sets up loop devices, which a confined container is not allowed to do.
# /var/lib/containers/storage: lets image-builder see the image built above.
mkdir -p output
podman run --rm --privileged --pull=newer \
    --security-opt label=type:unconfined_t \
    -v "${PWD}/config.toml:/config.toml:ro" \
    -v "${PWD}/output:/output" \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    ghcr.io/osbuild/image-builder-cli:v84.0.0 \
    build --bootc-ref "${tag}" --blueprint /config.toml \
    --output-dir "${name}" --output-name "${name}" qcow2

echo "disk image: output/${name}/${name}.qcow2"
