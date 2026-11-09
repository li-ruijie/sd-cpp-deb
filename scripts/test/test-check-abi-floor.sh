#!/usr/bin/env bash
# Verify check-abi-floor.sh judges every object it is given against both limits.
#
# No object is built here, so the suite borrows system ones and measures them
# first, with objdump rather than readelf, so the expected values are not
# derived by the method under test. The cases therefore hold on any host.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../check-abi-floor.sh"
fail=0

ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=1; }

for tool in readelf objdump; do
    command -v "$tool" >/dev/null || { echo "$0: $tool is required" >&2; exit 1; }
done

# The highest version of a family that the undefined dynamic symbols of an
# object reference, which is what the loader will demand of the system.
needs() {  # needs <file> <GLIBC|GLIBCXX>, printing nothing when there are none
    { objdump -T "$1" 2>/dev/null || true; } \
        | awk '$0 ~ /\*UND\*/' \
        | { grep -oE "\\($2_[0-9.]+\\)" || true; } | tr -d '()' | sed "s/^$2_//" \
        | sort -uV | tail -1
}

# One step beneath a version, by decrementing its last field.
below() {  # below <version>
    local head=${1%.*} last=${1##*.}
    printf '%s.%s\n' "$head" "$((last - 1))"
}

# true when version $1 sorts strictly beneath version $2
older() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

# A C++ object, needing both families, and a C object needing glibc alone at a
# strictly lower version, so that a limit beneath the first still admits the
# second. Searched for rather than named, since paths differ between
# distributions.
candidates=$(ls -d /usr/bin/* /usr/lib/x86_64-linux-gnu/*.so.* 2>/dev/null)
cxx_obj='' c_obj=''
for f in $candidates; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    g=$(needs "$f" GLIBC) x=$(needs "$f" GLIBCXX)
    if [ -n "$g" ] && [ "${g##*.}" -gt 0 ] && [ -n "$x" ] && [ "${x##*.}" -gt 0 ]; then
        cxx_obj=$f
        break
    fi
done
if [ -n "$cxx_obj" ]; then
    for f in $candidates; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        g=$(needs "$f" GLIBC)
        if [ -n "$g" ] && [ -z "$(needs "$f" GLIBCXX)" ] \
            && older "$g" "$(below "$(needs "$cxx_obj" GLIBC)")"; then
            c_obj=$f
            break
        fi
    done
fi

# libstdc++ defines every GLIBCXX version and needs none. It is the object on
# which reading version definitions as needs would go wrong.
stdcxx=$(ls /usr/lib/x86_64-linux-gnu/libstdc++.so.6.* 2>/dev/null | head -1 || true)

for v in cxx_obj c_obj stdcxx; do
    if [ -z "${!v}" ]; then
        echo "$0: no suitable system object found for $v" >&2
        echo "The suite cannot test anything without one, so it fails rather" >&2
        echo "than passing vacuously." >&2
        exit 1
    fi
done

glibc=$(needs "$cxx_obj" GLIBC)
cxx=$(needs "$cxx_obj" GLIBCXX)
echo "borrowing $cxx_obj (GLIBC_$glibc, GLIBCXX_$cxx), $c_obj, and $stdcxx"

run() {  # run <glibc> <glibcxx> <file>..., setting $status and $out
    status=0
    out=$("$script" "$@" 2>&1) || status=$?
}

expect() {  # expect <label> <status>
    if [ "$status" = "$2" ]; then ok "$1"; else
        bad "$1 (expected exit $2, got $status)"; printf '%s\n' "$out" | sed 's/^/      /'
    fi
}

echo "== limits =="
run "$glibc" "$cxx" "$cxx_obj"
expect "exactly at both limits passes" 0
printf '%s' "$out" | grep -q '::notice::' \
    && bad "no notice at the limit" || ok "no notice at the limit"

run "$(below "$glibc")" "$cxx" "$cxx_obj"
expect "one step beneath the glibc floor fails" 1
printf '%s' "$out" | grep -qF "$cxx_obj" \
    && ok "the glibc failure names the file" || bad "the glibc failure names the file"
printf '%s' "$out" | grep -qF "GLIBC_$glibc" \
    && ok "the glibc failure names the version" || bad "the glibc failure names the version"

run "$glibc" "$(below "$cxx")" "$cxx_obj"
expect "one step beneath the libstdc++ floor fails" 1
printf '%s' "$out" | grep -qF "GLIBCXX_$cxx" \
    && ok "the libstdc++ failure names the version" || bad "the libstdc++ failure names the version"

run 99.0 99.0.0 "$cxx_obj"
expect "a fall passes" 0
printf '%s' "$out" | grep -q '::notice::' \
    && ok "a fall is reported as a notice" || bad "a fall is reported as a notice"

echo "== every file is read =="
# The fault of 2026-11-08. sd-cli sat at the limit and was the only file read,
# while the libraries beside it had risen above it.
run "$(below "$glibc")" "$cxx" "$c_obj" "$c_obj" "$cxx_obj"
expect "one file over the limit among several fails" 1
printf '%s' "$out" | grep -qF "$cxx_obj" \
    && ok "it names the file over the limit" || bad "it names the file over the limit"

echo "== version definitions are not needs =="
run "$(needs "$stdcxx" GLIBC)" 3.4.0 "$stdcxx"
expect "libstdc++ is not judged by the versions it defines" 0

run "$(needs "$c_obj" GLIBC)" 3.4.0 "$c_obj"
expect "an object needing no libstdc++ passes any libstdc++ limit" 0

echo "== arguments =="
run "$glibc" "$cxx"
expect "no file exits 2" 2
run "$glibc" "$cxx" /nonexistent/object.so
expect "a missing file exits 2" 2
notelf=$(mktemp); trap 'rm -f "$notelf"' EXIT
printf 'not an object\n' > "$notelf"
run "$glibc" "$cxx" "$notelf"
expect "a file that is not ELF exits 2" 2
run "GLIBC_$glibc" "$cxx" "$cxx_obj"
expect "a prefixed limit exits 2" 2

exit "$fail"
