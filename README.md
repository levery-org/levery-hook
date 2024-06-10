# Levery

### **Uniswap v4 Hook for Impermanent Loss Mitigation and Regulatory Compliance 🦄**

![Levery Protocol](splash.jpg)

Levery enhances profitability for liquidity providers by leveraging Uniswap V4's hooks to implement dynamic fees based on
real-time market price feed oracles. These oracles supply trustworthy market price information, allowing for precise adjustments
of dynamic fees to maintain fair pricing and mitigate toxic arbitrage risks. This mechanism optimizes returns on investments
for liquidity providers and significantly reduces the impact of impermanent loss by ensuring that pool prices reflect current
market conditions.

Utilizing the PermissionManager component to enforce compliance controls over who can participate in swaps and liquidity
operations, Levery becomes capable of integrating comprehensive Know Your Customer (KYC) and Anti-Money Laundering (AML) checks
directly in the transaction flow. By ensuring that only verified and compliant users can engage in trading and liquidity
activities, Levery platform aligns with regulatory standards and mitigates potential compliance risks.

## Dynamic Fee Calculation

Let:
- $P_0$ and $P_1$ be the current prices for asset 0 and asset 1, respectively.
- $M$ be the real-time market price from the Oracle.
- $\alpha$ be the liquidity provider fee multiplier.
- $F_{\text{base}}$ be the base fee for the swap.
- $F_{\text{pool}}$ be the pool-specific fee for the swap, which takes precedence over $F_{\text{base}}$ if defined.

### Initial Swap Fee Definition

The initial swap fee $F_{\text{swap}}$ is defined as:

$$
F_{\text{swap}} = 
\begin{cases}
F_{\text{pool}} & \text{if } F_{\text{pool}} \neq 0 \\
F_{\text{base}} & \text{otherwise}
\end{cases}
$$

### Price Comparison and Fee Adjustment

If a market price oracle is defined, we adjust $F_{\text{swap}}$ based on the price comparison:

**If `compareWithPrice0` is true:**

$$
F_{\text{swap}} = 
\begin{cases}
F_{\text{swap}} + \left( \frac{P_0 - M}{M} \times \alpha \right) & \text{if } P_0 > M \text{ and } \text{params.zeroForOne} \\
F_{\text{swap}} + \left( \frac{M - P_0}{M} \times \alpha \right) & \text{if } P_0 < M \text{ and not } \text{params.zeroForOne} \\
F_{\text{swap}} & \text{otherwise}
\end{cases}
$$

**Else:**

$$
F_{\text{swap}} = 
\begin{cases}
F_{\text{swap}} + \left( \frac{M - P_1}{M} \times \alpha \right) & \text{if } P_1 < M \text{ and } \text{params.zeroForOne} \\
F_{\text{swap}} + \left( \frac{P_1 - M}{M} \times \alpha \right) & \text{if } P_1 > M \text{ and not } \text{params.zeroForOne} \\
F_{\text{swap}} & \text{otherwise}
\end{cases}
$$

### Final Fee Update

The updated swap fee is used to update the dynamic LP fee:

$$
\text{poolManager.updateDynamicLPFee}(key, F_{\text{swap}})
$$

### Description of the Calculations

The above calculations determine the dynamic swap fee ($F_{\text{swap}}$) by comparing the current asset prices ($P_0$ and $P_1$) with the real-time market price ($M$) obtained from an oracle. The liquidity provider fee multiplier ($\alpha$) is used to proportionally adjust the swap fee based on the price difference.

- If the current price of asset 0 ($P_0$) is greater than the market price ($M$) and the swap is from asset 0 to asset 1 ($\text{params.zeroForOne}$), the fee is increased proportionally to the difference.
- If the current price of asset 0 ($P_0$) is less than the market price ($M$) and the swap is from asset 1 to asset 0 ($\text{not params.zeroForOne}$), the fee is also increased proportionally to the difference.
- Similarly, if the current price of asset 1 ($P_1$) is less than the market price ($M$) and the swap is from asset 0 to asset 1 ($\text{params.zeroForOne}$), the fee is increased proportionally.
- If the current price of asset 1 ($P_1$) is greater than the market price ($M$) and the swap is from asset 1 to asset 0 ($\text{not params.zeroForOne}$), the fee is increased proportionally.

In all other cases (i.e., if none of these specific conditions are met), the swap fee remains unchanged.

This ensures that the swap fee dynamically adjusts to market conditions, providing a more accurate and fair fee structure for liquidity providers.

---

## Table of Contents

