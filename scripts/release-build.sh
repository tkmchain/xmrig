#!/usr/bin/env bash
# Cross-build a CPU miner and its static TLS/libuv dependencies.
set -euo pipefail
platform=${1:?linux, windows, macos or android}
arch=${2:?target architecture}
root=$(cd "$(dirname "$0")/.." && pwd)
work=${RELEASE_BUILD_ROOT:-$root/build-release}/$platform-$arch
prefix=$work/deps
mkdir -p "$work" "$prefix" "$root/dist"
jobs=${BUILD_JOBS:-2}
cmake_args=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix")
ssl_flags=(no-shared no-tests no-module --prefix="$prefix" --libdir=lib)
case "$platform/$arch" in
 linux/x86) triple=i686-linux-gnu; processor=i686; ssl_target=linux-x86 ;;
 linux/x64) triple=x86_64-linux-gnu; processor=x86_64; ssl_target=linux-x86_64 ;;
 linux/armv7) triple=arm-linux-gnueabihf; processor=armv7; ssl_target=linux-armv4 ;;
 linux/armv8) triple=aarch64-linux-gnu; processor=aarch64; ssl_target=linux-aarch64 ;;
 linux/riscv64) triple=riscv64-linux-gnu; processor=riscv64; ssl_target=linux64-riscv64 ;;
 windows/x86) triple=i686-w64-mingw32; processor=i686; ssl_target=mingw ;;
 windows/x64) triple=x86_64-w64-mingw32; processor=x86_64; ssl_target=mingw64 ;;
 macos/x64) processor=x86_64; ssl_target=darwin64-x86_64-cc ;;
 macos/armv8) processor=arm64; ssl_target=darwin64-arm64-cc ;;
 android/x86) abi=x86; ssl_target=android-x86 ;;
 android/x64) abi=x86_64; ssl_target=android-x86_64 ;;
 android/armv7) abi=armeabi-v7a; ssl_target=android-arm ;;
 android/armv8) abi=arm64-v8a; ssl_target=android-arm64 ;;
 *) echo "Unsupported target: $platform/$arch" >&2; exit 2 ;;
esac
if [[ $platform == linux || $platform == windows ]]; then
 system=Linux
 [[ $platform != windows ]] || system=Windows
 export CC=$triple-gcc CXX=$triple-g++ AR=$triple-ar RANLIB=$triple-ranlib
 cmake_args+=(-DCMAKE_SYSTEM_NAME="$system" -DCMAKE_SYSTEM_PROCESSOR="$processor" -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX")
 # Feature detection cannot execute target code on the build host.
 for feature in VECTOR ZICBOP ZBA ZBB ZVKB ZVKNED; do
  cmake_args+=("-DRANDOMX_${feature}_RUN_FAIL=1" "-DRANDOMX_${feature}_RUN_FAIL__TRYRUN_OUTPUT=")
 done
elif [[ $platform == android ]]; then
 export ANDROID_NDK_ROOT=${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to NDK r27c}
 export PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH"
 cmake_args+=(-DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_ROOT/build/cmake/android.toolchain.cmake" -DANDROID_ABI="$abi" -DANDROID_PLATFORM=android-24 -DANDROID_STL=c++_static)
 ssl_flags+=(-D__ANDROID_API__=24)
else
 export CC=clang CXX=clang++ MACOSX_DEPLOYMENT_TARGET=11.0
 cmake_args+=(-DCMAKE_OSX_ARCHITECTURES="$processor" -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 -DCMAKE_SYSTEM_PROCESSOR="$processor")
 ssl_flags+=(-mmacosx-version-min=11.0)
fi
# Match the versions pinned in this repository's existing dependency scripts.
uv=1.51.0
openssl=3.0.16
fetch() {
 curl --fail --location --retry 3 "$1" -o "$2"
 actual=$(shasum -a 256 "$2" | cut -d ' ' -f 1)
 [[ $actual == "$3" ]] || { echo "Dependency checksum mismatch: $2" >&2; exit 1; }
}
if [[ ! -d $work/libuv-v$uv ]]; then
 fetch "https://dist.libuv.org/dist/v$uv/libuv-v$uv.tar.gz" "$work/uv.tar.gz" 5f0557b90b1106de71951a3c3931de5e0430d78da1d9a10287ebc7a3f78ef8eb
 tar -xzf "$work/uv.tar.gz" -C "$work"
fi
if [[ ! -d $work/openssl-$openssl ]]; then
 fetch "https://github.com/openssl/openssl/releases/download/openssl-$openssl/openssl-$openssl.tar.gz" "$work/openssl.tar.gz" 57e03c50feab5d31b152af2b764f10379aecd8ee92f16c985983ce4a99f7ef86
 tar -xzf "$work/openssl.tar.gz" -C "$work"
fi
cmake -S "$work/libuv-v$uv" -B "$work/uv-build" "${cmake_args[@]}" -DLIBUV_BUILD_SHARED=OFF -DLIBUV_BUILD_TESTS=OFF -DLIBUV_BUILD_BENCH=OFF
cmake --build "$work/uv-build" --parallel "$jobs"
cmake --install "$work/uv-build"
(
 cd "$work/openssl-$openssl"
 perl Configure "$ssl_target" "${ssl_flags[@]}"
 make -j"$jobs" build_libs
 make install_dev
)
# libuv names its static archive differently across releases/toolchains.
uvlib=$(find "$prefix/lib" -maxdepth 1 -name '*uv*.a' -print -quit)
[[ -n $uvlib ]]
cmake -S "$root" -B "$work/miner" "${cmake_args[@]}" \
 -DXMRIG_DEPS="$prefix" -DUV_INCLUDE_DIR="$prefix/include" -DUV_LIBRARY="$uvlib" \
 -DOPENSSL_INCLUDE_DIR="$prefix/include" -DOPENSSL_SSL_LIBRARY="$prefix/lib/libssl.a" -DOPENSSL_CRYPTO_LIBRARY="$prefix/lib/libcrypto.a" \
 -DWITH_HWLOC=OFF -DWITH_OPENCL=OFF -DWITH_CUDA=OFF -DWITH_ADL=OFF -DWITH_NVML=OFF -DWITH_MSR=OFF -DWITH_DMI=OFF \
 -DWITH_TLS=ON -DARCH=default
cmake --build "$work/miner" --parallel "$jobs"
name=xmrig-$platform-$arch
stage=$work/$name
mkdir -p "$stage"
exe=xmrig
[[ $platform != windows ]] || exe=xmrig.exe
cp "$work/miner/$exe" "$stage/"
cp "$root/LICENSE" "$root/src/config.json" "$stage/"
cp "$root/.github/RELEASES.md" "$stage/README.md"
file "$stage/$exe"
if [[ $platform == macos || ($platform == linux && $arch == x64) ]]; then "$stage/$exe" --version; fi
if [[ $platform == windows ]]; then
 (cd "$work" && zip -qr "$root/dist/$name.zip" "$name")
else
 tar -czf "$root/dist/$name.tar.gz" -C "$work" "$name"
fi
