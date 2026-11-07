#!/bin/sh
# Runs every test (unit + BSC fork) against current BSC, one suite at a time, and prints a summary.
#   ./t.sh                 all suites
#   ./t.sh VenusRescue     only suites whose name contains "VenusRescue"
cd "$(dirname "$0")/contracts" || exit 1
export BSC_RPC_URL=${BSC_RPC_URL:-https://bsc-rpc.publicnode.com}
export FORK_BLOCK=${FORK_BLOCK:-$(cast block-number --rpc-url "$BSC_RPC_URL")}
echo "== BSC block $FORK_BLOCK via $BSC_RPC_URL"
forge build -q || exit 1
summary=""
fail=0
for s in RakeDepositorsClaimTest DeployRakeDepositorsClaimTest DeployVenusMarketRescuePatchesTest \
         VenusMarketRescuePatchTest PostRescueRakeFarmSafetyTest VenusRescueProposalTest; do
  case "$s" in *"$1"*) ;; *) continue ;; esac
  echo
  echo "== $(date +%H:%M:%S) $s ..."
  # Public RPCs drop calls under load (shows as "EvmError: Revert"); retry, the fork cache makes it quick.
  res="FAIL"
  for try in 1 2 3; do
    if forge test --match-contract "^$s\$" -vv; then res="PASS"; break; fi
    [ $try -lt 3 ] && echo "== $(date +%H:%M:%S) $s failed, retrying ($try/2) ..."
  done
  [ $res = PASS ] || fail=1
  summary="$summary$res  $s
"
done
echo
echo "== Summary (BSC block $FORK_BLOCK)"
printf "%s" "$summary"
[ $fail = 0 ] && echo "== ALL PASSED" || echo "== SOME FAILED"
exit $fail
