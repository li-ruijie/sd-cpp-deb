#!/usr/bin/env bash
# Cover package-cuda.sh, in particular that the CUDA suffix reaches Depends,
# that the cuda metapackage never does, and that the CUDA build of
# libstable-diffusion.so replaces the base copy through a diversion.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../package-cuda.sh"
pass=0
fail=0

ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else
            bad "$1"; printf '       expected %s, got %s\n' "$3" "$2"; fi }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf 'stands in for a compiled backend\n' > "$work/libggml-cuda.so"
printf 'stands in for the CUDA library\n'   > "$work/libstable-diffusion.so"

# The two licence texts the CUDA kernels bring in, at upstream's paths.
make_src() {
    mkdir -p "$1/thirdparty/cutlass" "$1/src/core/cuda/sageattention"
    printf 'CUTLASS BSD-3-Clause\n'      > "$1/thirdparty/cutlass/LICENSE.txt"
    printf 'SageAttention Apache-2.0\n' > "$1/src/core/cuda/sageattention/LICENSE"
}
src="$work/src"
make_src "$src"

run() { "$script" "$work/libggml-cuda.so" "$work/libstable-diffusion.so" "$@"; }

echo "== a well-formed call produces a .deb =="
deb=$(run "$src" 0.0.829 13-3 "$work/out" 2>"$work/err")
rc=$?
check "exit status" "$rc" "0"
[ "$rc" -eq 0 ] || sed 's/^/       /' "$work/err"
check "printed path" "$deb" "$work/out/sd-cpp-cuda_0.0.829_amd64.deb"

echo "== it ships the backend, the library, and the licence texts =="
contents=$(dpkg-deb -c "$deb" | awk '$NF ~ /^\.\/usr/ && $1 !~ /^d/ {print $NF}' | sort)
expected=$(printf '%s\n' \
    ./usr/lib/sd-cpp/libggml-cuda.so \
    ./usr/lib/sd-cpp/libstable-diffusion.so \
    ./usr/share/doc/sd-cpp-cuda/copyright \
    ./usr/share/doc/sd-cpp-cuda/cutlass.txt \
    ./usr/share/doc/sd-cpp-cuda/sageattention.txt | sort)
check "file list" "$contents" "$expected"

echo "== the shipped objects and texts are the ones given =="
ext=$(mktemp -d); dpkg-deb -x "$deb" "$ext"
check "library" "$(cat "$ext/usr/lib/sd-cpp/libstable-diffusion.so")" \
    "stands in for the CUDA library"
check "cutlass text" "$(cat "$ext/usr/share/doc/sd-cpp-cuda/cutlass.txt")" \
    "CUTLASS BSD-3-Clause"
check "sageattention text" "$(cat "$ext/usr/share/doc/sd-cpp-cuda/sageattention.txt")" \
    "SageAttention Apache-2.0"
rm -rf "$ext"

echo "== the library is installed over the base copy by a diversion =="
ctl=$(mktemp -d); dpkg-deb -e "$deb" "$ctl"
for s in preinst postrm; do
    [ -x "$ctl/$s" ] && ok "$s is executable" || bad "$s is executable"
    sh -n "$ctl/$s" 2>/dev/null && ok "$s parses" || bad "$s parses"
done
divert='--divert /usr/lib/sd-cpp/libstable-diffusion.so.distrib'
grep -q -- '--add' "$ctl/preinst" && grep -q -- "$divert" "$ctl/preinst" \
    && ok "preinst adds the diversion" || bad "preinst adds the diversion"
grep -q -- '--remove' "$ctl/postrm" && grep -q -- "$divert" "$ctl/postrm" \
    && ok "postrm removes the diversion" || bad "postrm removes the diversion"
for s in preinst postrm; do
    grep -q -- '--package sd-cpp-cuda' "$ctl/$s" && grep -q -- '--rename' "$ctl/$s" \
        && ok "$s names the package and renames" || bad "$s names the package and renames"
