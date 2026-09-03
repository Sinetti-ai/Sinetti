// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MaliciousReentrantToken is ERC20 {
    address public reentryTarget;
    bytes public reentryPayload;
    bool public reenterAfterTransfer;
    bool public reenterOnce;
    bool public callbackDone;
    bool public ignoreReentryFailure;
    bool public lastCallbackSucceeded;
    bytes public lastCallbackReturnData;
    uint256 public observedRecipientCredit;
    bool private inReentry;

    constructor() ERC20("Malicious Reentrant Token", "mRNT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(
        address target,
        bytes calldata payload,
        bool afterTransfer,
        bool oneShot
    ) external {
        reentryTarget = target;
        reentryPayload = payload;
        reenterAfterTransfer = afterTransfer;
        reenterOnce = oneShot;
        callbackDone = false;
        ignoreReentryFailure = false;
        lastCallbackSucceeded = false;
        delete lastCallbackReturnData;
        observedRecipientCredit = type(uint256).max;
    }

    function armIgnoringFailure(
        address target,
        bytes calldata payload,
        bool afterTransfer,
        bool oneShot
    ) external {
        reentryTarget = target;
        reentryPayload = payload;
        reenterAfterTransfer = afterTransfer;
        reenterOnce = oneShot;
        callbackDone = false;
        ignoreReentryFailure = true;
        lastCallbackSucceeded = false;
        delete lastCallbackReturnData;
        observedRecipientCredit = type(uint256).max;
    }

    function disarm() external {
        reentryTarget = address(0);
        reentryPayload = "";
        reenterAfterTransfer = false;
        reenterOnce = false;
        callbackDone = false;
        ignoreReentryFailure = false;
        lastCallbackSucceeded = false;
        delete lastCallbackReturnData;
        observedRecipientCredit = type(uint256).max;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (reentryTarget != address(0)) {
            (bool success, bytes memory returndata) = reentryTarget.staticcall(
                abi.encodeWithSignature("withdrawable(address,address)", address(this), to)
            );
            if (success && returndata.length >= 32) {
                observedRecipientCredit = abi.decode(returndata, (uint256));
            }
        }
        _maybeReenter(true);

        bool ok = super.transfer(to, value);

        _maybeReenter(false);

        return ok;
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override returns (bool) {
        _maybeReenter(true);

        bool ok = super.transferFrom(from, to, value);

        _maybeReenter(false);

        return ok;
    }

    function _maybeReenter(bool beforeTransfer) private {
        if (reentryTarget == address(0)) return;
        if (inReentry) return;
        if (beforeTransfer == reenterAfterTransfer) return;
        if (reenterOnce && callbackDone) return;

        if (reenterOnce) callbackDone = true;

        inReentry = true;
        (bool success, bytes memory returndata) = reentryTarget.call(reentryPayload);
        inReentry = false;
        lastCallbackSucceeded = success;
        lastCallbackReturnData = returndata;
        if (!success) {
            if (ignoreReentryFailure) return;
            if (returndata.length > 0) {
                assembly {
                    revert(add(returndata, 0x20), mload(returndata))
                }
            }
            revert("Reentrant callback failed");
        }
    }
}
