#!/usr/bin/env python3
"""Mutation check: each mutant below must make `forge test` fail.

Every mutant is one exact text replacement in src/BlazePhoenix.sol that must match exactly once.
The source is restored after every run. Exit 1 if any mutant survives or does not apply.
"""
import pathlib
import subprocess
import sys

SRC = pathlib.Path("src/BlazePhoenix.sol")

MUTANTS = [
    ("zero recipient accepted", "if (recipient == address(0)) revert", "if (false) revert"),
    ("supply off by one token", "1_000_000_000 * 10 ** 18", "1_000_000_001 * 10 ** 18"),
    ("decimals", "decimals = 18", "decimals = 6"),
    ("symbol", '"BZPX"', '"BZPZ"'),
    ("zero sender accepted", "if (from == address(0)) revert", "if (false) revert"),
    ("zero receiver accepted", "if (to   == address(0)) revert", "if (false) revert"),
    ("balance check off by one", "if (fromBal < amount) revert", "if (fromBal + 1 < amount) revert"),
    ("receiver credited wrong", "_balances[to]   += amount;", "_balances[to]   = amount;"),
    ("sender not debited", "_balances[from]  = fromBal - amount;", "_balances[from]  = fromBal;"),
    ("transfer event dropped", "emit Transfer(from, to, amount);", ""),
    ("transfer returns false", "_transfer(msg.sender, to, amount);\n        return true;", "_transfer(msg.sender, to, amount);\n        return false;"),
    ("zero spender accepted", "if (spender == address(0)) revert", "if (false) revert"),
    ("zero approver accepted", "if (owner_  == address(0)) revert", "if (false) revert"),
    ("approval event dropped", "emit Approval(owner_, spender, amount);", ""),
    ("infinite allowance spent", "if (current != type(uint256).max) {", "if (true) {"),
    ("allowance never spent", "_allowances[owner_][spender] = current - amount; }", "_allowances[owner_][spender] = current; }"),
    ("allowance check off by one", "if (current < amount)\n", "if (current + 1 < amount)\n"),
    ("transferFrom skips allowance", "_spendAllowance(from, msg.sender, amount);\n", ""),
    ("increase subtracts", "+ addedValue);", "- addedValue);"),
    ("decrease check loosened", "if (subtractedValue > current)", "if (subtractedValue > current + 1)"),
    ("decrease does nothing", "_approve(msg.sender, spender, current - subtractedValue);", "_approve(msg.sender, spender, current);"),
    ("burn keeps supply", "_totalSupply         -= amount;", ""),
    ("burn keeps balance", "_balances[msg.sender] = bal - amount;", "_balances[msg.sender] = bal;"),
    ("burn check off by one", "if (bal < amount) revert", "if (bal + 1 < amount) revert"),
    ("burn event dropped", "emit Transfer(msg.sender, address(0), amount);", ""),
]


def main() -> int:
    original = SRC.read_text()
    bad = []
    try:
        for name, old, new in MUTANTS:
            if original.count(old) != 1:
                bad.append(f"{name}: pattern matches {original.count(old)} times")
                continue
            SRC.write_text(original.replace(old, new))
            r = subprocess.run(
                ["forge", "test", "--no-match-contract", "Fork"],
                capture_output=True, text=True,
            )
            status = "killed" if r.returncode != 0 else "SURVIVED"
            print(f"{status:8}  {name}")
            if r.returncode == 0:
                bad.append(f"{name}: survived")
    finally:
        SRC.write_text(original)
    print(f"{len(MUTANTS) - len(bad)}/{len(MUTANTS)} killed")
    for b in bad:
        print("FAIL", b)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