done
rm -rf "$ctl"

echo "== the control file is right =="
ctrl=$(dpkg-deb -f "$deb")
check "package" "$(printf '%s' "$ctrl" | awk '/^Package:/{print $2}')" "sd-cpp-cuda"
check "architecture" "$(printf '%s' "$ctrl" | awk '/^Architecture:/{print $2}')" "amd64"
printf '%s' "$ctrl" | grep -q 'sd-cpp (= 0.0.829)' \
    && ok "pins the base package exactly" || bad "pins the base package exactly"
printf '%s' "$ctrl" | grep -q 'cuda-cudart-13-3' \
    && ok "names cuda-cudart with the suffix" || bad "names cuda-cudart with the suffix"
printf '%s' "$ctrl" | grep -q 'libcublas-13-3' \
    && ok "names libcublas with the suffix" || bad "names libcublas with the suffix"

echo "== the cuda metapackage is never depended on =="
# It pulls nvidia-open, which fights a distribution-packaged driver, and
# cuda-libraries-13-3 would add about 1.2 GB to satisfy two libraries.
deps=$(printf '%s' "$ctrl" | sed -n 's/^Depends: //p')
printf '%s' "$deps" | tr ',' '\n' | sed 's/^ *//' | grep -qE '^cuda( |$)' \
    && bad "must never depend on the cuda metapackage" \
    || ok "does not depend on the cuda metapackage"
printf '%s' "$deps" | grep -q 'cuda-libraries' \
    && bad "must not depend on cuda-libraries" || ok "does not depend on cuda-libraries"

echo "== a different suffix flows through =="
# Captured first. Piped straight into grep -q, dpkg-deb can take SIGPIPE, and
# under pipefail that reads as no match whatever the field holds.
deb2=$(run "$src" 0.0.830 12-6 "$work/out2")
ctrl2=$(dpkg-deb -f "$deb2")
printf '%s' "$ctrl2" | grep -q 'cuda-cudart-12-6' \
    && ok "suffix 12-6 reaches Depends" || bad "suffix 12-6 reaches Depends"
printf '%s' "$ctrl2" | grep -q 'sd-cpp (= 0.0.830)' \
    && ok "version 0.0.830 reaches Depends" || bad "version 0.0.830 reaches Depends"

echo "== a malformed suffix is refused =="
run "$src" 0.0.829 13.3 "$work/out3" >/dev/null 2>&1
check "exit status on a dotted suffix" "$?" "2"
run "$src" 0.0.829 cuda13 "$work/out4" >/dev/null 2>&1
check "exit status on a non-numeric suffix" "$?" "2"

echo "== a bad version is refused =="
run "$src" master-829 13-3 "$work/out5" >/dev/null 2>&1
check "exit status on a non-numeric version" "$?" "2"

echo "== a missing object is refused =="
"$script" "$work/nosuch.so" "$work/libstable-diffusion.so" "$src" 0.0.829 13-3 \
    "$work/out6" >/dev/null 2>&1
check "exit status on a missing backend" "$?" "2"
"$script" "$work/libggml-cuda.so" "$work/nosuch.so" "$src" 0.0.829 13-3 \
    "$work/out7" >/dev/null 2>&1
check "exit status on a missing library" "$?" "2"

echo "== a missing licence text fails the build =="
for lic in thirdparty/cutlass/LICENSE.txt src/core/cuda/sageattention/LICENSE; do
    nolic="$work/nolic-${lic##*/}"
    make_src "$nolic"
    rm "$nolic/$lic"
    out=$(run "$nolic" 0.0.829 13-3 "$work/out8" 2>&1)
    check "exit status without $lic" "$?" "1"
    printf '%s' "$out" | grep -q "$lic" \
        && ok "names $lic" || bad "names $lic"
done

echo "== wrong argument count is refused =="
run "$src" 0.0.829 13-3 >/dev/null 2>&1
check "exit status with five arguments" "$?" "2"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
