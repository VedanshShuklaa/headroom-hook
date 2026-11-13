// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HeadroomHook} from "../src/HeadroomHook.sol";

library HeadroomSalt {
    function find(address deployer, bytes32 initCodeHash) internal pure returns (bytes32 salt, address predicted) {
        uint160 flags = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;
        for (uint256 i; i < 1_000_000; ++i) {
            salt = bytes32(i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == flags) return (salt, predicted);
        }
        revert("No permission-valid salt within search limit");
    }
}

contract DeployHeadroom is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() public returns (HeadroomHook hook) {
        address manager = vm.envAddress("POOL_MANAGER");
        address weth = vm.envAddress("WETH");
        require(manager.code.length != 0, "POOL_MANAGER has no code");
        require(weth.code.length != 0, "WETH has no code");
        require(CREATE2_DEPLOYER.code.length != 0, "CREATE2 deployer missing");
        bytes32 hash = keccak256(abi.encodePacked(type(HeadroomHook).creationCode, abi.encode(manager, weth)));
        (bytes32 salt, address predicted) = HeadroomSalt.find(CREATE2_DEPLOYER, hash);
        require(predicted.code.length == 0, "Predicted hook already exists");
        vm.startBroadcast();
        hook = new HeadroomHook{salt: salt}(IPoolManager(manager), weth);
        vm.stopBroadcast();
        require(address(hook) == predicted, "Unexpected CREATE2 address");
        console2.log("Headroom hook:", address(hook));
        console2.log("PoolManager:", manager);
        console2.log("WETH:", weth);
    }
}
