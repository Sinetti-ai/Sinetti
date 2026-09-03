// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

contract RevertingMagicERC1271Wallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        assembly {
            mstore(0, shl(224, 0x1626ba7e))
            revert(0, 32)
        }
    }
}
