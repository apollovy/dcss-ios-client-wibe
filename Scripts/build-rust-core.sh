#!/usr/bin/env bash
set -euo pipefail

# Root of the Swift/Xcode project
PROJ_ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
RUST_CORE_DIR="${PROJ_ROOT}/RustCore"
CARGO_HOME="${PROJ_ROOT}/.cargo"
CARGO_TARGET_DIR="${RUST_CORE_DIR}/target"

echo "==> Building Rust core (static libs for iOS)..."
echo "Project root: ${PROJ_ROOT}"
echo "RustCore dir: ${RUST_CORE_DIR}"

if [[ ! -d "${RUST_CORE_DIR}" ]]; then
  echo "error: RustCore directory not found at ${RUST_CORE_DIR}" >&2
  exit 1
fi

mkdir -p "${CARGO_HOME}"
export CARGO_HOME
export CARGO_TARGET_DIR

cd "${RUST_CORE_DIR}"

# Build profile selection:
# Priority:
# 1) RUST_CARGO_PROFILE override ("debug" | "release")
# 2) Xcode CONFIGURATION mapping
# 3) Manual shell default -> debug (better local visibility of Rust logs)
if [[ -n "${RUST_CARGO_PROFILE:-}" ]]; then
  case "${RUST_CARGO_PROFILE}" in
    debug|release)
      CARGO_PROFILE="${RUST_CARGO_PROFILE}"
      ;;
    *)
      echo "error: unsupported RUST_CARGO_PROFILE='${RUST_CARGO_PROFILE}', use 'debug' or 'release'" >&2
      exit 1
      ;;
  esac
  XCODE_CONFIGURATION="${CONFIGURATION:-manual}"
elif [[ -n "${CONFIGURATION:-}" ]]; then
  XCODE_CONFIGURATION="${CONFIGURATION}"
  if [[ "${XCODE_CONFIGURATION}" =~ [Dd]ebug ]]; then
    CARGO_PROFILE="debug"
  else
    CARGO_PROFILE="release"
  fi
else
  XCODE_CONFIGURATION="manual"
  CARGO_PROFILE="debug"
fi

if [[ "${CARGO_PROFILE}" == "release" ]]; then
  CARGO_PROFILE_FLAG="--release"
else
  CARGO_PROFILE_FLAG=""
fi

echo "Xcode configuration: ${XCODE_CONFIGURATION}"
echo "Rust cargo profile: ${CARGO_PROFILE}"

RUSTUP="$(command -v rustup || true)"

if [[ -z "${RUSTUP}" ]]; then
  echo "error: rustup not found in PATH; please install rustup first" >&2
  exit 1
fi

TOOLCHAIN="${RUST_TOOLCHAIN:-$("${RUSTUP}" show active-toolchain | awk '{print $1}')}"
if [[ -z "${TOOLCHAIN}" ]]; then
  TOOLCHAIN="stable"
fi

TOOLCHAIN_RUSTC="$("${RUSTUP}" which --toolchain "${TOOLCHAIN}" rustc)"
TOOLCHAIN_CARGO="$("${RUSTUP}" which --toolchain "${TOOLCHAIN}" cargo)"

if [[ -z "${TOOLCHAIN_RUSTC}" || -z "${TOOLCHAIN_CARGO}" ]]; then
  echo "error: failed to resolve rustc/cargo for toolchain ${TOOLCHAIN}" >&2
  exit 1
fi

echo "Using rustup: ${RUSTUP}"
echo "Using toolchain: ${TOOLCHAIN}"
echo "Toolchain rustc: ${TOOLCHAIN_RUSTC}"
echo "Toolchain cargo: ${TOOLCHAIN_CARGO}"
"${TOOLCHAIN_RUSTC}" --version
"${TOOLCHAIN_CARGO}" --version

# Prevent accidental override from shell env (common source of mixed installs).
unset CARGO_BUILD_RUSTC || true
unset CARGO_BUILD_RUSTC_WRAPPER || true
unset RUSTC_WRAPPER || true
export RUSTC="${TOOLCHAIN_RUSTC}"
unset RUSTFLAGS || true
unset CFLAGS || true
unset CXXFLAGS || true
unset CPPFLAGS || true
unset LDFLAGS || true

# Targets for device + simulator:
# - aarch64-apple-ios: real iPhone
# - aarch64-apple-ios-sim: Apple Silicon simulator
# - x86_64-apple-ios: Intel simulator
IOS_TARGETS=(
  "aarch64-apple-ios"
  "aarch64-apple-ios-sim"
  "x86_64-apple-ios"
)

BUILT_TARGETS=""

BUILD_STAMP_DIR="${CARGO_TARGET_DIR}/.build-stamps"
mkdir -p "${BUILD_STAMP_DIR}"

