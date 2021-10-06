FROM alpine:latest AS builder

ARG LLVM_VERSION=13.0.0

# install packages required for build
RUN apk add git g++ python3-dev cmake ninja git linux-headers libexecinfo-dev binutils-dev libedit-dev swig xz-dev ncurses-dev libxml2-dev

# setup build environment
RUN mkdir /home/build

# download LLVM
RUN cd /home/build && git clone --depth 1 https://github.com/microblink/llvm-project --branch microblink-llvm-${LLVM_VERSION}

# RUN yum -y install bzip2 zip unzip libedit-devel libxml2-devel ncurses-devel python-devel swig python3

# build LLVM in two stages
RUN cd /home/build && \
    mkdir llvm-build-stage1 && \
    cd llvm-build-stage1 && \
    cmake -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        # For some weird reason building libc++abi.so.1 with LTO enabled creates a broken binary
        -DLLVM_ENABLE_LTO=OFF \
        -DLLVM_ENABLE_PROJECTS="clang;compiler-rt;libunwind;libcxx;libcxxabi;lld" \
        -DLLVM_TARGETS_TO_BUILD="Native" \
        -DLLVM_BINUTILS_INCDIR="/usr/include" \
        -DLLVM_ENABLE_EH=ON \
        -DLLVM_ENABLE_RTTI=ON \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DCLANG_DEFAULT_RTLIB=compiler-rt \
        -DCLANG_DEFAULT_CXX_STDLIB=libc++ \
        -DCLANG_DEFAULT_UNWINDLIB=libgcc \
        -DCLANG_DEFAULT_LINKER=lld \
        -DLLVM_DEFAULT_TARGET_TRIPLE="x86_64-alpine-linux-musl" \
        -DLIBCXXABI_ENABLE_STATIC_UNWINDER=ON \
        -DLIBCXXABI_USE_LLVM_UNWINDER=YES \
        -DLIBCXX_ABI_VERSION=2 \
        -DLIBCXX_ABI_UNSTABLE=ON \
        -DLIBCXX_HAS_MUSL_LIBC=ON \
        -DLIBCXX_ENABLE_EXCEPTIONS=OFF \
        -DLIBCXX_ENABLE_RTTI=ON \
        ../llvm-project/llvm && \
    ninja clang compiler-rt libunwind.so libc++.so lib/LLVMgold.so llvm-ar llvm-ranlib llvm-nm lld

# second stage - use built clang to build entire LLVM

ENV CC="/home/build/llvm-build-stage1/bin/clang"    \
    CXX="/home/build/llvm-build-stage1/bin/clang++" \
    LD_LIBRARY_PATH="/home/build/llvm-build-stage1/lib"

# required for building openmp
RUN apk add perl

RUN cd /home/build && \
    mkdir llvm-build-stage2 && \
    cd llvm-build-stage2 && \
    cmake -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_ENABLE_PROJECTS="clang;libcxx;libcxxabi;lld;lldb;compiler-rt;libunwind;clang-tools-extra;openmp;parallel-libs;polly" \
        -DLLVM_TARGETS_TO_BUILD="Native" \
        # TODO: enable LTO once finished (required in order to have LTO-enabled libc++ and friends)
        -DLLVM_ENABLE_LTO=ON \
        -DLLVM_BINUTILS_INCDIR="/usr/include" \
        -DLLVM_USE_LINKER="lld" \
        -DCMAKE_C_FLAGS="-B/usr/local" \
        -DCMAKE_CXX_FLAGS="-B/usr/local" \
        -DCMAKE_AR="/home/build/llvm-build-stage1/bin/llvm-ar" \
        -DCMAKE_RANLIB="/home/build/llvm-build-stage1/bin/llvm-ranlib" \
        -DCMAKE_NM="/home/build/llvm-build-stage1/bin/llvm-nm" \
        -DLLVM_ENABLE_EH=OFF \
        -DLLVM_ENABLE_RTTI=OFF \
        -DCMAKE_INSTALL_PREFIX=/home/llvm \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DCLANG_DEFAULT_LINKER=lld \
        -DCLANG_DEFAULT_RTLIB=compiler-rt \
        -DCLANG_DEFAULT_CXX_STDLIB=libc++ \
        -DCLANG_DEFAULT_UNWINDLIB=libunwind \
        -DLLVM_DEFAULT_TARGET_TRIPLE="x86_64-alpine-linux-musl" \
        -DLIBCXX_USE_COMPILER_RT=YES \
        -DLIBCXXABI_ENABLE_STATIC_UNWINDER=ON \
        -DLIBCXXABI_USE_LLVM_UNWINDER=YES \
        -DLIBCXXABI_USE_COMPILER_RT=YES \
        -DLIBCXX_ABI_VERSION=2 \
        -DLIBCXX_ABI_UNSTABLE=ON \
        -DLIBCXX_HAS_MUSL_LIBC=ON \
        -DLIBCXX_ENABLE_EXCEPTIONS=OFF \
        -DLIBCXX_ENABLE_RTTI=ON \
        -DLLDB_ENABLE_PYTHON=NO \
        ../llvm-project/llvm && \
    ninja

# install everything
RUN cd /home/build/llvm-build-stage2 && \
    ninja install

# Stage 2, copy artifacts to new image and prepare environment

FROM alpine:latest
COPY --from=builder /home/llvm /usr/local/

# built clang and friends depend on execinfo and use libgcc_s as unwinder (but the binaries they produce use libunwind)
RUN apk add --no-cache libexecinfo libgcc libatomic ncurses libc-dev libxml2

ENV CC="/usr/local/bin/clang"           \
    CXX="/usr/local/bin/clang++"        \
    AR="/usr/local/bin/llvm-ar"         \
    NM="/usr/local/bin/llvm-nm"         \
    RANLIB="/usr/local/bin/llvm-ranlib" \
    LD_LIBRARY_PATH="/usr/local/lib"
