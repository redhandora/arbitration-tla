#!/usr/bin/env bash
# Each witness is an invariant claiming some state is unreachable.  TLC must
# VIOLATE it: the counterexample proves the path is reachable.
# Usage: [BASE=<Config>] ./check-witnesses.sh [Witness ...]   (default: all,
# BASE=Coverage)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
ALL="NoReconfirm NoLeader NoArbPush NoCommittedEntry NoDegradeCommitted \
NoUpgradeAfterDegrade NoReconfirmAfterDegrade NoGhostTruncate NoArbGhostTruncate \
NoArbPushBesideLeader NoArbCatchUp NoLearnerWindow"
WITNESSES="${*:-$ALL}"
mkdir -p out
rc=0
for w in $WITNESSES; do
  cfg="Witness_$w"
  { cat "${BASE:-Coverage}.cfg"; echo "INVARIANT $w"; } > "$cfg.cfg"
  ./run.sh "$cfg" > "out/$cfg.out" 2>&1
  if grep -q "Invariant $w is violated" "out/$cfg.out"; then
    n=$(grep -cE '^State [0-9]+:' "out/$cfg.out")
    echo "REACHED  $w  (trace of $n states)"
  else
    echo "MISSING  $w  (see out/$cfg.out)"
    rc=1
  fi
  rm -f "$cfg.cfg"
done
exit $rc
