#!/bin/bash
set -e

# ============================================================
# ECH Proxy - HarmonyOS (OHOS) 交叉编译脚本
#
# 用法:
#   ./build-ohos.sh            # 编译 OpenSSL + Rust 库并复制进 HAP 工程
#   ./build-ohos.sh --setup    # 仅准备 Rust 目标与工具链包装器
#
# 产物:
#   android/rust/target/aarch64-unknown-linux-ohos/release/libechproxy.so
#   → ohos/entry/libs/arm64-v8a/libechproxy.so（hvigor 构建 HAP 时打包）
#
# 环境要求:
#   - Rust stable + rustup（脚本会补装 aarch64-unknown-linux-ohos 目标）
#   - DevEco Studio（默认自动探测；可用 OHOS_NDK_HOME 指向 native 目录）
#   - Windows 用 Git for Windows 的 Git-Bash 运行，且需 GNU make / perl
#
# 为什么 Windows 上要生成 .exe 包装器:
#   OHOS SDK 自带的 aarch64-unknown-linux-ohos-clang 是 shell 脚本，且
#   `$SOURCE` 未加引号，路径含空格（默认 DevEco 安装目录就有空格）时直接失效。
#   Rust 的 cc crate 用 CreateProcess 启动 CC，无法执行 shell 脚本（os error
#   193），因此 Windows 宿主上用 rustc 生成三个原生 .exe 包装器；Unix 宿主
#   用等价的 shell 包装器即可。
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OHOS_LIBS_DIR="$PROJECT_ROOT/ohos/entry/libs/arm64-v8a"
RUST_TARGET="aarch64-unknown-linux-ohos"
OPENSSL_VERSION="4.0.1"
OPENSSL_BUILD="$SCRIPT_DIR/openssl/build-ohos-arm64"
OPENSSL_SRC="$OPENSSL_BUILD/openssl-$OPENSSL_VERSION"
OPENSSL_INSTALL="$OPENSSL_BUILD/install"
TOOL_DIR="$SCRIPT_DIR/.build/ohos-toolchain"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[build]${NC} $1"; }
warn() { echo -e "${YELLOW}[warn]${NC} $1"; }
err() { echo -e "${RED}[error]${NC} $1"; exit 1; }

is_windows_host() {
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
        *) return 1 ;;
    esac
}

to_posix_path() {
    local P="$1"
    if command -v cygpath &>/dev/null; then
        cygpath -u "$P" 2>/dev/null || printf '%s' "$P"
    else
        printf '%s' "$P"
    fi
}

to_windows_path() {
    local P="$1"
    if command -v cygpath &>/dev/null; then
        cygpath -w "$P" 2>/dev/null || printf '%s' "$P"
    else
        printf '%s' "$P"
    fi
}

cpu_count() {
    if command -v nproc &>/dev/null; then
        nproc
    elif command -v sysctl &>/dev/null; then
        sysctl -n hw.ncpu 2>/dev/null || echo 4
    else
        echo 4
    fi
}

# ============================================================
# 1. 定位 OHOS NDK
# ============================================================
find_ndk() {
    if [ -n "${OHOS_NDK_HOME:-}" ]; then
        NDK_DIR="$(to_posix_path "$OHOS_NDK_HOME")"
    else
        local CANDIDATES=(
            "$HOME/DevEco-Studio/sdk/default/openharmony/native"
            "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native"
            "/opt/deveco-studio/sdk/default/openharmony/native"
            "D:/DevEco Studio/sdk/default/openharmony/native"
            "C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native"
        )
        local C
        for C in "${CANDIDATES[@]}"; do
            if [ -x "$C/llvm/bin/clang.exe" ] || [ -x "$C/llvm/bin/clang" ]; then
                NDK_DIR="$C"
                break
            fi
        done
    fi

    [ -n "${NDK_DIR:-}" ] && [ -d "$NDK_DIR" ] \
        || err "未找到 OHOS NDK，请设置 OHOS_NDK_HOME 指向 DevEco Studio 的 .../openharmony/native 目录"
    [ -d "$NDK_DIR/sysroot" ] \
        || err "NDK 缺少 sysroot: $NDK_DIR/sysroot"

    log "OHOS NDK: $NDK_DIR"
}

