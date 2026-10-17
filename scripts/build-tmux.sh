#!/bin/zsh
# Builds a self-contained tmux for the app to carry, so people don't have to install it themselves.
# libevent and utf8proc are linked in statically; the rest (ncurses, libSystem) ships with macOS.
# Output: build/tmux/tmux. Needs network access and Apple's command-line tools.
set -euo pipefail
cd "$(dirname "$0")/.."

TMUX_VERSION=3.8
LIBEVENT_VERSION=2.1.13-stable
UTF8PROC_VERSION=2.12.0

out=$PWD/build/tmux
work=$PWD/build/tmux-src
prefix=$work/prefix
[[ -x $out/tmux ]] && { echo "tmux already built: $out/tmux"; exit 0; }
rm -rf $work && mkdir -p $work $prefix/lib $prefix/include $out
cd $work
jobs=$(sysctl -n hw.ncpu)
export MACOSX_DEPLOYMENT_TARGET=14.0
# Treat functions newer than the deployment target as missing, so configure doesn't pick up
# something (like pipe2, macOS 27) that would crash on older macOS.
export CFLAGS="-O2 -arch arm64 -Werror=unguarded-availability-new -Werror=partial-availability"

fetch() { curl -fsSL "$1" | tar xz; }
fetch https://github.com/libevent/libevent/releases/download/release-$LIBEVENT_VERSION/libevent-$LIBEVENT_VERSION.tar.gz
fetch https://github.com/JuliaStrings/utf8proc/archive/refs/tags/v$UTF8PROC_VERSION.tar.gz
fetch https://github.com/tmux/tmux/releases/download/$TMUX_VERSION/tmux-$TMUX_VERSION.tar.gz

(cd libevent-$LIBEVENT_VERSION &&
  ac_cv_func_pipe2=no ac_cv_func_accept4=no ./configure --prefix=$prefix --enable-static --disable-shared --disable-openssl \
              --disable-samples --disable-libevent-regress --disable-debug-mode >/dev/null &&
  make -j$jobs >/dev/null && make install >/dev/null)

(cd utf8proc-$UTF8PROC_VERSION &&
  make -j$jobs CFLAGS="$CFLAGS" libutf8proc.a >/dev/null && cp libutf8proc.a $prefix/lib/ && cp utf8proc.h $prefix/include/)

(cd tmux-$TMUX_VERSION &&
  ./configure --enable-utf8proc --disable-jemalloc \
      LIBEVENT_CFLAGS="-I$prefix/include" LIBEVENT_LIBS="$prefix/lib/libevent_core.a" \
      LIBEVENT_CORE_CFLAGS="-I$prefix/include" LIBEVENT_CORE_LIBS="$prefix/lib/libevent_core.a" \
      LIBUTF8PROC_CFLAGS="-I$prefix/include" LIBUTF8PROC_LIBS="$prefix/lib/libutf8proc.a" >/dev/null &&
  make -j$jobs >/dev/null)

cp tmux-$TMUX_VERSION/tmux $out/tmux
strip $out/tmux
echo "Built $out/tmux"
otool -L $out/tmux
