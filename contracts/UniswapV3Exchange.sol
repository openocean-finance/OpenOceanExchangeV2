// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "./libraries/EthRejector.sol";
import "./libraries/Permitable.sol";
import "./interfaces/IUniswapV3.sol";
import "./interfaces/IWETH.sol";

contract UniswapV3Exchange is EthRejector, Permitable, IUniswapV3SwapCallback {
    using Address for address payable;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    uint256 private constant _ONE_FOR_ZERO_MASK = 1 << 255;
    uint256 private constant _WETH_WRAP_MASK = 1 << 254;
    uint256 private constant _WETH_UNWRAP_MASK = 1 << 253;
    bytes32 private constant _POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    bytes32 private constant _FF_FACTORY = 0xff1F98431c8aD98523631AE4a59f267346ea31F9840000000000000000000000;
    bytes32 private constant _SELECTORS = 0x0dfe1681d21220a7ddca3f430000000000000000000000000000000000000000;
    uint256 private constant _ADDRESS_MASK = 0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff;
    /// @dev The minimum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MIN_TICK)
    uint160 private constant _MIN_SQRT_RATIO = 4295128739 + 1;
    /// @dev The maximum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MAX_TICK)
    uint160 private constant _MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342 - 1;
    /// @dev Change for different chains
    address private constant _WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice Same as `uniswapV3SwapTo` but calls permit first,
    /// allowing to approve token spending and make a swap in one transaction.
    /// @param recipient Address that will receive swap funds
    /// @param srcToken Source token
    /// @param amount Amount of source tokens to swap
    /// @param minReturn Minimal allowed returnAmount to make transaction commit
    /// @param pools Pools chain used for swaps. Pools src and dst tokens should match to make swap happen
    /// @param permit Should contain valid permit that can be used in `IERC20Permit.permit` calls.
    /// See tests for examples
    function uniswapV3SwapToWithPermit(
        address payable recipient,
        IERC20 srcToken,
        uint256 amount,
        uint256 minReturn,
        uint256[] calldata pools,
        bytes calldata permit
    ) external returns (uint256 returnAmount) {
        _permit(address(srcToken), permit);
        return _uniswapV3Swap(recipient, amount, minReturn, pools, _isPermit2(permit));
    }

    /// @notice Performs swap using Uniswap V3 exchange. Wraps and unwraps ETH if required.
    /// Sending non-zero `msg.value` for anything but ETH swaps is prohibited
    /// @param recipient Address that will receive swap funds
    /// @param amount Amount of source tokens to swap
    /// @param minReturn Minimal allowed returnAmount to make transaction commit
    /// @param pools Pools chain used for swaps. Pools src and dst tokens should match to make swap happen
    function uniswapV3SwapTo(
        address payable recipient,
        uint256 amount,
        uint256 minReturn,
        uint256[] calldata pools
    ) external payable returns (uint256 returnAmount) {
        return _uniswapV3Swap(recipient, amount, minReturn, pools, false);
    }

    function _uniswapV3Swap(
        address payable recipient,
        uint256 amount,
        uint256 minReturn,
        uint256[] calldata pools,
        bool permit2
    ) internal returns (uint256 returnAmount) {
        uint256 len = pools.length;
        address dstToken;
        require(len > 0, "UniswapV3: empty pools");
        uint256 lastIndex = len - 1;
        returnAmount = amount;
        bool wrapWeth = pools[0] & _WETH_WRAP_MASK > 0;
        bool unwrapWeth = pools[lastIndex] & _WETH_UNWRAP_MASK > 0;
        if (wrapWeth) {
            require(msg.value == amount, "UniswapV3: wrong msg.value");
            IWETH(_WETH).deposit{value: amount}();
        } else {
            require(msg.value == 0, "UniswapV3: msg.value should be 0");
        }
        if (len > 1) {
            (returnAmount, ) = _makeSwap(address(this), wrapWeth || permit2 ? address(this) : msg.sender, pools[0], returnAmount);
            for (uint256 i = 1; i < lastIndex; i++) {
                (returnAmount, ) = _makeSwap(address(this), address(this), pools[i], returnAmount);
            }
            (returnAmount, dstToken) = _makeSwap(address(this), address(this), pools[lastIndex], returnAmount);
        } else {
            (returnAmount, dstToken) = _makeSwap(
                address(this),
                wrapWeth || permit2 ? address(this) : msg.sender,
                pools[0],
                returnAmount
            );
        }

        require(returnAmount >= minReturn, "UniswapV3: min return");

        assembly {
            function reRevert() {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }

            function run(_returnAmount, _recipient, _unwrapWeth, _dstToken) {
                let slp := shr(
                    232,
                    and(
                        calldataload(add(add(calldataload(0x64), 0x4), 0x20)),
                        0x00ffff0000000000000000000000000000000000000000000000000000000000
                    )
                )
                let finalAmount := div(mul(calldataload(0x44), 0x2710), sub(10000, slp))
                let emptyPtr := mload(0x40)
                switch gt(_returnAmount, finalAmount)
                case 1 {
                    switch _unwrapWeth
                    case 0 {
                        mstore(emptyPtr, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
                        mstore(add(emptyPtr, 0x4), _recipient)
                        mstore(add(emptyPtr, 0x24), finalAmount)
                        if iszero(call(gas(), _dstToken, 0, emptyPtr, 0x44, 0, 0)) {
                            reRevert()
                        }

                        mstore(add(emptyPtr, 0x4), 0x922164BBBd36Acf9E854AcBbF32faCC949fCAEef)
                        mstore(add(emptyPtr, 0x24), sub(_returnAmount, finalAmount))
                        if iszero(call(gas(), _dstToken, 0, emptyPtr, 0x44, 0, 0)) {
                            reRevert()
                        }
                    }
                    default {
                        mstore(emptyPtr, 0x2e1a7d4d00000000000000000000000000000000000000000000000000000000)
                        mstore(add(emptyPtr, 0x04), _returnAmount)
                        if iszero(
                            call(gas(), 0x000000000000000000000000C02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, 0, emptyPtr, 0x24, 0, 0)
                        ) {
                            reRevert()
                        }

                        if iszero(call(gas(), _recipient, finalAmount, 0, 0, 0, 0)) {
                            reRevert()
                        }

                        if iszero(
                            call(gas(), 0x922164BBBd36Acf9E854AcBbF32faCC949fCAEef, sub(_returnAmount, finalAmount), 0, 0, 0, 0)
                        ) {
                            reRevert()
                        }
                    }
                }
                default {
                    switch _unwrapWeth
                    case 0 {
                        mstore(emptyPtr, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
                        mstore(add(emptyPtr, 0x4), _recipient)
                        mstore(add(emptyPtr, 0x24), _returnAmount)
                        if iszero(call(gas(), _dstToken, 0, emptyPtr, 0x44, 0, 0)) {
                            reRevert()
                        }
                    }
                    default {
                        mstore(emptyPtr, 0x2e1a7d4d00000000000000000000000000000000000000000000000000000000)
                        mstore(add(emptyPtr, 0x04), _returnAmount)
                        if iszero(
                            call(gas(), 0x000000000000000000000000C02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, 0, emptyPtr, 0x24, 0, 0)
                        ) {
                            reRevert()
                        }

                        if iszero(call(gas(), _recipient, _returnAmount, 0, 0, 0, 0)) {
                            reRevert()
                        }
                    }
                }
            }

            run(returnAmount, recipient, unwrapWeth, dstToken)
        }
    }

    /// @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata /*data*/) external override {
        IERC20 token0;
        IERC20 token1;
        bytes32 ffFactoryAddress = _FF_FACTORY;
        bytes32 poolInitCodeHash = _POOL_INIT_CODE_HASH;
        address payer;

        assembly {
            // solhint-disable-line no-inline-assembly
            function reRevert() {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }

            function revertWithReason(m, len) {
                mstore(0x00, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(0x20, 0x0000002000000000000000000000000000000000000000000000000000000000)
                mstore(0x40, m)
                revert(0, len)
            }

            let emptyPtr := mload(0x40)
            let resultPtr := add(emptyPtr, 0x20)
            mstore(emptyPtr, _SELECTORS)

            if iszero(staticcall(gas(), caller(), emptyPtr, 0x4, resultPtr, 0x20)) {
                reRevert()
            }
            token0 := mload(resultPtr)
            if iszero(staticcall(gas(), caller(), add(emptyPtr, 0x4), 0x4, resultPtr, 0x20)) {
                reRevert()
            }
            token1 := mload(resultPtr)
            if iszero(staticcall(gas(), caller(), add(emptyPtr, 0x8), 0x4, resultPtr, 0x20)) {
                reRevert()
            }
            let fee := mload(resultPtr)

            let p := emptyPtr
            mstore(p, ffFactoryAddress)
            p := add(p, 21)
            // Compute the inner hash in-place
            mstore(p, token0)
            mstore(add(p, 32), token1)
            mstore(add(p, 64), fee)
            mstore(p, keccak256(p, 96))
            p := add(p, 32)
            mstore(p, poolInitCodeHash)
            let pool := and(keccak256(emptyPtr, 85), _ADDRESS_MASK)

            if iszero(eq(pool, caller())) {
                revertWithReason(0x00000010554e495633523a2062616420706f6f6c000000000000000000000000, 0x54) // UniswapV3: bad pool
            }

            calldatacopy(emptyPtr, 0x84, 0x20)
            payer := mload(emptyPtr)
        }

        if (amount0Delta > 0) {
            if (payer == address(this)) {
                token0.safeTransfer(msg.sender, uint256(amount0Delta));
            } else {
                token0.safeTransferFrom(payer, msg.sender, uint256(amount0Delta));
            }
        }
        if (amount1Delta > 0) {
            if (payer == address(this)) {
                token1.safeTransfer(msg.sender, uint256(amount1Delta));
            } else {
                token1.safeTransferFrom(payer, msg.sender, uint256(amount1Delta));
            }
        }
    }

    function _makeSwap(address recipient, address payer, uint256 pool, uint256 amount) private returns (uint256, address) {
        bool zeroForOne = pool & _ONE_FOR_ZERO_MASK == 0;
        if (zeroForOne) {
            (, int256 amount1) = IUniswapV3Pool(address(uint160(pool))).swap(
                recipient,
                zeroForOne,
                SafeCast.toInt256(amount),
                _MIN_SQRT_RATIO,
                abi.encode(payer)
            );
            return (SafeCast.toUint256(-amount1), IUniswapV3Pool(address(uint160(pool))).token1());
        } else {
            (int256 amount0, ) = IUniswapV3Pool(address(uint160(pool))).swap(
                recipient,
                zeroForOne,
                SafeCast.toInt256(amount),
                _MAX_SQRT_RATIO,
                abi.encode(payer)
            );
            return (SafeCast.toUint256(-amount0), IUniswapV3Pool(address(uint160(pool))).token0());
        }
    }
}
