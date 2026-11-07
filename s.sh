#!/bin/sh
# Runs the whole VIP on a BSC fork (sends nothing, no key) and prints every command, the amounts and the propose() arrays.
#   ./s.sh            current BSC block
#   ./s.sh xvs        also include the optional XVS grant
cd "$(dirname "$0")/contracts" || exit 1
export BSC_RPC_URL=${BSC_RPC_URL:-https://bsc-rpc.publicnode.com}
[ "$1" = xvs ] && export INCLUDE_XVS_GRANT=true
forge script script/SimulateVIP.s.sol --fork-url "$BSC_RPC_URL" --fork-block-number "$(cast block-number --rpc-url "$BSC_RPC_URL")"
