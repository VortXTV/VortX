# Source this helper; the returned lookup applies only to the native Cargo command.
# Never repair a toolchain by modifying its binaries, RPATHs or global loader settings.
native_rust_llvm_library_path() {
    local toolchain="${1:?pinned Rust toolchain required}"
    local sysroot host lookup objcopy
    sysroot="$(rustup run "$toolchain" rustc --print sysroot)" || return 1
    [[ "$sysroot" == /* && -d "$sysroot/lib" ]] || {
        echo "Missing native Rust toolchain library directory" >&2; return 1;
    }
    host="$(rustup run "$toolchain" rustc -vV | sed -n 's/^host: //p')" || return 1
    case "$host" in
        aarch64-apple-darwin|x86_64-apple-darwin) ;;
        *) echo "Unsupported native Rust toolchain host" >&2; return 1 ;;
    esac
    lookup="$sysroot/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
    objcopy="$sysroot/lib/rustlib/$host/bin/rust-objcopy"
    [[ -x "$objcopy" ]] || { echo "Missing native Rust stripping tool" >&2; return 1; }
    DYLD_LIBRARY_PATH="$lookup" "$objcopy" --version >/dev/null || {
        echo "Native Rust stripping tool cannot load its pinned LLVM library" >&2; return 1;
    }
    printf '%s\n' "$lookup"
}
