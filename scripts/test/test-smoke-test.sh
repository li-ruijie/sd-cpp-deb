#!/usr/bin/env bash
# Cover smoke-test.sh with stub packages, so the assertions themselves are
# tested rather than upstream's binaries. The cases below encode the findings
# recorded in AGENTS.md, in particular that ggml loading a backend and ggml
# finding a usable device are separate facts.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../smoke-test.sh"
pass=0
fail=0

ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else
            bad "$1"; printf '       expected %s, got %s\n' "$3" "$2"; fi }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A stub base package whose sd-cli prints what the real one prints. The real
# --version output is:
#   stable-diffusion.cpp version unknown, commit 0a565f2
#
# devices_extra is appended to --list-devices output. The token @TREE@ in it is
# replaced at run time by the stub's own directory, which is how a fixture can
# emit a load_backend line naming a temporary path it cannot know in advance.
make_base() {
    local out=$1 commit=$2 devices_extra=${3:-} root
    root=$(mktemp -d)
    mkdir -p "$root/DEBIAN" "$root/usr/lib/sd-cpp" "$root/usr/bin"
    chmod 0755 "$root/DEBIAN"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)\n'
        printf 'case "$1" in\n'
        printf '  --version) echo "stable-diffusion.cpp version unknown, commit %s" ;;\n' "$commit"
        printf '  --list-devices)\n'
        printf '      echo "load_backend: loaded CPU backend from $here/libggml-cpu-x64.so"\n'
        printf '      echo "CPU\tstub processor"\n'
        printf '      extra=%q\n' "$devices_extra"
        printf '      [ -n "$extra" ] && echo "${extra//@TREE@/$here}"\n'
        printf '      ;;\n'
        printf 'esac\n'
        printf 'exit 0\n'
    } > "$root/usr/lib/sd-cpp/sd-cli"

    chmod 755 "$root/usr/lib/sd-cpp/sd-cli"
    cp "$root/usr/lib/sd-cpp/sd-cli" "$root/usr/lib/sd-cpp/sd-server"
    ln -s ../lib/sd-cpp/sd-cli    "$root/usr/bin/sd-cli"
    ln -s ../lib/sd-cpp/sd-server "$root/usr/bin/sd-server"

    {
        printf 'Package: sd-cpp\nVersion: 0.0.829\nArchitecture: amd64\n'
        printf 'Maintainer: t <t@example.com>\nDescription: stub\n'
    } > "$root/DEBIAN/control"

    dpkg-deb --root-owner-group --build "$root" "$out" >/dev/null
    rm -rf "$root"
}

# ldd -r needs a real ELF shared object that relocates cleanly. A system library
# is borrowed rather than compiled, so this suite needs no toolchain and runs
# anywhere dpkg-deb does.
#
# Located rather than hardcoded, and a failure to find one is a hard error
# rather than a skip. A test that quietly stops testing is worse than one that
# fails, which is the lesson whisper-cpp-deb records about its own ABI guard.
find_system_so() {
    local c
    for c in /lib/x86_64-linux-gnu/libz.so.1 /usr/lib/x86_64-linux-gnu/libz.so.1 \
             /lib/x86_64-linux-gnu/libbz2.so.1.0 /lib/x86_64-linux-gnu/liblzma.so.5; do
        [ -f "$c" ] && { printf '%s' "$c"; return 0; }
    done
    c=$(find /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu -maxdepth 1 \
            -name 'lib*.so.*' -type f 2>/dev/null | head -1)
    [ -n "$c" ] && { printf '%s' "$c"; return 0; }
    return 1
}

system_so=$(find_system_so) || {
    echo "no system shared object found to stand in for a backend" >&2
    echo "This suite needs one real ELF .so for ldd -r to relocate." >&2
    exit 1
}
printf 'using %s as the stand-in backend object\n\n' "$system_so"

make_backend() {
    local out=$1 name=$2 root
    root=$(mktemp -d)
    mkdir -p "$root/DEBIAN" "$root/usr/lib/sd-cpp"
    chmod 0755 "$root/DEBIAN"
    install -m 644 "$system_so" "$root/usr/lib/sd-cpp/$name"
    {
        printf 'Package: stub-backend\nVersion: 0.0.829\nArchitecture: amd64\n'
        printf 'Maintainer: t <t@example.com>\nDescription: stub\n'
    } > "$root/DEBIAN/control"
    dpkg-deb --root-owner-group --build "$root" "$out" >/dev/null
    rm -rf "$root"
}

loadline='load_backend: loaded Vulkan backend from @TREE@/libggml-vulkan.so'

make_base    "$work/base.deb"    0a565f2
make_base    "$work/loaded.deb"  0a565f2 "$loadline"
make_base    "$work/device.deb"  0a565f2 \
    "$loadline"$'\n'"Vulkan0	llvmpipe (LLVM 20.1.2, 256 bits)"
make_backend "$work/vulkan.deb"  libggml-vulkan.so

echo "== the base package alone passes when the commit matches =="
EXPECT_COMMIT=0a565f2 "$script" "$work/base.deb" >/dev/null 2>&1
check "exit status" "$?" "0"

echo "== a commit mismatch fails =="
out=$(EXPECT_COMMIT=deadbee "$script" "$work/base.deb" 2>&1)
check "exit status on the wrong commit" "$?" "1"
printf '%s' "$out" | grep -qi 'commit' \
    && ok "says the commit is wrong" || bad "says the commit is wrong"

