// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { EnforcedOptionParam } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { OAppReceiver } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppReceiver.sol";
import { IOFT, SendParam, OFTReceipt, MessagingFee } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { Origin, ILayerZeroEndpointV2 } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import { Errors } from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/Errors.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { BZPX } from "../src/BZPX.sol";

interface IEndpointDelegates {
    function delegates(address oapp) external view returns (address);
}

/// @dev Common base: two mock endpoints (TestHelperOz5), A = "Base" (main), B = "Robinhood" (mirror).
///      Deployment and wiring mirror deploy/deploy.mjs: same constructor on both chains, mainChainId = 8453.
abstract contract BZPXBase is TestHelperOz5 {
    using OptionsBuilder for bytes;

    uint32 internal constant A_EID = 1; // "Base"
    uint32 internal constant B_EID = 2; // "Robinhood"
    uint256 internal constant MAIN_CHAIN_ID = 8453;
    uint256 internal constant MIRROR_CHAIN_ID = 4663;
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 internal constant CAP_ORACLE = 10_000_000e18; // inbound cap per source eid per window
    uint128 internal constant LZ_RECEIVE_GAS = 250_000; // = config/network.json lzReceiveGas

    BZPX internal a;
    BZPX internal b;
    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");
    address internal attacker = makeAddr("attacker");

    function setUp() public virtual override {
        vm.deal(owner, 1000 ether);
        vm.deal(user, 1000 ether);
        vm.deal(attacker, 1000 ether);
        super.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        vm.chainId(MAIN_CHAIN_ID);
        a = new BZPX(endpoints[A_EID], owner);
        vm.chainId(MIRROR_CHAIN_ID);
        b = new BZPX(endpoints[B_EID], owner);
        vm.chainId(31337); // back to the forge default chainid

        _wire(a, B_EID, address(b));
        _wire(b, A_EID, address(a));
    }

    /// @dev What the script's "wire" step does on the OFT side: peer + enforced options (lzReceive gas) for SEND.
    function _wire(BZPX local, uint32 remoteEid, address remote) internal {
        EnforcedOptionParam[] memory p = new EnforcedOptionParam[](1);
        p[0] = EnforcedOptionParam(remoteEid, 1, _options());
        vm.startPrank(owner);
        local.setPeer(remoteEid, bytes32(uint256(uint160(remote))));
        local.setEnforcedOptions(p);
        vm.stopPrank();
    }

    function _options() internal pure returns (bytes memory) {
        return OptionsBuilder.newOptions().addExecutorLzReceiveOption(LZ_RECEIVE_GAS, 0);
    }

    function _param(uint32 dstEid, address to, uint256 amountLD, uint256 minLD) internal pure returns (SendParam memory) {
        return SendParam(dstEid, bytes32(uint256(uint160(to))), amountLD, minLD, "", "", "");
    }

    function _send(BZPX src, uint32 dstEid, address from, address to, uint256 amountLD)
        internal
        returns (OFTReceipt memory r)
    {
        SendParam memory p = _param(dstEid, to, amountLD, 0);
        MessagingFee memory fee = src.quoteSend(p, false);
        vm.prank(from);
        (, r) = src.send{ value: fee.nativeFee }(p, fee, from);
    }

    function _deliverPackets(uint32 dstEid, BZPX dst) internal {
        verifyPackets(dstEid, addressToBytes32(address(dst)));
    }

    /// @dev The script's renounce procedure (deploy.mjs renounce): clear the delegate first, then renounce.
    function _renounce(BZPX t) internal {
        vm.startPrank(owner);
        t.setDelegate(address(0));
        t.renounceOwnership();
        vm.stopPrank();
    }

    function _totalSum() internal view returns (uint256) {
        return a.totalSupply() + b.totalSupply();
    }
}

