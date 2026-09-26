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
- Base image tags: <https://quay.io/repository/fedora/fedora-bootc?tab=tags>

## Rules for images

- One folder per image: `images/<name>/`, which is also the build context.
  It needs a `Containerfile` and a `.containerignore` (copy the fedora one).
- Put files in the folder at the path they get in the image (for example
  `images/<name>/usr/lib/...`). They are copied with `COPY . /`. Don't
  write files inline from `RUN`.
- Prefer `/usr` for content and config. Use `/etc` only for config that
  must be machine-local. Never leave files in `/var`: clean up package
  manager logs, caches and state in the same `RUN`.
- Use drop-in folders (`*.d/`) rather than editing files that packages
  ship.
- Never bake users, passwords, SSH keys or pull secrets into images. Login
  credentials go in `config.toml` (git-ignored). See `config.example.toml`.
- Pin the base image to a major release. Bumping it is its own change.
- The last instruction must be `RUN bootc container lint --fatal-warnings`.
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
```

If you can't run a build (for example no podman), say so explicitly
instead of claiming it works.

## Commits

Conventional Commits: `<type>(<scope>): <summary>`, with a body explaining
why. Never commit `config.toml`, `output/` or disk images (`.gitignore`
covers them).
