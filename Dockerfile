# Local build environment for the y623 firmware.
#
# Mirrors .github/workflows/build.yaml so a local build and a CI build see the
# same toolchain and the same packages. Pinned to linux/amd64 because the
# cross-toolchain ships as x86-64 Linux binaries (gcc/linux-x86/arm/...); on
# Apple Silicon this runs under Rosetta.
FROM --platform=linux/amd64 ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV SUNXI_TOOLCHAIN=/opt/yi/toolchain-sunxi-musl

RUN apt-get update && apt-get install -y --no-install-recommends \
        git unzip wget ca-certificates sudo build-essential \
        bison bisonc++ libbison-dev autoconf autotools-dev \
        automake libssl-dev zlib1g-dev libzzip-dev flex libfl-dev \
        yui-compressor closure-compiler optipng jpegoptim libtidy5deb1 node-less \
        sassc sass-spec libhtml-tidy-perl libxml2-utils rsync qemu-user-static \
    && rm -rf /var/lib/apt/lists/*

# Bake the cross-toolchain into its own layer so it is fetched once, not on
# every build. The upstream repo has no tags, so pin nothing and keep it
# shallow; CI clones the same default branch.
RUN git clone --depth 1 https://github.com/lindenis-org/lindenis-v536-prebuilt /tmp/lindenis \
    && mkdir -p ${SUNXI_TOOLCHAIN} \
    && cp -r /tmp/lindenis/gcc/linux-x86/arm/toolchain-sunxi-musl/toolchain ${SUNXI_TOOLCHAIN}/ \
    && rm -rf /tmp/lindenis

ENV STAGING_DIR=${SUNXI_TOOLCHAIN}
ENV PATH=${SUNXI_TOOLCHAIN}/toolchain/bin:${PATH}

WORKDIR /src
CMD ["/bin/bash"]
