#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
METADATA_FILE="${REPO_ROOT}/vendor-metadata.toml"
DIST_ROOT="${REPO_ROOT}/dist"
SOURCE_ROOT="${REPO_ROOT}/upstream"
BUILD_ROOT="${REPO_ROOT}/build"

read_metadata_string() {
  local key="$1"
  local value=""

  value="$(awk -F'"' -v metadata_key="${key}" '$1 == metadata_key " = " { print $2 }' "${METADATA_FILE}")"
  if [[ -z "${value}" ]]; then
    echo "Missing ${key} in ${METADATA_FILE}" >&2
    exit 1
  fi

  echo "${value}"
}

UPSTREAM_COMMIT="$(read_metadata_string "upstream_commit")"
SHORT_COMMIT="${UPSTREAM_COMMIT[1,8]}"
RELEASE_TAG="mupdf-${SHORT_COMMIT}"
SOURCE_ARCHIVE_NAME="${RELEASE_TAG}-source.tar.gz"
BUILD_ARCHIVE_NAME="${RELEASE_TAG}-macos-arm64-build.tar.gz"
CHECKSUM_FILE_NAME="${RELEASE_TAG}-SHA256SUMS.txt"

mkdir -p "${DIST_ROOT}"
rm -f "${DIST_ROOT}/${SOURCE_ARCHIVE_NAME}" "${DIST_ROOT}/${BUILD_ARCHIVE_NAME}" "${DIST_ROOT}/${CHECKSUM_FILE_NAME}"

tar -czf "${DIST_ROOT}/${SOURCE_ARCHIVE_NAME}" -C "${REPO_ROOT}" upstream
tar -czf "${DIST_ROOT}/${BUILD_ARCHIVE_NAME}" -C "${BUILD_ROOT}" macos-arm64

(
  cd "${DIST_ROOT}"
  shasum -a 256 "${SOURCE_ARCHIVE_NAME}" "${BUILD_ARCHIVE_NAME}" > "${CHECKSUM_FILE_NAME}"
)

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "release_tag=${RELEASE_TAG}"
    echo "source_archive=${DIST_ROOT}/${SOURCE_ARCHIVE_NAME}"
    echo "build_archive=${DIST_ROOT}/${BUILD_ARCHIVE_NAME}"
    echo "checksum_file=${DIST_ROOT}/${CHECKSUM_FILE_NAME}"
  } >> "${GITHUB_OUTPUT}"
fi

echo "Release artifacts are ready under ${DIST_ROOT}"
