// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { EnforcedOptionParam } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import { SendParam, MessagingFee, OFTReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { MessagingReceipt } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { BZPX } from "../src/BZPX.sol";

/// @dev parkedCount read through a local interface so this file also compiles against a contract without it.
interface IParkedCount {
    function parkedCount() external view returns (uint256);
}

interface IPacketHelper {
    function verifyPackets(
        uint32 dstEid,
        bytes32 dstAddress,
        uint256 packetAmount,
        address composer,
        bytes memory resolvedPayload
    ) external;
}

/// @dev Six-chain mesh handler. Sends are arbitrary (any amount up to INBOUND_CAP, no room check), so the parking path is
///      exercised; packets are delivered one at a time per destination (cross-path order is free); parked packets are
///      claimed by a keeper (early claims must revert with ParkedNotReleased) and burned by the endpoint delegate
///      (a non-delegate burn must revert with NotEndpointDelegate). The oracle is a shadow bucket per (destination, source
///      eid) and the supply deltas measured around every action, never the events of the contract under test.
contract Handler6 is Test {
    uint256 internal constant N = 6;
    uint256 internal constant CAP = 10_000_000e18;
    uint256 internal constant W = 1 days;
    uint256 internal constant UNIT = 1e12;
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    struct Pending {
        uint32 srcEid;
        uint64 nonce;
        bytes32 guid;
        address to;
        uint256 amount;
    }

    struct Shadow {
        uint256 used;
        uint256 updatedAt;
    }

    struct Rec {
        uint8 dst;
        uint8 state; // 0 open, 1 claimed, 2 burned
        BZPX.ParkedPacket p;
    }

    BZPX[N] internal tok;
    IPacketHelper public immutable helper;
    address public immutable delegate;
    address public immutable keeper;
    uint256 public immutable t0;
    address[] internal actors;

    mapping(uint256 dst => Pending[]) internal queue;
    mapping(uint256 dst => uint256) internal head;
    mapping(uint256 dst => mapping(uint32 srcEid => Shadow)) internal shadow;
    mapping(uint256 dst => mapping(uint32 srcEid => uint256)) public minted; // minted at dst from srcEid since t0
    Rec[] internal recs;

    uint256 public inFlight;
    uint256 public parkedOpen;
    uint256 public burned;
    uint256 public sends;
    uint256 public deliveries;
    uint256 public parks;
    uint256 public claims;
    uint256 public earlyClaims;
    uint256 public burns;

    constructor(BZPX[N] memory tok_, IPacketHelper helper_, address delegate_, address keeper_, address[] memory actors_) {
        tok = tok_;
        helper = helper_;
        delegate = delegate_;
        keeper = keeper_;
        actors = actors_;
        t0 = block.timestamp;
    }

    function eidOf(uint256 i) public pure returns (uint32) {
        return uint32(i + 1);
    }

    // ---------------------------------------------------------------- fuzzed actions

    function send(uint256 srcSeed, uint256 dstSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        uint256 s = srcSeed % N;
        uint256 k;
        while (k < N && tok[s].balanceOf(from) < UNIT) {
            s = (s + 1) % N;
            k++;
        }
        if (k == N) return;
        uint256 d = (s + 1 + (dstSeed % (N - 1))) % N;
        uint256 bal = tok[s].balanceOf(from);
        uint256 max = bal < CAP ? bal : CAP;
        _send(s, d, from, actors[toSeed % actors.length], bound(amount, 1, max / UNIT) * UNIT);
    }

    function deliver(uint256 dstSeed) external {
        uint256 d = dstSeed % N;
        uint256 k;
        while (k < N && head[d] == queue[d].length) {
            d = (d + 1) % N;
            k++;
        }
        if (k == N) return;
        _deliver(d);
    }

    function claim(uint256 seed) external {
        (bool found, uint256 i) = _open(seed);
        if (!found) return;
        Rec storage r = recs[i];
        BZPX t = tok[r.dst];
        BZPX.ParkedPacket memory p = r.p;
        if (block.timestamp < p.releaseAt) {
            vm.expectRevert(abi.encodeWithSelector(BZPX.ParkedNotReleased.selector, keccak256(abi.encode(p)), p.releaseAt));
            vm.prank(keeper);
            t.claimParked(p);
            earlyClaims++;
            return;
        }
        uint256 supplyBefore = t.totalSupply();
        uint256 toBefore = t.balanceOf(p.to);
        vm.prank(keeper);
        t.claimParked(p);
        assertEq(t.totalSupply() - supplyBefore, p.amountLD, "claim: minted != parked amount");
        assertEq(t.balanceOf(p.to) - toBefore, p.amountLD, "claim: recipient credit != parked amount");
        r.state = 1;
        parkedOpen -= p.amountLD;
        minted[r.dst][p.srcEid] += p.amountLD;
        claims++;
    }

    function burn(uint256 seed) external {
        (bool found, uint256 i) = _open(seed);
        if (!found) return;
        Rec storage r = recs[i];
        BZPX t = tok[r.dst];
        BZPX.ParkedPacket memory p = r.p;
        vm.expectRevert(abi.encodeWithSelector(BZPX.NotEndpointDelegate.selector, keeper));
        vm.prank(keeper);
        t.burnParked(p);
        uint256 supplyBefore = t.totalSupply();
        vm.prank(delegate);
        t.burnParked(p);
        assertEq(t.totalSupply(), supplyBefore, "burn: supply moved");
        uint256 level = _shadowLevel(r.dst, p.srcEid);
        shadow[r.dst][p.srcEid] = Shadow(level > p.amountLD ? level - p.amountLD : 0, block.timestamp);
        r.state = 2;
        parkedOpen -= p.amountLD;
        burned += p.amountLD;
        burns++;
    }

    function wait(uint256 s) external {
        vm.warp(block.timestamp + bound(s, 0, 1 days));
    }

    // ---------------------------------------------------------------- deterministic entry points (not fuzzed)

    function seedSend(uint256 s, uint256 d, address from, address to, uint256 amount) external {
        _send(s, d, from, to, amount);
    }

    function seedDeliver(uint256 d) external {
        _deliver(d);
    }

    // ---------------------------------------------------------------- checks (called by the invariants)

    /// Predicate B (cumulative): minted at dst from one source eid since t0 <= CAP + CAP * (t - t0) / W, exact (no rounding).
    function checkBoundB() external view {
        uint256 elapsed = block.timestamp - t0;
        for (uint256 d; d < N; d++) {
            for (uint256 s; s < N; s++) {
                if (s == d) continue;
                assertLe(minted[d][eidOf(s)] * W, CAP * W + elapsed * CAP, "bound B: minted since t0 > CAP + rate*(t-t0)");
            }
        }
    }

    /// Sum of the six supplies + in flight + parked + burned parked == 1e9, and the six supplies never exceed 1e9.
    function checkConservation() external view {
        uint256 sum;
        for (uint256 d; d < N; d++) sum += tok[d].totalSupply();
        assertLe(sum, SUPPLY, "sum of supplies > 1e9");
        assertEq(sum + inFlight + parkedOpen + burned, SUPPLY, "supply + in flight + parked + burned != 1e9");
    }

    /// Every one of the 30 buckets equals the shadow bucket.
    function checkBuckets() external view {
        for (uint256 d; d < N; d++) {
            for (uint256 s; s < N; s++) {
                if (s == d) continue;
                assertEq(tok[d].inboundAvailable(eidOf(s)), shadowAvailable(d, eidOf(s)), "bucket != shadow bucket");
            }
        }
    }

    /// A parked packet is claimable exactly while open; claimed or burned ones are gone.
    function checkParkedFlags() external view {
        for (uint256 i; i < recs.length; i++) {
            BZPX.ParkedPacket memory p = recs[i].p;
            assertEq(tok[recs[i].dst].parked(keccak256(abi.encode(p))), recs[i].state == 0, "parked flag != record state");
        }
    }

    /// parkedCount on each chain == records for that chain not yet claimed or burned (what the renounce gate reads).
    function checkParkedCount() external view {
        for (uint256 d; d < N; d++) {
            uint256 n;
            for (uint256 i; i < recs.length; i++) if (recs[i].dst == d && recs[i].state == 0) n++;
            assertEq(IParkedCount(address(tok[d])).parkedCount(), n, "parkedCount != open records");
        }
    }

    function shadowAvailable(uint256 d, uint32 e) public view returns (uint256) {
        uint256 level = _shadowLevel(d, e);
        return level < CAP ? CAP - level : 0;
    }

    // ---------------------------------------------------------------- internals

    function _send(uint256 s, uint256 d, address from, address to, uint256 amount) internal {
        SendParam memory p = SendParam(eidOf(d), bytes32(uint256(uint160(to))), amount, amount, "", "", "");
        MessagingFee memory fee = tok[s].quoteSend(p, false);
        vm.deal(from, from.balance + fee.nativeFee);
        vm.prank(from);
        (MessagingReceipt memory r, OFTReceipt memory o) = tok[s].send{ value: fee.nativeFee }(p, fee, from);
        assertEq(o.amountSentLD, amount, "send: amount not unit-aligned");
        queue[d].push(Pending(eidOf(s), r.nonce, r.guid, to, amount));
        inFlight += amount;
        sends++;
    }

    function _deliver(uint256 d) internal {
        Pending memory q = queue[d][head[d]++];
        BZPX t = tok[d];
        uint256 supplyBefore = t.totalSupply();
        uint256 toBefore = t.balanceOf(q.to);
        // a delivery never reverts (a revert here fails the run: fail_on_revert)
        helper.verifyPackets(eidOf(d), bytes32(uint256(uint160(address(t)))), 1, address(0), "");
        inFlight -= q.amount;
        deliveries++;
        uint64 releaseAt = _shadowAdmit(d, q.srcEid, q.amount);
        if (releaseAt == 0) {
            assertEq(t.totalSupply() - supplyBefore, q.amount, "fast path: minted != amount");
            assertEq(t.balanceOf(q.to) - toBefore, q.amount, "fast path: recipient credit != amount");
            minted[d][q.srcEid] += q.amount;
            return;
        }
        assertEq(t.totalSupply(), supplyBefore, "parked packet minted");
        BZPX.ParkedPacket memory p = BZPX.ParkedPacket(
            q.srcEid,
            bytes32(uint256(uint160(address(tok[q.srcEid - 1])))),
            q.nonce,
            q.guid,
            q.to,
            q.amount,
            releaseAt,
            ""
        );
        assertTrue(t.parked(keccak256(abi.encode(p))), "parked packet differs from the oracle (key or releaseAt)");
        recs.push();
        Rec storage r = recs[recs.length - 1];
        r.dst = uint8(d);
        r.p = p;
        parkedOpen += q.amount;
        parks++;
    }

    function _shadowLevel(uint256 d, uint32 e) internal view returns (uint256) {
        Shadow memory b = shadow[d][e];
        uint256 refill = ((block.timestamp - b.updatedAt) * CAP) / W;
        return b.used > refill ? b.used - refill : 0;
    }

    function _shadowAdmit(uint256 d, uint32 e, uint256 x) internal returns (uint64) {
        uint256 level = _shadowLevel(d, e) + x;
        shadow[d][e] = Shadow(level, block.timestamp);
        if (level <= CAP) return 0;
        return uint64(block.timestamp + ((level - CAP) * W + CAP - 1) / CAP);
    }

    function _open(uint256 seed) internal view returns (bool, uint256) {
        uint256 n = recs.length;
        if (n == 0) return (false, 0);
        uint256 start = seed % n;
        for (uint256 k; k < n; k++) {
            uint256 i = (start + k) % n;
            if (recs[i].state == 0) return (true, i);
        }
        return (false, 0);
    }
}

