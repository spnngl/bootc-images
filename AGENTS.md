# Agent guide

Read [ARCHITECTURE.md](ARCHITECTURE.md) first. It explains the layout and
the reasons behind the current choices.

## Sources of truth

Check the source rather than blog posts or memory:

- bootc: `github.com/bootc-dev/bootc` (`docs/src`, lint rules in
  `crates/lib/src/lints.rs`)
- Fedora bootc examples: `gitlab.com/fedora/bootc/examples`
- image-builder / bootc-image-builder: `github.com/osbuild/image-builder`
- buildah (Containerfile behaviour under podman): `github.com/containers/buildah`
- firewalld (zone/policy/ipset behaviour): `github.com/firewalld/firewalld`
  (`doc/xml` for docs, `src/firewall/core` for behaviour)
- nushell (`images/almalinux/geoblock.nu`): `github.com/nushell/nushell`,
  at the tag of the `ghcr.io/nushell/nushell` image the Containerfile uses
- Base image tags:
  <https://quay.io/repository/fedora/fedora-bootc?tab=tags>,
  <https://quay.io/repository/almalinuxorg/almalinux-bootc?tab=tags>

## Rules for images

- One folder per image: `images/<name>/`, with its own `Containerfile`.
  The build context is the shared `images/` folder (see
  `scripts/build.sh`), not the image's own folder: a `Containerfile` can
  `COPY`/`ADD` another image's files, e.g. `COPY ./fedora/sysroot/ /`.
  One `.containerignore` at `images/` covers every image; don't add a
  per-folder copy. `images/k3s/` is not an image: it holds the k3s
  install every `kubeenv` stage runs, and its `sysroot/`, which every
  `kubeenv` stage copies.
- Put files in `images/<name>/sysroot/`, at the path they get in the
  image (for example `images/<name>/sysroot/usr/lib/...`), copied with
  `COPY --link ./<name>/sysroot/ /`. Don't write files inline from `RUN`.
- Prefer `/usr` for content and config. Use `/etc` only for config that
  must be machine-local. Never leave files in `/var`: clean up package
  manager logs, caches and state in the same `RUN`.
- Use drop-in folders (`*.d/`) rather than editing files that packages
  ship.
- Never bake users, passwords, SSH keys or pull secrets into images. Login
  credentials go in `config.toml` (git-ignored). See `config.example.toml`.
- Pin the base image to a major release with `ARG BASE_VERSION=<version>`
  before `FROM`. It is also the image's tag. CI passes it from the
  `.github/workflows/build.yml` matrix: bump both, as their own change.
  Also compare the new base's `/etc/containers/policy.json` with
  `images/<name>/sysroot/etc/containers/policy.json` (see ARCHITECTURE.md,
  "Signing").
- New image: add it to both workflow matrices too (`hadolint` and `build`).
- Must pass `hadolint` (config: `.hadolint.yaml`). Fix findings; ignore
  one only with a comment saying why.
- bootc images: the last instruction must be `RUN bootc container lint`.
  The `/usr`/`/etc`/`/var` and `policy.json` rules above are for bootc
  images only.
- Application images (a binary run as a container, not a host OS, e.g.
  `images/cs-firewall-bouncer/`): static binary on `scratch`, no bootc
  lint; the last instruction is an exec-form smoke test
  (`RUN ["<binary>", ...]`) that needs no capability. `BASE_VERSION` is
  the upstream release. `scripts/build.sh` refuses them.
- Comment every significant step with *why*, and link docs when useful.

## Scripts

- Bash, `set -euo pipefail`, run from any folder (they `cd` to the repo
  root).
- Must pass `shellcheck`, including SC2250 (`${var}` braces).
- Check requirements first and fail with the command that fixes them.
- Keep them small. Add options only when there is a real need.

## Verifying changes

```sh
scripts/build.sh <name>   # needs rootful podman and ./config.toml
scripts/run.sh <name>     # macOS Apple Silicon, then: ssh -p 2222 <user>@localhost
shellcheck scripts/*.sh
podman run --rm -v "${PWD}:/w:ro" -w /w docker.io/hadolint/hadolint:v2.15.1 hadolint images/*/Containerfile
```

If you can't run a build (for example no podman), say so explicitly
instead of claiming it works.

## Commits

Conventional Commits: `<type>(<scope>): <summary>`, with a body explaining
why. Never commit `config.toml`, `output/` or disk images (`.gitignore`
covers them).
