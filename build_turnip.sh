#!/bin/bash -e
set -o pipefail

# 修改相依性檢查列表，加入標準交叉編譯工具
deps="git meson ninja patchelf unzip curl flex bison zip python3 aarch64-linux-gnu-gcc"
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
}

prepare_workdir(){
    mkdir -p "$workdir" && cd "$workdir"
    rm -rf "$srcfolder"
    # 下載 8 Elite 專用源碼
    git clone "$mesasrc" --depth=1 -b gen8 "$srcfolder"
    cd "$srcfolder"
    
    echo "#define TUGEN8_DRV_VERSION \"Chroot-Gen8-V${BUILD_VERSION}\"" > ./src/freedreno/vulkan/tu_version.h
}

build_lib_for_linux(){
    cd "$workdir/$srcfolder"

    # 針對 Adreno 8xx 的硬體修正
    sed -i '/a7xx_gen1 = GPUProps(/a \        has_early_preamble = False,' src/freedreno/common/freedreno_devices.py || true

    # 建立交叉編譯設定 (這是讓 Glibc 運行的關鍵)
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

    # 配置 Mesa：開啟 X11/Wayland 支援，關閉不必要的 OpenGL 以加快速度
    meson setup build-linux-aarch64 \
        --cross-file "linux-aarch64.txt" \
        --prefix "/tmp/turnip-pkg" \
        -Dbuildtype=release \
        -Dstrip=true \
        -Dplatforms=x11,wayland \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dvulkan-beta=true \
        -Dfreedreno-kmds=kgsl \
        -Degl=disabled \
        -Dglx=disabled \
        -Dopengl=false

    ninja -C build-linux-aarch64 install

    # 整理產物
    LIB_PATH=$(find "/tmp/turnip-pkg/lib" -name "libvulkan_freedreno.so" | head -n 1)
    ICD_PATH=$(find "/tmp/turnip-pkg/share/vulkan/icd.d" -name "freedreno_icd.*.json" | head -n 1)

    if [ -z "$LIB_PATH" ]; then
        echo "Build failed: libvulkan_freedreno.so not found!"
        exit 1
    fi

    mkdir -p "/tmp/final-zip"
    cp "$LIB_PATH" "/tmp/final-zip/"
    [ -n "$ICD_PATH" ] && cp "$ICD_PATH" "/tmp/final-zip/"

    cd "/tmp/final-zip"
    
    # 建立 meta.json
    cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "Turnip Gen8 (glibc)",
  "description": "Snapdragon 8 Elite Adreno 830 Support",
  "author": "stevenmx",
  "packageVersion": "${BUILD_VERSION}",
  "vendor": "Mesa-Whitebelyash",
  "driverVersion": "Vulkan 1.4",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF

    # 打包成 ZIP
    zip -9 "/tmp/a8xx-gen8-V${BUILD_VERSION}-glibc.zip" *
    cp "/tmp/a8xx-gen8-V${BUILD_VERSION}-glibc.zip" "$workdir/"
    echo "Done: a8xx-gen8-V${BUILD_VERSION}-glibc.zip"
}

run_all