llvm_tool() {
    local NAME="$1"
    if [ -x "$NDK_DIR/llvm/bin/$NAME.exe" ]; then
        printf '%s' "$NDK_DIR/llvm/bin/$NAME.exe"
    elif [ -x "$NDK_DIR/llvm/bin/$NAME" ]; then
        printf '%s' "$NDK_DIR/llvm/bin/$NAME"
    else
        return 1
    fi
}

# ============================================================
# 2. Rust 目标
# ============================================================
setup_rust() {
    command -v rustc &>/dev/null || err "未找到 rustc，请先安装 Rust stable"
    command -v rustup &>/dev/null || err "未找到 rustup，无法安装 $RUST_TARGET 目标"

    if ! rustup target list --installed | grep -q "^$RUST_TARGET$"; then
        log "安装 Rust 目标 $RUST_TARGET..."
        rustup target add "$RUST_TARGET"
    fi
    log "Rust: $(rustc --version)"
}

# ============================================================
# 3. 生成工具链包装器
#
# 注入与 SDK 自带 clang 包装器一致的参数（-target / --sysroot / -D__MUSL__），
# 额外补 -fuse-ld=lld。所有包装器都只做参数转发，不解析编译输出。
# ============================================================
write_windows_tools() {
    local NDK_WIN
    NDK_WIN="$(to_windows_path "$NDK_DIR")"
    mkdir -p "$TOOL_DIR"

    local CC_RS="$TOOL_DIR/ohos-cc.rs"
    cat > "$CC_RS" <<EOF
use std::env;
use std::process::{exit, Command};

fn main() {
    let ndk = r"$NDK_WIN";
    let clang = format!(r"{}\llvm\bin\clang.exe", ndk);
    let sysroot = format!(r"{}\sysroot", ndk);
    let mut cmd = Command::new(&clang);
    cmd.arg("-target").arg("aarch64-linux-ohos");
    cmd.arg(format!("--sysroot={}", sysroot));
    cmd.arg("-D__MUSL__");
    cmd.arg("-fuse-ld=lld");
    for a in env::args().skip(1) {
        cmd.arg(a);
    }
    match cmd.status() {
        Ok(s) => exit(s.code().unwrap_or(1)),
        Err(e) => {
            eprintln!("ohos-cc: failed to run {}: {}", clang, e);
            exit(1);
        }
    }
}
EOF

    local AR_RS="$TOOL_DIR/ohos-ar.rs"
    cat > "$AR_RS" <<EOF
use std::env;
use std::process::{exit, Command};

fn main() {
    let ndk = r"$NDK_WIN";
    let ar = format!(r"{}\llvm\bin\llvm-ar.exe", ndk);
    let mut cmd = Command::new(&ar);
    for a in env::args().skip(1) {
        cmd.arg(a);
    }
    match cmd.status() {
        Ok(s) => exit(s.code().unwrap_or(1)),
        Err(e) => {
            eprintln!("ohos-ar: failed to run {}: {}", ar, e);
            exit(1);
        }
    }
}
EOF

    local RANLIB_RS="$TOOL_DIR/ohos-ranlib.rs"
    cat > "$RANLIB_RS" <<EOF
use std::env;
use std::process::{exit, Command};

fn main() {
    let ndk = r"$NDK_WIN";
    let ranlib = format!(r"{}\llvm\bin\llvm-ranlib.exe", ndk);
    let mut cmd = Command::new(&ranlib);
    for a in env::args().skip(1) {
        cmd.arg(a);
    }
    match cmd.status() {
        Ok(s) => exit(s.code().unwrap_or(1)),
        Err(e) => {
            eprintln!("ohos-ranlib: failed to run {}: {}", ranlib, e);
            exit(1);
        }
    }
}
EOF

    rustc -O "$CC_RS" -o "$TOOL_DIR/ohos-cc.exe"
    rustc -O "$AR_RS" -o "$TOOL_DIR/ohos-ar.exe"
    rustc -O "$RANLIB_RS" -o "$TOOL_DIR/ohos-ranlib.exe"

    # Configure/Makefile 只能用 POSIX 路径：反斜杠会被 Perl 生成的 Makefile 吞掉；
    # 而环境变量喂给原生 cargo/cc 前必须转成 Windows 风格（MSYS 不转换环境变量）。
    HOST_CC="$TOOL_DIR/ohos-cc.exe"
    HOST_CXX="$HOST_CC"
    HOST_AR="$TOOL_DIR/ohos-ar.exe"
    HOST_RANLIB="$TOOL_DIR/ohos-ranlib.exe"
    HOST_CC_WIN="$(to_windows_path "$HOST_CC")"
    HOST_CXX_WIN="$HOST_CC_WIN"
    HOST_AR_WIN="$(to_windows_path "$HOST_AR")"
    HOST_RANLIB_WIN="$(to_windows_path "$HOST_RANLIB")"
}

