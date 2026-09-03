// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @notice Declares an arbitrary ERC-5267 domain, including shapes OpenZeppelin's
/// EIP712 cannot produce -- a domain carrying a salt, or one that omits chainId.
/// @dev A client that reads only name/version/chainId/verifyingContract and ignores
/// the `fields` bitmap will sign under an incomplete domain and produce a signature
/// the contract rejects. This mock exists so that refusal can be tested rather than
/// assumed.
contract ConfigurableDomainDeclarer {
    bytes1 private immutable _fields;
    string private _name;
    string private _version;
    uint256 private immutable _chainId;
    address private immutable _verifyingContract;
    bytes32 private immutable _salt;

    constructor(
        bytes1 fields_,
        string memory name_,
        string memory version_,
        uint256 chainId_,
        address verifyingContract_,
        bytes32 salt_
    ) {
        _fields = fields_;
        _name = name_;
        _version = version_;
        _chainId = chainId_;
        _verifyingContract = verifyingContract_;
        _salt = salt_;
    }

    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        return (
            _fields,
            _name,
            _version,
            _chainId,
            _verifyingContract,
            _salt,
            new uint256[](0)
        );
    }
}
