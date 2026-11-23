#!/usr/bin/env bash
# LOCAL REHEARSAL of bzpx.sh against two anvil forks (Base and Robinhood). Nothing reaches the real chains:
# the script's RPCs point at 127.0.0.1; the anvil instances only READ state from the real chains (forks).
# The key used is anvil test account 0 (public, worthless), only on these local forks.
# Usage: bash rehearsal.sh <work-dir>
set -u
W="${1:?work dir}"
mkdir -p "$W"
D="$(cd "$(dirname "$0")/.." && pwd)"
NETWORK="$D/../config/network.json"
UP_BASE="${UP_BASE:-$(node -e "console.log(require('$NETWORK').chains.base.rpc)")}"
UP_RH="${UP_RH:-$(node -e "console.log(require('$NETWORK').chains.robinhood.rpc)")}"
P1=18545
P2=18546
anvil --fork-url "$UP_BASE" --port $P1 --quiet --retries 10 --fork-retry-backoff 2000 > "$W/anvil-base.log" 2>&1 &
A1=$!
anvil --fork-url "$UP_RH" --port $P2 --quiet --retries 10 --fork-retry-backoff 2000 > "$W/anvil-rh.log" 2>&1 &
A2=$!
trap 'kill $A1 $A2 2>/dev/null' EXIT
for p in $P1 $P2; do
  for _ in $(seq 1 60); do cast chain-id --rpc-url http://127.0.0.1:$p > /dev/null 2>&1 && break; sleep 1; done
done
echo "anvil base chainid $(cast chain-id --rpc-url http://127.0.0.1:$P1)  rh chainid $(cast chain-id --rpc-url http://127.0.0.1:$P2)"

export RPC_BASE=http://127.0.0.1:$P1 RPC_ROBINHOOD=http://127.0.0.1:$P2
export BZPX_ADDRESSES="$W/addresses.json" BZPX_LOG="$W/deploys.txt"
rm -f "$BZPX_ADDRESSES" "$BZPX_LOG"
TK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 # anvil account 0 (public)
B="$D/bzpx.sh"
n=0
step() { # description  expected_rc  input  args...
  local desc="$1" exp="$2" inp="$3"
  shift 3
  n=$((n + 1))
  printf '%s' "$inp" | bash "$B" "$@" > "$W/step$n.txt" 2>&1
  local rc=$?
  local res=$([ "$rc" = "$exp" ] && echo OK || echo FAILED)
  printf 'STEP %02d %-7s rc=%s (expected %s) %s\n' "$n" "$res" "$rc" "$exp" "$desc"
  [ "$res" = OK ] || { echo "---- output:"; tail -20 "$W/step$n.txt"; }
}
deliver() {
  n=$((n + 1))
  node "$D/rehearsal/deliver.mjs" "$1" > "$W/step$n.txt" 2>&1
  local rc=$?
  printf 'STEP %02d %-7s rc=%s deliver %s -> other chain (DVNs impersonated)\n' "$n" "$([ $rc = 0 ] && echo OK || echo FAILED)" "$rc" "$1"
  [ $rc = 0 ] || tail -20 "$W/step$n.txt"
}

