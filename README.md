# BZPX Token

BZPX is the Blaze Phoenix token: a plain ERC-20 on Base.

| | |
|---|---|
| Chain | Base (8453) |
| Address | [`0x053D75c00FdD571538492e3B1686Bd963a0911A7`](https://basescan.org/token/0x053D75c00FdD571538492e3B1686Bd963a0911A7) |
| Supply | 1,000,000,000 BZPX, 18 decimals, minted once in the constructor |
| Source | [`src/BlazePhoenix.sol`](src/BlazePhoenix.sol), exact match on [Sourcify](https://repo.sourcify.dev/8453/0x053D75c00FdD571538492e3B1686Bd963a0911A7) |

## What the contract guarantees

- **Fixed supply.** The whole supply is minted once, to one recipient, in the constructor. There is no mint function, so the supply can only go down, through `burn` by a holder of their own tokens.
- **No owner.** No `Ownable`, no admin role, no pause, no blacklist, no upgrade proxy, no fee on transfer. Nobody can change balances, allowances or code after deployment.
- **Standard behaviour.** ERC-20 with the OpenZeppelin 5 custom errors, `increaseAllowance` / `decreaseAllowance`, and an infinite allowance (`type(uint256).max`) that is never spent.
- **No ETH.** The contract has no `receive` or `fallback`; sending ETH to it reverts.

The contract is about 120 lines and imports nothing.

## The deployed bytecode is this source

`test/Deployed.fork.t.sol` forks Base, compiles `src/BlazePhoenix.sol` with the deployment settings (solc 0.8.28, optimizer 200 runs, EVM `cancun`) and checks that the runtime bytecode at the token address is the same, byte for byte, apart from the trailing metadata hash, which depends on the file path.

## Build and test

Requires [Foundry](https://book.getfoundry.sh/).

```sh
git clone --recursive https://github.com/blazephoenixxyz-crypto/Blaze-Phoenix-Token
cd Blaze-Phoenix-Token
forge test                                          # unit, fuzz and invariant tests
BASE_RPC_URL=https://mainnet.base.org forge test    # adds the fork test against the live token
python3 scripts/mutants.py                          # every mutant must make the suite fail
```

| Suite | What it covers |
|---|---|
| `test/BlazePhoenix.t.sol` | metadata, mint, every revert with its exact error arguments, events, transfer, approve, transferFrom, allowance changes, burn, the missing admin surface; fuzz on transfers, allowances and burns |
| `test/BlazePhoenix.invariant.t.sol` | random call sequences: balances always add up to the supply, and the supply equals the mint minus the burns |
| `test/Deployed.fork.t.sol` | the live token on Base matches this source |
| `scripts/mutants.py` | 25 hand-written mutants of the source; each one must be killed by the suite |

CI runs all of them on every push and pull request.

## Earlier design

An omnichain (LayerZero OFT) version of BZPX was developed in this repository and never deployed. BZPX is a Base token only. That code is kept at the tag [`oft-archive`](https://github.com/blazephoenixxyz-crypto/Blaze-Phoenix-Token/tree/oft-archive).

## Security

See [SECURITY.md](SECURITY.md).

## License

MIT, as in the verified source.
