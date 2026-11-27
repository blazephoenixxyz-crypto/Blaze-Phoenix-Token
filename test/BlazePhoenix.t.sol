// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test, stdError} from "forge-std/Test.sol";
import {BlazePhoenix} from "../src/BlazePhoenix.sol";

contract BlazePhoenixTest is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    uint256 constant SUPPLY = 1_000_000_000 ether;

    BlazePhoenix t;
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        t = new BlazePhoenix(treasury);
    }

    // ─── constructor and metadata ───

    function test_metadata() public view {
        assertEq(t.name(), "Blaze Phoenix");
        assertEq(t.symbol(), "BZPX");
        assertEq(t.decimals(), 18);
    }

    function test_supplyMintedOnceToRecipient() public view {
        assertEq(t.totalSupply(), SUPPLY);
        assertEq(t.balanceOf(treasury), SUPPLY);
        assertEq(t.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsMint() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), alice, SUPPLY);
        new BlazePhoenix(alice);
    }

    function test_constructorRejectsZeroRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenix.ERC20InvalidReceiver.selector, address(0)));
        new BlazePhoenix(address(0));
    }

    /// No owner, no mint, no pause: these selectors do not exist, and there is no fallback.
    function test_noAdminSurface() public {
        bytes[5] memory calls = [
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("mint(address,uint256)", alice, 1),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("transferOwnership(address)", alice),
            abi.encodeWithSignature("burnFrom(address,uint256)", treasury, 1)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(t).call(calls[i]);
            assertFalse(ok);
        }
        (bool sent,) = address(t).call{value: 1}("");
        assertFalse(sent);
        assertEq(t.totalSupply(), SUPPLY);
    }

    // ─── transfer ───

    function test_transfer() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(treasury, alice, 100);
        vm.prank(treasury);
        assertTrue(t.transfer(alice, 100));
        assertEq(t.balanceOf(treasury), SUPPLY - 100);
        assertEq(t.balanceOf(alice), 100);
    }

    function test_transferWholeBalance() public {
        vm.prank(treasury);
        t.transfer(alice, SUPPLY);
        assertEq(t.balanceOf(treasury), 0);
        assertEq(t.balanceOf(alice), SUPPLY);
    }

    function test_transferZeroAmount() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(t.transfer(bob, 0));
        assertEq(t.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(treasury);
        t.transfer(treasury, 5);
        assertEq(t.balanceOf(treasury), SUPPLY);
    }

    function test_transferInsufficientBalance() public {
        vm.prank(treasury);
        t.transfer(alice, 10);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenix.ERC20InsufficientBalance.selector, alice, 10, 11));
        vm.prank(alice);
        t.transfer(bob, 11);
    }

    function test_transferToZeroReverts() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenix.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(treasury);
        t.transfer(address(0), 1);
    }

    // ─── approve and allowance ───

    function test_approve() public {
        vm.expectEmit(true, true, false, true);
        emit Approval(alice, bob, 7);
        vm.prank(alice);
        assertTrue(t.approve(bob, 7));
        assertEq(t.allowance(alice, bob), 7);
        vm.prank(alice);
        t.approve(bob, 3);
        assertEq(t.allowance(alice, bob), 3);
    }

    function test_approveZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenix.ERC20InvalidSpender.selector, address(0)));
        vm.prank(alice);
        t.approve(address(0), 1);
    }

    /// Unreachable on a live chain (msg.sender is never address(0)); pinned so the guard stays.
    function test_approveFromZeroReverts() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenix.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        t.approve(bob, 1);
    }

    function test_increaseAllowance() public {
        vm.startPrank(alice);
        t.approve(bob, 5);
        vm.expectEmit(true, true, false, true);
        emit Approval(alice, bob, 12);
        assertTrue(t.increaseAllowance(bob, 7));
        vm.stopPrank();
        assertEq(t.allowance(alice, bob), 12);
    }

    function test_increaseAllowanceOverflowReverts() public {
        vm.startPrank(alice);
        t.approve(bob, type(uint256).max);
        vm.expectRevert(stdError.arithmeticError);
        t.increaseAllowance(bob, 1);
        vm.stopPrank();
    }

    function test_decreaseAllowance() public {
        vm.startPrank(alice);
        t.approve(bob, 10);
        vm.expectEmit(true, true, false, true);
        emit Approval(alice, bob, 4);
        assertTrue(t.decreaseAllowance(bob, 6));
        assertEq(t.allowance(alice, bob), 4);
        t.decreaseAllowance(bob, 4);
        assertEq(t.allowance(alice, bob), 0);
        vm.stopPrank();
    }

    function test_decreaseAllowanceBelowZeroReverts() public {
        vm.startPrank(alice);
        t.approve(bob, 10);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenix.ERC20InsufficientAllowance.selector, bob, 10, 11));
        t.decreaseAllowance(bob, 11);
        vm.stopPrank();
    }

    // ─── transferFrom ───

    function test_transferFromSpendsAllowance() public {
        vm.prank(treasury);
        t.approve(alice, 50);
        vm.expectEmit(true, true, false, true);
        emit Transfer(treasury, bob, 30);
        vm.prank(alice);
        assertTrue(t.transferFrom(treasury, bob, 30));
        assertEq(t.allowance(treasury, alice), 20);
        assertEq(t.balanceOf(bob), 30);
        assertEq(t.balanceOf(treasury), SUPPLY - 30);
    }

    function test_transferFromExactAllowance() public {
        vm.prank(treasury);
        t.approve(alice, 30);
        vm.prank(alice);
        t.transferFrom(treasury, bob, 30);
        assertEq(t.allowance(treasury, alice), 0);
    }

    function test_transferFromInfiniteAllowanceNotSpent() public {
        vm.prank(treasury);
        t.approve(alice, type(uint256).max);
        vm.prank(alice);
        t.transferFrom(treasury, bob, 30);
        assertEq(t.allowance(treasury, alice), type(uint256).max);
    }

    function test_transferFromInsufficientAllowance() public {
        vm.prank(treasury);
        t.approve(alice, 5);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenix.ERC20InsufficientAllowance.selector, alice, 5, 6));
        vm.prank(alice);
        t.transferFrom(treasury, bob, 6);
    }

    function test_transferFromWithoutApprovalReverts() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenix.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        t.transferFrom(treasury, alice, 1);
    }

    function test_transferFromInsufficientBalance() public {
        vm.prank(bob);
        t.approve(alice, 100);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenix.ERC20InsufficientBalance.selector, bob, 0, 1));
        vm.prank(alice);
        t.transferFrom(bob, alice, 1);
    }

    function test_transferFromZeroSenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenix.ERC20InvalidSender.selector, address(0)));
        vm.prank(alice);
        t.transferFrom(address(0), bob, 0);
    }

    function test_transferFromToZeroReverts() public {
        vm.prank(treasury);
        t.approve(alice, 5);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenix.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        t.transferFrom(treasury, address(0), 5);
    }

    // ─── burn ───

    function test_burn() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(treasury, address(0), 1000);
        vm.prank(treasury);
        t.burn(1000);
        assertEq(t.totalSupply(), SUPPLY - 1000);
        assertEq(t.balanceOf(treasury), SUPPLY - 1000);
    }

    function test_burnEverything() public {
        vm.prank(treasury);
        t.burn(SUPPLY);
        assertEq(t.totalSupply(), 0);
        assertEq(t.balanceOf(treasury), 0);
    }

    function test_burnMoreThanBalanceReverts() public {
        vm.prank(treasury);
        t.transfer(alice, 10);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenix.ERC20InsufficientBalance.selector, alice, 10, 11));
        vm.prank(alice);
        t.burn(11);
    }

    // ─── fuzz ───

    function testFuzz_transferConserves(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != treasury);
        amount = bound(amount, 0, SUPPLY);
        uint256 before = t.balanceOf(to);
        vm.prank(treasury);
        t.transfer(to, amount);
        assertEq(t.balanceOf(treasury), SUPPLY - amount);
        assertEq(t.balanceOf(to), before + amount);
        assertEq(t.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 bal, uint256 amount) public {
        bal = bound(bal, 0, SUPPLY - 1);
        amount = bound(amount, bal + 1, type(uint256).max);
        vm.prank(treasury);
        t.transfer(alice, bal);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenix.ERC20InsufficientBalance.selector, alice, bal, amount));
        vm.prank(alice);
        t.transfer(bob, amount);
    }

    function testFuzz_transferFrom(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, type(uint256).max - 1);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(treasury);
        t.approve(alice, allowed);
        vm.prank(alice);
        if (amount > allowed) {
            vm.expectRevert(abi.encodeWithSelector(BlazePhoenix.ERC20InsufficientAllowance.selector, alice, allowed, amount));
            t.transferFrom(treasury, bob, amount);
            return;
        }
        t.transferFrom(treasury, bob, amount);
        assertEq(t.allowance(treasury, alice), allowed - amount);
        assertEq(t.balanceOf(bob), amount);
        assertEq(t.balanceOf(treasury), SUPPLY - amount);
    }

    function testFuzz_burn(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(treasury);
        t.burn(amount);
        assertEq(t.totalSupply(), SUPPLY - amount);
        assertEq(t.balanceOf(treasury), SUPPLY - amount);
    }

    function testFuzz_allowanceRoundTrip(uint256 a, uint256 b) public {
        a = bound(a, 0, type(uint256).max / 2);
        b = bound(b, 0, type(uint256).max / 2);
        vm.startPrank(alice);
        t.approve(bob, a);
        t.increaseAllowance(bob, b);
        assertEq(t.allowance(alice, bob), a + b);
        t.decreaseAllowance(bob, b);
        assertEq(t.allowance(alice, bob), a);
        vm.stopPrank();
    }
}
