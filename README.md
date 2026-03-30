# PDF Editor

Native macOS PDF editor scaffold for digital PDFs, with a strict safe-editing model, block-based editing state, and a replaceable engine boundary.

## What is implemented

- `PdfEditorCore` models editable paragraph blocks, line fragments, backend state, font fallback planning, text-fit validation, and session-driven save orchestration.
- `PdfEditorApp` provides the macOS shell and edits whole text blocks while drawing line-fragment highlights.
- `CompositePDFEngine` prefers MuPDF and falls back to explicit PDFKit read-only mode when MuPDF is unavailable or cannot safely open a file.
- `Vendor/mupdf/lock.toml` pins the MuPDF release consumed by this repo, and `Scripts/fetch-mupdf-build.sh` installs local macOS arm64 bridge artifacts under `Vendor/mupdf/build/macos-arm64/`.

## Important current limitation

The MuPDF package wiring and artifact workflow are in place, but the narrow C bridge has not been completed yet. That means:

- `MuPDFBridgeEngine` is still a bridge shell until the vendored artifacts are built and the bridge functions are implemented.
- `PDFKitEngine` is read-only fallback only. The old annotation-backed save path has been removed from the default editing flow.

## MuPDF dependency workflow

- This repo no longer tracks MuPDF source.
- `Vendor/mupdf/lock.toml` pins the mirror release, upstream commit, and expected artifact checksums.
- Install the pinned macOS arm64 build artifacts with:

```bash
./Scripts/fetch-mupdf-build.sh
```

- Install the pinned source snapshot into the ignored developer cache with:

```bash
./Scripts/fetch-mupdf-source.sh
```

- Rebuild local artifacts from the ignored source cache if you need a source-based local build:

```bash
./Scripts/build-mupdf.sh
```

- Bootstrap the separate mirror repo template with:

```bash
./Scripts/bootstrap-mupdf-mirror-template.sh /path/to/pdf-editor-mupdf-mirror
```

- After the mirror repo publishes a release, update this repo's lock file with:

```bash
./Scripts/update-mupdf-lock.sh <owner/repo> <upstream-commit> <source-sha256> <build-sha256>
```

## Verification

After fetching the pinned MuPDF artifacts, run:

```bash
./Scripts/fetch-mupdf-build.sh
HOME=/tmp/pdf-editor-home \
XDG_CACHE_HOME=/tmp/pdf-editor-cache \
CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test
git status --short
```

Expected results:

- `Vendor/mupdf/build/` is ignored and should not appear in `git status`.
- `Package.swift` should detect `Vendor/mupdf/build/macos-arm64/lib/libmupdf.a`.
- `swift test` should pass.

## Project layout

- `Sources/PdfEditorCore/`: engine boundary, block/session logic, fit validation, composite engine, current PDFKit fallback engine, and MuPDF bridge shell.
- `Sources/PdfEditorApp/`: macOS UI shell and `NSDocument` bridge class.
- `Sources/CPdfEngineBridge/`: thin C bridge target for MuPDF integration.
- `Vendor/mupdf/`: MuPDF lock file plus ignored local build/source caches.
- `MirrorBootstrap/mupdf-mirror-template/`: bootstrap template for the separate MuPDF mirror repo and its release workflow.
- `Tests/PdfEditorCoreTests/`: unit tests covering block staging, read-only rejection, and save-time fit validation.