write_unix_tools() {
    mkdir -p "$TOOL_DIR"
    local SYSROOT="$NDK_DIR/sysroot"
    local CLANG="$NDK_DIR/llvm/bin/clang"

    cat > "$TOOL_DIR/ohos-cc" <<EOF
#!/bin/sh
exec "$CLANG" -target aarch64-linux-ohos --sysroot="$SYSROOT" -D__MUSL__ -fuse-ld=lld "\$@"
EOF
    cat > "$TOOL_DIR/ohos-ar" <<EOF
#!/bin/sh
exec "$NDK_DIR/llvm/bin/llvm-ar" "\$@"
EOF
    cat > "$TOOL_DIR/ohos-ranlib" <<EOF
#!/bin/sh
exec "$NDK_DIR/llvm/bin/llvm-ranlib" "\$@"
EOF
    chmod +x "$TOOL_DIR/ohos-cc" "$TOOL_DIR/ohos-ar" "$TOOL_DIR/ohos-ranlib"

    HOST_CC="$TOOL_DIR/ohos-cc"
    HOST_CXX="$TOOL_DIR/ohos-cc"
    HOST_AR="$TOOL_DIR/ohos-ar"
    HOST_RANLIB="$TOOL_DIR/ohos-ranlib"
    HOST_CC_WIN="$HOST_CC"
    HOST_CXX_WIN="$HOST_CXX"
    HOST_AR_WIN="$HOST_AR"
    HOST_RANLIB_WIN="$HOST_RANLIB"
}

setup_toolchain() {
    if is_windows_host; then
        write_windows_tools
    else
        write_unix_tools
    fi
    log "工具链包装器: $TOOL_DIR"
}

