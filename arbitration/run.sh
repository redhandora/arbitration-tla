#!/usr/bin/env bash
# Model-check one config of Arbitration.tla.
# Usage: ./run.sh <Config> [extra TLC args]     e.g. ./run.sh Arbitration
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Java: $JAVA, else Homebrew's OpenJDK if present, else `java` on PATH.
if [ -z "${JAVA:-}" ]; then
  if [ -x /opt/homebrew/opt/openjdk/bin/java ]; then
    JAVA=/opt/homebrew/opt/openjdk/bin/java
  else
    JAVA=java
  fi
fi
JAR="${TLA2TOOLS:-$HERE/../tools/tla2tools.jar}"
CFG="${1:?usage: run.sh <Config> [extra TLC args]}"
shift
cd "$HERE"
# -deadlock: terminal states are expected (bounded model); we check
# invariants and properties, not deadlock freedom.
exec "$JAVA" -Xmx12g -XX:+UseParallelGC -cp "$JAR" tlc2.TLC \
  -deadlock -cleanup -workers 8 -metadir "states/$CFG" \
  -config "$CFG.cfg" "$@" Arbitration.tla