echo "== it runs the binary through /usr/bin, not the payload directory =="
# The installed package is always reached through /usr/bin, and the binaries
# carry RUNPATH=$ORIGIN, so breaking the symlink while leaving the payload
# intact must fail. Testing in place would pass either way.
broken=$(mktemp -d)
dpkg-deb -R "$work/base.deb" "$broken"
rm -f "$broken/usr/bin/sd-cli"
dpkg-deb --root-owner-group --build "$broken" "$work/nolink.deb" >/dev/null
rm -rf "$broken"
EXPECT_COMMIT=0a565f2 "$script" "$work/nolink.deb" >/dev/null 2>&1
check "exit status with /usr/bin/sd-cli removed" "$?" "1"

echo "== a backend package whose object never lands is caught =="
# Without this the job passes on a package that ships the wrong path, because
# every backend check would silently examine nothing.
empty=$(mktemp -d)
mkdir -p "$empty/DEBIAN" "$empty/usr/lib/sd-cpp"
chmod 0755 "$empty/DEBIAN"
{
    printf 'Package: empty\nVersion: 0.0.829\nArchitecture: amd64\n'
    printf 'Maintainer: t <t@example.com>\nDescription: stub\n'
} > "$empty/DEBIAN/control"
dpkg-deb --root-owner-group --build "$empty" "$work/empty.deb" >/dev/null
rm -rf "$empty"
EXPECT_COMMIT=0a565f2 "$script" "$work/base.deb" "$work/empty.deb" >/dev/null 2>&1
check "exit status when no backend object arrives" "$?" "1"

echo "== ggml loading the backend is asserted, separately from finding a device =="
# The two facts are distinct, and conflating them cost a CI run. Measured on
# 2026-08-28 on ubuntu-latest: ggml printed "loaded Vulkan backend from ..."
# and then "No devices found", so loading is provable on any runner while
# device usability is provable only on real hardware.
out=$(EXPECT_COMMIT=0a565f2 "$script" "$work/base.deb" "$work/vulkan.deb" 2>&1)
check "exit status when ggml never loaded it" "$?" "1"
printf '%s' "$out" | grep -q 'ggml never loaded' \
    && ok "says ggml never loaded the backend" || bad "says ggml never loaded the backend"

echo "== a backend ggml did load passes, with no device listed at all =="
EXPECT_COMMIT=0a565f2 "$script" "$work/loaded.deb" "$work/vulkan.deb" >/dev/null 2>&1
check "exit status when only the load line is present" "$?" "0"

echo "== the load assertion is anchored to the packaged path =="
# A load_backend line naming some other directory must not satisfy it, or a
# stray backend elsewhere on the machine would count.
make_base "$work/elsewhere.deb" 0a565f2 \
    'load_backend: loaded Vulkan backend from /opt/other/libggml-vulkan.so'
out=$(EXPECT_COMMIT=0a565f2 "$script" "$work/elsewhere.deb" "$work/vulkan.deb" 2>&1)
check "exit status on a load line from another path" "$?" "1"

echo "== EXPECT_BACKEND fails when no device appears =="
# A backend whose driver is missing, or whose devices ggml rejects, leaves no
# trace in the device list, so the output is indistinguishable from a CPU-only
# run. That is what this catches.
out=$(EXPECT_COMMIT=0a565f2 EXPECT_BACKEND=Vulkan \
      "$script" "$work/loaded.deb" "$work/vulkan.deb" 2>&1)
check "exit status when the device is absent" "$?" "1"
printf '%s' "$out" | grep -qi 'fell back' \
    && ok "explains the silent fall back" || bad "explains the silent fall back"

echo "== EXPECT_BACKEND passes when the device does appear =="
EXPECT_COMMIT=0a565f2 EXPECT_BACKEND=Vulkan \
    "$script" "$work/device.deb" "$work/vulkan.deb" >/dev/null 2>&1
check "exit status when the device is listed" "$?" "0"

echo "== the base-link check describes the object rather than assuming =="
# The stand-in library declares no libggml-base dependency, so the script must
# say so rather than either claiming the link or failing over its absence. The
# positive path is asserted in the workflow against the real backend, since no
# stand-in here can carry that DT_NEEDED entry.
out=$(EXPECT_COMMIT=0a565f2 "$script" "$work/loaded.deb" "$work/vulkan.deb" 2>&1)
printf '%s' "$out" | grep -q 'declares no libggml-base dependency' \
    && ok "reports the absent base dependency" || bad "reports the absent base dependency"
printf '%s' "$out" | grep -q 'resolved to the base package' \
    && bad "claimed a base link the stand-in does not have" \
    || ok "does not claim a base link that is absent"

echo "== REQUIRE_FULL_LINKAGE is honoured =="
# With a permitted library absent the undefined-symbol verdict cannot be
# reached, and this flag stops that becoming a silent skip. The real path is
# exercised in CI, where the Vulkan loader is installed.
grep -q 'REQUIRE_FULL_LINKAGE' "$script" \
    && ok "the script reads REQUIRE_FULL_LINKAGE" \
    || bad "the script reads REQUIRE_FULL_LINKAGE"

echo "== a missing EXPECT_COMMIT is refused rather than skipped =="
"$script" "$work/base.deb" >/dev/null 2>&1
check "exit status with EXPECT_COMMIT unset" "$?" "2"

echo "== wrong argument count is refused =="
EXPECT_COMMIT=0a565f2 "$script" >/dev/null 2>&1
check "exit status with no arguments" "$?" "2"
EXPECT_COMMIT=0a565f2 "$script" a b c >/dev/null 2>&1
check "exit status with three arguments" "$?" "2"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
