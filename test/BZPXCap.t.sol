// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Origin } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { SendParam, MessagingFee } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { BZPX } from "../src/BZPX.sol";
import { BZPXBase } from "./BZPX.t.sol";
import { IBZPXPark } from "./BZPXQueue.t.sol";

/// @notice Own-logic guards of BZPX: supply minted only on the main chain whatever the deploy arguments, and the
///         inbound cap per source endpoint id. A delivery is simulated as the endpoint (what a forged packet
///         attested by the configured DVNs looks like to the OApp). The oracle constants are the test's own.
/// @dev Red on c08bfdd (pre-fix contract): every test in this file fails there. The three inbound-cap tests
///      forgedFloodBounded, boundaryAndLinearRefill and parkedPacketClaimableAfterRefill are red on 5b5b5f6 (a
///      delivery above the available capacity reverted there; now it is parked and claimable from its release time).
contract BZPXCapTest is BZPXBase {
    uint256 internal constant CAP = 10_000_000e18; // oracle, not read from the contract
    uint256 internal constant WINDOW = 1 days;
    uint256 internal constant UNIT = 1e12; // 18 local decimals - 6 shared decimals
    bytes4 internal constant CAP_ERR = bytes4(keccak256("InboundCapExceeded(uint32,uint256,uint256)"));
    bytes4 internal constant NOT_FOUND = bytes4(keccak256("ParkedNotFound(bytes32)"));
    bytes4 internal constant NOT_RELEASED = bytes4(keccak256("ParkedNotReleased(bytes32,uint64)"));

    uint64 internal nonce;

    /// @dev Delivers a packet to `dst` from `srcEid` as the endpoint would after DVN verification.
    function _deliver(BZPX dst, uint32 srcEid, address peer, address to, uint256 amountLD)
        internal
        returns (uint64 n, bytes32 guid)
    {
        (bytes memory message, ) = OFTMsgCodec.encode(addressToBytes32(to), uint64(amountLD / UNIT), "");
        n = ++nonce;
        guid = keccak256(abi.encode(n));
        vm.prank(address(dst.endpoint()));
        dst.lzReceive(Origin(srcEid, addressToBytes32(peer), n), guid, message, address(0), "");
    }

    /// @dev The parked packet a delivery from `a` to `b` must leave, built from the test's own values.
    function _parkedAB(uint64 n, bytes32 guid, address to, uint256 amountLD, uint256 releaseAt)
        internal
        view
        returns (IBZPXPark.ParkedPacket memory)
    {
        return IBZPXPark.ParkedPacket(A_EID, addressToBytes32(address(a)), n, guid, to, amountLD, uint64(releaseAt), "");
    }

    function _isParked(IBZPXPark.ParkedPacket memory p) internal view returns (bool) {
        return IBZPXPark(address(b)).parked(keccak256(abi.encode(p)));
    }

    function _claimRevertsNotReleased(IBZPXPark.ParkedPacket memory p) internal {
        vm.expectRevert(abi.encodeWithSelector(NOT_RELEASED, keccak256(abi.encode(p)), p.releaseAt));
        IBZPXPark(address(b)).claimParked(p);
    }

    function _deployRaw(address ep, address owner_, uint256 legacyMainChainIdArg) internal returns (BZPX t) {
        bytes memory init = abi.encodePacked(type(BZPX).creationCode, abi.encode(ep, owner_, legacyMainChainIdArg));
        address x;
        assembly {
            x := create(0, add(init, 0x20), mload(init))
        }
        require(x != address(0), "deploy failed");
        t = BZPX(x);
    }

    // ---- fixed supply: one mint, only on chain 8453, whatever the constructor arguments ----

    function test_mintOnlyOnMainChain_wrongArgOnMirror() public {
        vm.chainId(MIRROR_CHAIN_ID);
        BZPX t = _deployRaw(endpoints[B_EID], owner, MIRROR_CHAIN_ID); // operator error: mirror's own chain id
        assertEq(t.totalSupply(), 0, "second supply minted on a mirror chain");
    }

    function testFuzz_mintOnlyOnMainChain_anyArg(uint64 chainId, uint256 arg) public {
        vm.assume(chainId != 0);
        vm.chainId(chainId);
        BZPX t = _deployRaw(endpoints[A_EID], owner, arg % 2 == 0 ? chainId : arg);
        assertEq(t.totalSupply(), chainId == MAIN_CHAIN_ID ? SUPPLY : 0);
        assertEq(t.balanceOf(owner), t.totalSupply());
    }

    // ---- inbound cap per source eid ----

    /// @dev A forged flood mints at most CAP at once; the excess is parked (no revert, no mint) and its release time
    ///      keeps the cumulative bound minted <= CAP + CAP * (t - t0) / WINDOW.
    function test_inboundCap_forgedFloodBounded() public {
        uint256 t0 = block.timestamp;
        _deliver(b, A_EID, address(a), attacker, CAP); // a whole window of capacity: minted
        (uint64 n, bytes32 g) = _deliver(b, A_EID, address(a), attacker, UNIT); // one more unit: parked, no revert
        assertEq(b.totalSupply(), CAP, "minted beyond the inbound cap");
        IBZPXPark.ParkedPacket memory p = _parkedAB(n, g, attacker, UNIT, t0 + 1); // ceil(UNIT * WINDOW / CAP) = 1
        assertTrue(_isParked(p), "excess not parked");
        _claimRevertsNotReleased(p);
        vm.warp(t0 + 1);
        IBZPXPark(address(b)).claimParked(p);
        assertEq(b.totalSupply(), CAP + UNIT);
        assertLe(b.totalSupply(), CAP + (CAP * (block.timestamp - t0)) / WINDOW, "cumulative inbound bound");
        assertFalse(_isParked(p));
    }

    function test_inboundCap_boundaryAndLinearRefill() public {
        uint256 t0 = block.timestamp;
        _deliver(b, A_EID, address(a), user, CAP - UNIT);
        _deliver(b, A_EID, address(a), user, UNIT); // exactly the remaining capacity: level == CAP, minted
        assertEq(b.totalSupply(), CAP);
        (uint64 n1, bytes32 g1) = _deliver(b, A_EID, address(a), user, UNIT); // one unit above: parked
        assertEq(b.totalSupply(), CAP);
        IBZPXPark.ParkedPacket memory p1 = _parkedAB(n1, g1, user, UNIT, t0 + 1);
        assertTrue(_isParked(p1), "one unit above the cap not parked");
        vm.warp(t0 + WINDOW / 2);
        uint256 half = 5_000_000e18; // CAP * (WINDOW / 2) / WINDOW, linear refill
        assertEq(b.inboundAvailable(A_EID), half - UNIT, "refill not linear or parked debt not counted");
        IBZPXPark(address(b)).claimParked(p1);
        assertEq(b.totalSupply(), CAP + UNIT);
        _deliver(b, A_EID, address(a), user, half - UNIT); // the available amount: minted
        assertEq(b.totalSupply(), CAP + half);
        (uint64 n2, bytes32 g2) = _deliver(b, A_EID, address(a), user, UNIT); // one unit above again: parked
        assertEq(b.totalSupply(), CAP + half);
        assertTrue(_isParked(_parkedAB(n2, g2, user, UNIT, block.timestamp + 1)));
        assertLe(b.totalSupply(), CAP + (CAP * (block.timestamp - t0)) / WINDOW, "cumulative inbound bound");
    }

    function test_inboundCap_parkedPacketClaimableAfterRefill() public {
        uint256 t0 = block.timestamp;
        address third = makeAddr("third");
        _deliver(b, A_EID, address(a), user, CAP);
        (uint64 n, bytes32 g) = _deliver(b, A_EID, address(a), user, CAP); // parked until a full refill
        assertEq(b.balanceOf(user), CAP);
        IBZPXPark.ParkedPacket memory p = _parkedAB(n, g, user, CAP, t0 + WINDOW);
        assertTrue(_isParked(p));
        vm.warp(t0 + WINDOW - 1);
        _claimRevertsNotReleased(p);
        vm.warp(t0 + WINDOW);
        vm.prank(third); // anyone can claim; the recipient is the packet's
        IBZPXPark(address(b)).claimParked(p);
        assertEq(b.balanceOf(user), 2 * CAP);
        assertEq(b.balanceOf(third), 0);
        vm.expectRevert(abi.encodeWithSelector(NOT_FOUND, keccak256(abi.encode(p))));
        IBZPXPark(address(b)).claimParked(p);
    }

    function test_inboundCap_isPerSourceEid() public {
        _deliver(b, A_EID, address(a), user, CAP);
        // a second source with its own peer keeps its own full capacity
        uint32 otherEid = 77;
        vm.prank(owner);
        b.setPeer(otherEid, addressToBytes32(address(0xBEEF)));
        _deliver(b, otherEid, address(0xBEEF), user, CAP);
        assertEq(b.totalSupply(), 2 * CAP);
    }

    function test_send_aboveCap_revertsAtSource_nothingBurned() public {
        uint256 amount = CAP + UNIT;
        SendParam memory p = _param(B_EID, user, amount, 0);
        uint256 before = a.balanceOf(owner);
        vm.expectRevert(abi.encodeWithSelector(CAP_ERR, B_EID, amount, CAP));
        a.quoteSend(p, false);
        MessagingFee memory fee = MessagingFee(1 ether, 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CAP_ERR, B_EID, amount, CAP));
        a.send{ value: 1 ether }(p, fee, owner);
        assertEq(a.balanceOf(owner), before);
        // the cap itself (dust removed) is sendable end to end
        _send(a, B_EID, owner, user, CAP + UNIT - 1);
        _deliverPackets(B_EID, b);
        assertEq(b.balanceOf(user), CAP);
        assertEq(_totalSum(), SUPPLY);
    }

    function deliverExt(BZPX dst, uint32 srcEid, address peer, address to, uint256 amountLD) external {
        _deliver(dst, srcEid, peer, to, amountLD);
    }
}
