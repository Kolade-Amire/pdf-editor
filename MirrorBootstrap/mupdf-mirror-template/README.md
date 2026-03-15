# MuPDF Mirror Repo Template

This template becomes the separate MuPDF mirror repo that owns:

- the flattened MuPDF source mirror
- the pinned upstream commit metadata
- the release workflow that publishes source and macOS arm64 build artifacts

## Setup

1. Commit this template into the dedicated mirror repo.
2. Run the `Publish MuPDF Release` workflow with the pinned upstream ref or a newer explicit ref.
3. Copy the generated checksums back into the app repo with:

```bash
./Scripts/update-mupdf-lock.sh <owner/repo> <upstream-commit> <source-sha256> <build-sha256>
```

## What the mirror repo publishes

- `${release_tag}-source.tar.gz` containing `upstream/`
- `${release_tag}-macos-arm64-build.tar.gz` containing `macos-arm64/`
- `${release_tag}-SHA256SUMS.txt`

The app repo consumes those artifacts through `Vendor/mupdf/lock.toml`.
