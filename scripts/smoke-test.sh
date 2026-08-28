#!/usr/bin/env bash
# Verify an sd-cpp tree runs, that any backend resolves against it, and that the
# backend was actually selected rather than silently ignored.
#
# EXPECT_COMMIT is required. sd-cli reports no version, only a commit, printing
# "stable-diffusion.cpp version unknown, commit 0a565f2". Asserting a version
# string would either fail always or, written loosely, assert nothing. The
# commit from the resolved upstream tag is used instead, which is stronger,
# since it proves the packaged binary came from the release the resolver chose.
#
# EXPECT_BACKEND, when set, names a device prefix that must appear in
# --list-devices output. This is the assertion that matters most. A backend
# whose loader or driver is missing is ignored by ggml in total silence, with
# output byte-identical to a run without it, so printing the list and passing
# would prove nothing at all. Measured on 2026-08-28 by dropping
# libggml-vulkan.so beside the other objects on a machine with no
# libvulkan.so.1 present.
#
# BACKEND_STUB_DIR, when set, is appended to LD_LIBRARY_PATH. The CUDA job
# points it at the toolkit stub directory, which supplies libcuda.so.1 in place
# of a real driver.
set -uo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: $0 <base.deb> [backend.deb]" >&2
    exit 2
fi

if [ -z "${EXPECT_COMMIT:-}" ]; then
    echo "$0: EXPECT_COMMIT must be set to the upstream short sha" >&2
    echo "Without it this script cannot tell which build it is testing." >&2
    exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for deb in "$@"; do
    dpkg-deb -x "$deb" "$work/root"
done

tree="$work/root/usr/lib/sd-cpp"
bin="$work/root/usr/bin"
export LD_LIBRARY_PATH="$tree${BACKEND_STUB_DIR:+:$BACKEND_STUB_DIR}"

status=0

# Called through /usr/bin rather than from $tree. The binaries carry
# RUNPATH=$ORIGIN and reaching them through the symlink is what an installed
# package actually does, so testing in place would pass even with the symlink
# broken or the payload moved.
if [ ! -x "$bin/sd-cli" ]; then
    echo "no executable at usr/bin/sd-cli in the package" >&2
    ls -la "$bin" >&2 2>/dev/null || true
    exit 1
fi

echo "== sd-cli --version, through the /usr/bin symlink =="
if ! version_out=$("$bin/sd-cli" --version 2>&1); then
    echo "sd-cli could not run at all:" >&2
    printf '%s\n' "$version_out" >&2
    exit 1
fi
printf '%s\n' "$version_out"

if ! printf '%s' "$version_out" | grep -q "$EXPECT_COMMIT"; then
    echo "sd-cli does not report commit $EXPECT_COMMIT" >&2
    echo "The packaged binary is not from the release the resolver chose." >&2
    status=1
fi

