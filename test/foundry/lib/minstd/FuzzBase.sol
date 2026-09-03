// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Vm} from "./Vm.sol";

/**
 * @title FuzzBase (minstd)
 * @notice Minimal base for this repo's Foundry tests: the Vm handle, the
 *         invariant-targeting registry forge queries by convention, and
 *         revert-on-failure assertions. Deliberately tiny - see Vm.sol for why
 *         forge-std is vendored down to this surface instead of imported.
 * @dev Failure model: every assertion reverts with a message, and forge marks
 *      a reverting test (or a reverting invariant function) as failed. The
 *      targeting getters mirror forge-std's StdInvariant ABI, which is what
 *      the invariant runner actually calls.
 */
abstract contract FuzzBase {
    /// @dev The canonical HEVM cheatcode address: address(uint160(uint256(keccak256("hevm cheat code")))).
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    address[] private _targetedContracts;
    address[] private _targetedSenders;
    FuzzSelector[] private _targetedSelectors;

    function targetContract(address newTargetedContract) internal {
        _targetedContracts.push(newTargetedContract);
    }

    function targetSender(address newTargetedSender) internal {
        _targetedSenders.push(newTargetedSender);
    }

    function targetSelector(FuzzSelector memory newTargetedSelector) internal {
        _targetedSelectors.push(newTargetedSelector);
    }

    function targetContracts() public view returns (address[] memory) {
        return _targetedContracts;
    }

    function targetSenders() public view returns (address[] memory) {
        return _targetedSenders;
    }

    function targetSelectors() public view returns (FuzzSelector[] memory) {
        return _targetedSelectors;
    }

    function assertTrue(bool condition, string memory err) internal pure {
        require(condition, err);
    }

    function assertEq(uint256 a, uint256 b, string memory err) internal pure {
        if (a != b) {
            revert(string.concat(err, ": ", _toString(a), " != ", _toString(b)));
        }
    }

    function assertEq(address a, address b, string memory err) internal pure {
        require(a == b, err);
    }

    function assertEq(bytes32 a, bytes32 b, string memory err) internal pure {
        require(a == b, err);
    }

    function assertGe(uint256 a, uint256 b, string memory err) internal pure {
        if (a < b) {
            revert(string.concat(err, ": ", _toString(a), " < ", _toString(b)));
        }
    }

    function assertLe(uint256 a, uint256 b, string memory err) internal pure {
        if (a > b) {
            revert(string.concat(err, ": ", _toString(a), " > ", _toString(b)));
        }
    }

    function _toString(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
