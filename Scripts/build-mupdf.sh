#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_ROOT="${REPO_ROOT}/Vendor/mupdf/source-cache/upstream"
OUTPUT_ROOT="${REPO_ROOT}/Vendor/mupdf/build/macos-arm64"
OUTPUT_LIB="${OUTPUT_ROOT}/lib"

source "${SCRIPT_DIR}/mupdf-lock.sh"

if [[ ! -d "${SOURCE_ROOT}" ]]; then
  echo "MuPDF source cache is missing at ${SOURCE_ROOT}" >&2
  echo "Run ./Scripts/fetch-mupdf-source.sh or unpack the mirror source archive first." >&2
  exit 1
fi

BUILD_EXTRACT="$(require_lock_string "" "build_extract")"
BUILD_TESSERACT="$(require_lock_string "" "build_tesseract")"

mkdir -p "${OUTPUT_LIB}"
rm -rf "${OUTPUT_ROOT}/include" "${OUTPUT_ROOT}/generated"

ARCH_FLAGS=(-arch arm64 -mmacosx-version-min=14.0)
XCFLAGS="${ARCH_FLAGS[*]}"
XLDFLAGS="${ARCH_FLAGS[*]}"

echo "Building MuPDF static libraries from source cache ${SOURCE_ROOT}"
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

echo "MuPDF artifacts copied to ${OUTPUT_ROOT}"
