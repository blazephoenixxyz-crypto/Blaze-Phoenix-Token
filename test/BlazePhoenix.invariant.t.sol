// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenix} from "../src/BlazePhoenix.sol";

/// Random sequences of every public mutating call among a closed set of holders.
contract Handler is Test {
    BlazePhoenix public immutable t;
    address[4] public actors;
    uint256 public burned;

    constructor(BlazePhoenix t_, address[4] memory actors_) {
        t = t_;
        actors = actors_;
    }

    function _actor(uint256 i) internal view returns (address) {
        return actors[i % actors.length];
    }

    function transfer(uint256 from, uint256 to, uint256 amount) external {
        address f = _actor(from);
        amount = bound(amount, 0, t.balanceOf(f));
        vm.prank(f);
        t.transfer(_actor(to), amount);
    }

    function approve(uint256 owner, uint256 spender, uint256 amount) external {
        vm.prank(_actor(owner));
        t.approve(_actor(spender), amount);
    }

    function increaseAllowance(uint256 owner, uint256 spender, uint256 amount) external {
        address o = _actor(owner);
        address s = _actor(spender);
        amount = bound(amount, 0, type(uint256).max - t.allowance(o, s));
        vm.prank(o);
        t.increaseAllowance(s, amount);
    }

    function decreaseAllowance(uint256 owner, uint256 spender, uint256 amount) external {
        address o = _actor(owner);
        address s = _actor(spender);
        amount = bound(amount, 0, t.allowance(o, s));
        vm.prank(o);
        t.decreaseAllowance(s, amount);
    }

    function transferFrom(uint256 spender, uint256 from, uint256 to, uint256 amount) external {
        address s = _actor(spender);
        address f = _actor(from);
        uint256 cap = t.balanceOf(f);
        uint256 allowed = t.allowance(f, s);
        if (allowed < cap) cap = allowed;
        amount = bound(amount, 0, cap);
        uint256 before = t.allowance(f, s);
        vm.prank(s);
        t.transferFrom(f, _actor(to), amount);
        uint256 expected = before == type(uint256).max ? before : before - amount;
        assertEq(t.allowance(f, s), expected);
    }

    function burn(uint256 who, uint256 amount) external {
        address w = _actor(who);
        amount = bound(amount, 0, t.balanceOf(w));
        vm.prank(w);
        t.burn(amount);
        burned += amount;
    }
}

contract BlazePhoenixInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    BlazePhoenix t;
    Handler h;
    address[4] actors;

    function setUp() public {
        actors = [makeAddr("a0"), makeAddr("a1"), makeAddr("a2"), makeAddr("a3")];
        t = new BlazePhoenix(actors[0]);
        h = new Handler(t, actors);
        targetContract(address(h));
    }

    /// Every token is held by one of the actors: the balances add up to the supply.
    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) sum += t.balanceOf(actors[i]);
        assertEq(sum, t.totalSupply());
    }

    /// The supply only moves down, and only by what was burned.
    function invariant_supplyIsMintMinusBurns() public view {
        assertEq(t.totalSupply(), SUPPLY - h.burned());
    }
}
