#!/usr/bin/env bash
# Assemble sd-cpp_<version>_amd64.deb from an upstream stable-diffusion.cpp
# Linux archive. No compilation: upstream publishes this build and we repackage
# it unchanged apart from the layout.
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <archive.zip> <version> <outdir>" >&2
    exit 2
fi

archive=$1
version=$2
outdir=$3

# A version that is quietly wrong produces a package the backends can never
# depend on, since each pins it exactly.
case "$version" in
    [0-9]*) ;;
    *) echo "$0: version must begin with a digit, got '$version'" >&2; exit 2 ;;
esac

[ -f "$archive" ] || { echo "$0: no such file: $archive" >&2; exit 2; }

# Reached through /usr/bin. The archive holds no other executables, and the
# check below fails on anything unrecognised rather than dropping it silently.
# Upstream has already renamed this tool once, from sd to sd-cli.
tools="sd-cli sd-server"

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

root="$staging/root"
libdir="$root/usr/lib/sd-cpp"
docdir="$root/usr/share/doc/sd-cpp"
# The output directory is created here rather than assumed. dpkg-deb fails with
# a bare "No such file or directory" when it is missing, which is what a caller
# passing a fresh path hits.
mkdir -p "$root/DEBIAN" "$libdir" "$root/usr/bin" "$docdir" "$outdir"

# dpkg-deb rejects a control directory outside 0755 to 0775, and a restrictive
# umask on the build host would otherwise produce one.
chmod 0755 "$root/DEBIAN"

# Upstream's zip stores every file at the top level, with no wrapping directory.
unzip -qq "$archive" -d "$libdir"

# The licence texts are documentation rather than payload. Both are required:
# a missing one means upstream changed the archive, and distributing the
# software without its terms is not an option.
for name in stable-diffusion.cpp.txt ggml.txt; do
    if [ ! -f "$libdir/$name" ]; then
        echo "$0: the archive carries no $name" >&2
        echo "The upstream licence must ship with the package, so this is" >&2
        echo "refused rather than packaged without it." >&2
        exit 1
    fi
    install -Dm644 "$libdir/$name" "$docdir/$name"
    rm -f "$libdir/$name"
done

# Debian policy requires /usr/share/doc/<package>/copyright. The two upstream
# texts sit beside it verbatim, and this file points at them rather than
# paraphrasing terms.
cat > "$docdir/copyright" <<'COPYRIGHT'
Upstream-Name: stable-diffusion.cpp
Source: https://github.com/leejet/stable-diffusion.cpp

Files: *
Copyright: Copyright (c) 2023 leejet and the stable-diffusion.cpp contributors
License: MIT
 The full text ships alongside this file as stable-diffusion.cpp.txt, taken
 verbatim from the upstream release archive.

Files: usr/lib/sd-cpp/libggml*
Copyright: Copyright (c) 2023-2024 The ggml authors
License: MIT
 The full text ships alongside this file as ggml.txt, taken verbatim from the
 upstream release archive.

Comment:
 The packaging that produced this .deb is separate work, licensed AGPL-3.0,
 and lives at https://github.com/li-ruijie/sd-cpp-deb. This package contains
 no part of it.
COPYRIGHT
chmod 644 "$docdir/copyright"

# The zip format stores no symlinks here, so each versioned library arrives as
# three byte-identical copies. Collapse them, and refuse to do so if they ever
# stop being identical, since that would mean discarding a real file.
for full in "$libdir"/*.so.*.*.*; do
    [ -f "$full" ] || continue
    stem=${full%%.so.*}
    ver=${full#*.so.}
    major=${ver%%.*}
    soname="$stem.so.$major"
    linker="$stem.so"

    for alias in "$soname" "$linker"; do
        [ -e "$alias" ] || continue
        if ! cmp -s "$alias" "$full"; then
            echo "$0: $(basename "$alias") differs from $(basename "$full")" >&2
            echo "These are expected to be identical copies. Collapsing them" >&2
            echo "to symlinks would discard a real file, so this is refused." >&2
            exit 1
        fi
    done

    [ -e "$soname" ] && ln -sf "$(basename "$full")"   "$soname"
    [ -e "$linker" ] && ln -sf "$(basename "$soname")" "$linker"
done

# Fail on an executable this script has never seen. An upstream rename would
# otherwise drop a tool from /usr/bin with no signal at all.
for path in "$libdir"/*; do
    [ -f "$path" ] || continue
    name=$(basename "$path")
    case "$name" in
        *.so | *.so.* | *.txt) continue ;;
    esac
    case " $tools " in
        *" $name "*) ;;
        *)
            echo "$0: unrecognised executable in the archive: $name" >&2
            echo "Add it to the tools allowlist here, then update the symlink" >&2
            echo "assertions in test-package-base.sh." >&2
            exit 1
            ;;
    esac
done

# Symlink the allowlist, failing if upstream dropped one of them. The binaries
# carry RUNPATH=$ORIGIN, which glibc expands from the real path after resolving
# the symlink, so no wrapper is needed. smoke-test.sh tests exactly that.
for name in $tools; do
    if [ ! -f "$libdir/$name" ]; then
        echo "$0: expected tool missing from the archive: $name" >&2
        exit 1
    fi
    chmod 755 "$libdir/$name"
    ln -s "../lib/sd-cpp/$name" "$root/usr/bin/$name"
done

# -type f leaves the soname symlinks created above alone, which is what we want.
find "$libdir" -name '*.so*' -type f -exec chmod 644 {} +

# dpkg-deb does not compute this, so it stays absent unless set here, and apt
# then reports no disk usage before installing. In KiB, excluding the control
# directory, which is not installed.
installed_size=$(du -ks --exclude=DEBIAN "$root" | cut -f1)

cat > "$root/DEBIAN/control" <<EOF
Package: sd-cpp
Version: ${version}
Architecture: amd64
Maintainer: li-ruijie <1547237+li-ruijie@users.noreply.github.com>
Homepage: https://github.com/leejet/stable-diffusion.cpp
Depends: libc6 (>= 2.38), libstdc++6 (>= 13.1), libgcc-s1, libgomp1
Installed-Size: ${installed_size}
Section: misc
Priority: optional
Description: stable-diffusion.cpp, diffusion model inference in C/C++
 Command line tool and HTTP server for image and video generation with Stable
 Diffusion, Flux, Wan, Qwen Image, and related models, repackaged from the
 upstream release archive. sd-server embeds a web interface and serves
 OpenAI-compatible, Automatic1111-compatible, and native APIs, listening on
 127.0.0.1 by default.
 .
 amd64 only, as upstream publishes no Linux arm64 build. The archives are
 built on Ubuntu 24.04, so glibc 2.38 and libstdc++ 13.1 are required. Debian
 trixie satisfies both and bookworm does not, which is why those floors are
 declared rather than left to fail at run time.
 .
 Models are not included and are not downloaded at install time. They run to
 several gigabytes and come from more than one hub, so fetching them is left
 to the user. The huggingface-cli package in this repository covers the
 Hugging Face half.
 .
 Install sd-cpp-cuda or sd-cpp-vulkan alongside this package to add GPU
 acceleration. Both may be installed together. A backend whose loader or
 driver is missing is ignored without any message, so confirm one is in use
 with sd-cli --list-devices rather than assuming.
EOF

deb="$outdir/sd-cpp_${version}_amd64.deb"
dpkg-deb --root-owner-group --build "$root" "$deb" >/dev/null
echo "$deb"