step "status without deploy (incomplete = 3)" 3 "" status
RPC_BASE=http://127.0.0.1:$P2 step "deploy refuses the wrong chain's RPC" 1 "$TK"$'\nDEPLOY\n' deploy
step "deploy cancelled with the wrong word" 0 "$TK"$'\ndeploy\n' deploy
step "deploy with an invalid key refuses" 1 "123"$'\nDEPLOY\n' deploy
step "deploy on both chains" 0 "$TK"$'\nDEPLOY\n' deploy
step "repeated deploy does not redo" 0 "$TK"$'\nDEPLOY\n' deploy
# simulates a deploy that dropped midway (RPC died after sending): only the "pending" record remains
cp "$BZPX_ADDRESSES" "$W/addresses.bak"
node -e "const f='$BZPX_ADDRESSES',fs=require('fs'),e=JSON.parse(fs.readFileSync(f));e.base={pending:{expectedAddress:e.base.address,nonce:0,tx:e.base.tx}};fs.writeFileSync(f,JSON.stringify(e))"
step "status shows the pending deploy (incomplete)" 3 "" status
step "deploy resumes a pending one with a contract (does not redo)" 0 "$TK"$'\nDEPLOY\n' deploy
node -e "const e=require('$BZPX_ADDRESSES'),b=JSON.parse(require('fs').readFileSync('$W/addresses.bak','utf8'));if(e.base.address!==b.base.address)process.exit(1)" && echo "         resume: base address equals the original OK" || echo "         resume: base address FAILED"
node -e "const f='$BZPX_ADDRESSES',fs=require('fs'),e=JSON.parse(fs.readFileSync(f));e.robinhood={pending:{expectedAddress:'0x000000000000000000000000000000000000dEaD',nonce:0}};fs.writeFileSync(f,JSON.stringify(e))"
step "pending deploy with a spent nonce and no contract refuses" 1 "$TK"$'\nDEPLOY\n' deploy
cp "$W/addresses.bak" "$BZPX_ADDRESSES"
step "renounce before wire refuses" 1 "$TK"$'\nRENOUNCE FOREVER\n' renounce
step "send before wire fails (no peer, no DVNs)" 1 "$TK"$'\nSEND\n' send base 1
step "wire cancelled" 0 "$TK"$'\nno\n' wire
step "status still incomplete" 3 "" status
step "wire on both chains" 0 "$TK"$'\nWIRE\n' wire
step "status complete" 0 "" status
# a pinned DVN without code fails every command closed, by role (the gate alone compares the config with itself)
DVN=$(node -e "console.log(require('$NETWORK').chains.base.dvns[0])")
DVN_CODE=$(cast code "$DVN" --rpc-url "$RPC_BASE")
cast rpc anvil_setCode "$DVN" 0x --rpc-url "$RPC_BASE" > /dev/null
step "status refuses a pinned DVN without code" 1 "" status
grep -q "dvn .* $DVN has no code" "$W/step$n.txt" && echo "         no code: the fault names the DVN OK" || echo "         no code: the fault names the DVN FAILED"
cast rpc anvil_setCode "$DVN" "$DVN_CODE" --rpc-url "$RPC_BASE" > /dev/null
step "status complete again once the DVN has code" 0 "" status
step "repeated wire does nothing" 0 "$TK"$'\nWIRE\n' wire
step "send base->robinhood 1000" 0 "$TK"$'\nSEND\n' send base 1000
deliver base
step "send robinhood->base 400" 0 "$TK"$'\nSEND\n' send robinhood 400
deliver robinhood
step "status after round trip" 0 "" status
# an owner-set msgInspector would be frozen by the renounce: the gate refuses it and wire resets it
AB0=$(node -e "console.log(require('$BZPX_ADDRESSES').base.address)")
cast send "$AB0" 'setMsgInspector(address)' 0x00000000000000000000000000000000000000ff --private-key "$TK" --rpc-url "$RPC_BASE" > /dev/null
step "renounce refuses while a msgInspector is set" 1 "" renounce
step "wire resets the msgInspector" 0 "$TK"$'\nWIRE\n' wire
step "renounce cancelled" 0 "$TK"$'\nrenounce\n' renounce
step "renounce" 0 "$TK"$'\nRENOUNCE FOREVER\n' renounce
step "status after renounce" 0 "" status
step "wire after renounce refuses" 1 "$TK"$'\nWIRE\n' wire
step "repeated renounce does nothing" 0 "$TK"$'\nRENOUNCE FOREVER\n' renounce
step "send base->robinhood 5 after renounce" 0 "$TK"$'\nSEND\n' send base 5
deliver base
# F1: the gate reads the parked queue. Two CAP sends seconds apart: the second exceeds the refilled bucket and parks.
step "send base->robinhood CAP" 0 "$TK"$'\nSEND\n' send base 10000000
deliver base
step "send base->robinhood CAP again (parks)" 0 "$TK"$'\nSEND\n' send base 10000000
deliver base
step "status shows the parked packet (config still complete)" 0 "" status
grep -q "parked packets: [1-9]" "$W/step$n.txt" && echo "         parked: status prints the count OK" || echo "         parked: status does NOT print the count"
step "renounce refuses while a packet is parked" 1 "" renounce
grep -q "robinhood: parkedQueueEmpty" "$W/step$n.txt" && echo "         parked: the fault names the chain OK" || echo "         parked: the fault does NOT name the chain"
step "final status" 0 "" status

echo "---- addresses and log"
cat "$BZPX_ADDRESSES"
cat "$BZPX_LOG"
echo "---- final on-chain checks (cast, read-only on the local forks)"
AB=$(node -e "console.log(require('$BZPX_ADDRESSES').base.address)")
AR=$(node -e "console.log(require('$BZPX_ADDRESSES').robinhood.address)")
SB=$(cast call "$AB" 'totalSupply()(uint256)' --rpc-url "$RPC_BASE")
SR=$(cast call "$AR" 'totalSupply()(uint256)' --rpc-url "$RPC_ROBINHOOD")
echo "supply base $SB  rh $SR"
echo "owner base $(cast call "$AB" 'owner()(address)' --rpc-url "$RPC_BASE")  rh $(cast call "$AR" 'owner()(address)' --rpc-url "$RPC_ROBINHOOD")"
