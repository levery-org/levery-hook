// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract PermissionManager {
    // Stores permissions for swaps
    mapping(address => bool) private swapPermissions;
    // Stores permissions for managing liquidity
    mapping(address => bool) private liquidityPermissions;

    // Address of the administrator (can be a governance contract or a specific wallet)
    address public admin;

    constructor() {
        admin = msg.sender; // Set the deployer as the initial admin
    }

    modifier onlyAdmin() {
        require(
            msg.sender == admin,
            "PermissionManager: caller is not the admin"
        );
        _;
    }

    // Function to change the administrator of the contract
    function setAdmin(address newAdmin) external onlyAdmin {
        require(
            newAdmin != address(0),
            "PermissionManager: new admin is the zero address"
        );
        admin = newAdmin;
    }

    // Set permissions for swaps
    function setSwapPermission(
        address user,
        bool permission
    ) external onlyAdmin {
        swapPermissions[user] = permission;
    }

    // Set permissions for managing liquidity
    function setLiquidityPermission(
        address user,
        bool permission
    ) external onlyAdmin {
        liquidityPermissions[user] = permission;
    }

    // Check if the user is allowed to swap
    function isSwapAllowed(address user) external view returns (bool) {
        return swapPermissions[user];
    }

    // Check if the user is allowed to manage liquidity
    function isLiquidityAllowed(address user) external view returns (bool) {
        return liquidityPermissions[user];
    }
}
