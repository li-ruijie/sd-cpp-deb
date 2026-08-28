# stable-diffusion.cpp Debian packages

Builds `sd-cpp`, `sd-cpp-vulkan`, and `sd-cpp-cuda` for
[li-ruijie/apt](https://li-ruijie.github.io/apt/), from
[leejet/stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp).

`sd-cpp` carries `sd-cli` and `sd-server`, repackaged from the upstream Linux release archive.
The two backend packages each add one ggml shared object, and both may be installed together.

## Requirements

amd64 only, since upstream publishes no Linux arm64 build of any variant.

Debian trixie or newer, or a distribution of equivalent vintage. The upstream archives are built
on Ubuntu 24.04 and need glibc 2.38 and libstdc++ 13.1, which bookworm does not have. Where the
requirement is unmet apt refuses the install rather than the binary failing to start, since both
floors are declared.

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

## Models

None are included and none are downloaded at install time. They run to several gigabytes and come
from more than one hub, so fetching them is left to the user. The `huggingface-cli` package in the
same APT repository covers the Hugging Face half.

## Building

The whole build runs in GitHub Actions, weekly on Sunday at 09:00 UTC and on demand. Only the CUDA
backend is compiled. The base package repackages upstream's prebuilt Linux archive, and the Vulkan
package extracts one shared object from upstream's prebuilt Vulkan archive after asserting that
archive is otherwise byte-identical to the CPU one.

## Licensing

Two separate things, which are easy to conflate.

The packaging in this repository, meaning the scripts, the workflow, and the tests, is AGPL-3.0,
matching the sibling builders and the APT repository itself. See `LICENSE`.

The packaged software is upstream's and stays under upstream's terms, which are MIT for
stable-diffusion.cpp and for ggml. Those texts ship inside every `sd-cpp` package at
`/usr/share/doc/sd-cpp/`, taken from the release archive rather than copied here, so they can never
drift from the build they describe.

## Tests

Every suite runs in CI on each build, and locally under WSL. They need `bash`, `dpkg-deb`, `zip`,
`unzip`, and `gcc`, with no network access.

```sh
for t in scripts/test/test-*.sh; do bash "$t" || echo "FAILED $t"; done
```
