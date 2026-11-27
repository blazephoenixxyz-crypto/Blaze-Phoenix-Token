// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenix} from "../src/BlazePhoenix.sol";

/// The token live on Base is this source: same runtime bytecode (the trailing CBOR metadata is
/// excluded, because it hashes the file path), same supply, same metadata.
/// Runs only when BASE_RPC_URL is set.
contract DeployedForkTest is Test {
    address constant BZPX = 0x053D75c00FdD571538492e3B1686Bd963a0911A7;
    uint256 constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
    }

    function _stripMetadata(bytes memory code) internal pure returns (bytes memory out) {
        uint256 n = code.length;
        uint256 meta = (uint256(uint8(code[n - 2])) << 8 | uint256(uint8(code[n - 1]))) + 2;
        out = new bytes(n - meta);
        for (uint256 i; i < out.length; ++i) out[i] = code[i];
    }

    function test_runtimeMatchesSource() public {
        BlazePhoenix local = new BlazePhoenix(address(this));
        bytes memory live = BZPX.code;
        assertGt(live.length, 0);
        assertEq(keccak256(_stripMetadata(live)), keccak256(_stripMetadata(address(local).code)));
    }

    function test_liveState() public view {
        BlazePhoenix t = BlazePhoenix(BZPX);
        assertEq(t.name(), "Blaze Phoenix");
        assertEq(t.symbol(), "BZPX");
        assertEq(t.decimals(), 18);
        assertLe(t.totalSupply(), SUPPLY);
    }
}
