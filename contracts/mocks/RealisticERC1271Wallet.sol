// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract RealisticERC1271Wallet is IERC1271 {
    address[] private owners;
    mapping(address => bool) public isOwner;
    uint256 public threshold;

    constructor(address owner_) {
        owners.push(owner_);
        isOwner[owner_] = true;
        threshold = 1;
    }

    function isValidSignature(bytes32 digest, bytes memory signature) external view returns (bytes4) {
        uint256 configuredThreshold = threshold;
        address owner = owners[0];
        bool recognizedOwner = isOwner[owner];
        (address recovered, ECDSA.RecoverError error, ) = ECDSA.tryRecover(digest, signature);

        return configuredThreshold == 1 && recognizedOwner && error == ECDSA.RecoverError.NoError && recovered == owner
            ? IERC1271.isValidSignature.selector
            : bytes4(0xffffffff);
    }

    function measureValidationGas(
        bytes32 digest,
        bytes calldata signature
    ) external view returns (uint256 gasUsed, bytes4 result) {
        uint256 gasBefore = gasleft();
        result = this.isValidSignature(digest, signature);
        gasUsed = gasBefore - gasleft();
    }
}
