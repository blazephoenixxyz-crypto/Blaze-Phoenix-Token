#!/usr/bin/env bash
# BZPX: deploy and configuration on the 6 chains of config/network.json (LayerZero V2 OFT).
# The private key is read with `read -s`: it is not shown on screen, not kept in shell history nor in a file.
# Usage: ./bzpx.sh status | deploy | wire | send <source> <amount> [chain] [recipient] | renounce [--execute]
set -u
cd "$(dirname "$0")" || exit 1
case "${1:-}" in
  status) exec node deploy.mjs status ;;
  deploy | wire | send | renounce) ;;
  *) echo "usage: ./bzpx.sh status | deploy | wire | send <source> <amount> [chain] [recipient] | renounce [--execute]" >&2; exit 64 ;;
esac
IFS= read -rs -p "Wallet private key (not shown on screen): " PK
echo >&2
export PK
node deploy.mjs "$@"
rc=$?
unset PK
exit $rc
