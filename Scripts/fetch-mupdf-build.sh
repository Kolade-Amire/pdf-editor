#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_ROOT="${REPO_ROOT}/Vendor/mupdf/build"
TARGET_ROOT="${OUTPUT_ROOT}/macos-arm64"

source "${SCRIPT_DIR}/mupdf-lock.sh"

ARCHIVE_NAME="$(require_lock_string "macos_arm64_build" "archive_name")"
ARCHIVE_URL="$(resolve_lock_value "macos_arm64_build" "url" "${MUPDF_BUILD_URL:-}")"
ARCHIVE_SHA256="$(resolve_lock_value "macos_arm64_build" "sha256" "${MUPDF_BUILD_SHA256:-}")"

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pdf-editor-mupdf-build.XXXXXX")"
ARCHIVE_PATH="${TEMP_ROOT}/${ARCHIVE_NAME}"

cleanup() {
  rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

echo "Fetching MuPDF macOS arm64 build archive"
download_to_path "${ARCHIVE_URL}" "${ARCHIVE_PATH}"
verify_sha256 "${ARCHIVE_SHA256}" "${ARCHIVE_PATH}"

mkdir -p "${OUTPUT_ROOT}"
rm -rf "${TARGET_ROOT}"
tar -xzf "${ARCHIVE_PATH}" -C "${OUTPUT_ROOT}"

if [[ ! -f "${TARGET_ROOT}/lib/libmupdf.a" ]]; then
  echo "Expected libmupdf.a was not extracted into ${TARGET_ROOT}" >&2
  exit 1
fi

if [[ ! -d "${TARGET_ROOT}/include" || ! -d "${TARGET_ROOT}/generated" ]]; then
  echo "Expected MuPDF headers were not extracted into ${TARGET_ROOT}" >&2
  exit 1
fi

echo "MuPDF build artifacts are ready at ${TARGET_ROOT}"
