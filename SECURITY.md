# Security Policy

BZPX is a token contract. We take security seriously and welcome responsible disclosure from researchers.

## Reporting a vulnerability

**Please do not open a public issue for security reports.**

Report privately to **contact@blazephoenix.xyz**. Include:

- a description of the issue and its impact,
- the affected contract, script or file and, where possible, `file:line`,
- a minimal proof-of-concept or the exact conditions to reproduce,
- your assessment of severity.

We aim to acknowledge a report within 72 hours and to keep you updated through triage and remediation. Please give us a reasonable window to fix and deploy before any public disclosure.

## Scope

- `src/BZPX.sol`: the token, including the inbound cap and the parked-packet queue.
- The deployment and configuration scripts in `deploy/` and the values in `config/network.json`.

## Out of scope

- Third-party code: LayerZero contracts, OpenZeppelin, wallets, RPC providers, GitHub, unless our code consumes them unsafely.
- Anything that needs a compromised private key or the victim's own device.
- Outdated dependencies or versions without a working exploit.
- Gas optimisations, style and informational notes.
- Theoretical reports without a proof of concept.
- Social engineering, phishing and physical attacks.

## Testing rules

- Test on a fork or on a local network. Do not test against other users' funds on a live chain.
- Never send a private key or seed phrase to anyone, including us.