1. [Table of Contents](#table-of-contents)
2. [Introduction](#introduction)
3. [Repository Structure](#repository-structure)
4. [Set up](#set-up)
5. [How It Works](#how-it-works)
6. [Testnet Deployment](#testnet-deployment)
7. [Troubleshooting](#troubleshooting)

---

## Introduction

[`Levery Hook`](https://github.com/levery-org/levery-hook)

1. The Levery hook [Levery.sol](src/Levery.sol) extends BaseHook to provide dynamic fee management and oracle integration
   for Uniswap V4 pools, enforcing compliance via PermissionManager and leveraging Chainlink Oracles for market price comparisons
   to adjust LP fees dynamically.
2. The [PermissionManager.sol](src/utils/PermissionManager.sol) manages administrative permissions for swaps and liquidity
   operations, allowing only authorized users to perform these actions through a mapping of permissions and an admin-controlled
   interface.
3. The Levery test contract [Levery.t.sol](test/Levery.t.sol) sets up and tests the Levery hook, focusing on dynamic fee
   management using price oracles for price comparisons, calculating appropriate fees, and performing swaps within a Uniswap
   V4 pool context.
4. The [MockOracle.sol](test/utils/MockOracle.sol) simulates a price oracle by allowing the admin to set and retrieve mock
   price data and round information for testing purposes.

---

## Repository Structure

```
.github/
    workflows/
        test.yml
lib/
    chainlink/
    forge-std/
    v4-core/
    v4-periphery/
src/
    utils/
        PermissionManager.sol
    Levery.sol
test/
    utils/
        HookMiner.sol
        MockOracle.sol
    Levery.t.sol
.gitignore
.gitmodules
compiler_config.json
foundry.toml
LICENSE
README.md
remappings.txt
splash.jpg
```

---

## Set up

_requires [foundry](https://book.getfoundry.sh)_

```
forge install
forge test
```

---

## How It Works

### Levery.sol

The `Levery.sol` contract is designed to integrate with Uniswap V4 pools, providing dynamic fee management and oracle integration to enhance trading and liquidity operations. Here’s how it works:

1. **Initialization and Setup**:

   - The contract initializes with a given `IPoolManager` address and sets default values for base swap fees and liquidity provider (LP) fee multipliers.
   - The `admin` address is set, which has special privileges to modify key parameters and manage permissions.

2. **Dynamic Fee Management**:

   - The contract supports dynamic fee structures that adjust based on real-time market conditions. This is done through oracles that provide up-to-date price information.
   - Each pool can have its specific base fee, and the contract allows setting a base fee for swaps and an LP fee multiplier to calculate fees dynamically.

3. **Oracle Integration**:

   - The contract can integrate with external oracles (e.g., Chainlink) to fetch real-time market prices.
   - These oracles provide the latest price data, which is used to adjust swap fees dynamically, ensuring fees reflect current market conditions and reducing the risk of impermanent loss.

4. **Permission Management**:

   - A `PermissionManager` contract is used to manage permissions for adding/removing liquidity and performing swaps.
   - Only users with the appropriate permissions can perform these actions, ensuring compliance and security.

5. **Liquidity Operations**:

   - Before adding or removing liquidity, the contract checks if the user has the necessary permissions.
   - The `beforeAddLiquidity` and `beforeRemoveLiquidity` functions ensure only authorized users can perform these actions.

6. **Swap Operations**:

   - The `beforeSwap` function performs checks and calculates new swap fees based on current pool prices and oracle data.
   - The contract adjusts swap fees proportionally based on the difference between the pool prices and market prices fetched from the oracle, ensuring fair pricing and protecting liquidity providers from harmful arbitrage.

7. **Real-Time Price Adjustments**:

   - The contract includes functions to fetch the latest prices from oracles and adjust them according to token decimals.
   - This ensures accurate price comparisons and appropriate fee adjustments.

8. **Advanced Fee Calculations**:

   - The contract uses sophisticated algorithms and mathematical functions (e.g., [FullMath.sol](https://github.com/Uniswap/v4-core/blob/ae86975b058d386c9be24e8994236f662affacdb/src/libraries/FullMath.sol), [TickMath.sol](https://github.com/Uniswap/v4-core/blob/ae86975b058d386c9be24e8994236f662affacdb/src/libraries/TickMath.sol)) to calculate precise prices and fees.
   - It ensures that swap fees are dynamically adjusted to reflect real-time market conditions, optimizing profitability for liquidity providers.

9. **Hook Permissions**:
   - The contract specifies which hook functions are enabled, ensuring that only the necessary hooks are active for liquidity and swap operations.
   - This modular approach allows for flexible and efficient management of trading and liquidity actions.

---

### PermissionManager.sol

The `PermissionManager.sol` contract is designed to manage permissions for swapping and managing liquidity within of Levery.
Here’s how it works:

1. **Initialization**:

   - The contract sets the deployer as the initial admin upon deployment.
   - The admin has special privileges to manage permissions for other users.

2. **Permission Management**:

   - The contract maintains two mappings to store permissions:
     - `swapPermissions`: A mapping to store swap permissions for users.
     - `liquidityPermissions`: A mapping to store liquidity management permissions for users.
   - Only the admin can modify these permissions.

3. **Admin Functions**:

   - **setAdmin**: Allows the current admin to set a new admin. This ensures that the control of the contract can be transferred if necessary.
   - **setSwapPermission**: Allows the admin to grant or revoke swap permissions for a specific user.
   - **setLiquidityPermission**: Allows the admin to grant or revoke liquidity management permissions for a specific user.

4. **Permission Checks**:
   - **isSwapAllowed**: Checks if a specific user has permission to perform swaps.
   - **isLiquidityAllowed**: Checks if a specific user has permission to manage liquidity.

---

### Interaction of PermissionManager.sol with Levery.sol

By integrating `PermissionManager`, the `Levery` contract ensures robust permission controls, enhancing security and compliance.

1. **Setting Permissions**:

   - The `Levery` contract uses the `PermissionManager` to enforce permission checks before allowing users to add/remove liquidity or perform swaps.
   - The admin of the `PermissionManager` contract can set or update permissions for users, ensuring only authorized users can interact with the `Levery` contract's functionalities.

2. **Before Add/Remove Liquidity**:

   - When a user attempts to add or remove liquidity, the `Levery` contract calls `isLiquidityAllowed` on the `PermissionManager` to verify if the user has the required permissions.
   - If the user is not authorized, the action is denied.

3. **Before Swap**:
   - Similarly, before performing a swap, the `Levery` contract calls `isSwapAllowed` on the `PermissionManager` to ensure the user has the necessary permissions.
   - Unauthorized users are prevented from executing the swap.

---

### Example Workflow

1. **Admin Sets Permissions**:

   - The admin sets permissions for a user to manage liquidity and perform swaps:
     ```solidity
     permissionManager.setLiquidityPermission(userAddress, true);
     permissionManager.setSwapPermission(userAddress, true);
     ```

2. **User Attempts to Add Liquidity**:

   - The user tries to add liquidity via the `Levery` contract.
   - The `Levery` contract calls `permissionManager.isLiquidityAllowed(userAddress)`.
   - If true, the user can proceed; otherwise, the action is blocked.

3. **User Attempts to Swap**:
   - The user initiates a swap through the `Levery` contract.
   - The `Levery` contract calls `permissionManager.isSwapAllowed(userAddress)`.
   - If true, the swap proceeds; otherwise, it is blocked.

---

## Testnet Deployment

For testing the Levery team deployed the Uniswap [v4-core](https://github.com/Uniswap/v4-core) contracts on Sepolia testnet. This deployment uses the version
of `v4-core` - which is commit hash `3351c80e58e6300cb263d33a4efe75b88ad7b9b2`.

The relevant addresses for testing on Sepolia Testnet are the ones below:

```bash
POOL_MANAGER = 0x75E7c1Fd26DeFf28C7d1e82564ad5c24ca10dB14
MODIFY_LIQUIDITY_ROUTER = 0x2b925D1036E2E17F79CF9bB44ef91B95a3f9a084
SWAP_ROUTER = 0xB8b53649b87F0e1eb3923305490a5cB288083f82
```

- Pool Manager (`PoolManager.sol`) - https://sepolia.etherscan.io/address/0x75e7c1fd26deff28c7d1e82564ad5c24ca10db14
- Modify Liquidity Router (`PoolModifyLiquidityTest.sol`) - https://sepolia.etherscan.io/address/0x2b925D1036E2E17F79CF9bB44ef91B95a3f9a084
- Swap Router (`PoolSwapTest.sol`) - https://sepolia.etherscan.io/address/0xB8b53649b87F0e1eb3923305490a5cB288083f82

NOTE: This is not an official deployment from Uniswap.

---

## Troubleshooting

### _Permission Denied_

When installing dependencies with `forge install`, Github may throw a `Permission Denied` error

Typically caused by missing Github SSH keys, and can be resolved by following the steps [here](https://docs.github.com/en/github/authenticating-to-github/connecting-to-github-with-ssh)

Or [adding the keys to your ssh-agent](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent#adding-your-ssh-key-to-the-ssh-agent), if you have already uploaded SSH keys

### Hook deployment failures

Hook deployment failures are caused by incorrect flags or incorrect salt mining

1. Verify the flags are in agreement:
   - `getHookCalls()` returns the correct flags
   - `flags` provided to `HookMiner.find(...)`
2. Verify salt mining is correct:
   - In **forge test**: the *deploye*r for: `new Hook{salt: salt}(...)` and `HookMiner.find(deployer, ...)` are the same. This will be `address(this)`. If using `vm.prank`, the deployer will be the pranking address
   - In **forge script**: the deployer must be the CREATE2 Proxy: `0x4e59b44847b379578588920cA78FbF26c0B4956C`
     - If anvil does not have the CREATE2 deployer, your foundry may be out of date. You can update it with `foundryup`

---
