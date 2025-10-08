#!/usr/bin/env bash
set -euo pipefail
# Preserve the default word-splitting behavior (space, tab, newline) to ensure
# that array expansions using space-delimited values continue to work while the
# script still opts in to bash's strict error handling modes.
IFS=$' \n\t'

# This script builds FFmpeg static libraries across all supported Apple
# platforms and emits XCFramework bundles that can be consumed from SwiftPM.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-"${REPO_ROOT}/build"}"
SOURCE_ROOT="${SOURCE_ROOT:-"${BUILD_ROOT}/_sources"}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-"${REPO_ROOT}/Artifacts"}"
LOG_DIR="${LOG_DIR:-"${BUILD_ROOT}/logs"}"

FFMPEG_REPO="${FFMPEG_REPO:-https://github.com/FFmpeg/FFmpeg.git}"
FFMPEG_REF="${FFMPEG_REF:-n7.0}" # Latest stable tagged release at the time of writing.
FFMPEG_LIBRARIES=(avcodec avdevice avfilter avformat avutil postproc swresample swscale)

# Ordered list of supported platform identifiers.
ALL_PLATFORMS=(
  macos
  ios
  ios-simulator
  tvos
  tvos-simulator
  visionos
  visionos-simulator
)

ORDERED_PLATFORMS=()

platform_min_version() {
  case "$1" in
    macos) echo "11.0" ;;
    ios|ios-simulator) echo "13.0" ;;
    tvos|tvos-simulator) echo "13.0" ;;
    visionos|visionos-simulator) echo "1.0" ;;
    *) return 1 ;;
  esac
}

platform_sdk() {
  case "$1" in
    macos) echo "macosx" ;;
    ios) echo "iphoneos" ;;
    ios-simulator) echo "iphonesimulator" ;;
    tvos) echo "appletvos" ;;
    tvos-simulator) echo "appletvsimulator" ;;
    visionos) echo "xros" ;;
    visionos-simulator) echo "xrssimulator" ;;
    *) return 1 ;;
  esac
}

platform_archs() {
  case "$1" in
    macos) echo "arm64 x86_64" ;;
    ios) echo "arm64" ;;
    ios-simulator) echo "arm64 x86_64" ;;
    tvos) echo "arm64" ;;
    tvos-simulator) echo "arm64 x86_64" ;;
    visionos) echo "arm64" ;;
    visionos-simulator) echo "arm64" ;;
    *) return 1 ;;
  esac
}

is_supported_platform() {
  local candidate="$1"
  for platform in "${ALL_PLATFORMS[@]}"; do
    if [[ "${platform}" == "${candidate}" ]]; then
      return 0
    fi
  done
  return 1
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command '$1' is not available" >&2
    exit 1
  fi
}

ensure_directories() {
  mkdir -p "${BUILD_ROOT}" "${SOURCE_ROOT}" "${ARTIFACTS_DIR}/xcframeworks" "${LOG_DIR}"
}

clone_ffmpeg() {
  local dest="${SOURCE_ROOT}/ffmpeg"
  if [[ -d "${dest}/.git" ]]; then
    pushd "${dest}" >/dev/null
    git fetch origin "${FFMPEG_REF}" --depth 1
    if git rev-parse "${FFMPEG_REF}" >/dev/null 2>&1; then
      git checkout "${FFMPEG_REF}"
    else
      git checkout FETCH_HEAD
    fi
    git reset --hard "${FFMPEG_REF}" 2>/dev/null || git reset --hard FETCH_HEAD
    popd >/dev/null
  else
    git clone --depth 1 --branch "${FFMPEG_REF}" "${FFMPEG_REPO}" "${dest}"
  fi
}

platform_to_version_flag() {
  local platform="$1"
  local min_version
  min_version="$(platform_min_version "${platform}")" || return 1

  case "${platform}" in
    macos) echo "-mmacosx-version-min=${min_version}" ;;
    ios|ios-simulator) echo "-mios-version-min=${min_version}" ;;
    tvos|tvos-simulator) echo "-mtvos-version-min=${min_version}" ;;
    visionos|visionos-simulator) echo "-mxros-version-min=${min_version}" ;;
  esac
}


