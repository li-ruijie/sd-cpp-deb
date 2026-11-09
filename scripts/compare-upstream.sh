#!/usr/bin/env bash
# Fail if the build here has drifted from upstream's own Linux Vulkan build.
#
# sd-cpp and sd-cpp-vulkan were repackaged from upstream's prebuilt Linux
# archive until 2026-11-09, so whatever upstream built with, they carried.
# They are now compiled here from a copy of upstream's configure line and a
# fixed list of submodules, so a change upstream makes to its own build would
# otherwise reach no package and raise no error. Three things are compared,
# each against the same upstream tag.
#
#   files       the members of upstream's Linux Vulkan zip against the archive
#               built here, which catches a new tool or library
#   flags       the -D options on the configure line of upstream's
#               ubuntu-latest-cmake-vulkan job against those used here, which
#               catches a feature switched on without any new file
#   submodules  upstream's .gitmodules against the list fetched here, which
#               catches an optional dependency the clone would skip in silence
#
# Every difference is reported before exiting, so one run shows them all.
set -uo pipefail

if [ "$#" -ne 5 ]; then
    echo "usage: $0 <archive.zip> <upstream.zip> <upstream-tree> <flags> <submodules>" >&2
    echo "  flags and submodules are each one whitespace-separated string" >&2
    exit 2
fi

ours=$1
theirs=$2
tree=$3
our_flags=$4
our_subs=$5

for f in "$ours" "$theirs"; do
    [ -f "$f" ] || { echo "$0: no such file: $f" >&2; exit 2; }
done
[ -d "$tree" ] || { echo "$0: no such directory: $tree" >&2; exit 2; }

# Each exclusion is deliberate, and its reason lives here beside it.
#
# start-server.sh and start-server.bat look for sd-server and a models
# directory beside themselves, which suits an unpacked folder and not
# /usr/lib/sd-cpp, so the build here leaves them out of the archive.
excluded_files='start-server.sh start-server.bat'
# CUTLASS is compiled only into the CUDA build of libstable-diffusion.so, which
# the cuda job clones separately with every submodule.
excluded_subs='thirdparty/cutlass'

status=0
report() {  # report <heading> <only-upstream> <only-here>
    if [ -z "$2$3" ]; then
        echo "$1: identical"
        return
    fi
    status=1
    echo "::error::$1 differ from upstream's own Linux Vulkan build"
    [ -z "$2" ] || printf '  only upstream: %s\n' $2
    [ -z "$3" ] || printf '  only here:     %s\n' $3
}

# One item per line, sorted, with the exclusions removed.
normalise() {  # normalise <exclusions>, reading items on stdin
    local ex=" $1 "
    tr -s '[:space:]' '\n' | grep -v '^$' | while read -r item; do
        case "$ex" in *" $item "*) ;; *) printf '%s\n' "$item" ;; esac
    done | sort -u
}

difference() {  # difference <a> <b>, printing what a holds and b does not
    comm -23 <(printf '%s\n' "$1") <(printf '%s\n' "$2") | grep -v '^$' || true
}

# Files.
up=$(unzip -Z1 "$theirs" | normalise "$excluded_files")
here=$(unzip -Z1 "$ours" | normalise "")
report "files" "$(difference "$up" "$here")" "$(difference "$here" "$up")"

# Flags. The job block runs from its own key to the next key at the same
# indentation, and the configure line is the one invoking "cmake .." rather
# than "cmake --build". Quotes are removed from both sides, since upstream
# quotes '$ORIGIN' for its shell and the variable here holds it bare.
workflow="$tree/.github/workflows/build.yml"
if [ ! -f "$workflow" ]; then
    status=1
    echo "::error::no $workflow, so upstream's configure line cannot be read"
else
    lines=$(awk '/^  ubuntu-latest-cmake-vulkan:[[:space:]]*$/ { on = 1; next }
                 on && /^  [^[:space:]#][^:]*:[[:space:]]*$/ { on = 0 }
                 on && /cmake[[:space:]]+\.\./' "$workflow")
    count=$(printf '%s' "$lines" | grep -c . || true)
    if [ "$count" -ne 1 ]; then
        status=1
        echo "::error::expected one configure line in ubuntu-latest-cmake-vulkan, found $count"
        echo "Upstream has restructured its workflow, so its configure line cannot be read."
        [ -z "$lines" ] || printf '  %s\n' "$lines"
    else
        up=$(printf '%s' "$lines" | grep -oE -- "-D[A-Za-z0-9_]+=[^[:space:]]+" \
            | tr -d "'\"" | normalise "")
        here=$(printf '%s' "$our_flags" | tr -d "'\"" | normalise "")
        report "flags" "$(difference "$up" "$here")" "$(difference "$here" "$up")"
    fi
fi

# Submodules.
gitmodules="$tree/.gitmodules"
if [ ! -f "$gitmodules" ]; then
    status=1
    echo "::error::no $gitmodules in the upstream tree"
else
    up=$(sed -n 's/^[[:space:]]*path[[:space:]]*=[[:space:]]*//p' "$gitmodules" \
        | normalise "$excluded_subs")
    here=$(printf '%s' "$our_subs" | normalise "")
    report "submodules" "$(difference "$up" "$here")" "$(difference "$here" "$up")"
fi

if [ "$status" -ne 0 ]; then
    echo
    echo "Adopt each difference in the build job, or add it to the exclusions in"
    echo "$0 with the reason it does not apply here."
fi
exit "$status"
