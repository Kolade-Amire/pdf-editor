#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
METADATA_FILE="${REPO_ROOT}/vendor-metadata.toml"
TARGET_ROOT="${REPO_ROOT}/upstream"

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

retry_command() {
  local attempt=1
  local max_attempts=3

  until "$@"; do
    if (( attempt >= max_attempts )); then
      return 1
    fi

    sleep $(( attempt * 5 ))
    attempt=$(( attempt + 1 ))
  done
}

write_metadata() {
  local resolved_commit="$1"
  local upstream_repo="$2"
  local build_extract="$3"
  local build_tesseract="$4"

  cat <<EOF > "${METADATA_FILE}"
schema_version = 1
upstream_repo = "${upstream_repo}"
upstream_commit = "${resolved_commit}"
import_strategy = "flattened-mirror"
submodules_expanded = true
submodule_note = "MuPDF upstream Git submodules are expanded into the committed mirror tree for reproducible releases."
build_extract = "${build_extract}"
build_tesseract = "${build_tesseract}"
EOF
}

verify_expanded_submodules() {
  local worktree="$1"
  local path=""

  while read -r _ path _; do
    [[ -z "${path}" ]] && continue
    if [[ ! -d "${worktree}/${path}" ]]; then
      echo "Expected submodule directory ${path} was not created." >&2
      exit 1
    fi

    if [[ -z "$(find "${worktree}/${path}" -mindepth 1 -not -name .git -print -quit)" ]]; then
      echo "Submodule ${path} is empty after recursive checkout." >&2
      exit 1
    fi
  done < <(git -C "${worktree}" submodule status --recursive)
}

UPSTREAM_REPO="$(read_metadata_string "upstream_repo")"
CURRENT_COMMIT="$(read_metadata_string "upstream_commit")"
IMPORT_STRATEGY="$(read_metadata_string "import_strategy")"
BUILD_EXTRACT="$(read_metadata_string "build_extract")"
BUILD_TESSERACT="$(read_metadata_string "build_tesseract")"
REQUESTED_REF="${1:-${CURRENT_COMMIT}}"

if [[ "${IMPORT_STRATEGY}" != "flattened-mirror" ]]; then
  echo "Unsupported import strategy ${IMPORT_STRATEGY}" >&2
  exit 1
fi

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mupdf-mirror-update.XXXXXX")"
SOURCE_CLONE="${TEMP_ROOT}/mupdf"

cleanup() {
  rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

echo "Cloning MuPDF from ${UPSTREAM_REPO}"
retry_command git clone "${UPSTREAM_REPO}" "${SOURCE_CLONE}"

echo "Checking out ${REQUESTED_REF}"
git -C "${SOURCE_CLONE}" checkout "${REQUESTED_REF}"
retry_command git -C "${SOURCE_CLONE}" submodule update --init --recursive

verify_expanded_submodules "${SOURCE_CLONE}"

RESOLVED_COMMIT="$(git -C "${SOURCE_CLONE}" rev-parse HEAD)"

mkdir -p "${TARGET_ROOT}"
rsync -a --delete --exclude '.git' "${SOURCE_CLONE}/" "${TARGET_ROOT}/"

write_metadata "${RESOLVED_COMMIT}" "${UPSTREAM_REPO}" "${BUILD_EXTRACT}" "${BUILD_TESSERACT}"

echo "Mirror updated to ${RESOLVED_COMMIT}"
