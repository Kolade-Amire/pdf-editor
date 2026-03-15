# MuPDF Dependency Lock

This app repo does not track MuPDF source anymore.

It tracks only:

- `Vendor/mupdf/lock.toml`
- ignored local build output under `Vendor/mupdf/build/`
- ignored local source cache under `Vendor/mupdf/source-cache/`

The separate mirror repo is bootstrapped from:

- `MirrorBootstrap/mupdf-mirror-template/`

## Lock file

Machine-readable dependency lock data lives in:

- `Vendor/mupdf/lock.toml`

That file records:

- mirror repo URL
- pinned top-level MuPDF commit
- release tag
- source artifact name, URL, and SHA-256
- macOS arm64 build artifact name, URL, and SHA-256
- the local source-build profile (`extract=no`, `tesseract=no`)

## Fetch workflow

Fetch the pinned macOS arm64 build artifacts with:

```bash
./Scripts/fetch-mupdf-build.sh
```

Fetch the pinned source snapshot into the ignored developer cache with:

```bash
./Scripts/fetch-mupdf-source.sh
```

If you need to rebuild from source locally:

```bash
./Scripts/build-mupdf.sh
```

## Mirror repo bootstrap

Create the separate MuPDF mirror repo from the template with:

```bash
./Scripts/bootstrap-mupdf-mirror-template.sh /path/to/pdf-editor-mupdf-mirror
```

That mirror repo owns:

- the flattened MuPDF source mirror
- the upstream refresh scripts
- the build/package scripts
- the GitHub Actions release workflow
- the published source/build archives and checksum file

After the mirror publishes a release, update this app repo's lock file with:

```bash
./Scripts/update-mupdf-lock.sh <owner/repo> <upstream-commit> <source-sha256> <build-sha256>
```

## Current status

- The lock is pinned to MuPDF commit `d237b318e7b6e9e2c0c295f43a60910c8241ed78`.
- The app repo consumes artifacts instead of tracked source.
- `MuPDFBridgeEngine` is still a bridge shell until the narrow C/Swift bridge is implemented against the built artifacts.
