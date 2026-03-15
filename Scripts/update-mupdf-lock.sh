#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCK_FILE="${REPO_ROOT}/Vendor/mupdf/lock.toml"

usage() {
  cat <<'EOF'
Usage:
  ./Scripts/update-mupdf-lock.sh <github-owner/repo> <upstream-commit> <source-sha256> <build-sha256>

Example:
  ./Scripts/update-mupdf-lock.sh koladeamire/pdf-editor-mupdf-mirror d237b318e7b6e9e2c0c295f43a60910c8241ed78 <source_sha> <build_sha>
EOF
}

if [[ "$#" -ne 4 ]]; then
  usage >&2
  exit 1
fi

GITHUB_REPO_SLUG="$1"
UPSTREAM_COMMIT="$2"
SOURCE_SHA256="$3"
BUILD_SHA256="$4"
SHORT_COMMIT="${UPSTREAM_COMMIT[1,8]}"
RELEASE_TAG="mupdf-${SHORT_COMMIT}"
BASE_URL="https://github.com/${GITHUB_REPO_SLUG}/releases/download/${RELEASE_TAG}"
MIRROR_REPO_URL="https://github.com/${GITHUB_REPO_SLUG}"
SOURCE_ARCHIVE_NAME="${RELEASE_TAG}-source.tar.gz"
BUILD_ARCHIVE_NAME="${RELEASE_TAG}-macos-arm64-build.tar.gz"

cat <<EOF > "${LOCK_FILE}"
schema_version = 1
mirror_repo = "${MIRROR_REPO_URL}"
upstream_commit = "${UPSTREAM_COMMIT}"
release_tag = "${RELEASE_TAG}"
build_extract = "no"
build_tesseract = "no"

[source]
archive_name = "${SOURCE_ARCHIVE_NAME}"
url = "${BASE_URL}/${SOURCE_ARCHIVE_NAME}"
sha256 = "${SOURCE_SHA256}"

[macos_arm64_build]
archive_name = "${BUILD_ARCHIVE_NAME}"
url = "${BASE_URL}/${BUILD_ARCHIVE_NAME}"
sha256 = "${BUILD_SHA256}"
EOF

echo "Updated ${LOCK_FILE} for ${RELEASE_TAG}"
