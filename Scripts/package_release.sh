#!/bin/bash

set -euo pipefail
export COPYFILE_DISABLE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-${REPO_ROOT}/build/frontend}"
PACKAGE_ROOT="${PACKAGE_ROOT:-${REPO_ROOT}/build/linux-package}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${REPO_ROOT}/build/release}"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_CODESIGN_IDENTITY="${APP_CODESIGN_IDENTITY:-${OUTER_SHELL_CODESIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}}"
APP_NOTARY_PROFILE="${APP_NOTARY_PROFILE:-${OUTER_SHELL_NOTARY_PROFILE:-}}"

require_file() {
    if [[ ! -f "$1" ]]; then
        echo "error: missing $1" >&2
        exit 1
    fi
}

require_file "${REPO_ROOT}/VERSION"
APP_VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION")"
if [[ ! "${APP_VERSION}" =~ ^[0-9A-Za-z.+_-]+$ ]]; then
    echo "error: ${REPO_ROOT}/VERSION must hold a version such as 1.1.0" >&2
    exit 1
fi

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
APP_CODESIGN_IDENTITY="${APP_CODESIGN_IDENTITY}" APP_NOTARY_PROFILE="${APP_NOTARY_PROFILE}" \
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
    mkdir -p "${app_root}/web"
    install -m 0644 "${REPO_ROOT}/Resources/ProfileWeb/index.html" "${app_root}/web/index.html"
    install -m 0644 "${REPO_ROOT}/app-icon.png" "${app_root}/web/app-icon.png"
    install -m 0644 "${REPO_ROOT}/Resources/ProfileWeb/app.css" "${app_root}/web/app.css"
    install -m 0644 "${REPO_ROOT}/Resources/ProfileWeb/app.js" "${app_root}/web/app.js"
    printf '%s\n' "${APP_VERSION}" > "${app_root}/version"
    tar --format ustar --no-xattrs -C "${STAGING_ROOT}" -czf "${OUTPUT_APP_ROOT}/${output_name}.tar.gz" Profile
    echo "Packaged ${OUTPUT_APP_ROOT}/${output_name}.tar.gz"
}

package_linux_variant aarch64 glibc linux-aarch64
package_linux_variant x86_64 glibc linux-x86_64
package_linux_variant aarch64 musl linux-aarch64-musl
package_linux_variant x86_64 musl linux-x86_64-musl

macos_codesign_args() {
    if [[ "${APP_CODESIGN_IDENTITY}" == "-" ]]; then
        printf '%s\n' --force --sign - --timestamp=none
    else
        printf '%s\n' --force --options runtime --timestamp --sign "${APP_CODESIGN_IDENTITY}"
    fi
}

sign_macos_app() {
    local path="$1"
    local args=()
    while IFS= read -r arg; do
        args+=("$arg")
    done < <(macos_codesign_args)
    /usr/bin/codesign "${args[@]}" "$path" >/dev/null
}

notarize_macos_app_if_requested() {
    local path="$1"
    if [[ -z "${APP_NOTARY_PROFILE}" ]]; then
        return 0
    fi
    if [[ "${APP_CODESIGN_IDENTITY}" == "-" ]]; then
        echo "error: APP_NOTARY_PROFILE requires APP_CODESIGN_IDENTITY" >&2
        exit 1
    fi
    local archive="${STAGING_ROOT}/$(basename "$path" .app)-notarize.zip"
    /usr/bin/ditto -c -k --norsrc --keepParent "$path" "$archive"
    xcrun notarytool submit "$archive" \
        --keychain-profile "${APP_NOTARY_PROFILE}" \
        --wait
    xcrun stapler staple "$path"
    rm -f "$archive"
}

echo "==> Building Profile container helpers"
rm -rf "${PACKAGE_ROOT}/helpers"
for helper_arch in x86_64 aarch64; do
    mkdir -p "${PACKAGE_ROOT}/helpers/linux-${helper_arch}"
    "${REPO_ROOT}/Helper/build.sh" linux "${helper_arch}" "${PACKAGE_ROOT}/helpers/linux-${helper_arch}/outer-profile-helper"
done

