// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { Origin } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

interface IEndpointV2Delegates {
    function delegates(address oapp) external view returns (address);
}

/// @title BZPX (Blaze Phoenix)
/// @notice Standard LayerZero V2 OFT (burn on send, mint on receive), unmodified: oft-evm 4.0.1 from
///         LayerZero-Labs and OpenZeppelin Contracts 5.6.1. The only own logic:
///         1. Fixed supply: TOTAL_SUPPLY is minted once, in the constructor, and only on chain MAIN_CHAIN_ID.
///            On every other chain the supply starts at 0 and only grows with packets from peers, which burn
///            the same amount on the source chain.
///         2. Inbound cap: the amount credited from one source endpoint id is limited to INBOUND_CAP per
///            INBOUND_WINDOW (capacity refills linearly). A delivery above the available capacity never reverts:
///            the packet is parked here with a release time (FIFO per source eid) and anyone can claim it from
///            then on. The endpoint delegate can burn a parked packet, which refunds its capacity. A packet above
///            INBOUND_CAP is rejected without credit or debt: a send above INBOUND_CAP reverts on the source chain.
/// @dev owner_ is both the Ownable owner and the endpoint delegate. A full renounce needs
///      setDelegate(address(0)) and then renounceOwnership(): the delegate survives renounceOwnership().
///      transferOwnership moves the delegate to the new owner.
contract BZPX is OFT {
    uint256 public constant MAIN_CHAIN_ID = 8453;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant INBOUND_CAP = 10_000_000e18;
    uint256 public constant INBOUND_WINDOW = 1 days;

    using OFTMsgCodec for bytes;
    using OFTMsgCodec for bytes32;

    struct Inbound {
        uint192 used; // level; above INBOUND_CAP while packets are parked (debt)
        uint64 updatedAt;
    }

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

    mapping(uint32 srcEid => Inbound) public inbound;
    mapping(bytes32 key => bool) public parked;
    uint256 public parkedCount; // parked packets not yet claimed or burned, all source eids

    event InboundParked(bytes32 indexed key, ParkedPacket packet);
    event InboundRejected(bytes32 indexed guid, uint32 srcEid, address to, uint256 amountLD);
    event ParkedBurned(bytes32 indexed key);

    error InboundCapExceeded(uint32 eid, uint256 amountLD, uint256 availableLD);
    error ParkedNotFound(bytes32 key);
    error ParkedNotReleased(bytes32 key, uint64 releaseAt);
    error NotEndpointDelegate(address caller);

    constructor(address lzEndpoint_, address owner_)
        OFT("Blaze Phoenix", "BZPX", lzEndpoint_, owner_)
        Ownable(owner_)
    {
        if (block.chainid == MAIN_CHAIN_ID) _mint(owner_, TOTAL_SUPPLY);
    }

    /// @notice Amount that can be credited now from srcEid_: the cap minus the level after refill, floor 0.
    function inboundAvailable(uint32 srcEid_) public view returns (uint256) {
        uint256 level = _level(srcEid_);
        return level < INBOUND_CAP ? INBOUND_CAP - level : 0;
    }

    /// @notice Credits a parked packet from its release time on. Permissionless; same peer check as lzReceive.
    function claimParked(ParkedPacket calldata p_) external {
        bytes32 key = keccak256(abi.encode(p_));
        if (!parked[key]) revert ParkedNotFound(key);
        if (block.timestamp < p_.releaseAt) revert ParkedNotReleased(key, p_.releaseAt);
        if (_getPeerOrRevert(p_.srcEid) != p_.sender) revert OnlyPeer(p_.srcEid, p_.sender);
        delete parked[key];
        parkedCount--;
        uint256 amountReceivedLD = _credit(p_.to, p_.amountLD, p_.srcEid);
        if (p_.composeMsg.length != 0) {
            endpoint.sendCompose(
                p_.to,
                p_.guid,
                0,
                OFTComposeMsgCodec.encode(p_.nonce, p_.srcEid, amountReceivedLD, p_.composeMsg)
            );
        }
        emit OFTReceived(p_.guid, p_.srcEid, p_.to, amountReceivedLD);
    }

    /// @notice Drops a parked packet and refunds its capacity. Only the endpoint delegate (who can burn a verified packet).
    function burnParked(ParkedPacket calldata p_) external {
        address delegate = IEndpointV2Delegates(address(endpoint)).delegates(address(this));
        if (msg.sender != delegate) revert NotEndpointDelegate(msg.sender);
        bytes32 key = keccak256(abi.encode(p_));
        if (!parked[key]) revert ParkedNotFound(key);
        delete parked[key];
        parkedCount--;
        uint256 level = _level(p_.srcEid);
        inbound[p_.srcEid] = Inbound(uint192(level > p_.amountLD ? level - p_.amountLD : 0), uint64(block.timestamp));
        emit ParkedBurned(key);
    }

    /// @dev The endpoint delegate follows the owner on transfer, so a former owner keeps no power on the endpoint
    ///      or over parked packets. renounceOwnership() is unchanged: see the contract @dev above.
    function transferOwnership(address newOwner_) public override onlyOwner {
        super.transferOwnership(newOwner_);
        endpoint.setDelegate(newOwner_);
    }

    function _debitView(
        uint256 amountLD_,
        uint256 minAmountLD_,
        uint32 dstEid_
    ) internal view override returns (uint256 amountSentLD, uint256 amountReceivedLD) {
        (amountSentLD, amountReceivedLD) = super._debitView(amountLD_, minAmountLD_, dstEid_);
        if (amountSentLD > INBOUND_CAP) revert InboundCapExceeded(dstEid_, amountSentLD, INBOUND_CAP);
    }

    /// @dev Upstream path when the packet fits; otherwise parks it. Never reverts on the cap, so the endpoint nonce is
    ///      consumed and later deliveries do not pay for a queue of refused packets.
    function _lzReceive(
        Origin calldata origin_,
        bytes32 guid_,
        bytes calldata message_,
        address executor_,
        bytes calldata extraData_
    ) internal override {
        uint256 amountLD = _toLD(message_.amountSD());
        address to = message_.sendTo().bytes32ToAddress();
        if (amountLD > INBOUND_CAP) {
            emit InboundRejected(guid_, origin_.srcEid, to, amountLD); // never honest: reverts at the source
            return;
        }
        uint64 releaseAt = _admit(origin_.srcEid, amountLD);
        if (releaseAt == 0) return super._lzReceive(origin_, guid_, message_, executor_, extraData_);
        ParkedPacket memory p = ParkedPacket(
            origin_.srcEid,
            origin_.sender,
            origin_.nonce,
            guid_,
            to,
            amountLD,
            releaseAt,
            message_.composeMsg()
        );
        bytes32 key = keccak256(abi.encode(p));
        parked[key] = true;
        parkedCount++;
        emit InboundParked(key, p);
    }

    /// @dev Adds amountLD_ to the refilled level and always stores it. Returns 0 if the level stays within the cap,
    ///      else the time at which it drains back to INBOUND_CAP, rounded up.
    function _admit(uint32 srcEid_, uint256 amountLD_) internal returns (uint64 releaseAt) {
        uint256 level = _level(srcEid_) + amountLD_;
        inbound[srcEid_] = Inbound(uint192(level), uint64(block.timestamp)); // each packet adds <= INBOUND_CAP
        if (level > INBOUND_CAP) {
            releaseAt = uint64(block.timestamp + Math.ceilDiv((level - INBOUND_CAP) * INBOUND_WINDOW, INBOUND_CAP));
        }
    }

    /// @dev Level after linear refill rounded down (in the protocol's favour), floor 0.
    function _level(uint32 srcEid_) internal view returns (uint256) {
        Inbound memory b = inbound[srcEid_];
        uint256 refill = ((block.timestamp - b.updatedAt) * INBOUND_CAP) / INBOUND_WINDOW;
        return b.used > refill ? b.used - refill : 0;
    }
}
