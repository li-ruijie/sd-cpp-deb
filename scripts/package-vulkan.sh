#!/usr/bin/env bash
# Assemble sd-cpp-vulkan_<version>_amd64.deb by taking libggml-vulkan.so out of
# the archive the build job compiles from upstream source. sd-cpp is built from
# the same archive, so the backend and the base library it links come from one
# build and cannot diverge.
#
# This script once took upstream's prebuilt CPU and Vulkan archives and refused
# to proceed unless every shared member was identical, since those were two
# separate upstream builds. Upstream moved those builds to Ubuntu 26.04 and
# glibc 2.43 in November 2026, beyond what Debian trixie carries, so both
# packages are now compiled here and that comparison has nothing to compare.
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <archive.zip> <version> <outdir>" >&2
    exit 2
fi

archive=$1
version=$2
outdir=$3

backend_name=libggml-vulkan.so

case "$version" in
    [0-9]*) ;;
    *) echo "$0: version must begin with a digit, got '$version'" >&2; exit 2 ;;
esac

[ -f "$archive" ] || { echo "$0: no such file: $archive" >&2; exit 2; }

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

mkdir -p "$staging/archive"
unzip -qq "$archive" -d "$staging/archive"

if [ ! -f "$staging/archive/$backend_name" ]; then
    echo "$0: the archive carries no $backend_name" >&2
    echo "The build job compiles with SD_VULKAN on, so its absence means that" >&2
    echo "build changed, and there is nothing to package." >&2
    exit 1
fi

root="$staging/root"
mkdir -p "$root/DEBIAN" "$root/usr/lib/sd-cpp" "$outdir"

# dpkg-deb rejects a control directory outside 0755 to 0775.
chmod 0755 "$root/DEBIAN"

install -m 644 "$staging/archive/$backend_name" "$root/usr/lib/sd-cpp/$backend_name"

installed_size=$(du -ks --exclude=DEBIAN "$root" | cut -f1)

cat > "$root/DEBIAN/control" <<EOF
Package: sd-cpp-vulkan
Version: ${version}
Architecture: amd64
Maintainer: li-ruijie <1547237+li-ruijie@users.noreply.github.com>
Homepage: https://github.com/leejet/stable-diffusion.cpp
Depends: sd-cpp (= ${version}), libvulkan1, libc6 (>= 2.38), libstdc++6 (>= 13.1)
Installed-Size: ${installed_size}
Section: misc
Priority: optional
Description: stable-diffusion.cpp, Vulkan backend
 Vulkan compute backend for sd-cpp, giving GPU acceleration on AMD, Intel, and
 NVIDIA hardware without requiring CUDA. Compiled from upstream source in the
 same build as the sd-cpp package, so the backend and the base library it
 links always match.
 .
 libvulkan1 is the loader and is depended on. The driver-specific ICD is not,
 since it comes from mesa-vulkan-drivers on AMD and Intel and from the
 proprietary driver on NVIDIA, so no single package name would be correct.
 .
 Where no usable Vulkan device is present, ggml ignores this backend without
 reporting anything at all and sd-cpp runs on CPU. Confirm the backend is in
 use with sd-cli --list-devices, which names every device ggml found, rather
 than assuming it loaded.
 .
 This package may be installed alongside sd-cpp-cuda. Choose between them with
 the --backend option.
EOF

deb="$outdir/sd-cpp-vulkan_${version}_amd64.deb"
dpkg-deb --root-owner-group --build "$root" "$deb" >/dev/null
echo "$deb"