compute_inputs_hash() {
  local target="$1"
  local hash_input=""

  hash_input+="toolchain:${TOOLCHAIN}"$'\n'
  hash_input+="target:${target}"$'\n'
  hash_input+="rustc:$("${TOOLCHAIN_RUSTC}" --version)"$'\n'
  hash_input+="cargo:$("${TOOLCHAIN_CARGO}" --version)"$'\n'

  local files=()
  if [[ -f "${RUST_CORE_DIR}/Cargo.toml" ]]; then
    files+=("${RUST_CORE_DIR}/Cargo.toml")
  fi
  if [[ -f "${RUST_CORE_DIR}/Cargo.lock" ]]; then
    files+=("${RUST_CORE_DIR}/Cargo.lock")
  fi
  if [[ -f "${RUST_CORE_DIR}/rust-toolchain.toml" ]]; then
    files+=("${RUST_CORE_DIR}/rust-toolchain.toml")
  fi
  if [[ -f "${RUST_CORE_DIR}/rust-toolchain" ]]; then
    files+=("${RUST_CORE_DIR}/rust-toolchain")
  fi

  while IFS= read -r -d '' file; do
    files+=("${file}")
  done < <(find "${RUST_CORE_DIR}/src" -type f -name "*.rs" -print0 | sort -z)

  for file in "${files[@]}"; do
    hash_input+="$("${TOOLCHAIN_CARGO}" -Vv 2>/dev/null | head -n 1):${file}:$(
      shasum "${file}" | awk '{print $1}'
    )"$'\n'
  done

  printf "%s" "${hash_input}" | shasum | awk '{print $1}'
}

ensure_target_for_toolchain() {
  local target="$1"
  if "${RUSTUP}" target list --toolchain "${TOOLCHAIN}" --installed | grep -qx "${target}"; then
    return 0
  fi

  echo "==> Installing target ${target} via rustup (toolchain: ${TOOLCHAIN})"
  "${RUSTUP}" target add --toolchain "${TOOLCHAIN}" "${target}" || return 1

  if ! "${RUSTUP}" target list --toolchain "${TOOLCHAIN}" --installed | grep -qx "${target}"; then
    echo "warning: target ${target} still missing in rustup toolchain ${TOOLCHAIN}" >&2
    return 1
  fi

  local libdir
  libdir="$("${TOOLCHAIN_RUSTC}" --print target-libdir --target "${target}" 2>/dev/null || true)"
  if [[ -z "${libdir}" || ! -d "${libdir}" ]]; then
    echo "warning: rustc from ${TOOLCHAIN} does not expose target-libdir for ${target}" >&2
    return 1
  fi
}

for target in "${IOS_TARGETS[@]}"; do
  echo "==> Ensuring Rust target ${target}"
  if ! ensure_target_for_toolchain "${target}"; then
    echo "warning: failed to provision target ${target}; skipping it" >&2
    continue
  fi

  TARGET_LIB_PATH="${RUST_CORE_DIR}/target/${target}/${CARGO_PROFILE}/libdcss_core.a"
  TARGET_STAMP_PATH="${BUILD_STAMP_DIR}/${target}.sha"
  CURRENT_HASH="$(compute_inputs_hash "${target}")"
  PREV_HASH="$( [[ -f "${TARGET_STAMP_PATH}" ]] && cat "${TARGET_STAMP_PATH}" || true )"

  if [[ -f "${TARGET_LIB_PATH}" && "${CURRENT_HASH}" == "${PREV_HASH}" ]]; then
    echo "==> skip cargo build ${CARGO_PROFILE_FLAG} --target ${target} (no RustCore changes)"
    BUILT_TARGETS="${BUILT_TARGETS} ${target}"
    continue
  fi

  echo "==> cargo build ${CARGO_PROFILE_FLAG} --target ${target} (inputs changed)"
  "${TOOLCHAIN_CARGO}" build ${CARGO_PROFILE_FLAG} --target "${target}" || {
    echo "warning: build failed for target ${target}; skipping it" >&2
    continue
  }
  printf "%s" "${CURRENT_HASH}" > "${TARGET_STAMP_PATH}"
  BUILT_TARGETS="${BUILT_TARGETS} ${target}"
done

OUT_DIR="${PROJ_ROOT}/BuildArtifacts"
mkdir -p "${OUT_DIR}"

LIBS=()
for target in ${BUILT_TARGETS}; do
  LIB_PATH="${RUST_CORE_DIR}/target/${target}/${CARGO_PROFILE}/libdcss_core.a"
  if [[ -f "${LIB_PATH}" ]]; then
    LIBS+=("${LIB_PATH}")
  fi
done