/// @notice Inbound cap on a six-endpoint mesh (30 paths). Not red-first: written after the fix (8006b3a); the parking
///         API does not exist on 5b5b5f6. What it guards is shown by mutants.
contract BZPXInvariant6Test is TestHelperOz5 {
    using OptionsBuilder for bytes;

    uint256 internal constant N = 6;
    uint256 internal constant MAIN_CHAIN_ID = 8453;
    uint256 internal constant CAP_ORACLE = 10_000_000e18;
    uint128 internal constant LZ_RECEIVE_GAS = 250_000; // = config/network.json lzReceiveGas

    BZPX[N] internal tok;
    Handler6 internal h;
    address internal owner_ = makeAddr("owner");
    address internal user = makeAddr("user");
    address internal third = makeAddr("third");

    function setUp() public override {
        super.setUp();
        setUpEndpoints(uint8(N), LibraryType.UltraLightNode);
        for (uint256 i; i < N; i++) {
            vm.chainId(i == 0 ? MAIN_CHAIN_ID : 1000 + i);
            tok[i] = new BZPX(endpoints[uint32(i + 1)], owner_);
        }
        vm.chainId(31337);
        bytes memory opts = OptionsBuilder.newOptions().addExecutorLzReceiveOption(LZ_RECEIVE_GAS, 0);
        for (uint256 i; i < N; i++) {
            EnforcedOptionParam[] memory p = new EnforcedOptionParam[](N - 1);
            uint256 k;
            vm.startPrank(owner_);
            for (uint256 j; j < N; j++) {
                if (j == i) continue;
                tok[i].setPeer(uint32(j + 1), bytes32(uint256(uint160(address(tok[j])))));
                p[k++] = EnforcedOptionParam(uint32(j + 1), 1, opts);
            }
            tok[i].setEnforcedOptions(p);
            vm.stopPrank();
        }
        address[] memory act = new address[](3);
        act[0] = owner_;
        act[1] = user;
        act[2] = third;
        h = new Handler6(tok, IPacketHelper(address(this)), owner_, makeAddr("keeper"), act);
        // spread supply: one CAP from the main chain to `user` on each mirror (fills each main->mirror bucket at t0)
        for (uint256 d = 1; d < N; d++) h.seedSend(0, d, owner_, user, CAP_ORACLE);
        for (uint256 d = 1; d < N; d++) h.seedDeliver(d);
        vm.prank(owner_);
        tok[0].transfer(third, 100_000_000e18);

        bytes4[] memory sel = new bytes4[](5);
        sel[0] = Handler6.send.selector;
        sel[1] = Handler6.deliver.selector;
        sel[2] = Handler6.claim.selector;
        sel[3] = Handler6.burn.selector;
        sel[4] = Handler6.wait.selector;
        targetSelector(FuzzSelector({ addr: address(h), selectors: sel }));
        targetContract(address(h));
    }

    function invariant_boundB_cumulativePerSourceEid() public view {
        h.checkBoundB();
    }

    function invariant_supplyConserved() public view {
        h.checkConservation();
    }

    function invariant_bucketsMatchShadow() public view {
        h.checkBuckets();
    }

    function invariant_parkedFlagsMatchRecords() public view {
        h.checkParkedFlags();
    }

    function invariant_parkedCountEqualsLiveKeys() public view {
        h.checkParkedCount();
    }

    /// Guard against an empty run: real sends and deliveries happened.
    function afterInvariant() external view {
        assertGt(h.sends(), 0, "no send");
        assertGt(h.deliveries(), 0, "no delivery");
    }

    /// Deterministic coverage of every handler branch on the mesh: park, early claim, claim, burn, mirror-to-mirror.
    function test_handler_parkClaimBurnOnSixChains() public {
        // main -> mirror 1 and 2 buckets are full at t0: two more CAP each park
        h.seedSend(0, 1, owner_, third, CAP_ORACLE);
        h.seedSend(0, 1, owner_, third, CAP_ORACLE);
        h.seedSend(0, 2, owner_, third, CAP_ORACLE);
        // mirror 1 -> mirror 3: fresh bucket for source eid 2, fast path
        h.seedSend(1, 3, user, user, CAP_ORACLE);
        for (uint256 i; i < 2; i++) h.seedDeliver(1);
        h.seedDeliver(2);
        h.seedDeliver(3);
        assertEq(h.parks(), 3, "parks");
        h.claim(0); // releaseAt = t0 + W: early
        assertEq(h.earlyClaims(), 1, "early claim");
        h.burn(1); // delegate burns the second park on mirror 1 and refunds its capacity
        assertEq(h.burns(), 1, "burn");
        vm.warp(block.timestamp + 1 days);
        h.claim(0);
        h.claim(0);
        assertEq(h.claims(), 2, "claims");
        assertEq(tok[3].balanceOf(user), 2 * CAP_ORACLE, "mirror-to-mirror fast path (one CAP from setUp + one from mirror 1)");
        h.checkBoundB();
        h.checkConservation();
        h.checkBuckets();
        h.checkParkedFlags();
        h.checkParkedCount();
    }
}
