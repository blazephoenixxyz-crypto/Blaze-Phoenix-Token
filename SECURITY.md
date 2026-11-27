# Security Policy

BZPX is a token contract. We welcome responsible disclosure from researchers.

## Reporting a vulnerability

**Please do not open a public issue for security reports.**

Report privately to **contact@blazephoenix.xyz**. Include:

- a description of the issue and its impact,
- the affected function and, where possible, `file:line`,
- a minimal proof of concept or the exact conditions to reproduce,
- your assessment of severity.

We aim to acknowledge a report within 72 hours and to keep you updated through triage.

## Scope

- `src/BlazePhoenix.sol`, deployed on Base at `0x053D75c00FdD571538492e3B1686Bd963a0911A7`.

## Out of scope

- The code at the `oft-archive` tag: it was never deployed.
- Third-party code: wallets, RPC providers, block explorers, GitHub.
- Anything that needs a compromised private key or the victim's own device.
- Known ERC-20 properties shared by every standard token, such as the `approve` ordering race that `increaseAllowance` and `decreaseAllowance` exist to avoid.
- Gas optimisations, style and informational notes.
- Theoretical reports without a proof of concept.
- Social engineering, phishing and physical attacks.