if [[ ${#LIBS[@]} -eq 0 ]]; then
  echo "error: no libdcss_core.a artifacts were built" >&2
  echo "hint: try explicitly setting toolchain, e.g. RUST_TOOLCHAIN=stable-x86_64-apple-darwin" >&2
  exit 1
fi

# Device + simulator outputs:
DEVICE_LIB="${RUST_CORE_DIR}/target/aarch64-apple-ios/${CARGO_PROFILE}/libdcss_core.a"
SIM_ARM64_LIB="${RUST_CORE_DIR}/target/aarch64-apple-ios-sim/${CARGO_PROFILE}/libdcss_core.a"
SIM_X64_LIB="${RUST_CORE_DIR}/target/x86_64-apple-ios/${CARGO_PROFILE}/libdcss_core.a"
SIM_UNIVERSAL_LIB="${OUT_DIR}/libdcss_core_iossim_universal.a"

if [[ -f "${DEVICE_LIB}" ]]; then
  if [[ ! -f "${OUT_DIR}/libdcss_core_ios_device.a" ]] || ! cmp -s "${DEVICE_LIB}" "${OUT_DIR}/libdcss_core_ios_device.a"; then
    cp -f "${DEVICE_LIB}" "${OUT_DIR}/libdcss_core_ios_device.a"
  fi
  echo "Device static lib: ${OUT_DIR}/libdcss_core_ios_device.a"
fi

if [[ -f "${SIM_ARM64_LIB}" && -f "${SIM_X64_LIB}" && $(command -v lipo >/dev/null 2>&1; echo $?) -eq 0 ]]; then
  if [[ ! -f "${SIM_UNIVERSAL_LIB}" || "${SIM_ARM64_LIB}" -nt "${SIM_UNIVERSAL_LIB}" || "${SIM_X64_LIB}" -nt "${SIM_UNIVERSAL_LIB}" ]]; then
    echo "==> Creating simulator universal static library with lipo"
    lipo -create "${SIM_ARM64_LIB}" "${SIM_X64_LIB}" -output "${SIM_UNIVERSAL_LIB}"
  else
    echo "==> skip lipo (simulator universal lib up-to-date)"
  fi
  echo "Simulator universal lib: ${SIM_UNIVERSAL_LIB}"
elif [[ -f "${SIM_ARM64_LIB}" ]]; then
  if [[ ! -f "${SIM_UNIVERSAL_LIB}" ]] || ! cmp -s "${SIM_ARM64_LIB}" "${SIM_UNIVERSAL_LIB}"; then
    cp -f "${SIM_ARM64_LIB}" "${SIM_UNIVERSAL_LIB}"
  fi
  echo "Simulator static lib (arm64 only): ${SIM_UNIVERSAL_LIB}"
elif [[ -f "${SIM_X64_LIB}" ]]; then
  if [[ ! -f "${SIM_UNIVERSAL_LIB}" ]] || ! cmp -s "${SIM_X64_LIB}" "${SIM_UNIVERSAL_LIB}"; then
    cp -f "${SIM_X64_LIB}" "${SIM_UNIVERSAL_LIB}"
  fi
  echo "Simulator static lib (x86_64 only): ${SIM_UNIVERSAL_LIB}"
fi

# Optional: build an xcframework to consume from Xcode
if command -v xcodebuild >/dev/null 2>&1; then
  XC_ARGS=()
  if [[ -f "${OUT_DIR}/libdcss_core_ios_device.a" ]]; then
    XC_ARGS+=(-library "${OUT_DIR}/libdcss_core_ios_device.a" -headers "${RUST_CORE_DIR}")
  fi
  if [[ -f "${SIM_UNIVERSAL_LIB}" ]]; then
    XC_ARGS+=(-library "${SIM_UNIVERSAL_LIB}" -headers "${RUST_CORE_DIR}")
  fi

  if [[ ${#XC_ARGS[@]} -eq 0 ]]; then
    echo "warning: no architecture libs for XCFramework; skipping" >&2
    touch "${OUT_DIR}/.rust_core_built"
    echo "==> Rust core build finished."
    exit 0
  fi

  XCFRAMEWORK_PLIST="${OUT_DIR}/DCSSCore.xcframework/Info.plist"
  NEED_XCFRAMEWORK_BUILD=1
  if [[ -f "${XCFRAMEWORK_PLIST}" ]]; then
    NEED_XCFRAMEWORK_BUILD=0
    if [[ -f "${OUT_DIR}/libdcss_core_ios_device.a" && "${OUT_DIR}/libdcss_core_ios_device.a" -nt "${XCFRAMEWORK_PLIST}" ]]; then
      NEED_XCFRAMEWORK_BUILD=1
    fi
    if [[ -f "${SIM_UNIVERSAL_LIB}" && "${SIM_UNIVERSAL_LIB}" -nt "${XCFRAMEWORK_PLIST}" ]]; then
      NEED_XCFRAMEWORK_BUILD=1
    fi
  fi

  if [[ ${NEED_XCFRAMEWORK_BUILD} -eq 0 ]]; then
    echo "==> skip XCFramework rebuild (artifacts unchanged)"
  else
    echo "==> Creating DCSSCore.xcframework"
    rm -rf "${OUT_DIR}/DCSSCore.xcframework"

    set +e
    xcodebuild -create-xcframework "${XC_ARGS[@]}" -output "${OUT_DIR}/DCSSCore.xcframework"
    XC_EXIT=$?
    set -e
    if [[ ${XC_EXIT} -eq 0 ]]; then
      echo "XCFramework: ${OUT_DIR}/DCSSCore.xcframework"
    else
      echo "warning: failed to create XCFramework; static .a is still available" >&2
    fi
  fi
fi

touch "${OUT_DIR}/.rust_core_built"
echo "==> Rust core build finished."

