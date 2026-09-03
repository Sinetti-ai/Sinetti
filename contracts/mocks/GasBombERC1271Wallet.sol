// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

contract GasBombERC1271Wallet is IERC1271 {
    function isValidSignature(bytes32, bytes memory) external view returns (bytes4) {
        uint256 accumulator;
        while (gasleft() > 500) {
            unchecked {
                accumulator += gasleft();
            }
        }
        return bytes4(uint32(accumulator));
    }
}