# ============================================================
# 4. 补齐 Git-Bash perl 的 OpenSSL Configure 依赖模块
#
# Git for Windows 的 perl 是裁剪版，缺 Pod::* / ExtUtils::MakeMaker /
# CPAN::Meta / Locale::Maketext::Simple，缺任一模块 Configure 都会退出码 2。
# 逻辑与 build-android.sh 相同：把对应 perl 版本核心源码的 lib/ 补进 site_perl。
# ============================================================
setup_perl_modules() {
    local PERL_BIN
    PERL_BIN="$(command -v perl 2>/dev/null || true)"
    [ -n "$PERL_BIN" ] || err "未找到 perl，OpenSSL Configure 依赖 perl"

    if "$PERL_BIN" -MPod::Usage -MExtUtils::MakeMaker -MExtUtils::Manifest \
        -MCPAN::Meta -MLocale::Maketext::Simple -e1 2>/dev/null; then
        return 0
    fi

    local PERL_VERSION SITE_LIB
    PERL_VERSION="$("$PERL_BIN" -e 'printf "%vd", $^V')"
    SITE_LIB="$("$PERL_BIN" -MConfig -e 'print $Config::Config{sitelib}')"
    SITE_LIB="$(to_posix_path "$SITE_LIB")"
    [ -n "$PERL_VERSION" ] && [ -n "$SITE_LIB" ] \
        || err "无法探测 perl 版本或 site_perl 目录"

    log "补齐 perl 模块 ($PERL_VERSION)..."
    local WORK="$SCRIPT_DIR/.build/perl-core-$PERL_VERSION"
    local TARBALL="$WORK/perl-$PERL_VERSION.tar.gz"
    local SRCDIR="$WORK/perl-$PERL_VERSION"
    mkdir -p "$WORK"

    if [ ! -d "$SRCDIR" ]; then
        local URL OK=0
        for URL in \
            "https://mirrors.tuna.tsinghua.edu.cn/CPAN/src/5.0/perl-$PERL_VERSION.tar.gz" \
            "https://mirrors.ustc.edu.cn/CPAN/src/5.0/perl-$PERL_VERSION.tar.gz" \
            "https://www.cpan.org/src/5.0/perl-$PERL_VERSION.tar.gz"
        do
            log "  下载 perl 核心源码: $URL"
            if curl -fsSL --retry 3 --retry-delay 3 --max-time 900 -o "$TARBALL" "$URL"; then
                OK=1
                break
            fi
            rm -f "$TARBALL"
        done
        [ "$OK" -eq 1 ] || err "perl 源码下载失败"
        tar tzf "$TARBALL" >/dev/null 2>&1 || err "perl 源码压缩包损坏"
        tar xzf "$TARBALL" -C "$WORK"
        rm -f "$TARBALL"
    fi

    local STAGE="$WORK/stage" D
    rm -rf "$STAGE"
    mkdir -p "$STAGE/lib"
    for D in "$SRCDIR/lib" "$SRCDIR"/cpan/*/lib "$SRCDIR"/dist/*/lib "$SRCDIR"/ext/*/lib; do
        [ -d "$D" ] || continue
        cp -R "$D"/. "$STAGE/lib"/
    done
    mkdir -p "$SITE_LIB"
    cp -Rn "$STAGE"/lib/. "$SITE_LIB"/

    "$PERL_BIN" -MPod::Usage -MExtUtils::MakeMaker -e1 2>/dev/null \
        || err "perl 模块补齐失败，请检查 $SITE_LIB"
    log "perl 模块补齐完成"
}

# ============================================================
# 5. 交叉编译 OpenSSL（带 ECH 支持）
#
# 目标 linux-aarch64；OHOS 的 libc 是 musl，clang 包装器补 -D__MUSL__。
# 必须 no-shared（静态链接进 libechproxy.so）+ 默认启用 threads：
# OpenSSL 4.0 的 -static 会隐式 no-threads，多线程代理会随机崩溃，故不传 -static。
# ============================================================
patch_ar_response_file() {
    # Windows 命令行上限 32K：libcrypto.a 的归档命令含数千个目标文件，必须在
    # make 内部用 $(file ...) 写响应文件，再让 llvm-ar 用 @file 读取。
    local MAKE_FILE="$OPENSSL_SRC/Makefile"
    [ -f "$MAKE_FILE" ] || return 0
    if grep -q 'nexhub-ar.rsp' "$MAKE_FILE"; then
        return 0
    fi

    log "为 Makefile 应用 ar 响应文件补丁 (Windows 命令行长度限制)..."
    # 每个分片必须用独立响应文件：make 可能在执行前一次性展开整段 recipe，
    # 复用同名文件会让所有 $(AR) 都只读到最后一个分片（只归档到 26 个对象）。
    perl -i -pe '
        BEGIN { $n = 0 }
        if (/^\t\$\(AR\) \$\(ARFLAGS\) (\S+) (.+)$/ && length($_) > 1000) {
            my ($ar, $objs) = ($1, $2);
            chomp $objs;
            $n++;
            my $rsp = "$ar.nexhub-ar-$n.rsp";
            $_ = "\t\$(file >$rsp,$objs)\n\t\$(AR) \$(ARFLAGS) $ar \@$rsp\n";
        }
    ' "$MAKE_FILE"
    grep -q 'nexhub-ar-1.rsp' "$MAKE_FILE" \
        || err "ar 响应文件补丁未生效（Makefile 结构可能随 OpenSSL 版本变化）"

    # 上一次失败可能留下残缺归档；不删的话 make 认为目标已是最新，不会重新归档。
    rm -f "$OPENSSL_SRC/libcrypto.a" "$OPENSSL_SRC/libssl.a" \
        "$OPENSSL_SRC"/*.nexhub-ar*.rsp
}

download_openssl() {
    [ -d "$OPENSSL_SRC" ] && return 0

    log "下载 OpenSSL $OPENSSL_VERSION 源码..."
    mkdir -p "$OPENSSL_BUILD"
    local REL="openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
    local TARBALL="$OPENSSL_BUILD/openssl-$OPENSSL_VERSION.tar.gz"
    local URL OK=0
    for URL in \
        "https://gh-proxy.com/https://github.com/openssl/openssl/releases/download/$REL" \
        "https://ghfast.top/https://github.com/openssl/openssl/releases/download/$REL" \
        "https://github.com/openssl/openssl/releases/download/$REL"
    do
        log "  $URL"
        if curl -fL --retry 3 --retry-delay 3 --max-time 1800 -o "$TARBALL" "$URL"; then
            OK=1
            break
        fi
        rm -f "$TARBALL"
    done
    [ "$OK" -eq 1 ] || err "OpenSSL 源码下载失败，请手动解压到: $OPENSSL_SRC"
    tar tzf "$TARBALL" >/dev/null 2>&1 || err "OpenSSL 压缩包损坏"
    tar xzf "$TARBALL" -C "$OPENSSL_BUILD"
    rm -f "$TARBALL"
    [ -f "$OPENSSL_SRC/include/openssl/ech.h" ] \
        || err "OpenSSL 源码缺少 ech.h，无法编译 ECH 支持"
}

verify_openssl_threads() {
    local AR_BIN NM_BIN TMP_DIR OBJ="libcrypto-lib-threads_pthread.o"
    AR_BIN="$(llvm_tool llvm-ar)" || return 2
    NM_BIN="$(llvm_tool llvm-nm)" || return 2
    TMP_DIR="$(mktemp -d)"

    if ! (cd "$TMP_DIR" && "$AR_BIN" x "$OPENSSL_INSTALL/lib/libcrypto.a" "$OBJ" 2>/dev/null) \
        || ! "$NM_BIN" --defined-only "$TMP_DIR/$OBJ" 2>/dev/null | grep -q "CRYPTO_THREAD_write_lock"; then
        rm -rf "$TMP_DIR"
        return 1
    fi
    rm -rf "$TMP_DIR"
    return 0
}

build_openssl() {
    if [ -f "$OPENSSL_INSTALL/lib/libssl.a" ] && [ -f "$OPENSSL_INSTALL/.threads-ok" ]; then
        log "OpenSSL 已编译 (threads 已启用)，跳过"
        return 0
    fi

    download_openssl
    setup_perl_modules

    # 同一源码目录只允许一种目标配置；检测到旧配置直接失败，避免复用错误架构的
    # 目标文件（历史上曾因 armv7 产物残留把 aarch64 构建编成 32 位汇编）。
    if [ -f "$OPENSSL_SRC/configdata.pm" ]; then
        if ! grep -q '"linux-aarch64"' "$OPENSSL_SRC/configdata.pm"; then
            err "OpenSSL 源码目录已被其它 Configure 目标污染: $OPENSSL_SRC
  请删除该目录后重跑（rm -rf \"$OPENSSL_SRC\"）"
        fi
    fi

    log "编译 OpenSSL $OPENSSL_VERSION (linux-aarch64, 带 ECH)..."
    cd "$OPENSSL_SRC"
    rm -f Makefile configdata.pm

    CC="$HOST_CC" CXX="$HOST_CXX" AR="$HOST_AR" RANLIB="$HOST_RANLIB" \
    ./Configure linux-aarch64 \
        --prefix="$OPENSSL_INSTALL" \
        --openssldir="$OPENSSL_INSTALL" \
        no-shared \
        no-module \
        no-tests \
        no-apps \
        no-docs

    if is_windows_host; then
        patch_ar_response_file
    fi

    make -j"$(cpu_count)"
    make install_sw

    local RC=0
    verify_openssl_threads || RC=$?
    if [ "$RC" -eq 2 ]; then
        err "NDK 缺少 llvm-ar/llvm-nm，无法校验 OpenSSL 产物"
    elif [ "$RC" -ne 0 ]; then
        err "OpenSSL 缺少多线程支持 (no-threads)，代理并发会崩溃；请检查 Configure 参数"
    fi

    touch "$OPENSSL_INSTALL/.threads-ok"
    log "OpenSSL 多线程校验通过"
}

# ============================================================
# 6. 交叉编译 Rust 库并放入 HAP 工程
# ============================================================
build_rust_lib() {
    cd "$SCRIPT_DIR"
    log "编译 ech-proxy ($RUST_TARGET)..."

    local OPENSSL_DIR_FOR_CARGO="$OPENSSL_INSTALL"
    if is_windows_host; then
        OPENSSL_DIR_FOR_CARGO="$(to_windows_path "$OPENSSL_INSTALL")"
    fi

    # build.rs 以 OPENSSL_INCLUDE_DIR/openssl/ech.h 是否存在决定 has_ech，
    # openssl-sys 用 OPENSSL_LIB_DIR 定位静态库；缺任一变量都会静默失去 ECH。
    OPENSSL_DIR="$OPENSSL_DIR_FOR_CARGO" \
    OPENSSL_INCLUDE_DIR="$OPENSSL_DIR_FOR_CARGO/include" \
    OPENSSL_LIB_DIR="$OPENSSL_DIR_FOR_CARGO/lib" \
    OPENSSL_STATIC=1 \
    CC_aarch64_unknown_linux_ohos="$HOST_CC_WIN" \
    CXX_aarch64_unknown_linux_ohos="$HOST_CXX_WIN" \
    AR_aarch64_unknown_linux_ohos="$HOST_AR_WIN" \
    RANLIB_aarch64_unknown_linux_ohos="$HOST_RANLIB_WIN" \
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER="$HOST_CC_WIN" \
    cargo build --release --target "$RUST_TARGET"

    local SO_FILE="$SCRIPT_DIR/target/$RUST_TARGET/release/libechproxy.so"
    [ -f "$SO_FILE" ] || err "编译产物未找到: $SO_FILE"

    local NM_BIN READELF_BIN
    NM_BIN="$(llvm_tool llvm-nm)" || err "NDK 缺少 llvm-nm"
    READELF_BIN="$(llvm_tool llvm-readelf)" || err "NDK 缺少 llvm-readelf"

    "$READELF_BIN" -h "$SO_FILE" | grep -q "AArch64" \
        || err "产物架构不是 AArch64: $SO_FILE"

    local SYM
    local SYM_DUMP
    SYM_DUMP="$(mktemp)"
    # 一次性导出符号表：llvm-nm 在 Windows 上被 grep -q 提前关闭管道会报
    # "LLVM ERROR: IO failure on output stream"，写文件可避免该噪声。
    "$NM_BIN" -D --defined-only "$SO_FILE" > "$SYM_DUMP"
    for SYM in ech_start_proxy ech_stop_proxy ech_is_alive ech_set_scope; do
        grep -q " T $SYM\$" "$SYM_DUMP" || err "产物缺少导出符号: $SYM"
    done

    # ech_helper.c 仅在 build.rs 检测到 openssl/ech.h 时编译；该符号通常是
    # local（cdylib 版本脚本不导出 C 辅助函数），故不能用 -D 查询。
    "$NM_BIN" "$SO_FILE" > "$SYM_DUMP"
    grep -qE "[[:space:]]ech_get_retry_config\$" "$SYM_DUMP" \
        || err "产物未包含 ECH helper（静默退化成了 no_ech）；请确认 OPENSSL_INCLUDE_DIR 指向带 ech.h 的 OpenSSL"
    rm -f "$SYM_DUMP"

    mkdir -p "$OHOS_LIBS_DIR"
    cp "$SO_FILE" "$OHOS_LIBS_DIR/libechproxy.so"
    log "已复制到 $OHOS_LIBS_DIR/libechproxy.so ($(du -h "$OHOS_LIBS_DIR/libechproxy.so" | cut -f1))"
}

main() {
    log "=== ECH Proxy 编译 (HarmonyOS arm64) ==="
    find_ndk
    setup_rust
    setup_toolchain

    if [ "${1:-}" = "--setup" ]; then
        log "工具链准备完成"
        exit 0
    fi

    command -v make &>/dev/null || err "未找到 make（Windows 请用 Git-Bash 运行）"
    build_openssl
    build_rust_lib
    log "=== 编译完成 ==="
}

main "$@"
