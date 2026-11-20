// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Vm } from "forge-std/Vm.sol";
import { console2 } from "forge-std/console2.sol";
import { Origin } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { EndpointV2Mock } from "@layerzerolabs/test-devtools-evm-foundry/contracts/mocks/EndpointV2Mock.sol";
import { DoubleEndedQueue } from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";
import { PacketV1Codec } from "@layerzerolabs/lz-evm-protocol-v2/contracts/messagelib/libs/PacketV1Codec.sol";
import { BZPX } from "../src/BZPX.sol";
import { BZPXBase } from "./BZPX.t.sol";

/// @dev Local view of the parking surface, declared here so this file also compiles against the pre-fix contract
///      (5b5b5f6): there every test of BZPXQueueTest fails by assertion or revert, not by compilation.
interface IBZPXPark {
    struct ParkedPacket {
        uint32 srcEid;
        bytes32 sender;
        uint64 nonce;
        bytes32 guid;
        address to;
        uint256 amountLD;
        uint64 releaseAt;
        bytes composeMsg;
    }

    event InboundParked(bytes32 indexed key, ParkedPacket packet);
    event InboundRejected(bytes32 indexed guid, uint32 srcEid, address to, uint256 amountLD);
    event ParkedBurned(bytes32 indexed key);

    function claimParked(ParkedPacket calldata p) external;
    function burnParked(ParkedPacket calldata p) external;
    function parked(bytes32 key) external view returns (bool);
}

interface IComposeQueue {
    function composeQueue(address from, address to, bytes32 guid, uint16 index) external view returns (bytes32);
}

