// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {HeadroomHook} from "../src/HeadroomHook.sol";

contract HeadroomHookTest is Deployers {
    HeadroomHook hook;

    function setUp() public {
        vm.fee(20 gwei);
        vm.deal(address(this), 1000 ether);
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        address target = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG));
        deployCodeTo("HeadroomHook.sol:HeadroomHook", abi.encode(manager, Currency.unwrap(currency0)), target);
        hook = HeadroomHook(target);
        LIQUIDITY_PARAMS.tickLower = -600;
        LIQUIDITY_PARAMS.tickUpper = 600;
        LIQUIDITY_PARAMS.liquidityDelta = 1000 ether;
        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(target), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
    }

    function params(bool direction, int256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(direction, amount, direction ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT);
    }

    function applied(PoolKey memory pool, bool direction, int256 amount) internal returns (uint24 fee) {
        vm.recordLogs();
        swap(pool, direction, amount, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager)
                    && logs[i].topics[0]
                        == keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
            ) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        revert("Missing PoolManager Swap event");
    }

    function testOneEthDiscountIsActuallyApplied() public {
        assertEq(applied(key, true, -1 ether), 1000);
        assertEq(hook.remainingAllowance(), 0);
    }

    function testExhaustionDoesNotReinitializeBudget() public {
        applied(key, true, -1 ether);
        assertEq(applied(key, true, -1 ether), 3000);
        assertEq(applied(key, true, -1 ether), 3000);
    }

    function testFeeFloorLeavesOnlyUnusedBudget() public {
        assertEq(applied(key, true, -0.1 ether), 500);
        assertEq(hook.remainingAllowance(), 0.00175 ether);
        assertEq(applied(key, true, -1 ether), 1250);
        assertEq(hook.remainingAllowance(), 0);
    }

    function testTenEthQuoteScalesDiscountBySize() public view {
        (uint24 fee, uint256 reserve, uint256 left) = hook.quote(key, params(true, -10 ether));
        assertEq(fee, 2800);
        assertEq(reserve, 0.002 ether);
        assertEq(left, 0);
        assertEq(hook.remainingAllowance(), 0.002 ether, "quote must not consume allowance");
    }

    function testOtherTokenInputUsesBaseFeeWithoutSpendingBudget() public {
        assertEq(applied(key, false, -1 ether), 3000);
        assertEq(hook.remainingAllowance(), 0.002 ether);
    }

    function testExactOutputUsesBaseFeeWithoutSpendingBudget() public {
        assertEq(applied(key, true, 0.1 ether), 3000);
        assertEq(hook.remainingAllowance(), 0.002 ether);
    }

    function testUnsupportedPoolIsRejected() public {
        Currency token = deployMintAndApproveCurrency();
        vm.expectRevert();
        initPool(currency1, token, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
    }

    function testDifferentPoolsShareOneBudget() public {
        (PoolKey memory other,) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(other, LIQUIDITY_PARAMS, "");
        assertEq(applied(key, true, -1 ether), 1000);
        assertEq(applied(other, true, -1 ether), 3000);
    }

    function testNativeEthInputReceivesDiscount() public {
        (PoolKey memory nativePool,) = initPoolAndAddLiquidityETH(
            Currency.wrap(address(0)),
            currency1,
            IHooks(address(hook)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1,
            100 ether
        );
        assertEq(applied(nativePool, true, -1 ether), 1000);
        assertEq(hook.remainingAllowance(), 0);
    }

    function testWethInCurrencyOneReceivesDiscount() public {
        (PoolKey memory nativeWeth,) = initPoolAndAddLiquidityETH(
            Currency.wrap(address(0)),
            currency0,
            IHooks(address(hook)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1,
            100 ether
        );
        assertEq(applied(nativeWeth, false, -1 ether), 1000);
        assertEq(hook.remainingAllowance(), 0);
    }

    function testChangingRouterAndPayerDoesNotResetAllowance() public {
        assertEq(applied(key, true, -1 ether), 1000);
        PoolSwapTest otherRouter = new PoolSwapTest(manager);
        address payer = makeAddr("second payer");
        MockERC20(Currency.unwrap(currency0)).mint(payer, 2 ether);
        vm.startPrank(payer);
        MockERC20(Currency.unwrap(currency0)).approve(address(otherRouter), type(uint256).max);
        vm.recordLogs();
        otherRouter.swap(key, params(true, -1 ether), PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager)
                    && logs[i].topics[0]
                        == keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
            ) {
                (,,,,, uint24 fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                assertEq(fee, 3000);
                found = true;
            }
        }
        assertTrue(found, "missing swap");
    }

    function testBlockChangeDoesNotResetWithinTransaction() public {
        applied(key, true, -1 ether);
        vm.roll(block.number + 1);
        assertEq(applied(key, true, -1 ether), 3000);
    }

    function testRevertedSettlementRollsReservationBack() public {
        address unfunded = makeAddr("unfunded");
        vm.expectRevert();
        vm.prank(unfunded);
        swapRouter.swap(key, params(true, -1 ether), PoolSwapTest.TestSettings(false, false), "");
        assertEq(hook.remainingAllowance(), 0.002 ether);
        assertEq(applied(key, true, -1 ether), 1000);
    }

    function testRevertedSettlementPreservesPreviouslySpentBudget() public {
        applied(key, true, -0.1 ether);
        address unfunded = makeAddr("unfunded");
        vm.expectRevert();
        vm.prank(unfunded);
        swapRouter.swap(key, params(true, -1 ether), PoolSwapTest.TestSettings(false, false), "");
        assertEq(hook.remainingAllowance(), 0.00175 ether);
    }

    function testPartialFillStillReservesAgainstRequestedAmount() public {
        vm.recordLogs();
        BalanceDelta delta = swapRouter.swap(
            key, SwapParams(true, -1 ether, SQRT_PRICE_1_1 - 1), PoolSwapTest.TestSettings(false, false), ""
        );
        assertLt(uint256(uint128(-delta.amount0())), 1 ether);
        assertEq(hook.remainingAllowance(), 0);
    }

    function testEmptyPoolStillReservesRequestedInput() public {
        (PoolKey memory empty,) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, SQRT_PRICE_1_1);
        BalanceDelta delta = swap(empty, true, -1 ether, "");
        assertEq(BalanceDelta.unwrap(delta), 0);
        assertEq(hook.remainingAllowance(), 0);
    }

    function testZeroBasefeeDoesNotDiscount() public {
        vm.fee(0);
        assertEq(applied(key, true, -1 ether), 3000);
        assertEq(hook.remainingAllowance(), 0);
        assertEq(applied(key, true, -1 ether), 3000);
    }

    function testBasefeeIsCappedBeforeMultiplication() public {
        vm.fee(type(uint64).max);
        assertEq(hook.initialAllowance(), 0.01 ether);
        (uint24 fee, uint256 reserve,) = hook.quote(key, params(true, -10 ether));
        assertEq(fee, 2000);
        assertEq(reserve, 0.01 ether);
    }

    function testChangingPriorityTipDoesNotChangeQuote() public {
        (uint24 first,,) = hook.quote(key, params(true, -1 ether));
        vm.txGasPrice(500 gwei);
        (uint24 second,,) = hook.quote(key, params(true, -1 ether));
        assertEq(first, 1000);
        assertEq(second, first);
    }

    function testSignedExtremeAndZeroAmountQuotes() public view {
        (uint24 huge, uint256 reserve, uint256 left) = hook.quote(key, params(true, type(int256).min));
        assertEq(huge, 3000);
        assertEq(reserve, 0);
        assertEq(left, 0.002 ether);
        (uint24 zero, uint256 zeroReserve,) = hook.quote(key, params(true, 0));
        assertEq(zero, 3000);
        assertEq(zeroReserve, 0);
    }

    function testRoundingUpCannotLeakFractionalWei() public {
        (uint24 fee, uint256 reserve, uint256 left) = hook.quote(key, params(true, -401));
        assertEq(fee, 500);
        assertEq(reserve, 2, "401 * 2500 / 1e6 rounds up from 1.0025");
        assertEq(left, 0.002 ether - 2);
        applied(key, true, -401);
        assertEq(hook.remainingAllowance(), left);
    }

    function testDirectCallbacksAreRejected() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params(true, -1 ether), "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
    }

    function testStaticFeePoolRejected() public {
        PoolKey memory fixedPool = key;
        fixedPool.fee = 3000;
        vm.expectRevert();
        manager.initialize(fixedPool, SQRT_PRICE_1_1);
    }

    function testInvalidQuoteHookRejected() public {
        PoolKey memory invalid = key;
        invalid.hooks = IHooks(address(0));
        vm.expectRevert(HeadroomHook.IncorrectHook.selector);
        hook.quote(invalid, params(true, -1 ether));
    }

    function testZeroWethDeploymentRejected() public {
        vm.expectRevert(HeadroomHook.InvalidWeth.selector);
        deployCodeTo("HeadroomHook.sol:HeadroomHook", abi.encode(manager, address(0)), address(hook));
    }

    function testFuzzReservationAndFeeBounds(uint112 amountSeed, uint64 gasSeed) public {
        uint256 amount = bound(uint256(amountSeed), 1, 1e26);
        vm.fee(uint256(gasSeed));
        uint256 budget = hook.initialAllowance();
        (uint24 fee, uint256 reserve, uint256 left) = hook.quote(key, params(true, -int256(amount)));
        assertGe(fee, 500);
        assertLe(fee, 3000);
        assertLe(reserve, budget);
        assertEq(reserve + left, budget);
        uint256 nominal = amount * (3000 - fee);
        assertGe(reserve * 1_000_000, nominal);
        assertLt(reserve * 1_000_000 - nominal, 1_000_000);
        (uint24 biggerFee,,) = hook.quote(key, params(true, -int256(amount + 1)));
        assertGe(biggerFee, fee);
    }

    function testFuzzRepeatedSwapsCannotOverspend(uint96 seed) public {
        uint256 amount = bound(uint256(seed), 1e12, 2 ether);
        uint256 previous = hook.initialAllowance();
        for (uint256 i; i < 12; ++i) {
            swap(key, true, -int256(amount), "");
            uint256 left = hook.remainingAllowance();
            assertLe(left, previous);
            previous = left;
        }
        assertLe(previous, 0.002 ether);
    }

    function testFuzzHigherBasefeeCannotRaiseEligibleFee(uint64 firstGas, uint64 extraGas) public {
        vm.fee(uint256(firstGas) / 2);
        (uint24 first,,) = hook.quote(key, params(true, -1 ether));
        vm.fee(uint256(firstGas) / 2 + uint256(extraGas) / 2);
        (uint24 second,,) = hook.quote(key, params(true, -1 ether));
        assertLe(second, first);
    }

    function testDemo() public {
        console2.log("Basefee (gwei):", block.basefee / 1 gwei);
        console2.log("Starting allowance (wei):", hook.remainingAllowance());
        console2.log("First 0.1 ETH swap fee (millionths):", applied(key, true, -0.1 ether));
        console2.log("Remaining allowance (wei):", hook.remainingAllowance());
        console2.log("Next 1 ETH swap fee (millionths):", applied(key, true, -1 ether));
        console2.log("After exhaustion (millionths):", applied(key, true, -1 ether));
        assertEq(hook.remainingAllowance(), 0);
    }
}
