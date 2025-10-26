KipuBankV2: Secure Multi-Token Bank 

This document describes the upgraded version of the KipuBank Smart Contract, refactored for production-readiness, emphasizing security, multi-token support, and dynamic capacity management using Chainlink Oracles.

Overview of Improvements
The original KipuBank was transformed into a robust decentralized banking platform. The key design changes focused on three areas:

Security and Patterns: The vulnerable "Interactions before Effects" pattern was replaced with a strict Checks-Effects-Interactions sequence in all transfer functions to prevent reentrancy attacks. Access control was upgraded from basic Ownable to OpenZeppelin's AccessControl, enabling granular roles like MANAGER_ROLE for administrative delegation.

Accounting and Multi-Token Support: The dual accounting system was replaced by a single, consistent Nested Mapping (user => token => balance) to handle both ERC-20 tokens and native ETH (address(0)). Universal deposit() and withdraw() functions were introduced, replacing the separate per-token functions.

Capacity and Oracle Integration: The static, volatile ETH-based bank limit was replaced with a dynamic capacity check based on USD value. This required integrating Chainlink Data Feeds (ETH/USD price) and implementing internal decimal standardization (6 decimals) for all USD-value accounting, ensuring stability regardless of token price fluctuations.

Design Decisions and Trade-offs

1. Unified Multi-Asset Accounting
We use a single nested mapping (s_balances) to track all user assets. This is the industry standard for vaults, offering clarity and extensibility. Native Ether is identified using the zero address (address(0)).

2. Dynamic Capacity Limit in USD
The total bank deposits (s_totalDepositedUSD) and the capacity limit (s_bankCapUSD) are constantly tracked in USD (6 decimal places). This provides a stable, real-world limit. The _calculateUsdValue function is crucial here, converting the input token amount (e.g., 18 decimals of ETH) into the internal 6-decimal USD standard using the Chainlink ETH/USD Data Feed.

3. Access Control Strategy
We use AccessControl to enforce a separation of duties:

The DEFAULT_ADMIN_ROLE manages and assigns all other roles.

The MANAGER_ROLE is delegated to manage operational parameters, specifically calling setBankCap() (to adjust the limit) and setTokenDecimals() (to onboard new ERC-20 tokens).

Deployment and Interaction
Prerequisites
You will need a Solidity compiler (^0.8.20) and development tools like Hardhat or Foundry, along with OpenZeppelin and Chainlink dependencies.

Contract Deployment
The KipuBankV2 constructor requires two parameters upon deployment:

ethUsdFeedAddress: The address of the ETH/USD Chainlink Data Feed on the target testnet.

initialCapUSD: The bank capacity limit specified in USD, scaled to 6 decimal places (e.g., 1000000000000 for $1,000,000).

Interaction Guide

1. Set Token Decimals (Manager Action)
For the contract to accurately value any ERC-20 token, its decimal count must be set by the Manager:

// Example: Setting USDC (which has 6 decimals)
KipuBankV2.setTokenDecimals(0xYourUSDCAddress, 6);

2. Deposit ETH
Call the deposit function with address(0) as the token address, or simply send ETH to the contract's address (which triggers the receive function).

// Calling deposit(address _token, uint256 _amount)
// _token: 0x0000000000000000000000000000000000000000
// _amount: 0 (or ignored)
// transaction value: 1 ETH (or desired amount in wei)
KipuBankV2.deposit(0x000...000, 0, { value: 1000000000000000000 });

3. Deposit ERC-20 (e.g., USDC)
The user must first call approve() on the ERC-20 token contract, giving KipuBankV2 permission to move the funds.

// User calls deposit on KipuBankV2:
// _token: USDC address (e.g., 0xYourUSDCAddress)
// _amount: 1000000000 (1000 USDC)
KipuBankV2.deposit(0xYourUSDCAddress, 1000000000);

4. Withdraw Tokens
Use the universal withdraw function for both token types.

// Withdraw ETH
KipuBankV2.withdraw(0x000...000, 500000000000000000); // 0.5 ETH in wei

// Withdraw USDC
KipuBankV2.withdraw(0xYourUSDCAddress, 100000000); // 100 USDC (6 decimals)
