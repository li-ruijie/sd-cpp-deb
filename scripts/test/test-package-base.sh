#!/usr/bin/env bash
# Cover package-base.sh against a synthetic archive shaped like upstream's, so
# the suite runs offline and in about a second rather than fetching 33 MB.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../package-base.sh"
pass=0
fail=0

ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else
            bad "$1"; printf '       expected %s, got %s\n' "$3" "$2"; fi }

# Upstream's shape: two executables, versioned library triplets stored as three
# byte-identical copies, unversioned objects, and the two licence files. Stored
# with bare names rather than a ./ prefix, since upstream's archive is flat and
# the dedup glob in package-base.sh matches on that.
make_zip() {
    local dir out
    out=$1
    dir=$(mktemp -d)
    printf '#!/bin/true\n' > "$dir/sd-cli"
    printf '#!/bin/true\n' > "$dir/sd-server"
    printf 'real webp library\n' > "$dir/libwebp.so.7.2.0"
    cp "$dir/libwebp.so.7.2.0" "$dir/libwebp.so.7"
    cp "$dir/libwebp.so.7.2.0" "$dir/libwebp.so"
    printf 'ggml base\n' > "$dir/libggml-base.so.0.19.0"
    cp "$dir/libggml-base.so.0.19.0" "$dir/libggml-base.so.0"
    cp "$dir/libggml-base.so.0.19.0" "$dir/libggml-base.so"
    printf 'cpu variant\n'   > "$dir/libggml-cpu-haswell.so"
    printf 'the library\n'   > "$dir/libstable-diffusion.so"
    printf 'MIT for ggml\n'  > "$dir/ggml.txt"
    printf 'MIT for sd.cpp\n' > "$dir/stable-diffusion.cpp.txt"
    ( cd "$dir" && zip -q "$out" ./* )
    rm -rf "$dir"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
zip_path="$work/archive.zip"
make_zip "$zip_path"

echo "== a well-formed archive produces a .deb =="
deb=$("$script" "$zip_path" 0.0.829 "$work/out" 2>"$work/err")
rc=$?
check "exit status" "$rc" "0"
[ "$rc" -eq 0 ] || sed 's/^/       /' "$work/err"
check "printed path" "$deb" "$work/out/sd-cpp_0.0.829_amd64.deb"
[ -f "$deb" ] && ok "the file exists" || bad "the file exists"

echo "== the control file is right =="
ctrl=$(dpkg-deb -f "$deb")
check "package"      "$(printf '%s' "$ctrl" | awk '/^Package:/{print $2}')" "sd-cpp"
check "version"      "$(printf '%s' "$ctrl" | awk '/^Version:/{print $2}')" "0.0.829"
check "architecture" "$(printf '%s' "$ctrl" | awk '/^Architecture:/{print $2}')" "amd64"
printf '%s' "$ctrl" | grep -q 'libgomp1' \
    && ok "depends on libgomp1" || bad "depends on libgomp1"
printf '%s' "$ctrl" | grep -q 'libc6 (>= 2.38)' \
    && ok "declares the glibc floor" || bad "declares the glibc floor"
printf '%s' "$ctrl" | grep -q 'libstdc++6 (>= 13.1)' \
    && ok "declares the libstdc++ floor" || bad "declares the libstdc++ floor"
# dpkg-deb leaves this unset unless the script computes it, and apt then
# reports no disk usage before installing.
size=$(printf '%s' "$ctrl" | awk '/^Installed-Size:/{print $2}')
case "$size" in
    [1-9]*) ok "Installed-Size is set to $size KiB" ;;
    *) bad "Installed-Size is set, got '${size:-unset}'" ;;
esac

echo "== the layout is right =="
contents=$(dpkg-deb -c "$deb")
for p in ./usr/lib/sd-cpp/sd-cli ./usr/lib/sd-cpp/sd-server \
         ./usr/bin/sd-cli ./usr/bin/sd-server \
         ./usr/share/doc/sd-cpp/ggml.txt \
         ./usr/share/doc/sd-cpp/stable-diffusion.cpp.txt \
         ./usr/share/doc/sd-cpp/copyright; do
    printf '%s\n' "$contents" | grep -q " $p" \
        && ok "ships $p" || bad "ships $p"
done

echo "== the licence texts do not stay in the payload directory =="
printf '%s\n' "$contents" | grep -q './usr/lib/sd-cpp/ggml.txt' \
    && bad "licence text left in the payload" \
    || ok "licence text moved out of the payload"

echo "== /usr/bin entries are relative symlinks =="
# Relative, so the package relocates and so $ORIGIN resolves through them.
link=$(printf '%s\n' "$contents" | awk '/ \.\/usr\/bin\/sd-cli ->/{print $NF}')
check "sd-cli target" "$link" "../lib/sd-cpp/sd-cli"
link=$(printf '%s\n' "$contents" | awk '/ \.\/usr\/bin\/sd-server ->/{print $NF}')
check "sd-server target" "$link" "../lib/sd-cpp/sd-server"

echo "== duplicate libraries collapse to symlinks =="
printf '%s\n' "$contents" | grep -q './usr/lib/sd-cpp/libwebp.so.7 -> libwebp.so.7.2.0' \
    && ok "soname is a symlink" || bad "soname is a symlink"
printf '%s\n' "$contents" | grep -q './usr/lib/sd-cpp/libwebp.so -> libwebp.so.7' \
    && ok "linker name is a symlink" || bad "linker name is a symlink"
printf '%s\n' "$contents" | grep -q './usr/lib/sd-cpp/libggml-base.so.0 -> libggml-base.so.0.19.0' \
    && ok "ggml soname is a symlink" || bad "ggml soname is a symlink"

echo "== unversioned objects are left alone =="
printf '%s\n' "$contents" | grep -qE '\./usr/lib/sd-cpp/libggml-cpu-haswell\.so ->' \
    && bad "cpu variant wrongly symlinked" || ok "cpu variant left as a real file"

echo "== an unrecognised executable fails the build =="
zip2="$work/extra.zip"
make_zip "$zip2"
extra=$(mktemp -d); printf '#!/bin/true\n' > "$extra/sd-bench"
( cd "$extra" && zip -qg "$zip2" sd-bench ); rm -rf "$extra"
out=$("$script" "$zip2" 0.0.829 "$work/out2" 2>&1)
check "exit status on an unknown binary" "$?" "1"
printf '%s' "$out" | grep -q 'sd-bench' \
    && ok "names the unrecognised binary" || bad "names the unrecognised binary"

echo "== upstream's launcher scripts are left out =="
# Since master-982 the archive carries these. They locate sd-server and a
# models directory relative to themselves, which suits an unpacked folder and
# not /usr/lib/sd-cpp.
zip8="$work/launchers.zip"
make_zip "$zip8"
l=$(mktemp -d)
printf '#!/bin/sh\n' > "$l/start-server.sh"; chmod 755 "$l/start-server.sh"
printf '@echo off\r\n' > "$l/start-server.bat"
( cd "$l" && zip -qg "$zip8" start-server.sh start-server.bat ); rm -rf "$l"
deb8=$("$script" "$zip8" 0.0.829 "$work/out8" 2>"$work/err8")
rc=$?
check "exit status with the launchers present" "$rc" "0"
[ "$rc" -eq 0 ] || sed 's/^/       /' "$work/err8"
if [ -f "$deb8" ]; then
    # Captured first. Piped straight into grep -q, dpkg-deb can take SIGPIPE,
    # and under pipefail that reads as no match whatever the listing holds.
    listing=$(dpkg-deb -c "$deb8")
    printf '%s\n' "$listing" | grep -q 'start-server' \
        && bad "launchers left out of the package" \
        || ok "launchers left out of the package"
else
    bad "launchers left out of the package"
fi

echo "== the Vulkan backend is left to sd-cpp-vulkan =="
# The base is built from the Vulkan archive, whose library carries the Vulkan
# kernels, so the backend itself arrives here too and must not ship twice.
zip9="$work/vulkan.zip"
make_zip "$zip9"
v=$(mktemp -d); printf 'vulkan backend\n' > "$v/libggml-vulkan.so"
( cd "$v" && zip -qg "$zip9" libggml-vulkan.so ); rm -rf "$v"
deb9=$("$script" "$zip9" 0.0.829 "$work/out9" 2>"$work/err9")
rc=$?
check "exit status on the Vulkan archive" "$rc" "0"
[ "$rc" -eq 0 ] || sed 's/^/       /' "$work/err9"
if [ -f "$deb9" ]; then
    listing=$(dpkg-deb -c "$deb9")
    printf '%s\n' "$listing" | grep -q 'libggml-vulkan' \
        && bad "backend left out of the base package" \
        || ok "backend left out of the base package"
else
    bad "backend left out of the base package"
fi

echo "== a missing expected tool fails the build =="
zip3="$work/missing.zip"
make_zip "$zip3"
zip -qd "$zip3" sd-server
"$script" "$zip3" 0.0.829 "$work/out3" >/dev/null 2>&1
check "exit status when sd-server is absent" "$?" "1"

echo "== a bad version is refused =="
"$script" "$zip_path" master-829 "$work/out4" >/dev/null 2>&1
check "exit status on a non-numeric version" "$?" "2"

echo "== differing duplicates are refused rather than silently linked =="
# Collapsing these would discard a real file, so the script must stop.
zip5="$work/diff.zip"
make_zip "$zip5"
d=$(mktemp -d); printf 'DIFFERENT CONTENT\n' > "$d/libwebp.so.7"
( cd "$d" && zip -qg "$zip5" libwebp.so.7 ); rm -rf "$d"
out=$("$script" "$zip5" 0.0.829 "$work/out5" 2>&1)
check "exit status when a soname copy differs" "$?" "1"
printf '%s' "$out" | grep -q 'libwebp.so.7' \
    && ok "names the differing file" || bad "names the differing file"

echo "== a missing upstream licence fails the build =="
zip6="$work/nolicence.zip"
make_zip "$zip6"
zip -qd "$zip6" ggml.txt
out=$("$script" "$zip6" 0.0.829 "$work/out6" 2>&1)
check "exit status when ggml.txt is absent" "$?" "1"
printf '%s' "$out" | grep -q 'ggml.txt' \
    && ok "names the missing licence" || bad "names the missing licence"

echo "== a missing archive is refused =="
"$script" "$work/nosuch.zip" 0.0.829 "$work/out7" >/dev/null 2>&1
check "exit status on a missing archive" "$?" "2"

echo "== wrong argument count is refused =="
"$script" "$zip_path" 0.0.829 >/dev/null 2>&1
check "exit status with two arguments" "$?" "2"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