/// @dev Shared helpers. Oracle = the constants below and arithmetic done here, never values read from BZPX.
abstract contract BZPXParkBase is BZPXBase {
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;

    uint256 internal constant CAP = 10_000_000e18;
    uint256 internal constant WINDOW = 1 days;
    uint256 internal constant UNIT = 1e12; // 18 local decimals - 6 shared decimals
    bytes4 internal constant NOT_FOUND = bytes4(keccak256("ParkedNotFound(bytes32)"));
    bytes4 internal constant NOT_RELEASED = bytes4(keccak256("ParkedNotReleased(bytes32,uint64)"));
    bytes4 internal constant NOT_DELEGATE = bytes4(keccak256("NotEndpointDelegate(address)"));
    bytes4 internal constant ONLY_PEER = bytes4(keccak256("OnlyPeer(uint32,bytes32)"));
    bytes4 internal constant NO_PEER = bytes4(keccak256("NoPeer(uint32)"));
    bytes32 internal constant PARKED_TOPIC =
        keccak256("InboundParked(bytes32,(uint32,bytes32,uint64,bytes32,address,uint256,uint64,bytes))");

    uint64 internal nonce;
    address internal keeper = makeAddr("keeper");

    // parked packets seen in InboundParked logs, in arrival order (what an off-chain keeper indexes)
    bytes[] internal qData;
    address[] internal qChain;
    uint64[] internal qRel;
    bool[] internal qDone;
    mapping(address => uint256) internal lastRel;

    function _ip(BZPX t) internal pure returns (IBZPXPark) {
        return IBZPXPark(address(t));
    }

    function _nextGuid() internal view returns (bytes32) {
        return keccak256(abi.encode("guid", nonce + 1));
    }

    /// @dev Delivers to `b` from A_EID as the endpoint does after DVN verification (honest or forged alike).
    function _deliverSD(address to, uint64 amountSD, bytes memory compose) internal returns (uint64 n, bytes32 guid) {
        (bytes memory message, ) = OFTMsgCodec.encode(addressToBytes32(to), amountSD, compose);
        guid = _nextGuid();
        n = ++nonce;
        vm.prank(address(b.endpoint()));
        b.lzReceive(Origin(A_EID, addressToBytes32(address(a)), n), guid, message, address(0), "");
    }

    function _deliver(address to, uint256 amountLD, bytes memory compose) internal returns (uint64, bytes32) {
        return _deliverSD(to, uint64(amountLD / UNIT), compose);
    }

    function _pk(uint64 n, bytes32 guid, address to, uint256 x, uint256 releaseAt, bytes memory compose)
        internal
        view
        returns (IBZPXPark.ParkedPacket memory)
    {
        return IBZPXPark.ParkedPacket(A_EID, addressToBytes32(address(a)), n, guid, to, x, uint64(releaseAt), compose);
    }

    function _key(IBZPXPark.ParkedPacket memory p) internal pure returns (bytes32) {
        return keccak256(abi.encode(p));
    }

    function _claim(IBZPXPark.ParkedPacket memory p) internal {
        vm.prank(keeper);
        _ip(b).claimParked(p);
    }

    function _claimReverts(IBZPXPark.ParkedPacket memory p, bytes memory err) internal {
        vm.expectRevert(err);
        vm.prank(keeper);
        _ip(b).claimParked(p);
    }

    /// @dev Reads InboundParked logs since the last call; checks key == keccak256(abi.encode(packet)) and that the
    ///      release time never decreases in arrival order per chain (FIFO).
    function _harvest() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length < 2 || logs[i].topics[0] != PARKED_TOPIC) continue;
            assertEq(logs[i].topics[1], keccak256(logs[i].data), "parked key is not the packet hash");
            IBZPXPark.ParkedPacket memory p = abi.decode(logs[i].data, (IBZPXPark.ParkedPacket));
            assertGe(uint256(p.releaseAt), lastRel[logs[i].emitter], "a later arrival was scheduled ahead (FIFO)");
            lastRel[logs[i].emitter] = p.releaseAt;
            qData.push(logs[i].data);
            qChain.push(logs[i].emitter);
            qRel.push(p.releaseAt);
            qDone.push(false);
        }
    }

    /// @dev Keeper: claims every released packet once, then tries the same packet again (must fail).
    ///      Returns the amount minted on `b` by these claims and the number of successful second claims.
    function _keeperRun() internal returns (uint256 mintedB, uint256 doubles) {
        for (uint256 i; i < qData.length; i++) {
            if (qDone[i] || qRel[i] > block.timestamp) continue;
            IBZPXPark.ParkedPacket memory p = abi.decode(qData[i], (IBZPXPark.ParkedPacket));
            IBZPXPark t = IBZPXPark(qChain[i]);
            uint256 s0 = b.totalSupply();
            vm.prank(keeper);
            try t.claimParked(p) {
                qDone[i] = true;
            } catch {
                continue;
            }
            vm.prank(keeper);
            try t.claimParked(p) {
                doubles++;
            } catch {}
            if (qChain[i] == address(b)) mintedB += b.totalSupply() - s0;
        }
    }

    function _unclaimed() internal view returns (uint256 s) {
        for (uint256 i; i < qData.length; i++) {
            if (!qDone[i]) s += abi.decode(qData[i], (IBZPXPark.ParkedPacket)).amountLD;
        }
    }

    function _cool(address x) internal {
        (bool ok, ) = address(vm).call(abi.encodeWithSignature("cool(address)", x));
        require(ok, "vm.cool missing");
    }

    function _pop(uint32 dstEid, address dst) internal returns (bytes memory pkt, bytes memory opts) {
        bytes32 guid = packetsQueue[dstEid][addressToBytes32(dst)].popBack();
        pkt = packets[guid];
        opts = optionsLookup[guid];
    }

    function nonceOf(bytes calldata pkt) external pure returns (uint64) {
        return PacketV1Codec.nonce(pkt);
    }

    function guidOf(bytes calldata pkt) external pure returns (bytes32) {
        return PacketV1Codec.guid(pkt);
    }

    function msgOf(bytes calldata pkt) external pure returns (bytes memory) {
        return PacketV1Codec.message(pkt);
    }

    /// @dev Sends `x` A->B and returns the verified, not yet executed packet.
    function _sendVerified(address from, uint256 x) internal returns (bytes memory pkt, bytes memory opts) {
        _send(a, B_EID, from, from, x);
        (pkt, opts) = _pop(B_EID, address(b));
        this.validatePacket(pkt, "");
    }

    function _endpointDeliver(bytes memory pkt) internal returns (uint256 used) {
        Origin memory o = Origin(A_EID, addressToBytes32(address(a)), this.nonceOf(pkt));
        bytes32 g = this.guidOf(pkt);
        bytes memory m = this.msgOf(pkt);
        uint256 g0 = gasleft();
        EndpointV2Mock(endpoints[B_EID]).lzReceive(o, address(b), g, m, "");
        used = g0 - gasleft();
    }
}

