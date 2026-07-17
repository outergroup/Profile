#!/bin/bash

set -euo pipefail
export COPYFILE_DISABLE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-${REPO_ROOT}/build/frontend}"
PACKAGE_ROOT="${PACKAGE_ROOT:-${REPO_ROOT}/build/linux-package}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${REPO_ROOT}/build/release}"
CONFIGURATION="${CONFIGURATION:-Release}"

require_file() {
    if [[ ! -f "$1" ]]; then
        echo "error: missing $1" >&2
        exit 1
    fi
}

require_file "${PACKAGE_ROOT}/RemoteLinuxBinaries/aarch64/ProfileBackend"
require_file "${PACKAGE_ROOT}/RemoteLinuxBinaries/x86_64/ProfileBackend"
require_file "${PACKAGE_ROOT}/RemoteLinuxBinariesMusl/aarch64/ProfileBackend"
require_file "${PACKAGE_ROOT}/RemoteLinuxBinariesMusl/x86_64/ProfileBackend"
require_file "${REPO_ROOT}/app-icon.png"

mkdir -p "${OUTPUT_ROOT}" "${PACKAGE_ROOT}/bundles"

echo "==> Building Profile frontend"
/usr/bin/xcodebuild \
    -project "${REPO_ROOT}/Profile.xcodeproj" \
    -scheme Profile \
    -configuration "${CONFIGURATION}" \
    SYMROOT="${BUILD_ROOT}" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

echo "==> Archiving ProfileContent bundles"
"${REPO_ROOT}/Scripts/archive_profile_bundle.sh" \
    "${BUILD_ROOT}/${CONFIGURATION}/Profile.bundle" \
    "${PACKAGE_ROOT}/bundles" \
    ProfileContent.bundle

STAGING_ROOT="$(mktemp -d)"
trap 'rm -rf "${STAGING_ROOT}"' EXIT

OUTPUT_APP_ROOT="${OUTPUT_ROOT}/Profile"
rm -rf "${OUTPUT_APP_ROOT}"
mkdir -p "${OUTPUT_APP_ROOT}"

package_linux_variant() {
    local arch="$1"
    local libc="$2"
    local output_name="$3"
    local binary_directory=RemoteLinuxBinaries
    [[ "${libc}" == musl ]] && binary_directory=RemoteLinuxBinariesMusl
    local app_root="${STAGING_ROOT}/Profile"
    rm -rf "${app_root}"
    mkdir -p \
        "${app_root}/${binary_directory}/${arch}" \
        "${app_root}/bundles"
    install -m 0755 "${PACKAGE_ROOT}/${binary_directory}/${arch}/ProfileBackend" "${app_root}/${binary_directory}/${arch}/ProfileBackend"
    install -m 0644 "${PACKAGE_ROOT}/bundles/ProfileContent.bundle.macos-arm.aar" "${app_root}/bundles/ProfileContent.bundle.macos-arm.aar"
    install -m 0644 "${PACKAGE_ROOT}/bundles/ProfileContent.bundle.macos-x86.aar" "${app_root}/bundles/ProfileContent.bundle.macos-x86.aar"
    install -m 0644 "${REPO_ROOT}/app-icon.png" "${app_root}/app-icon.png"
    tar --format ustar --no-xattrs -C "${STAGING_ROOT}" -czf "${OUTPUT_APP_ROOT}/${output_name}.tar.gz" Profile
    echo "Packaged ${OUTPUT_APP_ROOT}/${output_name}.tar.gz"
}

package_linux_variant aarch64 glibc linux-aarch64
package_linux_variant x86_64 glibc linux-x86_64
package_linux_variant aarch64 musl linux-aarch64-musl
package_linux_variant x86_64 musl linux-x86_64-musl