build_arch() {
  local platform="$1"
  local arch="$2"

  local sdk
  sdk="$(platform_sdk "${platform}")" || {
    echo "error: unknown platform '${platform}'" >&2
    exit 1
  }
  local sysroot="$(xcrun --sdk "${sdk}" --show-sdk-path)"
  local cc="$(xcrun --sdk "${sdk}" --find clang)"
  local cxx="$(xcrun --sdk "${sdk}" --find clang++)"
  local version_flag=""
  version_flag="$(platform_to_version_flag "${platform}")" || version_flag=""

  local build_dir="${BUILD_ROOT}/${platform}/${arch}/build"
  local install_dir="${BUILD_ROOT}/${platform}/${arch}/install"

  rm -rf "${build_dir}" "${install_dir}"
  mkdir -p "${build_dir}" "${install_dir}"

  pushd "${build_dir}" >/dev/null

  PKG_CONFIG_PATH="" \
  PKG_CONFIG_LIBDIR="" \
  "${SOURCE_ROOT}/ffmpeg/configure" \
    --prefix="${install_dir}" \
    --pkg-config-flags="--static" \
    --target-os=darwin \
    --arch="${arch}" \
    --cc="${cc}" \
    --cxx="${cxx}" \
    --enable-cross-compile \
    --enable-static \
    --disable-shared \
    --disable-programs \
    --disable-doc \
    --disable-debug \
    --enable-pthreads \
    --enable-version3 \
    --enable-avcodec \
    --enable-avdevice \
    --enable-avfilter \
    --enable-avformat \
    --enable-avutil \
    --enable-postproc \
    --enable-swresample \
    --enable-swscale \
    --extra-cflags="-arch ${arch} -isysroot ${sysroot} ${version_flag}" \
    --extra-ldflags="-arch ${arch} -isysroot ${sysroot} ${version_flag}" \
    --sysroot="${sysroot}" \
    --enable-pic

  make -j"$(sysctl -n hw.logicalcpu)"
  make install

  popd >/dev/null
}

build_platform() {
  local platform="$1"
  local archs_string
  local archs=()

  archs_string="$(platform_archs "${platform}")" || {
    echo "warning: no architectures defined for platform '${platform}'" >&2
    return
  }

  IFS=' ' read -r -a archs <<< "${archs_string}"

  for arch in "${archs[@]}"; do
    local log_file="${LOG_DIR}/configure-${platform}-${arch}.log"
    echo "Building FFmpeg for ${platform} (${arch})"
    build_arch "${platform}" "${arch}" > >(tee "${log_file}") 2>&1
  done
}

package_library() {
  local library="$1"
  local args=()
  for platform in "${ORDERED_PLATFORMS[@]}"; do
    local archs_string
    local archs=()

    archs_string="$(platform_archs "${platform}")" || continue
    IFS=' ' read -r -a archs <<< "${archs_string}"

    for arch in "${archs[@]}"; do
      local install_dir="${BUILD_ROOT}/${platform}/${arch}/install"
      local static_lib="${install_dir}/lib/lib${library}.a"
      local headers_dir="${install_dir}/include"
      if [[ ! -f "${static_lib}" ]]; then
        continue
      fi
      args+=("-library" "${static_lib}" "-headers" "${headers_dir}")
    done
  done

  if [[ ${#args[@]} -eq 0 ]]; then
    echo "warning: skipping lib${library} because no build artifacts were found" >&2
    return
  fi

  mkdir -p "${ARTIFACTS_DIR}/xcframeworks"
  xcodebuild -create-xcframework "${args[@]}" \
    -output "${ARTIFACTS_DIR}/xcframeworks/lib${library}.xcframework"
}

package_libraries() {
  for library in "${FFMPEG_LIBRARIES[@]}"; do
    package_library "${library}"
  done
}

usage() {
  cat <<USAGE
Usage: $0 [--platform <name>] [--ffmpeg-ref <ref>] [--skip-package]

Options:
  --platform <name>   Build only the specified platform (repeat to add more). Defaults to all.
  --ffmpeg-ref <ref>  Git ref or tag to fetch from the FFmpeg repository (default: ${FFMPEG_REF}).
  --skip-package      Skip XCFramework packaging (useful when only building artifacts).
USAGE
}

main() {
  local platforms=()
  local skip_package=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --platform)
        platforms+=("$2")
        shift 2
        ;;
      --ffmpeg-ref)
        FFMPEG_REF="$2"
        shift 2
        ;;
      --skip-package)
        skip_package=1
        shift 1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "error: unknown argument $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  if [[ ${#platforms[@]} -eq 0 ]]; then
    platforms=("${ALL_PLATFORMS[@]}")
  fi

  ORDERED_PLATFORMS=()
  for platform in "${platforms[@]}"; do
    if ! is_supported_platform "${platform}"; then
      echo "warning: skipping unknown platform '${platform}'" >&2
      continue
    fi
    ORDERED_PLATFORMS+=("${platform}")
  done

  if [[ ${#ORDERED_PLATFORMS[@]} -eq 0 ]]; then
    echo "error: no valid platforms provided" >&2
    exit 1
  fi

  require_command git
  require_command xcrun
  require_command make
  require_command sysctl
  require_command xcodebuild
  require_command nasm
  require_command yasm

  ensure_directories
  clone_ffmpeg

  for platform in "${ORDERED_PLATFORMS[@]}"; do
    build_platform "${platform}"
  done

  if [[ ${skip_package} -eq 0 ]]; then
    package_libraries
  else
    echo "Skipping XCFramework packaging step"
  fi
}

main "$@"
