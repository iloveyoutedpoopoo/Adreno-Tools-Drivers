#!/bin/bash -e
set -o pipefail

# 將 Android NDK 依賴改為標準 aarch64-linux-gnu-gcc 工具
deps="git meson ninja patchelf unzip curl pip flex bison zip glslangValidator python3 aarch64-linux-gnu-gcc"
workdir="$(pwd)/turnip_workdir"
mesasrc="https://github.com/whitebelyash/mesa-tu8.git"
srcfolder="mesa"
BUILD_VERSION="${BUILD_VERSION:-1.0}"

run_all(){
    check_deps
    prepare_workdir
    build_lib_for_linux gen8
}

check_deps(){
    for deps_chk in $deps; do
        if ! command -v "$deps_chk" >/dev/null 2>&1 ; then
            echo "Missing dependency: $deps_chk"
            exit 1
        fi
    done
    pip install mako --break-system-packages &> /dev/null || true
}

prepare_workdir(){
    mkdir -p "$workdir" && cd "$workdir"
    rm -rf "$srcfolder"
    git clone "$mesasrc" --depth=1 --no-single-branch "$srcfolder"
    cd "$srcfolder"
    
    echo "#define TUGEN8_DRV_VERSION \"\"" > ./src/freedreno/vulkan/tu_version.h
}

build_lib_for_linux(){
    cd "$workdir/$srcfolder"
    git checkout "origin/$1"

    # 保留可能需要的硬體修正 (移除了 Android stub 的 sed 替換)
    sed -i '/a7xx_gen1 = GPUProps(/a \        has_early_preamble = False,' src/freedreno/common/freedreno_devices.py || true

    # 建立標準 Linux ARM64 交叉編譯設定檔
    cat <<EOF >"linux-aarch64.txt"
[binaries]
c = 'aarch64-linux-gnu-gcc'
cpp = 'aarch64-linux-gnu-g++'
ar = 'aarch64-linux-gnu-ar'
strip = 'aarch64-linux-gnu-strip'
pkg-config = 'aarch64-linux-gnu-pkg-config'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

    # 針對 Linux 平台進行編譯 (開啟 X11, Wayland 支援，保留 KGSL 後台)
    meson setup build-linux-aarch64 \
        --cross-file "linux-aarch64.txt" \
        --prefix "/tmp/turnip-$1" \
        -Dbuildtype=release \
        -Dstrip=true \
        -Dplatforms=x11,wayland \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dvulkan-beta=true \
        -Dfreedreno-kmds=kgsl \
        -Degl=disabled \
        -Dglx=disabled \
        -Dopengl=false \
        -Dshared-glapi=false

    ninja -C build-linux-aarch64 install

    # 確保編譯成功 (Linux multiarch 可能會安裝在 lib/aarch64-linux-gnu 或是 lib/)
    LIB_PATH=$(find "/tmp/turnip-$1/lib" -name "libvulkan_freedreno.so" | head -n 1)
    if [ -z "$LIB_PATH" ]; then
        echo "Build failed: libvulkan_freedreno.so not found!"
        exit 1
    fi

    # 找出系統生成的標準 Vulkan ICD 檔案
    ICD_PATH=$(find "/tmp/turnip-$1/share/vulkan/icd.d" -name "freedreno_icd.*.json" | head -n 1)

    mkdir -p "/tmp/pkg-$1"
    cp "$LIB_PATH" "/tmp/pkg-$1/"
    if [ -n "$ICD_PATH" ]; then
        cp "$ICD_PATH" "/tmp/pkg-$1/"
    fi

    cd "/tmp/pkg-$1"
    
    # 為了相容 Winlator UI 直接匯入的習慣，保留 meta.json
    cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "Turnip Gen8 (glibc/Ubuntu)",
  "description": "A8xx support for Linux chroot",
  "author": "stevenmx",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan 1.4.348",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF

    # 將生成的驅動與 ICD 打包
    zip -9 "/tmp/a8xx-$1-V${BUILD_VERSION}-glibc.zip" libvulkan_freedreno.so meta.json *.json
    cp "/tmp/a8xx-$1-V${BUILD_VERSION}-glibc.zip" "$workdir/"
}

run_all    export STRIP=llvm-strip
    export OBJDUMP=llvm-objdump
    export OBJCOPY=llvm-objcopy
    export LDFLAGS="-fuse-ld=lld"

    GITHASH=$(git rev-parse --short HEAD)

    local cver="36"
    [ ! -f "$ndk/aarch64-linux-android${cver}-clang" ] && cver="35"
    [ ! -f "$ndk/aarch64-linux-android${cver}-clang" ] && cver="34"

    cat <<EOF >"android-aarch64.txt"
[binaries]
ar = '$ndk/llvm-ar'
c = ['ccache', '$ndk/aarch64-linux-android${cver}-clang']
cpp = ['ccache', '$ndk/aarch64-linux-android${cver}-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = '$ndk/ld.lld'
cpp_ld = '$ndk/ld.lld'
strip = '$ndk/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$ndk/pkg-config', '/usr/bin/pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

    cat <<EOF >"native.txt"
[build_machine]
c = ['ccache', 'clang']
cpp = ['ccache', 'clang++']
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'ld.lld'
cpp_ld = 'ld.lld'
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

    meson setup build-android-aarch64 \
        --cross-file "android-aarch64.txt" \
        --native-file "native.txt" \
        --prefix "/tmp/turnip-$1" \
        -Dbuildtype=release \
        -Dstrip=true \
        -Dplatforms=android \
        -Dvideo-codecs= \
        -Dplatform-sdk-version=36 \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dvulkan-beta=true \
        -Dfreedreno-kmds=kgsl \
        -Degl=disabled \
        -Dandroid-libbacktrace=disabled

    ninja -C build-android-aarch64 install

    if [ ! -f "/tmp/turnip-$1/lib/libvulkan_freedreno.so" ]; then
        exit 1
    fi

    cd "/tmp/turnip-$1/lib"
    
    cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "Turnip Gen8 V29",
  "description": "A8xx support",
  "author": "stevenmx",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan 1.4.348",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF

    zip -9 "/tmp/a8xx-$1-V${BUILD_VERSION}.zip" libvulkan_freedreno.so meta.json
    cp "/tmp/a8xx-$1-V${BUILD_VERSION}.zip" "$workdir/"
}

run_all
