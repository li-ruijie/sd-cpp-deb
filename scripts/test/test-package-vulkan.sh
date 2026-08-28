#!/usr/bin/env bash
# Cover package-vulkan.sh, whose whole purpose is the byte-identity assertion
# between upstream's Vulkan archive and its CPU archive.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../package-vulkan.sh"
pass=0
fail=0

ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else
            bad "$1"; printf '       expected %s, got %s\n' "$3" "$2"; fi }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The CPU archive, and a Vulkan archive that is the same plus one backend.
src=$(mktemp -d)
printf '#!/bin/true\n'      > "$src/sd-cli"
printf '#!/bin/true\n'      > "$src/sd-server"
printf 'the library\n'      > "$src/libstable-diffusion.so"
printf 'ggml base\n'        > "$src/libggml-base.so.0.19.0"
( cd "$src" && zip -q "$work/cpu.zip" ./* )
printf 'vulkan backend\n'   > "$src/libggml-vulkan.so"
( cd "$src" && zip -q "$work/vulkan.zip" ./* )
rm -rf "$src"

echo "== a matching pair produces a .deb =="
deb=$("$script" "$work/vulkan.zip" "$work/cpu.zip" 0.0.829 "$work/out" 2>"$work/err")
rc=$?
check "exit status" "$rc" "0"
[ "$rc" -eq 0 ] || sed 's/^/       /' "$work/err"
check "printed path" "$deb" "$work/out/sd-cpp-vulkan_0.0.829_amd64.deb"

echo "== it ships exactly one file, in the right place =="
contents=$(dpkg-deb -c "$deb" | awk '$NF ~ /^\.\/usr/ && $1 !~ /^d/ {print $NF}')
check "file count" "$(printf '%s\n' "$contents" | grep -c .)" "1"
check "path" "$contents" "./usr/lib/sd-cpp/libggml-vulkan.so"

echo "== the shipped object is the one from the Vulkan archive =="
ext=$(mktemp -d); dpkg-deb -x "$deb" "$ext"
check "contents" "$(cat "$ext/usr/lib/sd-cpp/libggml-vulkan.so")" "vulkan backend"
rm -rf "$ext"

echo "== the control file is right =="
ctrl=$(dpkg-deb -f "$deb")
check "package" "$(printf '%s' "$ctrl" | awk '/^Package:/{print $2}')" "sd-cpp-vulkan"
check "architecture" "$(printf '%s' "$ctrl" | awk '/^Architecture:/{print $2}')" "amd64"
printf '%s' "$ctrl" | grep -q 'sd-cpp (= 0.0.829)' \
    && ok "pins the base package exactly" || bad "pins the base package exactly"
printf '%s' "$ctrl" | grep -q 'libvulkan1' \
    && ok "depends on libvulkan1" || bad "depends on libvulkan1"
# The ICD comes from mesa-vulkan-drivers on AMD and Intel and from the
# proprietary driver on NVIDIA, so no single package name is correct.
printf '%s' "$ctrl" | grep -q '^Depends:.*mesa-vulkan-drivers' \
    && bad "must not depend on an ICD" || ok "does not depend on an ICD"

echo "== a divergent shared file is refused =="
cp "$work/vulkan.zip" "$work/bad.zip"
d=$(mktemp -d); printf 'CHANGED\n' > "$d/libstable-diffusion.so"
( cd "$d" && zip -qg "$work/bad.zip" libstable-diffusion.so ); rm -rf "$d"
out=$("$script" "$work/bad.zip" "$work/cpu.zip" 0.0.829 "$work/out2" 2>&1)
check "exit status on divergence" "$?" "1"
printf '%s' "$out" | grep -q 'libstable-diffusion.so' \
    && ok "names the offending file" || bad "names the offending file"

echo "== a Vulkan archive missing the backend is refused =="
cp "$work/cpu.zip" "$work/nobackend.zip"
out=$("$script" "$work/nobackend.zip" "$work/cpu.zip" 0.0.829 "$work/out3" 2>&1)
check "exit status when the backend is absent" "$?" "1"
printf '%s' "$out" | grep -q 'libggml-vulkan.so' \
    && ok "says the backend is missing" || bad "says the backend is missing"

echo "== a second extra file is refused =="
cp "$work/vulkan.zip" "$work/extra.zip"
d=$(mktemp -d); printf 'x\n' > "$d/libggml-cuda.so"
( cd "$d" && zip -qg "$work/extra.zip" libggml-cuda.so ); rm -rf "$d"
out=$("$script" "$work/extra.zip" "$work/cpu.zip" 0.0.829 "$work/out4" 2>&1)
check "exit status on a second extra file" "$?" "1"
printf '%s' "$out" | grep -q 'libggml-cuda.so' \
    && ok "names the unexpected file" || bad "names the unexpected file"

echo "== a bad version is refused =="
"$script" "$work/vulkan.zip" "$work/cpu.zip" master-829 "$work/out5" >/dev/null 2>&1
check "exit status on a non-numeric version" "$?" "2"

echo "== a missing archive is refused =="
"$script" "$work/nosuch.zip" "$work/cpu.zip" 0.0.829 "$work/out6" >/dev/null 2>&1
check "exit status on a missing vulkan archive" "$?" "2"
"$script" "$work/vulkan.zip" "$work/nosuch.zip" 0.0.829 "$work/out7" >/dev/null 2>&1
check "exit status on a missing cpu archive" "$?" "2"

echo "== wrong argument count is refused =="
"$script" "$work/vulkan.zip" "$work/cpu.zip" 0.0.829 >/dev/null 2>&1
check "exit status with three arguments" "$?" "2"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
