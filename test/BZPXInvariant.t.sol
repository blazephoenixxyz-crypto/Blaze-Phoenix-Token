// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { SendParam, MessagingFee } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { BZPX } from "../src/BZPX.sol";
import { BZPXBase } from "./BZPX.t.sol";

interface IHelper {
    function verifyPackets(uint32 dstEid, bytes32 dstAddress) external;
}

/// @dev Handler: random sends in both directions among several actors, and out-of-order deliveries.
contract Handler is Test {
    BZPX public immutable a;
    BZPX public immutable b;
    IHelper public immutable helper;
    uint32 internal constant A_EID = 1;
    uint32 internal constant B_EID = 2;
    address[] internal actors;
    uint256 public inFlightAB; // burned on A, not yet minted on B
    uint256 public inFlightBA;
    uint256 public sends;
    uint256 public deliveries;

    constructor(BZPX a_, BZPX b_, IHelper h, address[] memory act) {
        a = a_;
        b = b_;
        helper = h;
        actors = act;
    }

    function sendRandom(bool aToB, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        BZPX src = aToB ? a : b;
        address sender = actors[fromSeed % actors.length];
        address recipient = actors[toSeed % actors.length];
        uint256 bal = src.balanceOf(sender);
        // room at the destination: inbound capacity left for this source minus what is already in flight
        uint256 room = (aToB ? b : a).inboundAvailable(aToB ? A_EID : B_EID) - (aToB ? inFlightAB : inFlightBA);
        if (bal < 1e12 || room < 1e12) return;
        amount = bound(amount, 1e12, bal < room ? bal : room);
        SendParam memory p = SendParam(aToB ? B_EID : A_EID, bytes32(uint256(uint160(recipient))), amount, 0, "", "", "");
        MessagingFee memory fee = src.quoteSend(p, false);
        vm.deal(sender, sender.balance + fee.nativeFee);
        vm.prank(sender);
        src.send{ value: fee.nativeFee }(p, fee, sender);
        uint256 sent = (amount / 1e12) * 1e12;
        if (aToB) inFlightAB += sent;
        else inFlightBA += sent;
        sends++;
    }

    /// @dev lets the inbound capacity refill (linear, up to one full window)
    function wait_(uint256 s) external {
        vm.warp(block.timestamp + bound(s, 0, 1 days));
    }

    function deliver(bool toB) external {
        if (toB) {
            helper.verifyPackets(B_EID, bytes32(uint256(uint160(address(b)))));
            inFlightAB = 0;
        } else {
            helper.verifyPackets(A_EID, bytes32(uint256(uint160(address(a)))));
            inFlightBA = 0;
        }
        deliveries++;
    }
}

contract BZPXInvariantTest is BZPXBase {
    Handler internal h;

    function setUp() public override {
        super.setUp();
        address[] memory act = new address[](3);
        act[0] = owner;
        act[1] = user;
        act[2] = makeAddr("third");
        h = new Handler(a, b, IHelper(address(this)), act);
        // spread some supply across the actors on both sides
        _send(a, B_EID, owner, user, CAP_ORACLE); // one packet carries at most the inbound cap
        _deliverPackets(B_EID, b);
        vm.prank(owner);
        a.transfer(makeAddr("third"), 100_000_000e18);
        targetContract(address(h));
    }

    /// The sum of the supplies on both chains never exceeds 1e9 and, together with what is in flight, is exactly 1e9.
    function invariant_sumOfSupplies() public view {
        uint256 sum_ = a.totalSupply() + b.totalSupply();
        assertLe(sum_, SUPPLY, "sum > 1e9");
        assertEq(sum_ + h.inFlightAB() + h.inFlightBA(), SUPPLY, "sum + in flight != 1e9");
    }

    /// Guards against a vacuous invariant: real sends and deliveries happened.
    function afterInvariant() external view {
        assertGt(h.sends(), 0, "no sends");
        assertGt(h.deliveries(), 0, "no deliveries");
    }
}
