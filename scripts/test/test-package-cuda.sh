#!/usr/bin/env bash
# Cover package-cuda.sh, in particular that the CUDA suffix reaches Depends and
# that the cuda metapackage never does.
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

echo "== a well-formed call produces a .deb =="
deb=$("$script" "$work/libggml-cuda.so" 0.0.829 13-3 "$work/out" 2>"$work/err")
rc=$?
check "exit status" "$rc" "0"
[ "$rc" -eq 0 ] || sed 's/^/       /' "$work/err"
check "printed path" "$deb" "$work/out/sd-cpp-cuda_0.0.829_amd64.deb"

echo "== it ships exactly one file, in the right place =="
contents=$(dpkg-deb -c "$deb" | awk '$NF ~ /^\.\/usr/ && $1 !~ /^d/ {print $NF}')
check "file count" "$(printf '%s\n' "$contents" | grep -c .)" "1"
check "path" "$contents" "./usr/lib/sd-cpp/libggml-cuda.so"

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
deb2=$("$script" "$work/libggml-cuda.so" 0.0.830 12-6 "$work/out2")
dpkg-deb -f "$deb2" | grep -q 'cuda-cudart-12-6' \
    && ok "suffix 12-6 reaches Depends" || bad "suffix 12-6 reaches Depends"
dpkg-deb -f "$deb2" | grep -q 'sd-cpp (= 0.0.830)' \
    && ok "version 0.0.830 reaches Depends" || bad "version 0.0.830 reaches Depends"

echo "== a malformed suffix is refused =="
"$script" "$work/libggml-cuda.so" 0.0.829 13.3 "$work/out3" >/dev/null 2>&1
check "exit status on a dotted suffix" "$?" "2"
"$script" "$work/libggml-cuda.so" 0.0.829 cuda13 "$work/out4" >/dev/null 2>&1
check "exit status on a non-numeric suffix" "$?" "2"

echo "== a bad version is refused =="
"$script" "$work/libggml-cuda.so" master-829 13-3 "$work/out5" >/dev/null 2>&1
check "exit status on a non-numeric version" "$?" "2"

echo "== a missing backend is refused =="
"$script" "$work/nosuch.so" 0.0.829 13-3 "$work/out6" >/dev/null 2>&1
check "exit status on a missing backend" "$?" "2"

echo "== wrong argument count is refused =="
"$script" "$work/libggml-cuda.so" 0.0.829 13-3 >/dev/null 2>&1
check "exit status with three arguments" "$?" "2"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
