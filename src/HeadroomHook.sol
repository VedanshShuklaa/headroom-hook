// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Gas-responsive LP fees with one nominal ETH discount allowance per transaction.
/// @dev All pools and callers share the allowance for this hook instance. No ETH is refunded.
contract HeadroomHook is BaseHook {
    uint24 public constant BASE_FEE = 3000;
    uint24 public constant MIN_FEE = 500;
    uint256 public constant REFERENCE_GAS = 100_000;
    uint256 public constant BASEFEE_CAP = 100 gwei;
    uint256 private constant FEE_DENOMINATOR = 1_000_000;

    bytes32 private constant INITIALIZED_SLOT = keccak256("headroom.transient.initialized");
    bytes32 private constant REMAINING_SLOT = keccak256("headroom.transient.remaining");

    /// @notice The chain's canonical 18-decimal WETH, supplied at deployment.
    address public immutable weth;

    error UnsupportedPool();
    error MustUseDynamicFee();
    error InvalidWeth();
    error IncorrectHook();

    event DiscountReserved(
        bytes32 indexed poolId, uint24 fee, uint256 requestedInput, uint256 reservationWei, uint256 remainingWei
    );

    constructor(IPoolManager manager, address weth_) BaseHook(manager) {
        if (weth_ == address(0)) revert InvalidWeth();
        weth = weth_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.afterInitialize = true;
        p.beforeSwap = true;
    }

    /// @notice Initial nominal allowance in ETH wei; not a measurement of actual gas spent.
    function initialAllowance() public view returns (uint256) {
        return REFERENCE_GAS * (block.basefee > BASEFEE_CAP ? BASEFEE_CAP : block.basefee);
    }

    /// @notice Remaining allowance in this transaction, or a fresh allowance if unused.
    function remainingAllowance() public view returns (uint256 remaining) {
        bytes32 initializedSlot = INITIALIZED_SLOT;
        bytes32 remainingSlot = REMAINING_SLOT;
        uint256 initialized;
        assembly ("memory-safe") {
            initialized := tload(initializedSlot)
            remaining := tload(remainingSlot)
        }
        if (initialized == 0) remaining = initialAllowance();
    }

    /// @notice Quote the next fee and nominal reservation, without consuming allowance.
    /// @return fee LP fee in millionths.
    /// @return reservation Nominal ETH wei reserved against the requested gross input.
    /// @return remaining Allowance that would remain after this swap's reservation.
    /// @dev A standalone eth_call starts fresh; simulate a complete batch to quote a batch.
    function quote(PoolKey calldata key, SwapParams calldata params)
        public
        view
        returns (uint24 fee, uint256 reservation, uint256 remaining)
    {
        _validatePool(key);
        remaining = remainingAllowance();
        fee = BASE_FEE;
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        if (params.amountSpecified >= 0 || !_isGasCurrency(input)) return (fee, 0, remaining);

        // Safe even for int256.min, whose positive magnitude does not fit int256.
        uint256 amount = uint256(-(params.amountSpecified + 1)) + 1;
        uint256 reduction = FullMath.mulDiv(remaining, FEE_DENOMINATOR, amount);
        if (reduction > BASE_FEE - MIN_FEE) reduction = BASE_FEE - MIN_FEE;
        if (reduction == 0) return (fee, 0, remaining);

        // Safe: reduction was capped to BASE_FEE - MIN_FEE = 2500 above.
        // forge-lint: disable-next-line(unsafe-typecast)
        fee -= uint24(reduction);
        // Round reservations up, so fractional wei cannot create extra allowance.
        reservation = FullMath.mulDivRoundingUp(amount, reduction, FEE_DENOMINATOR);
        remaining -= reservation;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        _validatePool(key);
        poolManager.updateDynamicLPFee(key, BASE_FEE);
        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (uint24 fee, uint256 reservation, uint256 remaining) = quote(key, params);
        bytes32 initializedSlot = INITIALIZED_SLOT;
        bytes32 remainingSlot = REMAINING_SLOT;
        // Deliberately persists for the WHOLE transaction, including across unlocks/callers.
        // A separate marker distinguishes an exhausted allowance from a fresh transaction.
        assembly ("memory-safe") {
            tstore(initializedSlot, 1)
            tstore(remainingSlot, remaining)
        }
        if (reservation != 0) {
            emit DiscountReserved(
                keccak256(abi.encode(key)), fee, uint256(-(params.amountSpecified + 1)) + 1, reservation, remaining
            );
        }
        // Reservations are not refunded on partial/zero fills. A revert rolls them back.
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _validatePool(PoolKey calldata key) private view {
        if (address(key.hooks) != address(this)) revert IncorrectHook();
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) revert MustUseDynamicFee();
        if (!_isGasCurrency(key.currency0) && !_isGasCurrency(key.currency1)) revert UnsupportedPool();
    }

    function _isGasCurrency(Currency currency) private view returns (bool) {
        address token = Currency.unwrap(currency);
        return token == address(0) || token == weth;
    }
}
