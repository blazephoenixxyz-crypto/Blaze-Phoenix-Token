# BZPX Token

BZPX is the Blaze Phoenix token, built as a [LayerZero V2](https://docs.layerzero.network/) Omnichain Fungible Token (OFT). Tokens are burned on the source chain and minted on the destination chain, so the total supply across chains stays constant.

The contract in `src/BZPX.sol` is the standard `OFT` from `@layerzerolabs/oft-evm` 4.0.1 on OpenZeppelin Contracts 5.6.1, with two additions of its own:

1. **Fixed supply.** `TOTAL_SUPPLY` (1,000,000,000 BZPX, 18 decimals) is minted once, in the constructor, and only on `MAIN_CHAIN_ID` (Base, 8453). On every other chain the supply starts at zero and grows only with packets from peers, which burn the same amount on the source chain.
2. **Inbound cap.** The amount credited from one source endpoint id is limited to `INBOUND_CAP` (10,000,000 BZPX) per `INBOUND_WINDOW` (1 day); capacity refills linearly. A delivery above the available capacity never reverts: the packet is parked with a release time (FIFO per source eid) and anyone can claim it once released. The endpoint delegate can burn a parked packet, which refunds its capacity. A send above `INBOUND_CAP` reverts on the source chain.

The owner is both the `Ownable` owner and the LayerZero endpoint delegate. A full renounce needs `setDelegate(address(0))` first and then `renounceOwnership()`, because the delegate survives `renounceOwnership()`.

## Layout

| Path | Content |
|---|---|
| `src/BZPX.sol` | the token |
| `test/` | Foundry tests: unit, fuzz, invariant, gas, and fork tests against the real endpoints |
| `config/network.json` | chains, endpoint ids, libraries, executors, DVNs, confirmations, receive gas |
| `deploy/` | Node scripts for deployment, wiring, status checks and the renounce gate (`bzpx.sh`, `deploy.mjs`, `mesh.mjs`) |
| `deploy/rehearsal/` | local rehearsal against two anvil forks; nothing reaches a live chain |
| `deploy/BZPX.artifact.json` | compiled artifact the deploy script uses (regenerate with `node deploy/generate-artifact.mjs` after `forge build`) |
| `deploy/verification/` | standard-JSON input for block-explorer verification |

## Build and test

Requires [Foundry](https://book.getfoundry.sh/) and Node.js 20 or newer.

```sh
npm ci
forge build
forge test --no-match-contract Fork      # unit, fuzz, invariant and gas suites; no network needed
npm ci --prefix deploy
node --test deploy/test/*.test.mjs       # configuration checks for the deploy scripts
```

The fork suite (`test/BZPXFork.t.sol`) runs against the real endpoints. It reads the RPC URLs from `config/network.json`; override them with `RPC_BASE` and `RPC_ROBINHOOD`, and pin blocks with `BLOCK_BASE` and `BLOCK_RH`. It sends nothing and uses no keys.

To regenerate the verification input:

```sh
forge verify-contract <address> src/BZPX.sol:BZPX --show-standard-json-input > deploy/verification/BZPX.standard-input.json
```

## Deploying

`deploy/bzpx.sh` reads the private key from a hidden prompt (never from a file or the shell history) and passes it to `deploy/deploy.mjs` as an environment variable only for the duration of the command.

```sh
./deploy/bzpx.sh status                 # read-only
./deploy/bzpx.sh deploy
./deploy/bzpx.sh wire                   # explicit LayerZero config on every direction, plus peers
./deploy/bzpx.sh send base 1 robinhood  # test send
./deploy/bzpx.sh renounce               # read-only gate
./deploy/bzpx.sh renounce --execute     # irreversible
```

Rehearse first with `bash deploy/rehearsal/rehearsal.sh <work-dir>`.

The renounce gate reads every owner-settable slot that can be read without enumeration: the LayerZero config and peer of each direction in `config/network.json`, and `msgInspector` and `preCrime` on each chain. Peers and enforced options for endpoint ids outside `config/network.json` are not enumerable on-chain and are not covered.

## License

Business Source License 1.1, see [LICENSE](LICENSE). Change Date 2030-06-01, Change License GPL-2.0-or-later.

## Security

See [SECURITY.md](SECURITY.md).