/// @notice Inbound cap without a revert in lzReceive: a delivery above the available capacity is parked with a
///         release time (FIFO per source eid) and claimed later by anyone.
/// @dev Red on 5b5b5f6 (cap enforced by reverting in lzReceive): every test in this contract fails there.
contract BZPXQueueTest is BZPXParkBase {
    // ---- PoC-1 (verifier): a cycling attacker can no longer starve a user ----

    function test_cycleGriefing_victimServedWithinCapitalBound() public {
        uint256 capital = 400_000e18;
        uint256 victim = 50_000e18;
        uint256 step = 360; // < victim * WINDOW / CAP = 432 s
        uint256 victimBound = 3888; // ceilDiv((capital + victim) * WINDOW, CAP)
        vm.startPrank(owner);
        a.transfer(attacker, capital);
        a.transfer(user, victim);
        vm.stopPrank();
        vm.recordLogs();
        uint256 t0 = block.timestamp;
        uint256 mintedB;
        uint256 s0 = b.totalSupply();
        _send(a, B_EID, owner, owner, CAP); // the bucket A->B is full at t0
        _deliverPackets(B_EID, b);
        mintedB += b.totalSupply() - s0;
        _harvest();
        uint256 aV;
        for (uint256 s = 1; s <= 60; s++) {
            vm.warp(t0 + s * step);
            if (s == 1) {
                _send(a, B_EID, user, user, victim); // the victim arrives first
                aV = block.timestamp;
                s0 = b.totalSupply();
                _deliverPackets(B_EID, b);
                mintedB += b.totalSupply() - s0;
                uint256 before = qData.length;
                _harvest();
                assertEq(qData.length, before + 1, "victim packet not parked");
                assertEq(b.balanceOf(user), 0, "victim credited above the available capacity");
            }
            // the attacker sends all it holds on A (two packets, the small one last), and all it holds on B back
            uint256 balA = a.balanceOf(attacker);
            if (balA >= 2e18) {
                s0 = b.totalSupply();
                _send(a, B_EID, attacker, attacker, balA - 1e18);
                _send(a, B_EID, attacker, attacker, 1e18);
                _deliverPackets(B_EID, b);
                mintedB += b.totalSupply() - s0;
                _harvest();
            }
            uint256 balB = (b.balanceOf(attacker) / UNIT) * UNIT;
            if (balB >= UNIT) {
                _send(b, A_EID, attacker, attacker, balB);
                _deliverPackets(A_EID, a);
                _harvest();
            }
            (uint256 m, uint256 doubles) = _keeperRun();
            mintedB += m;
            assertEq(doubles, 0, "a parked packet was claimed twice");
            assertLe(mintedB, CAP + ((block.timestamp - t0) * CAP) / WINDOW, "minted on B above CAP + r*(t-t0)");
            if (block.timestamp >= aV + victimBound) assertEq(b.balanceOf(user), victim, "victim not served in bound");
        }
        assertEq(b.balanceOf(user), victim, "victim balance");
        assertEq(a.totalSupply() + b.totalSupply() + _unclaimed(), SUPPLY, "supply + parked != total");
    }

    // ---- PoC-2 (verifier): refused packets no longer pile up in the endpoint ----

    function test_refusedQueue_deliveryWithEnforcedGas_k80() public {
        vm.prank(owner);
        a.transfer(user, 10e18);
        _send(a, B_EID, owner, owner, CAP);
        _deliverPackets(B_EID, b);
        for (uint256 i; i < 80; i++) {
            (bytes memory p, bytes memory o) = _sendVerified(owner, 1e18);
            try this.lzReceive(p, o) {} catch {}
        }
        assertEq(b.balanceOf(owner), CAP, "over-cap packets credited at once");
        vm.warp(block.timestamp + WINDOW);
        (bytes memory pkt, bytes memory opts) = _sendVerified(user, 1e18);
        _cool(endpoints[B_EID]);
        _cool(address(b));
        bool ok;
        try this.lzReceive(pkt, opts) {
            ok = true;
        } catch {}
        assertTrue(ok, "delivery with the enforced gas failed after 80 over-cap packets");
        assertEq(b.balanceOf(user), 1e18);
    }

    // ---- claim: release time, single use, exact packet, peer, recipient ----

    function test_claim_beforeReleaseAt_reverts_atReleaseAt_mints() public {
        uint256 t0 = block.timestamp;
        _deliver(user, CAP, "");
        uint256 x = 1_000e18;
        (uint64 n, bytes32 g) = _deliver(user, x, "");
        IBZPXPark.ParkedPacket memory p = _pk(n, g, user, x, t0 + 9, ""); // ceil(1000e18 * W / CAP) = 9
        assertTrue(_ip(b).parked(_key(p)), "not parked with releaseAt t0+9");
        assertEq(b.balanceOf(user), CAP);
        vm.warp(t0 + 8);
        _claimReverts(p, abi.encodeWithSelector(NOT_RELEASED, _key(p), uint64(t0 + 9)));
        vm.warp(t0 + 9);
        _claim(p);
        assertEq(b.balanceOf(user), CAP + x);
        assertFalse(_ip(b).parked(_key(p)));
    }

    function test_claim_twice_reverts() public {
        uint256 t0 = block.timestamp;
        _deliver(user, CAP, "");
        (uint64 n, bytes32 g) = _deliver(user, 1_000e18, "");
        IBZPXPark.ParkedPacket memory p = _pk(n, g, user, 1_000e18, t0 + 9, "");
        vm.warp(t0 + 9);
        _claim(p);
        _claimReverts(p, abi.encodeWithSelector(NOT_FOUND, _key(p)));
        assertEq(b.balanceOf(user), CAP + 1_000e18);
    }

    function test_claim_wrongPacket_reverts_thirdPartyClaimPaysRecipient() public {
        uint256 t0 = block.timestamp;
        uint256 x = 1_000e18;
        _deliver(user, CAP, "");
        (uint64 n, bytes32 g) = _deliver(user, x, "");
        vm.warp(t0 + 9);
        IBZPXPark.ParkedPacket[6] memory lies = [
            _pk(n, g, user, x + UNIT, t0 + 9, ""),
            _pk(n, g, user, x - UNIT, t0 + 9, ""),
            _pk(n, g, keeper, x, t0 + 9, ""),
            _pk(n, g, user, x, t0 + 8, ""),
            _pk(n + 1, g, user, x, t0 + 9, ""),
            _pk(n, keccak256("other"), user, x, t0 + 9, "")
        ];
        for (uint256 i; i < lies.length; i++) {
            _claimReverts(lies[i], abi.encodeWithSelector(NOT_FOUND, _key(lies[i])));
        }
        _claim(_pk(n, g, user, x, t0 + 9, ""));
        assertEq(b.balanceOf(user), CAP + x, "recipient not paid");
        assertEq(b.balanceOf(keeper), 0, "claimer paid");
    }

    function test_claim_peerChanged_reverts() public {
        uint256 t0 = block.timestamp;
        _deliver(user, CAP, "");
        (uint64 n, bytes32 g) = _deliver(user, 1_000e18, "");
        IBZPXPark.ParkedPacket memory p = _pk(n, g, user, 1_000e18, t0 + 9, "");
        vm.warp(t0 + 9);
        vm.prank(owner);
        b.setPeer(A_EID, bytes32(uint256(0xBEEF)));
        _claimReverts(p, abi.encodeWithSelector(ONLY_PEER, A_EID, addressToBytes32(address(a))));
        vm.prank(owner);
        b.setPeer(A_EID, bytes32(0));
        _claimReverts(p, abi.encodeWithSelector(NO_PEER, A_EID));
        vm.prank(owner);
        b.setPeer(A_EID, addressToBytes32(address(a)));
        _claim(p);
        assertEq(b.balanceOf(user), CAP + 1_000e18);
    }

    // ---- burn by the endpoint delegate refunds the bucket ----

    function test_burnParked_onlyDelegate_refundsBucket() public {
        address delegado = makeAddr("delegado");
        uint256 t0 = block.timestamp;
        uint256 x = 1_000_000e18;
        _deliver(user, CAP, "");
        (uint64 n, bytes32 g) = _deliver(user, x, "");
        IBZPXPark.ParkedPacket memory p = _pk(n, g, user, x, t0 + 8640, ""); // ceil(1e24 * W / CAP) = 8640
        assertTrue(_ip(b).parked(_key(p)));
        vm.prank(owner);
        b.setDelegate(delegado); // the owner is no longer the endpoint delegate
        vm.warp(t0 + 100);
        assertEq(b.inboundAvailable(A_EID), 0);
        vm.expectRevert(abi.encodeWithSelector(NOT_DELEGATE, owner));
        vm.prank(owner);
        _ip(b).burnParked(p);
        vm.expectRevert(abi.encodeWithSelector(NOT_DELEGATE, attacker));
        vm.prank(attacker);
        _ip(b).burnParked(p);
        vm.expectEmit(true, false, false, false, address(b));
        emit IBZPXPark.ParkedBurned(_key(p));
        vm.prank(delegado);
        _ip(b).burnParked(p);
        assertFalse(_ip(b).parked(_key(p)));
        // refund: level CAP + x - floor(100 * CAP / W) - x  =>  available = floor(100 * CAP / W)
        assertEq(b.inboundAvailable(A_EID), 11574074074074074074074, "burn did not refund the bucket");
        vm.expectRevert(abi.encodeWithSelector(NOT_FOUND, _key(p)));
        vm.prank(delegado);
        _ip(b).burnParked(p);
        vm.warp(t0 + 8640);
        _claimReverts(p, abi.encodeWithSelector(NOT_FOUND, _key(p)));
        assertEq(b.totalSupply(), CAP);
    }

    /// @dev After the renounce procedure (setDelegate(0), renounceOwnership) nobody can burn a parked packet:
    ///      the former owner, an attacker and the recipient all revert NotEndpointDelegate(caller); the packet and the
    ///      bucket stay as they were, and the packet is still claimable at releaseAt (the only way out).
    function test_burnParked_delegateZero_revertsForAnyCaller() public {
        uint256 t0 = block.timestamp;
        uint256 x = 1_000_000e18;
        _deliver(user, CAP, "");
        (uint64 n, bytes32 g) = _deliver(user, x, "");
        IBZPXPark.ParkedPacket memory p = _pk(n, g, user, x, t0 + 8640, "");
        vm.startPrank(owner);
        b.setDelegate(address(0));
        b.renounceOwnership();
        vm.stopPrank();
        assertEq(b.owner(), address(0));
        vm.warp(t0 + 100);
        address[3] memory callers = [owner, attacker, user];
        for (uint256 i; i < callers.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(NOT_DELEGATE, callers[i]));
            vm.prank(callers[i]);
            _ip(b).burnParked(p);
        }
        assertTrue(_ip(b).parked(_key(p)), "packet gone without a delegate");
        assertEq(b.inboundAvailable(A_EID), 0, "bucket refunded without a delegate");
        vm.warp(t0 + 8640);
        _claim(p);
        assertFalse(_ip(b).parked(_key(p)));
        assertEq(b.balanceOf(user), CAP + x);
        assertEq(b.totalSupply(), CAP + x);
    }

    // ---- a packet above the cap is never honest: rejected without credit and without debt ----

    function test_aboveCapPacket_rejectedNoDebt() public {
        uint256 t0 = block.timestamp;
        uint64 maxSD = type(uint64).max;
        vm.expectEmit(true, false, false, true, address(b));
        emit IBZPXPark.InboundRejected(_nextGuid(), A_EID, user, uint256(maxSD) * UNIT);
        _deliverSD(user, maxSD, "");
        vm.expectEmit(true, false, false, true, address(b));
        emit IBZPXPark.InboundRejected(_nextGuid(), A_EID, user, CAP + UNIT);
        _deliver(user, CAP + UNIT, "");
        assertEq(b.totalSupply(), 0);
        assertEq(b.inboundAvailable(A_EID), CAP, "a rejected packet created debt");
        _deliver(user, CAP, ""); // exactly the cap: credited at once
        assertEq(b.balanceOf(user), CAP, "cap-sized packet not credited at once");
        vm.warp(t0 + WINDOW);
        _deliver(user, CAP, "");
        assertEq(b.balanceOf(user), 2 * CAP);
    }

    // ---- compose: nothing sent at park time, sent with the real amount at claim ----

    function test_composeParked_claimSendsComposeWithAmount() public {
        address composer = makeAddr("composer");
        bytes memory payload = bytes("compose payload");
        // OFTMsgCodec.encode prepends composeFrom = msg.sender of this frame; the packet carries composeFrom ++ payload
        bytes memory compose = abi.encodePacked(addressToBytes32(msg.sender), payload);
        uint256 t0 = block.timestamp;
        uint256 x = 1_000e18;
        _deliver(user, CAP, "");
        (uint64 n, bytes32 g) = _deliver(composer, x, payload);
        IBZPXPark.ParkedPacket memory p = _pk(n, g, composer, x, t0 + 9, compose);
        assertTrue(_ip(b).parked(_key(p)));
        IComposeQueue ep = IComposeQueue(endpoints[B_EID]);
        assertEq(ep.composeQueue(address(b), composer, g, 0), bytes32(0), "compose sent at park time");
        vm.warp(t0 + 9);
        _claim(p);
        assertEq(b.balanceOf(composer), x);
        assertEq(
            ep.composeQueue(address(b), composer, g, 0),
            keccak256(OFTComposeMsgCodec.encode(n, A_EID, x, compose)),
            "compose not sent with the claimed amount"
        );
    }

    // ---- FIFO ----

    function test_fifo_laterArrivalNotAhead() public {
        uint256 t0 = block.timestamp;
        uint256 d1 = 5_000_000e18;
        _deliver(user, CAP, "");
        (uint64 n1, bytes32 g1) = _deliver(user, d1, "");
        IBZPXPark.ParkedPacket memory p1 = _pk(n1, g1, user, d1, t0 + 43200, "");
        vm.warp(t0 + 10);
        (uint64 n2, bytes32 g2) = _deliver(keeper, UNIT, ""); // dust arriving later
        // releaseAt = t0+10 + ceil((d1 - floor(10*CAP/W) + UNIT) * W / CAP) = t0 + 43201
        IBZPXPark.ParkedPacket memory p2 = _pk(n2, g2, keeper, UNIT, t0 + 43201, "");
        assertTrue(_ip(b).parked(_key(p1)), "p1");
        assertTrue(_ip(b).parked(_key(p2)), "dust not queued behind p1");
        vm.warp(t0 + 43200);
        _claimReverts(p2, abi.encodeWithSelector(NOT_RELEASED, _key(p2), uint64(t0 + 43201)));
        _claim(p1);
        vm.warp(t0 + 43201);
        _claim(p2);
        assertEq(b.totalSupply(), CAP + d1 + UNIT);
    }

    function testFuzz_fifo_arrivalOrder(uint64[4] memory amountsSD, uint32[4] memory gaps) public {
        vm.recordLogs();
        _deliver(user, CAP, "");
        _harvest();
        uint256 maxRel;
        for (uint256 i; i < 4; i++) {
            vm.warp(block.timestamp + bound(gaps[i], 0, WINDOW));
            uint256 before = qData.length;
            _deliverSD(user, uint64(bound(amountsSD[i], 1, CAP / UNIT)), "");
            _harvest(); // asserts releaseAt non-decreasing among parked arrivals
            if (qData.length == before) {
                assertLe(maxRel, block.timestamp, "a fast packet overtook a parked one");
            } else {
                maxRel = qRel[qData.length - 1];
            }
        }
    }

    // ---- forged packets: cumulative bound from t0, nothing lost ----

    function testFuzz_forgeBound_cumulative(uint64[8] memory amountsSD, uint32[8] memory gaps) public {
        vm.recordLogs();
        uint256 t0 = block.timestamp;
        uint256 minted;
        uint256 accepted;
        for (uint256 i; i < 8; i++) {
            uint64 sd = i == 0 ? amountsSD[0] : uint64(bound(amountsSD[i], 0, CAP / UNIT)); // index 0 raw
            uint256 s0 = b.totalSupply();
            _deliverSD(user, sd, "");
            minted += b.totalSupply() - s0;
            if (uint256(sd) * UNIT <= CAP) accepted += uint256(sd) * UNIT;
            _harvest();
            (uint256 m, uint256 doubles) = _keeperRun();
            minted += m;
            assertEq(doubles, 0, "claimed twice");
            assertLe(minted, CAP + ((block.timestamp - t0) * CAP) / WINDOW, "minted above CAP + r*(t-t0)");
            vm.warp(block.timestamp + bound(gaps[i], 0, 2 * WINDOW));
        }
        vm.warp(block.timestamp + 8 * WINDOW); // 7 packets <= CAP each drain within 7 windows
        (uint256 m2, ) = _keeperRun();
        minted += m2;
        assertEq(minted, accepted, "accepted amount not fully credited");
        assertEq(b.totalSupply(), accepted);
    }

    // ---- rounding: refill down, release time up ----

    function test_refillRoundsDown() public {
        uint256 t0 = block.timestamp;
        uint256 x1 = 3009259259000000000000; // floor(26*CAP/W) = 3009259259259259259259, unit-floored
        uint256 x2 = 115740741000000000000; // 259259259259 + floor(CAP/W) + 1
        assertEq((259259259259 + 115740740740740740740 + 1) % UNIT, 0); // self-check of the constants
        _deliver(user, CAP, "");
        vm.warp(t0 + 26);
        _deliver(user, x1, "");
        assertEq(b.balanceOf(user), CAP + x1);
        vm.warp(t0 + 27);
        assertEq(b.inboundAvailable(A_EID), x2 - 1, "refill not rounded down");
        (uint64 n, bytes32 g) = _deliver(user, x2, "");
        assertEq(b.balanceOf(user), CAP + x1, "credited 1 wei above the floored refill");
        assertTrue(_ip(b).parked(_key(_pk(n, g, user, x2, t0 + 28, ""))), "not parked 1 s");
    }

    function test_releaseAtRoundsUp() public {
        uint256 t0 = block.timestamp;
        uint256 d = CAP / 2 + UNIT;
        _deliver(user, CAP, "");
        (uint64 n, bytes32 g) = _deliver(user, d, "");
        IBZPXPark.ParkedPacket memory p = _pk(n, g, user, d, t0 + 43201, ""); // ceil(43200 + 8.64e-9)
        assertTrue(_ip(b).parked(_key(p)), "releaseAt not rounded up");
        vm.warp(t0 + 43200);
        _claimReverts(p, abi.encodeWithSelector(NOT_RELEASED, _key(p), uint64(t0 + 43201)));
        vm.warp(t0 + 43201);
        _claim(p);
        assertEq(b.balanceOf(user), CAP + d);
    }
}