install_web_resources() {
    local web_root="$1"
    mkdir -p "${web_root}"
    install -m 0644 "${REPO_ROOT}/Resources/ProfileWeb/index.html" "${web_root}/index.html"
    install -m 0644 "${REPO_ROOT}/Resources/ProfileWeb/app.css" "${web_root}/app.css"
    install -m 0644 "${REPO_ROOT}/Resources/ProfileWeb/app.js" "${web_root}/app.js"
    install -m 0644 "${REPO_ROOT}/app-icon.png" "${web_root}/app-icon.png"
}

install_content_bundles() {
    local bundles_root="$1"
    mkdir -p "${bundles_root}"
    install -m 0644 "${PACKAGE_ROOT}/bundles/ProfileContent.bundle.macos-arm.aar" "${bundles_root}/ProfileContent.bundle.macos-arm.aar"
    install -m 0644 "${PACKAGE_ROOT}/bundles/ProfileContent.bundle.macos-x86.aar" "${bundles_root}/ProfileContent.bundle.macos-x86.aar"
}

WORKER_CONTEXT="${STAGING_ROOT}/worker"
mkdir -p "${WORKER_CONTEXT}"
cp -R "${REPO_ROOT}/Backend" "${WORKER_CONTEXT}/Backend"
install_web_resources "${WORKER_CONTEXT}/web"
install_content_bundles "${WORKER_CONTEXT}/bundles"
cp "${REPO_ROOT}/Backend/ContainerWorker.Dockerfile" "${WORKER_CONTEXT}/Dockerfile"
WORKER_IMAGE="outershell/profile-tracing-worker:$(cd "${WORKER_CONTEXT}" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum | shasum | cut -c1-12)"

package_macos_variant() {
    local arch="$1"
    local output_name="$2"
    local app_root="${STAGING_ROOT}/Profile"
    local app_bundle="${app_root}/Profile.app"
    local resources="${app_bundle}/Contents/Resources"
    rm -rf "${app_root}"
    mkdir -p "${app_bundle}/Contents/MacOS" "${resources}"
    cc -std=gnu17 -O2 -Wall -Wextra -arch "${arch}" \
        -DAPP_NAME=\"Profile\" "${REPO_ROOT}/Backend/MacContainerBackend.c" \
        -o "${app_bundle}/Contents/MacOS/ProfileBackend"
    install_content_bundles "${resources}/bundles"
    install_web_resources "${resources}/web"
    install -m 0644 "${REPO_ROOT}/app-icon.png" "${resources}/app-icon.png"
    cp -R "${WORKER_CONTEXT}" "${resources}/worker-build"
    printf '%s\n' "${WORKER_IMAGE}" > "${resources}/worker-image"
    cp -R "${PACKAGE_ROOT}/helpers" "${resources}/helpers"
    local info_plist="${app_bundle}/Contents/Info.plist"
    /usr/bin/plutil -create xml1 "${info_plist}"
    /usr/bin/plutil -insert CFBundleExecutable -string ProfileBackend "${info_plist}"
    /usr/bin/plutil -insert CFBundleIdentifier -string org.outershell.Profile "${info_plist}"
    /usr/bin/plutil -insert CFBundleName -string Profile "${info_plist}"
    /usr/bin/plutil -insert CFBundlePackageType -string APPL "${info_plist}"
    /usr/bin/plutil -insert CFBundleShortVersionString -string "${APP_VERSION}" "${info_plist}"
    /usr/bin/plutil -insert CFBundleVersion -string "${APP_VERSION}" "${info_plist}"
    /usr/bin/plutil -insert LSBackgroundOnly -bool true "${info_plist}"
    sign_macos_app "${app_bundle}"
    notarize_macos_app_if_requested "${app_bundle}"
    printf '%s\n' "${APP_VERSION}" > "${app_root}/version"
    tar --format ustar --no-xattrs -C "${STAGING_ROOT}" -czf "${OUTPUT_APP_ROOT}/${output_name}.tar.gz" Profile
    echo "Packaged ${OUTPUT_APP_ROOT}/${output_name}.tar.gz"
}

package_macos_variant arm64 macos-arm64
package_macos_variant x86_64 macos-x86_64
