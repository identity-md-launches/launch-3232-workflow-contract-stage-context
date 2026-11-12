// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IExternal.sol";
import {ILpDeskViews} from "./interfaces/ILpDesk.sol";

/// @notice Holds the project wallet's 600,000,000 NOTSTOCK until split(): 50/60 to LpDesk, 10/60 to the dev wallet,
/// once, after PriceGuard has registered NOTSTOCK. The dev share is 10/60 rounded down and LpDesk takes the rest,
/// so nothing stays behind (audit finding 6e61c2a0).
contract GenesisSplitter {
    address public immutable lpDesk;
    address public immutable devWallet;
    bool public done;

    event Split(uint256 toLpDesk, uint256 toDev);

    error AlreadySplit();
    error NotRegistered();
    error NothingToSplit();

    constructor(address lpDesk_, address devWallet_) {
        lpDesk = lpDesk_;
        devWallet = devWallet_;
    }

    function split() external {
        if (done) revert AlreadySplit();
        if (!ILpDeskViews(lpDesk).registered()) revert NotRegistered();
        IERC20 token = IERC20(ILpDeskViews(lpDesk).notStock());
        uint256 bal = token.balanceOf(address(this));
        if (bal == 0) revert NothingToSplit();
        done = true;
        uint256 devShare = bal * 10 / 60;
        uint256 deskShare = bal - devShare;
        require(token.transfer(devWallet, devShare));
        require(token.transfer(lpDesk, deskShare));
        emit Split(deskShare, devShare);
    }
}
