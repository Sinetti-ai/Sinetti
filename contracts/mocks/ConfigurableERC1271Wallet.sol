// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract ConfigurableERC1271Wallet is IERC1271 {
    enum SignatureBehavior {
        Valid,
        Revert,
        WrongMagic,
        ShortReturn
    }

    address public immutable owner;
    SignatureBehavior public signatureBehavior;

    constructor(address owner_) {
        owner = owner_;
    }

    function setSignatureBehavior(SignatureBehavior behavior) external {
        require(msg.sender == owner, "not owner");
        signatureBehavior = behavior;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory result) {
        require(msg.sender == owner, "not owner");

        (bool success, bytes memory returndata) = target.call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
        return returndata;
    }

    function isValidSignature(bytes32 digest, bytes memory signature) external view returns (bytes4) {
        if (signatureBehavior == SignatureBehavior.Revert) {
            revert("signature check reverted");
        }
        if (signatureBehavior == SignatureBehavior.WrongMagic) {
            return bytes4(0xffffffff);
        }
        if (signatureBehavior == SignatureBehavior.ShortReturn) {
            assembly ("memory-safe") {
                mstore(0x00, shl(224, 0x1626ba7e))
                return(0x00, 0x02)
            }
        }

        return ECDSA.recover(digest, signature) == owner
            ? IERC1271.isValidSignature.selector
            : bytes4(0xffffffff);
    }
}
