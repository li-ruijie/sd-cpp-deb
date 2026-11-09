#!/usr/bin/env bash
# Fail if any object requires a newer glibc or libstdc++ than Depends declares.
#
# sd-cpp declares libc6 (>= 2.38) and libstdc++6 (>= 13.1), and the backends
# lean on those floors. A newer requirement anywhere in the payload breaks the
# package on the very systems those floors admit, with a loader error at start.
# Every object is read, since the requirement can rise in one library while
# the executables stay put. On 2026-11-08 sd-cli still required GLIBC_2.38
# while libggml-base and every CPU variant required GLIBC_2.43, and a check
# that read sd-cli alone passed.
#
# Only the version needs section is read. readelf -V also prints version
# definitions, and a library that defines GLIBCXX versions, as libstdc++
# itself does, would otherwise be judged by what it provides.
#
# A floor that has fallen is reported rather than failed. It only means the
# declared Depends is stricter than it needs to be.
set -euo pipefail

if [ "$#" -lt 3 ]; then
    echo "usage: $0 <max-glibc> <max-glibcxx> <file>..." >&2
    echo "for example: $0 2.38 3.4.32 build/bin/*" >&2
    exit 2
fi

max_glibc=$1
max_cxx=$2
shift 2

for limit in "$max_glibc" "$max_cxx"; do
    if ! printf '%s' "$limit" | grep -qE '^[0-9]+(\.[0-9]+)+$'; then
        echo "$0: limits are bare versions such as 2.38, got '$limit'" >&2
        exit 2
    fi
done

for f in "$@"; do
    [ -f "$f" ] || { echo "$0: no such file: $f" >&2; exit 2; }
    readelf -h "$f" >/dev/null 2>&1 || { echo "$0: not an ELF object: $f" >&2; exit 2; }
done

# true when version $1 sorts strictly above version $2
newer() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

# The highest version of one family in the version needs section of a file.
highest() {  # highest <file> <GLIBC|GLIBCXX>
    readelf -V -W "$1" \
        | awk '/^Version needs section/ { on = 1; next }
               /^Version (definition|symbols) section/ { on = 0 }
               on' \
        | { grep -oE "Name: $2_[0-9.]+" || true; } \
        | sed "s/^Name: $2_//" | sort -uV | tail -1
}

status=0
top_glibc='' top_cxx=''
for f in "$@"; do
    g=$(highest "$f" GLIBC)
    x=$(highest "$f" GLIBCXX)
    printf '  %-12s %-16s %s\n' "${g:+GLIBC_$g}" "${x:+GLIBCXX_$x}" "$f"

    if [ -n "$g" ] && newer "$g" "$max_glibc"; then
        echo "::error::$f requires GLIBC_$g, above the declared GLIBC_$max_glibc"
        status=1
    fi
    if [ -n "$x" ] && newer "$x" "$max_cxx"; then
        echo "::error::$f requires GLIBCXX_$x, above the declared GLIBCXX_$max_cxx"
        status=1
    fi

    if [ -n "$g" ] && { [ -z "$top_glibc" ] || newer "$g" "$top_glibc"; }; then top_glibc=$g; fi
    if [ -n "$x" ] && { [ -z "$top_cxx" ] || newer "$x" "$top_cxx"; }; then top_cxx=$x; fi
done

echo "highest across $# files: GLIBC_${top_glibc:-none} and GLIBCXX_${top_cxx:-none}"

if [ "$status" -ne 0 ]; then
    echo "Raise the floors in Depends in package-base.sh and package-vulkan.sh, and"
    echo "the limits passed here, only after confirming which suites still satisfy"
    echo "them. Debian trixie carries glibc 2.41, so anything above excludes it."
    exit 1
fi

if [ -n "$top_glibc" ] && newer "$max_glibc" "$top_glibc"; then
    echo "::notice::the glibc floor fell to GLIBC_$top_glibc, so Depends is stricter than needed"
fi
if [ -n "$top_cxx" ] && newer "$max_cxx" "$top_cxx"; then
    echo "::notice::the libstdc++ floor fell to GLIBCXX_$top_cxx, so Depends is stricter than needed"
fi
echo "every object is within GLIBC_$max_glibc and GLIBCXX_$max_cxx"