/// @notice Gas logs only (no assertion): endpoint delivery after k over-cap packets (before: refused and pending;
///         after: parked), claim cost with 0 vs 80 packets ahead, park path vs fast path.
contract BZPXQueueGasTest is BZPXParkBase {
    function _gasAfterK(uint256 k) internal returns (uint256) {
        vm.prank(owner);
        a.transfer(user, 10e18);
        _send(a, B_EID, owner, owner, CAP);
        _deliverPackets(B_EID, b);
        for (uint256 i; i < k; i++) {
            (bytes memory p, bytes memory o) = _sendVerified(owner, 1e18);
            try this.lzReceive(p, o) {} catch {}
        }
        vm.warp(block.timestamp + WINDOW);
        (bytes memory pkt, ) = _sendVerified(user, 1e18);
        _cool(endpoints[B_EID]);
        _cool(address(b));
        return _endpointDeliver(pkt);
    }

    function test_gas_deliveryAfterKRefused_k0() public {
        console2.log("endpoint.lzReceive gas, k=0", _gasAfterK(0));
    }

    function test_gas_deliveryAfterKRefused_k20() public {
        console2.log("endpoint.lzReceive gas, k=20", _gasAfterK(20));
    }

    function test_gas_deliveryAfterKRefused_k60() public {
        console2.log("endpoint.lzReceive gas, k=60", _gasAfterK(60));
    }

    function test_gas_deliveryAfterKRefused_k80() public {
        console2.log("endpoint.lzReceive gas, k=80", _gasAfterK(80));
    }

    function test_gas_claim_k0_vs_k80() public {
        uint256 t0 = block.timestamp;
        _deliver(user, CAP, "");
        IBZPXPark.ParkedPacket[] memory ps = new IBZPXPark.ParkedPacket[](81);
        for (uint256 i; i < 81; i++) {
            (uint64 n, bytes32 g) = _deliver(user, 1e18, "");
            // releaseAt of the (i+1)-th 1e18 packet: ceil((i+1) * 1e18 * W / CAP)
            ps[i] = _pk(n, g, user, 1e18, t0 + ((i + 1) * 1e18 * WINDOW + CAP - 1) / CAP, "");
        }
        vm.warp(t0 + WINDOW);
        _cool(address(b));
        uint256 g0 = gasleft();
        _claim(ps[0]);
        console2.log("claimParked gas, 0 ahead", g0 - gasleft());
        _cool(address(b));
        g0 = gasleft();
        _claim(ps[80]);
        console2.log("claimParked gas, 80 ahead", g0 - gasleft());
    }

    function test_gas_parkVsFast() public {
        _cool(address(b));
        uint256 g0 = gasleft();
        _deliver(user, CAP, "");
        console2.log("b.lzReceive gas, fast path (cold)", g0 - gasleft());
        _cool(address(b));
        g0 = gasleft();
        _deliver(user, 1e18, "");
        console2.log("b.lzReceive gas, park path (cold)", g0 - gasleft());
    }
}
