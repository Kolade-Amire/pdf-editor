#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE_ROOT="${REPO_ROOT}/MirrorBootstrap/mupdf-mirror-template"

usage() {
  cat <<'EOF'
Usage:
  ./Scripts/bootstrap-mupdf-mirror-template.sh <target-directory>
EOF
}

if [[ "$#" -ne 1 ]]; then
  usage >&2
  exit 1
fi

TARGET_ROOT="$1"

if [[ ! -d "${TEMPLATE_ROOT}" ]]; then
  echo "Mirror template is missing at ${TEMPLATE_ROOT}" >&2
  exit 1
fi

mkdir -p "${TARGET_ROOT}"
rsync -a "${TEMPLATE_ROOT}/" "${TARGET_ROOT}/"

echo "MuPDF mirror template copied to ${TARGET_ROOT}"
