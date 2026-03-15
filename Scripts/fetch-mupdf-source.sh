#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_CACHE_ROOT="${REPO_ROOT}/Vendor/mupdf/source-cache"
TARGET_ROOT="${SOURCE_CACHE_ROOT}/upstream"

source "${SCRIPT_DIR}/mupdf-lock.sh"

ARCHIVE_NAME="$(require_lock_string "source" "archive_name")"
ARCHIVE_URL="$(resolve_lock_value "source" "url" "${MUPDF_SOURCE_URL:-}")"
ARCHIVE_SHA256="$(resolve_lock_value "source" "sha256" "${MUPDF_SOURCE_SHA256:-}")"

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pdf-editor-mupdf-source.XXXXXX")"
ARCHIVE_PATH="${TEMP_ROOT}/${ARCHIVE_NAME}"

cleanup() {
  rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

echo "Fetching MuPDF source archive"
download_to_path "${ARCHIVE_URL}" "${ARCHIVE_PATH}"
verify_sha256 "${ARCHIVE_SHA256}" "${ARCHIVE_PATH}"

mkdir -p "${SOURCE_CACHE_ROOT}"
rm -rf "${TARGET_ROOT}"
tar -xzf "${ARCHIVE_PATH}" -C "${SOURCE_CACHE_ROOT}"

if [[ ! -f "${TARGET_ROOT}/Makefile" ]]; then
  echo "Expected MuPDF source tree was not extracted into ${TARGET_ROOT}" >&2
  exit 1
fi

echo "MuPDF source cache is ready at ${TARGET_ROOT}"
