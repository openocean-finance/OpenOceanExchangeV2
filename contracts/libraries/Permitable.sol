// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";

import "./RevertReasonParser.sol";

/// @title Interface for DAI-style permits
interface IDaiLikePermit {
    function permit(
        address holder,
        address spender,
        uint256 nonce,
        uint256 expiry,
        bool allowed,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

/// @title SignatureTransfer
/// @notice Handles ERC20 token transfers through signature based actions
/// @dev Requires user's token approval on the Permit2 contract
interface IPermit2 {
    /// @notice The token and amount details for a transfer signed in the permit transfer signature
    struct TokenPermissions {
        // ERC20 token address
        address token;
        // the maximum amount that can be spent
        uint256 amount;
    }

    /// @notice The signed permit message for a single token transfer
    struct PermitTransferFrom {
        TokenPermissions permitted;
        // a unique value for every token owner's signature to prevent signature replays
        uint256 nonce;
        // deadline on the permit signature
        uint256 deadline;
    }

    /// @notice Specifies the recipient address and amount for batched transfers.
    /// @dev Recipients and amounts correspond to the index of the signed token permissions array.
    /// @dev Reverts if the requested amount is greater than the permitted signed amount.
    struct SignatureTransferDetails {
        // recipient address
        address to;
        // spender requested amount
        uint256 requestedAmount;
    }

    /// @notice A map from token owner address and a caller specified word index to a bitmap. Used to set bits in the bitmap to prevent against signature replay protection
    /// @dev Uses unordered nonces so that permit messages do not need to be spent in a certain order
    /// @dev The mapping is indexed first by the token owner, then by an index specified in the nonce
    /// @dev It returns a uint256 bitmap
    /// @dev The index, or wordPosition is capped at type(uint248).max
    function nonceBitmap(address, uint256) external view returns (uint256);

    /// @notice Transfers a token using a signed permit message
    /// @dev Reverts if the requested amount is greater than the permitted signed amount
    /// @param permit The permit data signed over by the owner
    /// @param owner The owner of the tokens to transfer
    /// @param transferDetails The spender's requested transfer details for the permitted token
    /// @param signature The signature to verify
    function permitTransferFrom(
        PermitTransferFrom memory permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;

    /// @notice Returns the domain separator for the current chain.
    /// @dev Uses cached version if chainid and address are unchanged from construction.
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @title Base contract with common permit handling logics
contract Permitable {
    address public permit2;

    function permit2DomainSeperator() external view returns (bytes32) {
        return IPermit2(permit2).DOMAIN_SEPARATOR();
    }

    function _permit(address token, bytes calldata permit) internal returns (bool) {
        if (permit.length > 0) {
            if (permit.length == 32 * 7 || permit.length == 32 * 8) {
                (bool success, bytes memory result) = _permit1(token, permit);
                if (!success) {
                    revert(RevertReasonParser.parse(result, "Permit failed: "));
                }
                return false;
            } else {
                (bool success, bytes memory result) = _permit2(permit);
                if (!success) {
                    revert(RevertReasonParser.parse(result, "Permit2 failed: "));
                }
                return true;
            }
        }
        return false;
    }

    function _isPermit2(bytes calldata permit) internal pure returns (bool) {
        return permit.length == 32 * 11 || permit.length == 32 * 12;
    }

    function _permit1(address token, bytes calldata permit) private returns (bool success, bytes memory result) {
        if (permit.length == 32 * 7) {
            // solhint-disable-next-line avoid-low-level-calls
            (success, result) = token.call(abi.encodePacked(IERC20Permit.permit.selector, permit));
        } else if (permit.length == 32 * 8) {
            // solhint-disable-next-line avoid-low-level-calls
            (success, result) = token.call(abi.encodePacked(IDaiLikePermit.permit.selector, permit));
        }
    }

    function _permit2(bytes calldata permit) private returns (bool success, bytes memory result) {
        (, , address owner, ) = abi.decode(
            permit,
            (IPermit2.PermitTransferFrom, IPermit2.SignatureTransferDetails, address, bytes)
        );
        require(owner == msg.sender, "Permit2 denied");
        // solhint-disable-next-line avoid-low-level-calls
        (success, result) = permit2.call(abi.encodePacked(IPermit2.permitTransferFrom.selector, permit)); // TODO support batch permit
    }

    /// @notice Finds the next valid nonce for a user, starting from 0.
    /// @param owner The owner of the nonces
    /// @return nonce The first valid nonce starting from 0
    function permit2NextNonce(address owner) external view returns (uint256 nonce) {
        nonce = _permit2NextNonce(owner, 0, 0);
    }

    /// @notice Finds the next valid nonce for a user, after from a given nonce.
    /// @dev This can be helpful if you're signing multiple nonces in a row and need the next nonce to sign but the start one is still valid.
    /// @param owner The owner of the nonces
    /// @param start The nonce to start from
    /// @return nonce The first valid nonce after the given nonce
    function permit2NextNonceAfter(address owner, uint256 start) external view returns (uint256 nonce) {
        uint248 word = uint248(start >> 8);
        uint8 pos = uint8(start);
        if (pos == type(uint8).max) {
            // If the position is 255, we need to move to the next word
            word++;
            pos = 0;
        } else {
            // Otherwise, we just move to the next position
            pos++;
        }
        nonce = _permit2NextNonce(owner, word, pos);
    }

    /// @notice Finds the next valid nonce for a user, starting from a given word and position.
    /// @param owner The owner of the nonces
    /// @param word Word to start looking from
    /// @param pos Position inside the word to start looking from
    function _permit2NextNonce(address owner, uint248 word, uint8 pos) internal view returns (uint256 nonce) {
        while (true) {
            uint256 bitmap = IPermit2(permit2).nonceBitmap(owner, word);

            // Check if the bitmap is completely full
            if (bitmap == type(uint256).max) {
                // If so, move to the next word
                ++word;
                pos = 0;
                continue;
            }
            if (pos != 0) {
                // If the position is not 0, we need to shift the bitmap to ignore the bits before position
                bitmap = bitmap >> pos;
            }
            // Find the first zero bit in the bitmap
            while (bitmap & 1 == 1) {
                bitmap = bitmap >> 1;
                ++pos;
            }

            return _permit2NonceFromWordAndPos(word, pos);
        }
    }

    /// @notice Constructs a nonce from a word and a position inside the word
    /// @param word The word containing the nonce
    /// @param pos The position of the nonce inside the word
    /// @return nonce The nonce constructed from the word and position
    function _permit2NonceFromWordAndPos(uint248 word, uint8 pos) internal pure returns (uint256 nonce) {
        // The last 248 bits of the word are the nonce bits
        nonce = uint256(word) << 8;
        // The first 8 bits of the word are the position inside the word
        nonce |= pos;
    }
}
