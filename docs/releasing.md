# Releasing and deployment

## Versioning

- Workspace version: `[workspace.package] version` in `Cargo.toml` (SemVer).
- Tag format: `vX.Y.Z`, matching the workspace version.
- Record changes in [CHANGELOG.md](../CHANGELOG.md) under the new version heading.

## Release procedure

1. Update `version` in `Cargo.toml`, run `cargo update -w` so that `Cargo.lock` matches, and update the changelog.
2. Run `make ci` locally and make sure CI on `main` is green.
3. Commit, then tag and push: `git tag -a v0.1.0 -m "v0.1.0" && git push origin v0.1.0`.
4. `.github/workflows/release.yml` then:
   - runs the host tests;
   - builds `trill` for `arm-unknown-linux-musleabihf`, `aarch64-unknown-linux-musl`, and `x86_64-unknown-linux-musl` with `cargo-zigbuild`;
   - packages `trill-<version>-<target>.tar.gz` (binary, LICENSE, COMMERCIAL-LICENSE.md, README.md) with a `.sha256` file for each archive;
   - creates a GitHub Release for the tag with all archives and a combined `SHA256SUMS`.

A **manual run** (Actions → Release → *Run workflow*) builds and packages the same archives, versioned `0.0.0-<sha>`, and keeps them as workflow artifacts. It does not publish a release.

Permissions: the build job has `contents: read`. Only the publish job, which runs on tags, gets `contents: write`, through the built-in `GITHUB_TOKEN`. No other secrets are used.

No release has been tagged yet.

## Artifacts

| Archive | Runs on |
|---|---|
| `trill-X.Y.Z-arm-unknown-linux-musleabihf.tar.gz` | Pi Zero / Zero W / Pi 1, and 32-bit Pi OS on later Pis |
| `trill-X.Y.Z-aarch64-unknown-linux-musl.tar.gz` | 64-bit Pi OS on Pi 3/4/5/Zero 2 W |
| `trill-X.Y.Z-x86_64-unknown-linux-musl.tar.gz` | x86-64 Linux |

All binaries are statically linked. None has been run on target hardware with a sensor yet.

## Verifying and installing

```sh
sha256sum -c SHA256SUMS --ignore-missing
tar xzf trill-X.Y.Z-arm-unknown-linux-musleabihf.tar.gz
scp trill-X.Y.Z-arm-unknown-linux-musleabihf/trill pi@<host>:/tmp/
ssh pi@<host> 'sudo install -m 0755 /tmp/trill /usr/local/bin/trill && trill identify'
```

On read-only-root systems such as the ZPOD Buildroot image, install to a writable location (for example under `/data`) or package the binary for the host's app mechanism. ZPOD `.zpa` packaging is defined by the ZPOD project (`docs/APP-BUNDLE.md` in that repository) and is not produced here.

## Local packaging

```sh
make pi-zero pi-arm64 x86-musl
make dist            # dist/*.tar.gz + dist/SHA256SUMS
```
