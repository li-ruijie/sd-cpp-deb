#!/usr/bin/env bash
# Assemble sd-cpp-vulkan_<version>_amd64.deb by taking libggml-vulkan.so out of
# upstream's prebuilt Vulkan archive. No compilation, no Vulkan SDK on the
# runner, and no shader toolchain, unlike the sibling whisper-cpp-deb which
# compiles its Vulkan backend.
#
# The CPU archive is required as well, and is not a convenience. This package
# rests on a measured property, that upstream's Vulkan archive is the CPU
# archive plus exactly one file, verified by hashing all 36 members on
# 2026-08-28. Should upstream ever diverge the two builds, taking the backend
# alone would ship an object compiled against a base that was never published,
# which fails to load on a user's machine with no useful message. The assertion
# below is the guard on that.
set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "usage: $0 <vulkan.zip> <cpu.zip> <version> <outdir>" >&2
    exit 2
fi

vulkan_zip=$1
cpu_zip=$2
version=$3
outdir=$4

backend_name=libggml-vulkan.so

case "$version" in
    [0-9]*) ;;
    *) echo "$0: version must begin with a digit, got '$version'" >&2; exit 2 ;;
esac

for f in "$vulkan_zip" "$cpu_zip"; do
    [ -f "$f" ] || { echo "$0: no such file: $f" >&2; exit 2; }
done

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

mkdir -p "$staging/vulkan" "$staging/cpu"
unzip -qq "$vulkan_zip" -d "$staging/vulkan"
unzip -qq "$cpu_zip"    -d "$staging/cpu"

# Every member of the Vulkan archive must either be the backend or be identical
# to its CPU counterpart. Compared by content rather than by name, so a rebuild
# that silently changed a library is caught as well as a renamed one.
missing_backend=1
status=0
for path in "$staging/vulkan"/*; do
    [ -f "$path" ] || continue
    name=$(basename "$path")

    if [ "$name" = "$backend_name" ]; then
        missing_backend=0
        continue
    fi

    if [ ! -f "$staging/cpu/$name" ]; then
        echo "$0: $name is in the Vulkan archive and not in the CPU archive" >&2
        status=1
        continue
    fi

    if ! cmp -s "$path" "$staging/cpu/$name"; then
        echo "$0: $name differs between the Vulkan and CPU archives" >&2
        status=1
    fi
done

if [ "$missing_backend" -ne 0 ]; then
    echo "$0: the Vulkan archive carries no $backend_name" >&2
    status=1
fi

if [ "$status" -ne 0 ]; then
    echo >&2
    echo "The Vulkan archive is expected to be the CPU archive plus exactly" >&2
    echo "$backend_name, and it is not, so upstream has changed how it builds" >&2
    echo "these. Re-measure before shipping: the backend may no longer match" >&2
    echo "the base package this depends on." >&2
    exit 1
fi

root="$staging/root"
mkdir -p "$root/DEBIAN" "$root/usr/lib/sd-cpp" "$outdir"

# dpkg-deb rejects a control directory outside 0755 to 0775.
chmod 0755 "$root/DEBIAN"

install -m 644 "$staging/vulkan/$backend_name" "$root/usr/lib/sd-cpp/$backend_name"

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
 NVIDIA hardware without requiring CUDA. Taken from upstream's own prebuilt
 Vulkan archive rather than compiled here, after checking that archive is
 otherwise byte-identical to the one the sd-cpp package is built from.
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
