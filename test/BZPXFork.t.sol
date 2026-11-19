// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, Vm, console2 } from "forge-std/Test.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { EnforcedOptionParam } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import { SendParam, MessagingFee } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { Origin, ILayerZeroEndpointV2 } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import { IMessageLib } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLib.sol";
import { Errors } from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/Errors.sol";
import { PacketV1Codec } from "@layerzerolabs/lz-evm-protocol-v2/contracts/messagelib/libs/PacketV1Codec.sol";
import { UlnConfig } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import { ExecutorConfig } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/SendLibBase.sol";
import { BZPX } from "../src/BZPX.sol";

interface IReceiveUln {
    function verify(bytes calldata _packetHeader, bytes32 _payloadHash, uint64 _confirmations) external;
    function commitVerification(bytes calldata _packetHeader, bytes32 _payloadHash) external;
}

interface ILibApp {
    function executorConfigs(address oapp, uint32 eid) external view returns (uint32 maxMessageSize, address executor);
    function getAppUlnConfig(address oapp, uint32 eid) external view returns (UlnConfig memory);
}

interface IEndpointExtra {
    function delegates(address oapp) external view returns (address);
    function eid() external view returns (uint32);
}

/// @dev Test against the REAL Base and Robinhood endpoints (forks). Touches no keys and broadcasts nothing.
///      RPCs via environment variables (RPC_BASE, RPC_ROBINHOOD; by default the public ones in config/network.json).
///      Blocks via BLOCK_BASE / BLOCK_RH (0 = latest).
///      Delivery works as on the network: the 2 configured DVNs attest (prank), anyone calls commitVerification,
///      and anyone calls endpoint.lzReceive with the enforced-option gas (the executor does this on the network).
contract BZPXForkTest is Test {
    using OptionsBuilder for bytes;
    using PacketV1Codec for bytes;

    struct ChainCfg {
        string name;
        uint256 chainId;
        uint32 eid;
        address endpoint;
        address sendLib;
        address receiveLib;
        address executor;
        uint32 maxMessageSize;
        address[] dvns;
        uint64 confirmations;
        string rpc;
    }

    // Dead DVN (the default DVN in both directions, checked on-chain on 2026-10-29)
    address internal constant DEAD_DVN_BASE = 0x6498b0632f3834D7647367334838111c8C889703;
    address internal constant DEAD_DVN_RH = 0x6788f52439ACA6BFF597d3eeC2DC9a44B8FEE842;
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;
    bytes32 internal constant PACKET_SENT = keccak256("PacketSent(bytes,bytes,address)");

    ChainCfg internal base;
    ChainCfg internal rh;
    uint256 internal mainChainId;
    uint128 internal lzReceiveGas;
    uint256 internal forkBase;
    uint256 internal forkRh;
    BZPX internal tBase;
    BZPX internal tRh;
    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");

    function setUp() public {
        string memory json = vm.readFile("config/network.json");
        base = _read(json, ".chains.base");
        rh = _read(json, ".chains.robinhood");
        mainChainId = vm.parseJsonUint(json, ".mainChainId");
        lzReceiveGas = uint128(vm.parseJsonUint(json, ".lzReceiveGas"));

        forkBase = _fork(vm.envOr("RPC_BASE", base.rpc), vm.envOr("BLOCK_BASE", uint256(0)));
        forkRh = _fork(vm.envOr("RPC_ROBINHOOD", rh.rpc), vm.envOr("BLOCK_RH", uint256(0)));

        // same constructor on both chains, as in deploy/deploy.mjs
        vm.selectFork(forkBase);
        vm.deal(owner, 10 ether);
        tBase = new BZPX(base.endpoint, owner);
        console2.log("base block", block.number);
        vm.selectFork(forkRh);
        vm.deal(owner, 10 ether);
        vm.deal(user, 10 ether);
        tRh = new BZPX(rh.endpoint, owner);
        console2.log("robinhood block", block.number);
    }

    // ---------------------------------------------------------------- tests

    /// The deployment points at the right endpoint on each chain, with the right eid, and only Base mints.
    function test_fork_endpointEidChainIdAndSupply() public {
        _confereChain(forkBase, tBase, base, rh, SUPPLY);
        _confereChain(forkRh, tRh, rh, base, 0);
    }

    /// With the LayerZero default config (Dead DVN) no transfer is possible: the explicit config is mandatory.
    function test_fork_defaultRouteHasDeadDVN() public {
        vm.selectFork(forkBase);
        _wirePeerOnly(tBase, rh.eid, address(tRh));
        _checkDeadDVN(base.sendLib, tBase, rh.eid, DEAD_DVN_BASE);
        vm.expectRevert();
        tBase.quoteSend(_param(rh.eid, user, 1e18), false);

        vm.selectFork(forkRh);
        _wirePeerOnly(tRh, base.eid, address(tBase));
        _checkDeadDVN(rh.sendLib, tRh, base.eid, DEAD_DVN_RH);
        vm.expectRevert();
        tRh.quoteSend(_param(base.eid, user, 1e18), false);
    }

    /// After "wire" (libs, executor, 2 DVNs, confirmations, enforced options), a quote exists in both directions
    /// and the effective config read from the endpoint is exactly the requested one (no dependence on defaults).
    function test_fork_wireGivesQuoteAndPinnedConfig() public {
        _wireAll();
        vm.selectFork(forkBase);
        MessagingFee memory f1 = tBase.quoteSend(_param(rh.eid, user, 1e18), false);
        _checkEffectiveConfig(tBase, base, rh);
        vm.selectFork(forkRh);
        MessagingFee memory f2 = tRh.quoteSend(_param(base.eid, user, 1e18), false);
        _checkEffectiveConfig(tRh, rh, base);
        console2.log("fee base->rh (wei)", f1.nativeFee);
        console2.log("fee rh->base (wei)", f2.nativeFee);
        assertGt(f1.nativeFee, 0);
        assertGt(f2.nativeFee, 0);
        assertLt(f1.nativeFee, 0.01 ether, "fee base->rh absurd");
        assertLt(f2.nativeFee, 0.01 ether, "fee rh->base absurd");
    }

    /// Round trip through the real endpoints, ULNs and DVNs: 1 DVN is not enough, 2 are; sum of supplies = 1e9.
    function test_fork_endToEndRoundTrip() public {
        _wireAll();
        uint256 out = 1000e18;
        uint256 back = 400e18;

        // Base -> Robinhood
        vm.selectFork(forkBase);
        bytes memory packet = _sendPacket(tBase, base, rh.eid, owner, user, out);
        assertEq(tBase.totalSupply(), SUPPLY - out, "base did not burn");
        vm.selectFork(forkRh);
        uint256 gasOut = _deliverPacket(packet, rh, base.confirmations, address(tRh));
        assertEq(tRh.balanceOf(user), out, "rh did not mint");
        assertEq(tRh.totalSupply(), out);

        // Robinhood -> Base
        bytes memory packet2 = _sendPacket(tRh, rh, base.eid, user, owner, back);
        assertEq(tRh.totalSupply(), out - back, "rh did not burn");
        vm.selectFork(forkBase);
        uint256 gasBack = _deliverPacket(packet2, base, rh.confirmations, address(tBase));
        assertEq(tBase.balanceOf(owner), SUPPLY - out + back, "base did not mint");

        // invariant
        uint256 sBase = tBase.totalSupply();
        vm.selectFork(forkRh);
        assertEq(sBase + tRh.totalSupply(), SUPPLY, "sum != 1e9");

        console2.log("gas endpoint.lzReceive rh (1st receipt)", gasOut);
        console2.log("gas endpoint.lzReceive base", gasBack);
        // at least 50 % headroom over the worst measured case (1st receipt: new recipient, supply 0, new nonce)
        assertLt(gasOut * 3 / 2, lzReceiveGas, "headroom < 50% (out)");
        assertLt(gasBack * 3 / 2, lzReceiveGas, "headroom < 50% (back)");
    }

    /// A packet from a sender that is not the peer, even with both DVNs attesting, does not pass the real endpoint.
    function test_fork_wrongPeerRejected() public {
        _wireAll();
        vm.selectFork(forkRh);
        address fake = makeAddr("bzpx-fake");
        bytes memory msg_ = abi.encodePacked(bytes32(uint256(uint160(user))), uint64(1e12)); // 1e12 SD = 1e24 LD
        bytes memory header = abi.encodePacked(
            uint8(1), uint64(1), base.eid, bytes32(uint256(uint160(fake))), rh.eid, bytes32(uint256(uint160(address(tRh))))
        );
        bytes32 payloadHash = keccak256(abi.encodePacked(keccak256("guid"), msg_));
        for (uint256 i = 0; i < rh.dvns.length; i++) {
            vm.prank(rh.dvns[i]);
            IReceiveUln(rh.receiveLib).verify(header, payloadHash, base.confirmations);
        }
        vm.expectRevert(Errors.LZ_PathNotInitializable.selector);
        IReceiveUln(rh.receiveLib).commitVerification(header, payloadHash);
        assertEq(tRh.totalSupply(), 0);
    }

    // ---------------------------------------------------------------- wire (mirrors deploy/deploy.mjs "wire")

    function _wireAll() internal {
        vm.selectFork(forkBase);
        _wire(tBase, base, rh, address(tRh));
        vm.selectFork(forkRh);
        _wire(tRh, rh, base, address(tBase));
    }

    function _wire(BZPX t, ChainCfg memory loc, ChainCfg memory rem, address peer) internal {
        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(loc.endpoint);
        vm.startPrank(owner);
        t.setPeer(rem.eid, bytes32(uint256(uint160(peer))));
        ep.setSendLibrary(address(t), rem.eid, loc.sendLib);
        ep.setReceiveLibrary(address(t), rem.eid, loc.receiveLib, 0);
        SetConfigParam[] memory s = new SetConfigParam[](2);
        s[0] = SetConfigParam(rem.eid, 1, abi.encode(ExecutorConfig(loc.maxMessageSize, loc.executor)));
        s[1] = SetConfigParam(rem.eid, 2, abi.encode(_uln(loc.confirmations, loc.dvns)));
        ep.setConfig(address(t), loc.sendLib, s);
        SetConfigParam[] memory r = new SetConfigParam[](1);
        r[0] = SetConfigParam(rem.eid, 2, abi.encode(_uln(rem.confirmations, loc.dvns)));
        ep.setConfig(address(t), loc.receiveLib, r);
        t.setEnforcedOptions(_enforced(rem.eid));
        vm.stopPrank();
    }

    function _wirePeerOnly(BZPX t, uint32 remEid, address peer) internal {
        vm.startPrank(owner);
        t.setPeer(remEid, bytes32(uint256(uint160(peer))));
        t.setEnforcedOptions(_enforced(remEid));
        vm.stopPrank();
    }

    function _enforced(uint32 remEid) internal view returns (EnforcedOptionParam[] memory p) {
        p = new EnforcedOptionParam[](1);
        p[0] = EnforcedOptionParam(remEid, 1, OptionsBuilder.newOptions().addExecutorLzReceiveOption(lzReceiveGas, 0));
    }

    /// 2 required DVNs, optional NIL (255): nothing inherited from the default config.
    function _uln(uint64 conf, address[] memory dvns) internal pure returns (UlnConfig memory) {
        return UlnConfig(conf, uint8(dvns.length), type(uint8).max, 0, dvns, new address[](0));
    }

    // ---------------------------------------------------------------- send and delivery

    function _sendPacket(BZPX t, ChainCfg memory loc, uint32 dstEid, address from, address to, uint256 amount)
        internal
        returns (bytes memory packet)
    {
        SendParam memory p = _param(dstEid, to, amount);
        MessagingFee memory fee = t.quoteSend(p, false);
        vm.recordLogs();
        vm.prank(from);
        t.send{ value: fee.nativeFee }(p, fee, from);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == loc.endpoint && logs[i].topics[0] == PACKET_SENT) {
                address lib;
                (packet,, lib) = abi.decode(logs[i].data, (bytes, bytes, address));
                assertEq(lib, loc.sendLib, "unexpected send lib");
                return packet;
            }
        }
        revert("no PacketSent");
    }

    /// Delivers as on the network, asserting that 1 DVN is not enough and that too few confirmations are not enough.
    function _deliverPacket(bytes memory packet, ChainCfg memory dst, uint64 conf, address receiver)
        internal
        returns (uint256 gasUsed)
    {
        (bytes memory header, bytes32 payloadHash, Origin memory o, bytes32 guid, bytes memory message) = this.parts(packet);
        assertEq(o.srcEid == base.eid ? rh.eid : base.eid, dst.eid);
        IReceiveUln uln = IReceiveUln(dst.receiveLib);

        // 1st DVN with too few confirmations, then only 1 DVN: not yet verifiable
        vm.prank(dst.dvns[0]);
        uln.verify(header, payloadHash, conf - 1);
        vm.expectRevert(bytes4(keccak256("LZ_ULN_Verifying()")));
        uln.commitVerification(header, payloadHash);
        vm.prank(dst.dvns[0]);
        uln.verify(header, payloadHash, conf);
        vm.expectRevert(bytes4(keccak256("LZ_ULN_Verifying()")));
        uln.commitVerification(header, payloadHash);
        // 2nd DVN: now it works
        vm.prank(dst.dvns[1]);
        uln.verify(header, payloadHash, conf);
        uln.commitVerification(header, payloadHash);

        ILayerZeroEndpointV2(dst.endpoint).lzReceive{ gas: lzReceiveGas }(o, receiver, guid, message, "");
        gasUsed = vm.lastCallGas().gasTotalUsed; // gas spent inside the endpoint call (= what the executor must provide)
    }

    function parts(bytes calldata p)
        external
        pure
        returns (bytes memory header, bytes32 payloadHash, Origin memory o, bytes32 guid, bytes memory message)
    {
        header = p.header();
        payloadHash = p.payloadHash();
        o = Origin(p.srcEid(), p.sender(), p.nonce());
        guid = p.guid();
        message = p.message();
    }

    // ---------------------------------------------------------------- checks

    function _confereChain(uint256 fork, BZPX t, ChainCfg memory loc, ChainCfg memory rem, uint256 supply) internal {
        vm.selectFork(fork);
        assertEq(block.chainid, loc.chainId, string.concat(loc.name, ": chainid"));
        assertGt(loc.endpoint.code.length, 0, string.concat(loc.name, ": endpoint has no code"));
        assertEq(address(t.endpoint()), loc.endpoint, string.concat(loc.name, ": endpoint"));
        assertEq(IEndpointExtra(loc.endpoint).eid(), loc.eid, string.concat(loc.name, ": eid"));
        assertEq(IEndpointExtra(loc.endpoint).delegates(address(t)), owner, string.concat(loc.name, ": delegate"));
        assertEq(t.owner(), owner);
        assertEq(t.totalSupply(), supply, string.concat(loc.name, ": supply"));
        assertEq(t.balanceOf(owner), supply);
        assertEq(t.name(), "Blaze Phoenix");
        assertEq(t.symbol(), "BZPX");
        assertEq(t.decimals(), 18);
        assertEq(t.sharedDecimals(), 6);
        // default libs = the ones wire pins
        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(loc.endpoint);
        assertEq(ep.getSendLibrary(address(t), rem.eid), loc.sendLib, string.concat(loc.name, ": default send lib"));
        (address rl, bool isDefault) = ep.getReceiveLibrary(address(t), rem.eid);
        assertEq(rl, loc.receiveLib, string.concat(loc.name, ": default receive lib"));
        assertTrue(isDefault);
        assertTrue(ep.isSupportedEid(rem.eid), string.concat(loc.name, ": remote eid unsupported"));
    }

    function _checkDeadDVN(address sendLib, BZPX t, uint32 remEid, address dead) internal view {
        UlnConfig memory c = abi.decode(IMessageLib(sendLib).getConfig(remEid, address(t), 2), (UlnConfig));
        assertEq(c.requiredDVNs.length, 1, "default: n DVNs");
        assertEq(c.requiredDVNs[0], dead, "default: DVN is not the Dead DVN");
    }

    function _checkEffectiveConfig(BZPX t, ChainCfg memory loc, ChainCfg memory rem) internal view {
        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(loc.endpoint);
        assertEq(ep.getSendLibrary(address(t), rem.eid), loc.sendLib);
        (address rl, bool isDefault) = ep.getReceiveLibrary(address(t), rem.eid);
        assertEq(rl, loc.receiveLib);
        assertFalse(isDefault, "receive lib still default");
        ExecutorConfig memory e = abi.decode(IMessageLib(loc.sendLib).getConfig(rem.eid, address(t), 1), (ExecutorConfig));
        assertEq(e.executor, loc.executor);
        assertEq(e.maxMessageSize, loc.maxMessageSize);
        UlnConfig memory s = abi.decode(IMessageLib(loc.sendLib).getConfig(rem.eid, address(t), 2), (UlnConfig));
        assertEq(s.confirmations, loc.confirmations);
        assertEq(s.requiredDVNs, loc.dvns);
        assertEq(s.optionalDVNs.length, 0);
        UlnConfig memory r = abi.decode(IMessageLib(loc.receiveLib).getConfig(rem.eid, address(t), 2), (UlnConfig));
        assertEq(r.confirmations, rem.confirmations);
        assertEq(r.requiredDVNs, loc.dvns);
        assertEq(r.optionalDVNs.length, 0);
        // the OApp's OWN config (not inherited): pinned even if LayerZero changes the defaults
        (uint32 mms, address ex) = ILibApp(loc.sendLib).executorConfigs(address(t), rem.eid);
        assertEq(mms, loc.maxMessageSize, "executor app: maxMessageSize");
        assertEq(ex, loc.executor, "executor app: executor");
        UlnConfig memory sa = ILibApp(loc.sendLib).getAppUlnConfig(address(t), rem.eid);
        assertEq(sa.confirmations, loc.confirmations, "uln app send: conf");
        assertEq(sa.requiredDVNCount, loc.dvns.length);
        assertEq(sa.optionalDVNCount, type(uint8).max, "uln app send: optional NIL");
        assertEq(sa.requiredDVNs, loc.dvns);
        UlnConfig memory ra = ILibApp(loc.receiveLib).getAppUlnConfig(address(t), rem.eid);
        assertEq(ra.confirmations, rem.confirmations, "uln app receive: conf");
        assertEq(ra.requiredDVNCount, loc.dvns.length);
        assertEq(ra.optionalDVNCount, type(uint8).max, "uln app receive: optional NIL");
        assertEq(ra.requiredDVNs, loc.dvns);
        assertFalse(ep.isDefaultSendLibrary(address(t), rem.eid), "send lib still default");
    }

    // ---------------------------------------------------------------- utils

    function _param(uint32 dstEid, address to, uint256 amountLD) internal pure returns (SendParam memory) {
        return SendParam(dstEid, bytes32(uint256(uint160(to))), amountLD, 0, "", "", "");
    }

    function _fork(string memory url, uint256 blockNumber) internal returns (uint256) {
        return blockNumber == 0 ? vm.createFork(url) : vm.createFork(url, blockNumber);
    }

    function _read(string memory json, string memory k) internal pure returns (ChainCfg memory c) {
        c.name = vm.parseJsonString(json, string.concat(k, ".name"));
        c.chainId = vm.parseJsonUint(json, string.concat(k, ".chainId"));
        c.eid = uint32(vm.parseJsonUint(json, string.concat(k, ".eid")));
        c.endpoint = vm.parseJsonAddress(json, string.concat(k, ".endpoint"));
        c.sendLib = vm.parseJsonAddress(json, string.concat(k, ".sendLib"));
        c.receiveLib = vm.parseJsonAddress(json, string.concat(k, ".receiveLib"));
        c.executor = vm.parseJsonAddress(json, string.concat(k, ".executor"));
        c.maxMessageSize = uint32(vm.parseJsonUint(json, string.concat(k, ".maxMessageSize")));
        c.dvns = vm.parseJsonAddressArray(json, string.concat(k, ".dvns"));
        c.confirmations = uint64(vm.parseJsonUint(json, string.concat(k, ".confirmations")));
        c.rpc = vm.parseJsonString(json, string.concat(k, ".rpc"));
    }
}