contract BZPXTest is BZPXBase {
    // 1. Initial supply exists only on the main chain.
    function test_initialSupplyOnlyOnMain() public view {
        assertEq(a.totalSupply(), SUPPLY, "main: supply");
        assertEq(a.balanceOf(owner), SUPPLY, "main: everything with the owner");
        assertEq(b.totalSupply(), 0, "mirror: supply 0");
        assertEq(a.name(), "Blaze Phoenix");
        assertEq(a.symbol(), "BZPX");
        assertEq(b.name(), "Blaze Phoenix");
        assertEq(b.symbol(), "BZPX");
        assertEq(a.owner(), owner);
        assertEq(b.owner(), owner);
        assertEq(IEndpointDelegates(endpoints[A_EID]).delegates(address(a)), owner, "delegate A");
        assertEq(IEndpointDelegates(endpoints[B_EID]).delegates(address(b)), owner, "delegate B");
    }

    function testFuzz_constructorMintsOnlyOnMainChain(uint64 chainId) public {
        vm.chainId(chainId);
        BZPX t = new BZPX(endpoints[A_EID], owner);
        assertEq(t.totalSupply(), chainId == MAIN_CHAIN_ID ? SUPPLY : 0);
    }

    function test_constructorRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new BZPX(endpoints[A_EID], address(0));
    }

    // 2. Base -> Robinhood and back.
    function test_sendRoundTrip() public {
        OFTReceipt memory r = _send(a, B_EID, owner, user, 1000e18);
        assertEq(r.amountSentLD, 1000e18);
        assertEq(a.totalSupply(), SUPPLY - 1000e18, "burned at the source");
        assertEq(b.balanceOf(user), 0, "still in flight");
        _deliverPackets(B_EID, b);
        assertEq(b.balanceOf(user), 1000e18, "minted at the destination");
        assertEq(_totalSum(), SUPPLY);

        _send(b, A_EID, user, owner, 400e18);
        assertEq(b.totalSupply(), 600e18);
        _deliverPackets(A_EID, a);
        assertEq(a.balanceOf(owner), SUPPLY - 600e18);
        assertEq(b.balanceOf(user), 600e18);
        assertEq(_totalSum(), SUPPLY);
    }

    // 3. Sum <= 1e9 under fuzz (see also BZPXInvariant.t.sol).
    function testFuzz_sumNeverExceedsSupply(uint256 out, uint256 back) public {
        out = bound(out, 0, CAP_ORACLE); // one packet carries at most the inbound cap
        _send(a, B_EID, owner, user, out);
        uint256 out_ = (out / 1e12) * 1e12;
        assertEq(_totalSum(), SUPPLY - out_, "in flight: sum = supply - in flight");
        _deliverPackets(B_EID, b);
        assertEq(_totalSum(), SUPPLY);
        back = bound(back, 0, b.balanceOf(user)); // <= out <= cap
        _send(b, A_EID, user, user, back);
        assertLe(_totalSum(), SUPPLY);
        _deliverPackets(A_EID, a);
        assertEq(_totalSum(), SUPPLY);
    }

    // 4. A message from the wrong peer is rejected (direct and end to end).
    function test_wrongPeerRejected_direct() public {
        bytes memory msg_ = abi.encodePacked(bytes32(uint256(uint160(attacker))), uint64(1e15));
        Origin memory o = Origin(A_EID, bytes32(uint256(uint160(attacker))), 1);
        vm.prank(endpoints[B_EID]);
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.OnlyPeer.selector, A_EID, o.sender));
        b.lzReceive(o, bytes32(0), msg_, address(0), "");
        // and a caller that is not the endpoint never reaches the peer check
        Origin memory ok = Origin(A_EID, bytes32(uint256(uint160(address(a)))), 1);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OAppReceiver.OnlyEndpoint.selector, attacker));
        b.lzReceive(ok, bytes32(0), msg_, address(0), "");
        assertEq(b.totalSupply(), 0);
    }

    function test_wrongPeerRejected_endToEnd() public {
        // The attacker deploys its own "BZPX" on chain A (with 1e9 fake tokens) and points it at our B.
        vm.chainId(MAIN_CHAIN_ID);
        BZPX fake = new BZPX(endpoints[A_EID], attacker);
        vm.startPrank(attacker);
        fake.setPeer(B_EID, bytes32(uint256(uint160(address(b)))));
        EnforcedOptionParam[] memory p = new EnforcedOptionParam[](1);
        p[0] = EnforcedOptionParam(B_EID, 1, _options());
        fake.setEnforcedOptions(p);
        vm.stopPrank();
        _send(fake, B_EID, attacker, attacker, 1e24);
        vm.expectRevert(); // the endpoint refuses: b.allowInitializePath(fake origin) == false
        this.verifyPackets(B_EID, addressToBytes32(address(b)));
        assertEq(b.totalSupply(), 0, "nothing minted");
    }

    // 5. An unauthorized caller changes nothing (OFT and endpoint).
    function test_unauthorizedChangesNothing() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker);
        vm.startPrank(attacker);
        vm.expectRevert(err);
        a.setPeer(B_EID, bytes32(uint256(uint160(attacker))));
        vm.expectRevert(err);
        a.setDelegate(attacker);
        vm.expectRevert(err);
        a.setEnforcedOptions(new EnforcedOptionParam[](0));
        vm.expectRevert(err);
        a.setMsgInspector(attacker);
        vm.expectRevert(err);
        a.setPreCrime(attacker);
        vm.expectRevert(err);
        a.transferOwnership(attacker);
        vm.expectRevert(err);
        a.renounceOwnership();
        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(endpoints[A_EID]);
        address lib = ep.defaultSendLibrary(B_EID);
        vm.expectRevert(Errors.LZ_Unauthorized.selector);
        ep.setConfig(address(a), lib, new SetConfigParam[](0));
        vm.expectRevert(Errors.LZ_Unauthorized.selector);
        ep.setSendLibrary(address(a), B_EID, lib);
        vm.stopPrank();
        assertEq(a.peers(B_EID), bytes32(uint256(uint160(address(b)))));
        assertEq(a.owner(), owner);
    }

    // 6. After renouncing (setDelegate(0) + renounceOwnership) nobody can change peers or config; sends keep working.
    function test_afterRenounceNobodyCanChange() public {
        _renounce(a);
        assertEq(a.owner(), address(0));
        assertEq(IEndpointDelegates(endpoints[A_EID]).delegates(address(a)), address(0), "delegate cleared");
        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(endpoints[A_EID]);
        address lib = ep.defaultSendLibrary(B_EID);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        a.setPeer(B_EID, bytes32(uint256(uint160(attacker))));
        vm.expectRevert(Errors.LZ_Unauthorized.selector);
        ep.setConfig(address(a), lib, new SetConfigParam[](0));
        vm.expectRevert(Errors.LZ_Unauthorized.selector);
        ep.setSendLibrary(address(a), B_EID, lib);
        vm.stopPrank();
        // liveness: keeps working without an owner
        _send(a, B_EID, owner, user, 5e18);
        _deliverPackets(B_EID, b);
        assertEq(b.balanceOf(user), 5e18);
    }

    /// @dev Documents the trap: renounceOwnership() alone does NOT remove the delegate on the endpoint.
    function test_renounceWithoutClearingDelegateLeavesEndpointPower() public {
        vm.prank(owner);
        a.renounceOwnership();
        assertEq(IEndpointDelegates(endpoints[A_EID]).delegates(address(a)), owner);
        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(endpoints[A_EID]);
        address lib = ep.defaultSendLibrary(B_EID);
        vm.prank(owner);
        ep.setSendLibrary(address(a), B_EID, lib); // succeeds: the delegate still has control
        assertEq(ep.getSendLibrary(address(a), B_EID), lib);
    }

    // 7. Decimals: 18 local, 6 shared, dust stays with the sender.
    function test_decimalsAndDust() public {
        assertEq(a.decimals(), 18);
        assertEq(b.decimals(), 18);
        assertEq(a.sharedDecimals(), 6);
        assertEq(a.decimalConversionRate(), 1e12);
        assertEq(b.decimalConversionRate(), 1e12);
        uint256 before_ = a.balanceOf(owner);
        OFTReceipt memory r = _send(a, B_EID, owner, user, 1e12 + 123);
        assertEq(r.amountSentLD, 1e12, "dust removed");
        assertEq(r.amountReceivedLD, 1e12);
        assertEq(a.balanceOf(owner), before_ - 1e12, "dust stays with the sender");
        _deliverPackets(B_EID, b);
        assertEq(b.balanceOf(user), 1e12);
        // below 1e12 wei (1e-6 BZPX) nothing goes through; with minAmountLD = amountLD it reverts on slippage
        SendParam memory p = _param(B_EID, user, 1e12 - 1, 1e12 - 1);
        vm.expectRevert(abi.encodeWithSelector(IOFT.SlippageExceeded.selector, 0, 1e12 - 1));
        a.quoteSend(p, false);
    }

    // 8. Limits: the whole supply fits in one send; the uint64 ceiling is ~18,446x above the supply.
    function test_limitsFullCapRoundTrip() public {
        // the largest packet is the inbound cap (BZPXCap.t.sol covers cap + 1 unit)
        _send(a, B_EID, owner, user, CAP_ORACLE);
        assertEq(a.totalSupply(), SUPPLY - CAP_ORACLE);
        _deliverPackets(B_EID, b);
        assertEq(b.totalSupply(), CAP_ORACLE);
        _send(b, A_EID, user, owner, CAP_ORACLE);
        _deliverPackets(A_EID, a);
        assertEq(a.balanceOf(owner), SUPPLY);
        assertEq(b.totalSupply(), 0);
    }

    function test_limitsUint64OverflowReverts() public {
        // the uint64 shared-decimals ceiling is unreachable: the inbound cap refuses first, at quote time
        uint256 maxLD = uint256(type(uint64).max) * 1e12;
        assertGt(maxLD / SUPPLY, 18_000, "headroom of the uint64 ceiling over the supply");
        bytes4 capErr = bytes4(keccak256("InboundCapExceeded(uint32,uint256,uint256)"));
        vm.expectRevert(abi.encodeWithSelector(capErr, B_EID, maxLD + 1e12, CAP_ORACLE));
        a.quoteSend(_param(B_EID, user, maxLD + 1e12, 0), false);
        vm.expectRevert(abi.encodeWithSelector(capErr, B_EID, maxLD, CAP_ORACLE));
        a.quoteSend(_param(B_EID, user, maxLD, 0), false);
    }

    // 9. The lzReceive gas (new recipient) fits within the enforced option with headroom.
    /// The enforced options hand-encoded by deploy/deploy.mjs are byte-for-byte those of OptionsBuilder.
    function test_optionsMatchScript() public pure {
        assertEq(_options(), hex"0003010011010000000000000000000000000003d090");
    }

    function test_lzReceiveGasFitsEnforced() public {
        bytes memory m = abi.encodePacked(bytes32(uint256(uint160(makeAddr("fresh")))), uint64(1e6));
        Origin memory o = Origin(A_EID, bytes32(uint256(uint160(address(a)))), 1);
        vm.prank(endpoints[B_EID]);
        uint256 g = gasleft();
        b.lzReceive(o, bytes32(uint256(1)), m, address(0), "");
        g -= gasleft();
        emit log_named_uint("gas lzReceive OFT (new recipient)", g);
        assertLt(g, LZ_RECEIVE_GAS / 2, "headroom >= 2x");
        assertEq(b.balanceOf(makeAddr("fresh")), 1e18);
    }
}
