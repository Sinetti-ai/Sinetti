// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

contract ReturnBombERC1271Wallet is IERC1271 {
    uint256 public immutable returnSize;

    constructor(uint256 returnSize_) {
        require(returnSize_ >= 32, "return size below ABI word");
        returnSize = returnSize_;
    }

    function isValidSignature(bytes32, bytes memory) external view returns (bytes4) {
        uint256 size = returnSize;
        bytes4 magicValue = IERC1271.isValidSignature.selector;

        assembly {
            mstore(0, magicValue)
            return(0, size)
        }
    }
}
