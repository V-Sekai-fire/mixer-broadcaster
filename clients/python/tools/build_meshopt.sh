#!/bin/sh
# MIT. Builds meshoptimizer (MIT, Arseny Kapoulkine) at the commit remesh.elf pins into mixer/broadcaster/native/, the
# library meshlets.py loads. Usage: MESHOPTIMIZER_DIR=<checkout at 9e1f07b> tools/build_meshopt.sh
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/../mixer/broadcaster/native"
mkdir -p "$OUT"
case "$(uname)" in
  Darwin) NAME=libmeshoptimizer.dylib; FLAGS="-dynamiclib" ;;
  MINGW*|MSYS*|CYGWIN*) NAME=meshoptimizer.dll; FLAGS="-shared" ;;
  *) NAME=libmeshoptimizer.so; FLAGS="-shared -fPIC" ;;
esac
${CXX:-c++} -O2 -std=c++11 $FLAGS "$MESHOPTIMIZER_DIR"/src/*.cpp -o "$OUT/$NAME"
echo "built $OUT/$NAME"
