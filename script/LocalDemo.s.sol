// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HeadroomHook} from "../src/HeadroomHook.sol";
import {HeadroomSalt} from "./DeployHeadroom.s.sol";

/// @dev LOCAL MOCK-TOKEN DEMO ONLY. Unrestricted callers spend this fixture's mock inventory.
/// Uses upstream TEST routers, with no user slippage protection. Not a production router.
contract DemoMarket {
    IPoolManager public immutable manager;
    HeadroomHook public immutable hook;
    PoolSwapTest public immutable routerA;
    PoolSwapTest public immutable routerB;
    PoolKey public key;
    bool public immutable wethIsZero;

    constructor(
        IPoolManager manager_,
        HeadroomHook hook_,
        MockERC20 weth,
        MockERC20 asset,
        PoolSwapTest routerA_,
        PoolSwapTest routerB_,
        PoolModifyLiquidityTest liquidity
    ) {
        manager = manager_;
        hook = hook_;
        routerA = routerA_;
        routerB = routerB_;
        wethIsZero = address(weth) < address(asset);
        key = PoolKey(
            Currency.wrap(wethIsZero ? address(weth) : address(asset)),
            Currency.wrap(wethIsZero ? address(asset) : address(weth)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            IHooks(address(hook_))
        );
        weth.mint(address(this), 10_000 ether);
        asset.mint(address(this), 10_000 ether);
        weth.approve(address(routerA_), type(uint256).max);
        weth.approve(address(routerB_), type(uint256).max);
        weth.approve(address(liquidity), type(uint256).max);
        asset.approve(address(liquidity), type(uint256).max);
        manager_.initialize(key, 79228162514264337593543950336);
        liquidity.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, 1000 ether, bytes32(0)), "");
    }

    /// @notice Execute two real swaps through different callers in one transaction.
    function batch() external {
        SwapParams memory p =
            SwapParams(wethIsZero, -1 ether, wethIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        routerA.swap(key, p, PoolSwapTest.TestSettings(false, false), "");
        routerB.swap(key, p, PoolSwapTest.TestSettings(false, false), "");
    }
}

contract LocalDemo is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() public returns (DemoMarket market) {
        require(block.chainid == 31337, "Local Anvil chain only");
        vm.startBroadcast();
        PoolManager manager = new PoolManager(msg.sender);
        MockERC20 weth = new MockERC20("Demo WETH", "WETH", 18);
        MockERC20 asset = new MockERC20("Demo Asset", "DEMO", 18);
        bytes32 hash = keccak256(abi.encodePacked(type(HeadroomHook).creationCode, abi.encode(manager, address(weth))));
        (bytes32 salt, address predicted) = HeadroomSalt.find(CREATE2_DEPLOYER, hash);
        HeadroomHook hook = new HeadroomHook{salt: salt}(manager, address(weth));
        require(address(hook) == predicted, "Unexpected CREATE2 address");
        PoolSwapTest routerA = new PoolSwapTest(manager);
        PoolSwapTest routerB = new PoolSwapTest(manager);
        PoolModifyLiquidityTest liquidity = new PoolModifyLiquidityTest(manager);
        market = new DemoMarket(manager, hook, weth, asset, routerA, routerB, liquidity);
        vm.stopBroadcast();
        console2.log("Demo market:", address(market));
        console2.log("PoolManager:", address(manager));
        console2.log("Headroom hook:", address(hook));
    }
}
