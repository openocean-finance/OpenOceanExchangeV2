// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

abstract contract EthRejector {
    receive() external payable {
        // require(msg.sender != tx.origin, "ETH deposit rejected");
    }
}
