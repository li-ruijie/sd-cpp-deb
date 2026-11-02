#!/usr/bin/env bash
# Assemble sd-cpp-cuda_<version>_amd64.deb from a compiled libggml-cuda.so and
# a CUDA build of libstable-diffusion.so.
#
# Upstream publishes no Linux CUDA build, so unlike the base and Vulkan
# packages this backend is compiled rather than repackaged.
#
# From master-1037 the CUDA kernels for RoPE, INT8, and attention live in
# libstable-diffusion.so rather than in ggml, so the backend alone runs those
# operations on the CPU. The package therefore also carries a CUDA build of
# that library, compiled with the Vulkan kernels as well so that sd-cpp-vulkan
# keeps them when both are installed, and diverts the base package's copy.
#
# upstream-src is the source tree the library was compiled from. The CUTLASS
# and SageAttention licence texts are taken from it, since both are compiled
# into the library.
#
# cuda-suffix is the CUDA release in NVIDIA's apt package-name form, so 13.3
# becomes 13-3. It must match the toolkit the backend was compiled against,
# since the sonames it records are version specific. The workflow derives it
# from nvcc rather than hardcoding it, so a container bump moves the declared
# dependency with it instead of leaving it stale.
set -euo pipefail

if [ "$#" -ne 6 ]; then
    echo "usage: $0 <libggml-cuda.so> <libstable-diffusion.so> <upstream-src>" \
         "<version> <cuda-suffix> <outdir>" >&2
    exit 2
fi

backend=$1
library=$2
src=$3
version=$4
cuda_suffix=$5
outdir=$6

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
[ -f "$library" ] || { echo "$0: no such file: $library" >&2; exit 2; }

# Both are required, as in package-base.sh. A missing one means upstream moved
# it, and distributing the compiled code without its terms is not an option.
for lic in thirdparty/cutlass/LICENSE.txt src/core/cuda/sageattention/LICENSE; do
    if [ ! -f "$src/$lic" ]; then
        echo "$0: the source tree carries no $lic" >&2
        echo "Its code is compiled into the library, so this is refused" >&2
        echo "rather than packaged without its licence." >&2
        exit 1
    fi
done

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

root="$staging/root"
docdir="$root/usr/share/doc/sd-cpp-cuda"
mkdir -p "$root/DEBIAN" "$root/usr/lib/sd-cpp" "$docdir" "$outdir"

# dpkg-deb rejects a control directory outside 0755 to 0775.
chmod 0755 "$root/DEBIAN"

install -m 644 "$backend" "$root/usr/lib/sd-cpp/libggml-cuda.so"
install -m 644 "$library" "$root/usr/lib/sd-cpp/libstable-diffusion.so"
install -m 644 "$src/thirdparty/cutlass/LICENSE.txt" "$docdir/cutlass.txt"
install -m 644 "$src/src/core/cuda/sageattention/LICENSE" "$docdir/sageattention.txt"

cat > "$docdir/copyright" <<'COPYRIGHT'
Upstream-Name: stable-diffusion.cpp
Source: https://github.com/leejet/stable-diffusion.cpp

Files: *
Copyright: Copyright (c) 2023 leejet and the stable-diffusion.cpp contributors
License: MIT
 The full text ships with sd-cpp, on which this package depends, as
 /usr/share/doc/sd-cpp/stable-diffusion.cpp.txt.

Files: usr/lib/sd-cpp/libggml-cuda.so
Copyright: Copyright (c) 2023-2024 The ggml authors
License: MIT
 The full text ships with sd-cpp as /usr/share/doc/sd-cpp/ggml.txt.

Files: usr/lib/sd-cpp/libstable-diffusion.so
Copyright: Copyright (c) 2017 - 2025 NVIDIA CORPORATION & AFFILIATES
 Copyright (c) 2024 by SageAttention team.
 Copyright (c) 2023 by FlashInfer team.
License: BSD-3-Clause and Apache-2.0
 The library compiles in CUTLASS, under BSD-3-Clause, and SageAttention
 with helpers it adapts from FlashInfer, under Apache-2.0. Both texts ship
 alongside this file, as cutlass.txt and sageattention.txt, taken verbatim
 from the upstream source tree.

Comment:
 The packaging that produced this .deb is separate work, licensed AGPL-3.0,
 and lives at https://github.com/li-ruijie/sd-cpp-deb. This package contains
 no part of it.
COPYRIGHT
chmod 644 "$docdir/copyright"

# The base package's library moves aside while this one is installed and moves
# back on removal. sd-cli finds the library through RUNPATH=$ORIGIN, so it must
# sit at this exact path. abort-upgrade and purge need nothing, since the
# diversion either still belongs to an installed version or is already gone.
cat > "$root/DEBIAN/preinst" <<'PREINST'
#!/bin/sh
set -e
if [ "$1" = install ] || [ "$1" = upgrade ]; then
    dpkg-divert --package sd-cpp-cuda --add --rename \
        --divert /usr/lib/sd-cpp/libstable-diffusion.so.distrib \
        /usr/lib/sd-cpp/libstable-diffusion.so
fi
PREINST

cat > "$root/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
if [ "$1" = remove ] || [ "$1" = abort-install ] || [ "$1" = disappear ]; then
    dpkg-divert --package sd-cpp-cuda --remove --rename \
        --divert /usr/lib/sd-cpp/libstable-diffusion.so.distrib \
        /usr/lib/sd-cpp/libstable-diffusion.so
fi
POSTRM
chmod 0755 "$root/DEBIAN/preinst" "$root/DEBIAN/postrm"

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
 The CUDA kernels for RoPE, INT8, and attention live in libstable-diffusion.so
 rather than in the backend, so this package also carries a CUDA build of that
 library and diverts the copy sd-cpp installs. That build includes the Vulkan
 kernels too, so sd-cpp-vulkan keeps them when both are installed. Removing
 this package restores the sd-cpp copy.
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
 collides with a distribution-packaged driver. The CUDA build of the library
 links libcuda.so.1 directly, so where the driver is missing sd-cli and
 sd-server refuse to start with a loader error naming that library. Removing
 this package returns them to the CPU. Where the driver is present but no
 device is usable, ggml finds no device and sd-cpp runs on CPU without
 reporting why, so confirm the backend is in use with sd-cli --list-devices.
EOF

deb="$outdir/sd-cpp-cuda_${version}_amd64.deb"
dpkg-deb --root-owner-group --build "$root" "$deb" >/dev/null
echo "$deb"