if [ "$#" -eq 2 ]; then
    backend=""
    for candidate in libggml-vulkan.so libggml-cuda.so; do
        [ -f "$tree/$candidate" ] && backend=$candidate
    done

    # A backend package was passed but nothing landed in the tree, which would
    # leave every check below silently examining nothing.
    if [ -z "$backend" ]; then
        echo "a backend package was given but no backend landed in $tree" >&2
        ls -la "$tree" >&2
        exit 1
    fi

    echo "== resolving $backend against the base package =="
    # ldd -r performs relocation, so it reports undefined symbols rather than
    # only missing libraries. That is the ABI check this design rests on.
    if ! resolved=$(ldd -r "$tree/$backend" 2>&1); then
        echo "ldd could not process the backend at all:" >&2
        printf '%s\n' "$resolved" >&2
        exit 1
    fi
    # Print the whole list rather than only a verdict. The NCCL link in
    # llama-cpp-deb was found by reading a passing test's output.
    printf '%s\n' "$resolved"

    # The link that actually matters. A ggml backend declares libggml-base.so.0
    # and must bind to the base package's copy rather than to some other one on
    # the machine. This holds whatever else is missing from the environment.
    #
    # Conditional on the object declaring it, so the check describes the object
    # in front of it rather than assuming. Whether a real backend declares it at
    # all is asserted in the workflow, against the real object, since a
    # stand-in library in the unit tests cannot exercise that path.
    if readelf -d "$tree/$backend" 2>/dev/null \
         | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' | grep -q '^libggml-base\.so'; then
        if printf '%s\n' "$resolved" | grep -q "libggml-base.so.0 => $tree/"; then
            echo "libggml-base.so.0 resolved to the base package"
        else
            echo "the backend declares libggml-base.so.0 but did not bind to" >&2
            echo "the copy in this package:" >&2
            printf '%s\n' "$resolved" | grep 'libggml-base' | sed 's/^/  /' >&2
            status=1
        fi
    else
        echo "note: this object declares no libggml-base dependency"
    fi

    # Split missing libraries into the ones the target machine legitimately
    # supplies and everything else.
    permitted='libcuda\.so|libcudart\.so|libcublas\.so|libcublasLt\.so|libvulkan\.so'
    missing=$(printf '%s\n' "$resolved" | grep 'not found' || true)
    unexpected_missing=$(printf '%s\n' "$missing" | grep -vE "$permitted" || true)

    if [ -n "$(printf '%s' "$unexpected_missing" | tr -d '[:space:]')" ]; then
        echo "the backend is missing a library it needs:" >&2
        printf '%s\n' "$unexpected_missing" | sed 's/^/  /' >&2
        status=1
    fi

    # An undefined symbol is only evidence of an ABI fault when every library
    # resolved. Where a permitted one is absent, the loader reports every symbol
    # it would have provided as undefined, so the verdict would be meaningless.
    # Measured on 2026-08-28: with libvulkan.so.1 absent, ldd -r reports
    # vkGetInstanceProcAddr and three others undefined against a backend that is
    # in fact correct.
    if [ -n "$(printf '%s' "$missing" | tr -d '[:space:]')" ]; then
        echo "note: these libraries are absent here, so the undefined-symbol" >&2
        echo "verdict cannot be reached:" >&2
        printf '%s\n' "$missing" | sed 's/^/  /' >&2
        # REQUIRE_FULL_LINKAGE stops that from becoming a silent skip. Every CI
        # job sets it, having installed the loader or supplied a stub, so an
        # environment that quietly stopped testing fails instead.
        if [ -n "${REQUIRE_FULL_LINKAGE:-}" ]; then
            echo "REQUIRE_FULL_LINKAGE is set, so this is a failure rather" >&2
            echo "than an unjudged check. Install the loader, or supply it" >&2
            echo "through BACKEND_STUB_DIR, before running this." >&2
            status=1
        fi
    elif printf '%s\n' "$resolved" | grep -q 'undefined symbol'; then
        echo "the backend has undefined symbols against the base package" >&2
        status=1
    fi
fi

echo "== sd-cli --list-devices =="
devices_out=$("$bin/sd-cli" --list-devices 2>&1)
printf '%s\n' "$devices_out"

if [ -n "${EXPECT_BACKEND:-}" ]; then
    echo "== confirming ggml selected the $EXPECT_BACKEND backend =="
    if printf '%s\n' "$devices_out" | grep -qi "^${EXPECT_BACKEND}"; then
        printf 'found: %s\n' \
            "$(printf '%s\n' "$devices_out" | grep -i "^${EXPECT_BACKEND}")"
    else
        echo "no $EXPECT_BACKEND device was listed, so ggml fell back to CPU" >&2
        echo "A backend whose loader or driver is missing is ignored in" >&2
        echo "silence, producing output identical to a run without it, which" >&2
        echo "is exactly what this assertion exists to catch." >&2
        status=1
    fi
fi

exit "$status"
