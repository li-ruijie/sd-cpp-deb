#!/usr/bin/env bash
# Cover compare-upstream.sh, which holds the build here equal to upstream's own
# Linux Vulkan build in files, configure flags, and submodules.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../compare-upstream.sh"
pass=0
fail=0

ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Flags as the workflow here sets them, and the submodules it fetches.
flags='-DSD_BUILD_SHARED_LIBS=ON -DSD_VULKAN=ON -DGGML_NATIVE=OFF
-DCMAKE_INSTALL_RPATH=$ORIGIN'
subs='ggml examples/server/frontend thirdparty/libwebp'

zip_of() {  # zip_of <out.zip> <name>..., one small file per name
    local d; d=$(mktemp -d)
    for n in "${@:2}"; do printf '%s\n' "$n" > "$d/$n"; done
    ( cd "$d" && zip -q "$1" ./* )
    rm -rf "$d"
}

# An upstream tree, from a workflow body and a submodule list.
tree_of() {  # tree_of <dir> <vulkan-job-run-lines> <submodule-path>...
    local dir=$1 run=$2; shift 2
    mkdir -p "$dir/.github/workflows"
    cat > "$dir/.github/workflows/build.yml" <<EOF
jobs:
  ubuntu-latest-cmake:
    runs-on: ubuntu-latest
    steps:
      - name: Build
        run: |
          mkdir build
          cd build
          cmake .. -DSD_BUILD_SHARED_LIBS=ON -DGGML_NATIVE=OFF -DSOMETHING_ELSE=ON
          cmake --build . --config Release

  ubuntu-latest-cmake-vulkan:
    runs-on: ubuntu-latest
    steps:
      - name: Build
        run: |
$run

  windows-latest-cmake:
    runs-on: windows-2022
    steps:
      - name: Build
        run: |
          cmake .. -DSD_VULKAN=ON -DWINDOWS_ONLY=ON
EOF
    : > "$dir/.gitmodules"
    for p in "$@"; do
        printf '[submodule "%s"]\n\tpath = %s\n\turl = https://example.invalid/%s.git\n' \
            "$p" "$p" "$p" >> "$dir/.gitmodules"
    done
}

good_run="          mkdir build
          cd build
          cmake .. -DSD_BUILD_SHARED_LIBS=ON -DSD_VULKAN=ON -DGGML_NATIVE=OFF -DCMAKE_INSTALL_RPATH='\$ORIGIN'
          cmake --build . --config Release"

zip_of "$work/ours.zip"     sd-cli sd-server libggml-base.so libggml-vulkan.so ggml.txt
zip_of "$work/upstream.zip" sd-cli sd-server libggml-base.so libggml-vulkan.so ggml.txt \
                            start-server.sh start-server.bat
tree_of "$work/good" "$good_run" ggml examples/server/frontend thirdparty/libwebp thirdparty/cutlass

run() {  # run <label> <expected-status> <ours.zip> <upstream.zip> <tree> [flags] [subs]
    local label=$1 want=$2
    out=$("$script" "$3" "$4" "$5" "${6-$flags}" "${7-$subs}" 2>&1)
    status=$?
    if [ "$status" = "$want" ]; then ok "$label"; else
        bad "$label (expected exit $want, got $status)"; printf '%s\n' "$out" | sed 's/^/       /'
    fi
}

names() {  # names <label> <text>, asserting the last output names it
    printf '%s' "$out" | grep -qF -- "$2" && ok "$1" || bad "$1"
}

echo "== a faithful build passes =="
run "matching files, flags, and submodules" 0 "$work/ours.zip" "$work/upstream.zip" "$work/good"
# Upstream quotes '$ORIGIN' for its shell, and the variable here holds it bare.
# Both mean the same rpath, so quoting must not count as a difference.
# Only the Vulkan job is read. The CPU and Windows jobs carry other flags.

echo "== files =="
zip_of "$work/up-extra.zip" sd-cli sd-server libggml-base.so libggml-vulkan.so ggml.txt sd-bench
run "a file only upstream ships fails" 1 "$work/ours.zip" "$work/up-extra.zip" "$work/good"
names "it names the file" "sd-bench"
zip_of "$work/ours-extra.zip" sd-cli sd-server libggml-base.so libggml-vulkan.so ggml.txt extra.so
run "a file only this build ships fails" 1 "$work/ours-extra.zip" "$work/upstream.zip" "$work/good"
names "it names that file" "extra.so"

echo "== flags =="
tree_of "$work/newflag" "${good_run/-DGGML_NATIVE=OFF/-DGGML_NATIVE=OFF -DSD_NEW_FEATURE=ON}" \
    ggml examples/server/frontend thirdparty/libwebp
run "a flag only upstream sets fails" 1 "$work/ours.zip" "$work/upstream.zip" "$work/newflag"
names "it names the flag" "-DSD_NEW_FEATURE=ON"
tree_of "$work/changed" "${good_run/-DGGML_NATIVE=OFF/-DGGML_NATIVE=ON}" \
    ggml examples/server/frontend thirdparty/libwebp
run "a changed value fails" 1 "$work/ours.zip" "$work/upstream.zip" "$work/changed"
names "it names upstream's value" "-DGGML_NATIVE=ON"
run "a flag only this build sets fails" 1 "$work/ours.zip" "$work/upstream.zip" "$work/good" \
    "$flags -DEXTRA=ON"
names "it names that flag" "-DEXTRA=ON"

tree_of "$work/nojob" "          echo no configure line here" ggml
run "a Vulkan job with no configure line fails" 1 "$work/ours.zip" "$work/upstream.zip" "$work/nojob" \
    "$flags" ggml
names "it says the configure line could not be read" "configure line"
tree_of "$work/twolines" "$good_run
          cmake .. -DSD_VULKAN=ON" ggml examples/server/frontend thirdparty/libwebp
run "two configure lines fail" 1 "$work/ours.zip" "$work/upstream.zip" "$work/twolines"
mkdir -p "$work/nofile"; : > "$work/nofile/.gitmodules"
run "a tree with no workflow fails" 1 "$work/ours.zip" "$work/upstream.zip" "$work/nofile" \
    "$flags" ""

echo "== submodules =="
tree_of "$work/newsub" "$good_run" ggml examples/server/frontend thirdparty/libwebp \
    thirdparty/cutlass thirdparty/newlib
run "a submodule neither fetched nor excluded fails" 1 \
    "$work/ours.zip" "$work/upstream.zip" "$work/newsub"
names "it names the submodule" "thirdparty/newlib"
tree_of "$work/dropped" "$good_run" ggml examples/server/frontend
run "a fetched submodule upstream dropped fails" 1 "$work/ours.zip" "$work/upstream.zip" "$work/dropped"
names "it names that submodule" "thirdparty/libwebp"

echo "== every fault is reported, not only the first =="
run "files, flags, and submodules all differing fails" 1 \
    "$work/ours-extra.zip" "$work/up-extra.zip" "$work/newsub" "$flags -DEXTRA=ON"
for n in sd-bench extra.so -DEXTRA=ON thirdparty/newlib; do names "it names $n" "$n"; done

echo "== arguments =="
run "a missing archive exits 2" 2 "$work/nosuch.zip" "$work/upstream.zip" "$work/good"
run "a missing upstream archive exits 2" 2 "$work/ours.zip" "$work/nosuch.zip" "$work/good"
run "a missing tree exits 2" 2 "$work/ours.zip" "$work/upstream.zip" "$work/nosuch"
out=$("$script" "$work/ours.zip" "$work/upstream.zip" "$work/good" 2>&1); status=$?
[ "$status" = 2 ] && ok "three arguments exit 2" || bad "three arguments exit 2 (got $status)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
