/**
 * SPDX-License-Identifier: MIT
 *
 * Copyright (c) 2018-2020 CENTRE SECZ
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

pragma solidity 0.6.12;

import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "../../v1/Ownable.sol";
import { FiatTokenV2 } from "../FiatTokenV2.sol";
import { FiatTokenProxy } from "../../v1/FiatTokenProxy.sol";
import { V2UpgraderHelper } from "./V2UpgraderHelper.sol";

/**
 * @title V2 Upgrader
 * @notice Performs USDC v2 upgrade, and runs a basic sanity test in a single
 * atomic transaction, rolling back if any issues are found. This may be
 * overkill, but the peace of mind is worth the gas spent. By performing the
 * upgrade atomically, it ensures that there is no disruption of service if the
 * upgrade is not successful for some unforeseen circumstances.
 * @dev Read docs/v2_upgrade.md
 */
contract V2Upgrader is Ownable {
    using SafeMath for uint256;

    FiatTokenProxy private _proxy;
    FiatTokenV2 private _implementation;
    V2UpgraderHelper private _helper;

    /**
     * @notice Constructor
     * @param proxy             FiatTokenProxy contract
     * @param implementation    FiatTokenV2 implementation contract
     * @param helper            V2UpgraderHelper contract
     */
    constructor(
        FiatTokenProxy proxy,
        FiatTokenV2 implementation,
        V2UpgraderHelper helper
    ) public Ownable() {
        _proxy = proxy;
        _implementation = implementation;
        _helper = helper;
    }

    /**
     * @notice Upgrade, transfer proxy admin role to a given address, run a
     * sanity test, and tear down the upgrader contract, in a single atomic
     * transaction. It rolls back if there is an error.
     * @param newName       New ERC20 name (e.g. "USD//C" -> "USD Coin")
     * @param newProxyAdmin Grantee of the proxy admin role
     */
    function upgrade(string calldata newName, address newProxyAdmin)
        external
        onlyOwner
    {
        // The helper needs to be used to read contract state because
        // AdminUpgradeabilityProxy does not allow the proxy admin to make
        // proxy calls.

        // Check that this contract sufficient funds to run the tests
        uint256 contractBal = _helper.balanceOf(address(this));
        require(contractBal >= 2e5, "V2Upgrader: 0.2 USDC needed");

        uint256 callerBal = _helper.balanceOf(msg.sender);

        // Keep original contract metadata
        string memory symbol = _helper.symbol();
        uint8 decimals = _helper.decimals();
        string memory currency = _helper.currency();
        address masterMinter = _helper.masterMinter();
        address owner = _helper.owner();
        address pauser = _helper.pauser();
        address blacklister = _helper.blacklister();

        // Change implementation contract address
        _proxy.upgradeTo(address(_implementation));

        // Transfer admin role
        _proxy.changeAdmin(newProxyAdmin);

        // Initialize V2 contract
        FiatTokenV2 v2 = FiatTokenV2(address(_proxy));
        v2.initializeV2(newName);

        // Sanity test
        // Check metadata
        require(
            keccak256(bytes(newName)) == keccak256(bytes(newName)) &&
                keccak256(bytes(symbol)) == keccak256(bytes(v2.symbol())) &&
                decimals == v2.decimals() &&
                keccak256(bytes(currency)) == keccak256(bytes(v2.currency())) &&
                masterMinter == v2.masterMinter() &&
                owner == v2.owner() &&
                pauser == v2.pauser() &&
                blacklister == v2.blacklister(),
            "V2Upgrader: metadata test failed"
        );

        // Test balanceOf
        require(
            v2.balanceOf(address(this)) == contractBal,
            "V2Upgrader: balanceOf test failed"
        );

        // Test transfer
        require(
            v2.transfer(msg.sender, 1e5) &&
                v2.balanceOf(msg.sender) == callerBal.add(1e5) &&
                v2.balanceOf(address(this)) == contractBal.sub(1e5),
            "V2Upgrader: transfer test failed"
        );

        // Test approve/transferFrom
        require(
            v2.approve(address(_helper), 1e5) &&
                v2.allowance(address(this), address(_helper)) == 1e5 &&
                _helper.transferFrom(address(this), msg.sender, 1e5) &&
                v2.allowance(address(this), msg.sender) == 0 &&
                v2.balanceOf(msg.sender) == callerBal.add(2e5) &&
                v2.balanceOf(address(this)) == contractBal.sub(2e5),
            "V2Upgrader: approve/transferFrom test failed"
        );

        // Transfer any remaining USDC to the caller
        withdrawUSDC();

        selfdestruct(msg.sender);
    }

    /**
     * @notice Withdraw any USDC in the contract
     */
    function withdrawUSDC() public onlyOwner {
        IERC20 usdc = IERC20(address(_proxy));
        require(
            usdc.transfer(msg.sender, usdc.balanceOf(address(this))),
            "V2Upgrader: failed to withdraw USDC"
        );
    }

    /**
     * @notice Transfer proxy admin role to newProxyAdmin, and self-destruct
     * @param newProxyAdmin Grantee of the proxy admin role
     */
    function abortUpgrade(address newProxyAdmin) external onlyOwner {
        _proxy.changeAdmin(newProxyAdmin);
        selfdestruct(msg.sender);
    }
}
