// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IExternal.sol";
import {ILpDeskViews} from "./interfaces/ILpDesk.sol";
import {FirmAddresses} from "./FirmAddresses.sol";

/// @notice Created by LpDesk's constructor. Anyone sends it NOTSTOCK; burn() by anyone sends the whole balance
/// to the dead address. The token is read from LpDesk at each call, never stored here.
contract Burner {
    address public immutable lpDesk;

    event Burned(uint256 amount);

    error NothingToBurn();

    constructor(address lpDesk_) {
        lpDesk = lpDesk_;
    }

    function burn() external {
        IERC20 token = IERC20(ILpDeskViews(lpDesk).notStock());
        uint256 bal = token.balanceOf(address(this));
        if (bal == 0) revert NothingToBurn();
        require(token.transfer(FirmAddresses.DEAD, bal));
        emit Burned(bal);
    }
}
