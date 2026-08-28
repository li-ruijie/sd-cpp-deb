#!/usr/bin/env bash
# Assemble sd-cpp-cuda_<version>_amd64.deb from a compiled libggml-cuda.so.
#
# Upstream publishes no Linux CUDA build, so unlike the base and Vulkan
# packages this backend is compiled rather than repackaged.
#
# cuda-suffix is the CUDA release in NVIDIA's apt package-name form, so 13.3
# becomes 13-3. It must match the toolkit the backend was compiled against,
# since the sonames it records are version specific. The workflow derives it
# from nvcc rather than hardcoding it, so a container bump moves the declared
# dependency with it instead of leaving it stale.
set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "usage: $0 <libggml-cuda.so> <version> <cuda-suffix> <outdir>" >&2
    exit 2
fi

backend=$1
version=$2
cuda_suffix=$3
outdir=$4

case "$version" in
    [0-9]*) ;;
    *) echo "$0: version must begin with a digit, got '$version'" >&2; exit 2 ;;
esac

case "$cuda_suffix" in
    [0-9]*-[0-9]*)
        # Reject anything with a character that is not a digit or a hyphen,
        # so 13-3x or 13.3 cannot reach a package name.
        case "$cuda_suffix" in
            *[!0-9-]*)
                echo "$0: cuda-suffix must look like 13-3, got '$cuda_suffix'" >&2
                exit 2
                ;;
        esac
        ;;
    *)
        echo "$0: cuda-suffix must look like 13-3, got '$cuda_suffix'" >&2
        exit 2
        ;;
esac

[ -f "$backend" ] || { echo "$0: no such file: $backend" >&2; exit 2; }

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

root="$staging/root"
mkdir -p "$root/DEBIAN" "$root/usr/lib/sd-cpp" "$outdir"

# dpkg-deb rejects a control directory outside 0755 to 0775.
chmod 0755 "$root/DEBIAN"

install -m 644 "$backend" "$root/usr/lib/sd-cpp/libggml-cuda.so"

installed_size=$(du -ks --exclude=DEBIAN "$root" | cut -f1)

cat > "$root/DEBIAN/control" <<EOF
Package: sd-cpp-cuda
Version: ${version}
Architecture: amd64
Maintainer: li-ruijie <1547237+li-ruijie@users.noreply.github.com>
Homepage: https://github.com/leejet/stable-diffusion.cpp
Depends: sd-cpp (= ${version}), cuda-cudart-${cuda_suffix}, libcublas-${cuda_suffix}
Installed-Size: ${installed_size}
Section: misc
Priority: optional
Description: stable-diffusion.cpp, CUDA backend
 NVIDIA CUDA backend for sd-cpp, compiled for compute capabilities 8.9 and
 12.0 with PTX fallback from 9.0. Upstream publishes no Linux CUDA build, so
 this is compiled rather than repackaged.
 .
 The CUDA runtime is depended on rather than bundled, since cuBLAS alone is an
 818 MB archive. Exactly the two runtime packages the backend links are named,
 rather than NVIDIA's cuda-libraries metapackage, which would add 1.2 GB of
 libraries that go unused. check-backend-deps.sh fails the build if the backend
 ever links a CUDA library outside that set, so the pin cannot drift out of
 step with the linkage.
 .
 Both come from NVIDIA's own CUDA apt repository, which must be configured on
 the target machine. Debian's nvidia-cuda-toolkit is 12.4 and is both too old
 for compute capability 12.0 and the wrong soname for a CUDA 13 build.
 .
 The NVIDIA driver is deliberately not depended on, since its package name
 varies by distribution and the cuda metapackage would pull nvidia-open, which
 collides with a distribution-packaged driver. Where the driver is missing,
 ggml loads this backend, finds no device, and sd-cpp runs on CPU without
 reporting why. Confirm it is in use with sd-cli --list-devices.
EOF

deb="$outdir/sd-cpp-cuda_${version}_amd64.deb"
dpkg-deb --root-owner-group --build "$root" "$deb" >/dev/null
echo "$deb"
