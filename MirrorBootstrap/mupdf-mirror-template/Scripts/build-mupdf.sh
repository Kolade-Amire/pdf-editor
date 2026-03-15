#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
METADATA_FILE="${REPO_ROOT}/vendor-metadata.toml"
SOURCE_ROOT="${REPO_ROOT}/upstream"
OUTPUT_ROOT="${REPO_ROOT}/build/macos-arm64"
OUTPUT_LIB="${OUTPUT_ROOT}/lib"

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

BUILD_EXTRACT="$(read_metadata_string "build_extract")"
BUILD_TESSERACT="$(read_metadata_string "build_tesseract")"

mkdir -p "${OUTPUT_LIB}"
rm -rf "${OUTPUT_ROOT}/include" "${OUTPUT_ROOT}/generated"

ARCH_FLAGS=(-arch arm64 -mmacosx-version-min=14.0)
XCFLAGS="${ARCH_FLAGS[*]}"
XLDFLAGS="${ARCH_FLAGS[*]}"

make -C "${SOURCE_ROOT}" \
  build=release \
  "extract=${BUILD_EXTRACT}" \
  "tesseract=${BUILD_TESSERACT}" \
  XCFLAGS="${XCFLAGS}" \
  XLDFLAGS="${XLDFLAGS}" \
  HAVE_X11=no \
  HAVE_GLUT=no \
  libs

BUILD_DIR="${SOURCE_ROOT}/build/release"

cp "${BUILD_DIR}/libmupdf.a" "${OUTPUT_LIB}/"

if [[ -f "${BUILD_DIR}/libmupdf-third.a" ]]; then
  cp "${BUILD_DIR}/libmupdf-third.a" "${OUTPUT_LIB}/"
fi

if [[ -f "${BUILD_DIR}/libmupdf-threads.a" ]]; then
  cp "${BUILD_DIR}/libmupdf-threads.a" "${OUTPUT_LIB}/"
fi

if [[ -f "${BUILD_DIR}/libmupdf-pkcs7.a" ]]; then
  cp "${BUILD_DIR}/libmupdf-pkcs7.a" "${OUTPUT_LIB}/"
fi

rsync -a "${SOURCE_ROOT}/include/" "${OUTPUT_ROOT}/include/"
rsync -a "${SOURCE_ROOT}/generated/" "${OUTPUT_ROOT}/generated/"

echo "Build artifacts are ready at ${OUTPUT_ROOT}"
