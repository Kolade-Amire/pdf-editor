#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCK_FILE="${REPO_ROOT}/Vendor/mupdf/lock.toml"

require_lock_file() {
  if [[ ! -f "${LOCK_FILE}" ]]; then
    echo "MuPDF lock file is missing at ${LOCK_FILE}" >&2
    exit 1
  fi
}

read_lock_string() {
  local section="$1"
  local key="$2"

  awk -F'"' -v section="${section}" -v lock_key="${key}" '
    /^\[/ {
      in_section = ($0 == "[" section "]")
      next
    }
    section == "" && $1 == lock_key " = " {
      print $2
      exit
    }
    in_section && $1 == lock_key " = " {
      print $2
      exit
    }
  ' "${LOCK_FILE}"
}

require_lock_string() {
  local section="$1"
  local key="$2"
  local value=""

  value="$(read_lock_string "${section}" "${key}")"
  if [[ -z "${value}" ]]; then
    echo "Missing ${key} in section [${section}] of ${LOCK_FILE}" >&2
    exit 1
  fi

  echo "${value}"
}

resolve_lock_value() {
  local section="$1"
  local key="$2"
  local override="${3:-}"
  local value=""

  if [[ -n "${override}" ]]; then
    echo "${override}"
    return 0
  fi

  value="$(require_lock_string "${section}" "${key}")"
  if [[ "${value}" == "UNSET" ]]; then
    echo "Lock value ${key} in section [${section}] is not configured." >&2
    echo "Set it in ${LOCK_FILE} or pass an override environment variable." >&2
    exit 1
  fi

  echo "${value}"
}

download_to_path() {
  local source_url="$1"
  local destination_path="$2"

  if [[ "${source_url}" == file://* ]]; then
    cp "${source_url#file://}" "${destination_path}"
    return 0
  fi

  curl --fail --location --silent --show-error "${source_url}" -o "${destination_path}"
}

verify_sha256() {
  local expected_sha="$1"
  local file_path="$2"
  local actual_sha=""

  actual_sha="$(shasum -a 256 "${file_path}" | awk '{ print $1 }')"
  if [[ "${actual_sha}" != "${expected_sha}" ]]; then
    echo "SHA-256 mismatch for ${file_path}" >&2
    echo "Expected: ${expected_sha}" >&2
    echo "Actual:   ${actual_sha}" >&2
    exit 1
  fi
}

require_lock_file
