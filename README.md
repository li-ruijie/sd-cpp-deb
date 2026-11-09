# stable-diffusion.cpp Debian packages

Builds `sd-cpp`, `sd-cpp-vulkan`, and `sd-cpp-cuda` for
[li-ruijie/apt](https://li-ruijie.github.io/apt/), from
[leejet/stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp).

`sd-cpp` carries `sd-cli` and `sd-server`, compiled from upstream source at each release tag.
`sd-cpp-vulkan` adds one ggml shared object from the same build. `sd-cpp-cuda` adds the CUDA
backend and also replaces `libstable-diffusion.so` with a CUDA build, through a `dpkg-divert` that
removing the package undoes, since upstream compiles its CUDA kernels for RoPE, INT8, and
attention into that library. Both backend packages may be installed together.

## Requirements

amd64 only, since upstream publishes no Linux arm64 build of any variant.

Debian trixie or newer, or a distribution of equivalent vintage. The packages are built on Ubuntu
24.04 and need glibc 2.38 and libstdc++ 13.1, which bookworm does not have. Where the requirement
is unmet apt refuses the install rather than the binary failing to start, since both floors are
declared.

## Install

```sh
sudo apt install sd-cpp
sudo apt install sd-cpp-vulkan      # AMD, Intel, or NVIDIA through Vulkan
sudo apt install sd-cpp-cuda        # NVIDIA, needs NVIDIA's CUDA apt repository
```

## Confirming a backend is in use

ggml ignores a backend whose loader or driver is missing, and it does so without reporting
anything, so a run that fell back to the CPU looks exactly like a run with no backend installed.
Check which devices were found:

```sh
sd-cli --list-devices
```

A CPU entry alone means no GPU backend loaded. Select between backends with `--backend`.

`sd-cpp-cuda` is the exception to that silence. Its build of `libstable-diffusion.so` links the
NVIDIA driver library `libcuda.so.1` directly, so on a machine without the driver `sd-cli` and
`sd-server` refuse to start with a loader error naming that library. Removing `sd-cpp-cuda`
returns them to the CPU.

## Models

None are included and none are downloaded at install time. They run to several gigabytes and come
from more than one hub, so fetching them is left to the user. The `huggingface-cli` package in the
same APT repository covers the Hugging Face half.

## Building

The whole build runs in GitHub Actions, weekly on Sunday at 09:00 UTC and on demand. Two compiles
run side by side, both in Ubuntu 24.04 containers at the upstream release tag.

- One compile uses upstream's own Linux Vulkan configuration, web interface included, and the base
  and Vulkan packages divide its output between them. Its `libstable-diffusion.so` carries Vulkan
  kernels, which register nothing without a Vulkan device.
- The other compiles the CUDA backend and a CUDA build of `libstable-diffusion.so`.

Upstream publishes prebuilt Linux archives, and until November 2026 the base and Vulkan packages
were repackaged from them. From `master-1050` those archives require glibc 2.43, since upstream
builds on GitHub's `ubuntu-latest`, which moved to 26.04. That excludes Debian trixie, at 2.41.

Before anything is published, every shipped object is checked against the declared glibc and
libstdc++ floors. The base and Vulkan packages are then smoke tested on Debian trixie itself.

## Licensing

Two separate things, which are easy to conflate.

The packaging in this repository, meaning the scripts, the workflow, and the tests, is AGPL-3.0,
matching the sibling builders and the APT repository itself. See `LICENSE`.

The packaged software is upstream's and stays under upstream's terms, which are MIT for
stable-diffusion.cpp and for ggml. Those texts ship inside every `sd-cpp` package at
`/usr/share/doc/sd-cpp/`, taken from the source tree at the release tag rather than copied here, so
they can never drift from the build they describe. The CUDA build of the library also compiles in
CUTLASS, under BSD-3-Clause, and SageAttention, under Apache-2.0, and `sd-cpp-cuda` ships both
texts at `/usr/share/doc/sd-cpp-cuda/`, taken from the source tree it was built from.

## Tests

Every suite runs in CI on each build, and locally under WSL. They need `bash`, `dpkg-deb`, `zip`,
`unzip`, `readelf`, and `objdump`, with no compiler and no network access.

```sh
for t in scripts/test/test-*.sh; do bash "$t" || echo "FAILED $t"; done
```
