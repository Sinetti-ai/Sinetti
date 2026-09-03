// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/**
 * @title Vm (minstd)
 * @notice The minimal cheatcode surface this repo's Foundry suites use,
 *         vendored instead of depending on forge-std: the npm forge-std mirror
 *         has an unofficial publisher and stale versions (a supply-chain call
 *         this security repo refuses), and a git submodule would break the
 *         fresh-clone gate confusingly. Signatures checked against forge-std
 *         v1.9.6 (commit 8b4ea38e8ccf9bfd12ab299b7f7a4dd7d1c3a71f, src/Vm.sol).
 * @dev The cheatcode contract lives at the canonical HEVM address; every
 *      function here is implemented by the Foundry EVM itself.
 */
interface Vm {
    /// @notice Set block.timestamp for subsequent calls.
    function warp(uint256 newTimestamp) external;

    /// @notice Set block.number.
    function roll(uint256 newHeight) external;

    /// @notice Set msg.sender for exactly the next call.
    function prank(address msgSender) external;

    /// @notice Set msg.sender for all calls until stopPrank.
    function startPrank(address msgSender) external;

    /// @notice End a startPrank.
    function stopPrank() external;

    /// @notice The address for a given private key.
    function addr(uint256 privateKey) external pure returns (address keyAddr);

    /// @notice ECDSA-sign a digest with a private key.
    function sign(
        uint256 privateKey,
        bytes32 digest
    ) external pure returns (uint8 v, bytes32 r, bytes32 s);

    /// @notice Discard this fuzz run when the condition is false.
    function assume(bool condition) external pure;

    /// @notice Expect any revert on the next call.
    function expectRevert() external;

    /// @notice Expect the next call to revert with this selector.
    function expectRevert(bytes4 revertData) external;

    /// @notice Expect the next call to revert with exactly this data.
    function expectRevert(bytes calldata revertData) external;

    /// @notice Attach a display label to an address in traces.
    function label(address account, string calldata newLabel) external;
}
