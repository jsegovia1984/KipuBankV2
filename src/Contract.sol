// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Security and Access Control Enhancements
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// Chainlink for Oracles
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBankV2
 * @notice A multi-token decentralized bank with a dynamic USD capacity limit,
 * utilizing AccessControl and Chainlink for secure management.
 */
contract KipuBankV2 is AccessControl {
    using SafeERC20 for IERC20;

    // =================================================================
    // Constants and Immutables
    // =================================================================

    // DEFAULT_ADMIN_ROLE is inherited from AccessControl.
    /// @notice Role for managing bank parameters (e.g., changing cap, oracle)
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @notice Address 0 as identifier for the native token (ETH)
    address public constant NATIVE_TOKEN = address(0);
    /// @notice Internal accounting standard (6 decimals, common for stablecoins)
    uint256 public constant INTERNAL_DECIMALS = 6;
    /// @notice Scaling factor (10^6) to normalize to INTERNAL_DECIMALS
    uint256 public constant NORMALIZATION_FACTOR = 10 ** INTERNAL_DECIMALS;
    /// @notice Timeout for oracle price freshness (1 hour)
    uint16 public constant ORACLE_HEARTBEAT = 3600;

    // Chainlink Price Feed Decimals (ETH/USD)
    uint8 public constant CHAINLINK_DECIMALS = 8;
    
    // =================================================================
    // State variables
    // =================================================================

    /// @notice Address of the main ETH/USD oracle
    AggregatorV3Interface private immutable i_ethUsdFeed;
    /// @notice Mapping of ERC-20 token decimals (for accurate accounting)
    mapping(address => uint8) private s_tokenDecimals;

    /// @notice userAddress => tokenAddress => user balance
    mapping(address => mapping(address => uint256)) private s_balances;

    /// @notice Maximum deposit limit for the entire bank (in USD with 6 decimals)
    uint256 public s_bankCapUSD;
    /// @notice Total value deposited in the bank (in USD with 6 decimals)
    uint256 public s_totalDepositedUSD;

    // =================================================================
    // Custom Errors
    // =================================================================
    error KipuBankV2__CapExceeded(uint256 valueUSD, uint256 capUSD);
    error KipuBankV2__InsufficientFunds(address token, uint256 requested, uint256 balance);
    error KipuBankV2__InvalidAmount();
    error KipuBankV2__StalePrice();
    error KipuBankV2__OracleCompromised();
    error KipuBankV2__TransferFailed();
    error KipuBankV2__ZeroPrice();
    error KipuBankV2__TokenNotERC20();

    // =================================================================
    // Events
    // =================================================================

    event Deposit(address indexed user, address indexed token, uint256 amount, uint256 valueUSD);
    event Withdrawal(address indexed user, address indexed token, uint256 amount, uint256 valueUSD);
    event BankCapUpdated(uint256 oldCap, uint256 newCap);
    event TokenDecimalsSet(address indexed token, uint8 decimals);

    // =================================================================
    // Constructor
    // =================================================================

    /**
     * @notice Constructor to initialize the bank
     * @param ethUsdFeedAddress Address of the Chainlink Data Feed for ETH/USD.
     * @param initialCapUSD Initial capacity limit of the bank in USD (using 6 decimals).
     */
    constructor(address ethUsdFeedAddress, uint256 initialCapUSD) {
        // Access Control Initialization
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);

        // Immutables Initialization
        i_ethUsdFeed = AggregatorV3Interface(ethUsdFeedAddress);
        s_bankCapUSD = initialCapUSD;

        // ETH has 18 decimals. This is fixed.
        s_tokenDecimals[NATIVE_TOKEN] = 18;
    }

    // =================================================================
    // Oracle Logic
    // =================================================================

    /**
     * @notice Gets the ETH/USD price from the Chainlink Data Feed.
     * @return ethUSDPrice_ Current ETH price in USD (with 8 decimals, according to Chainlink).
     */
    function getEthUsdPrice() public view returns (uint256 ethUSDPrice_) {
        // Chainlink oracles return (roundId, price, startedAt, updatedAt, answeredInRound)
        (, int256 ethUSDPrice,, uint256 updatedAt,) = i_ethUsdFeed.latestRoundData();

        if (ethUSDPrice <= 0) revert KipuBankV2__OracleCompromised();
        if (block.timestamp - updatedAt > ORACLE_HEARTBEAT) revert KipuBankV2__StalePrice();

        // Convert int256 to uint256
        ethUSDPrice_ = uint256(ethUSDPrice);
    }

    // =================================================================
    // Decimal Conversion and Valuation Logic (Multi-Token)
    // =================================================================

    /**
     * @notice Calculates the value of a token amount in USD, normalized to 6 decimals.
     * @dev Assumes all tokens are valued using the ETH/USD price as a reference.
     * For USDC (or stablecoins ~1USD), conversion is simplified.
     * @param _token Address of the token (address(0) for ETH).
     * @param _amount Token amount in its native decimals.
     * @return amountUSD Normalized amount in USD (6 decimals).
     */
    function _calculateUsdValue(address _token, uint256 _amount) internal view returns (uint256 amountUSD) {
        if (_amount == 0) return 0;
        
        uint8 tokenDecimals = s_tokenDecimals[_token];
        if (tokenDecimals == 0 && _token != NATIVE_TOKEN) revert KipuBankV2__TokenNotERC20(); // Decimals not configured

        if (_token == NATIVE_TOKEN) { 
            // 1. Get ETH/USD price (8 decimals)
            uint256 priceUSD = getEthUsdPrice();
            if (priceUSD == 0) revert KipuBankV2__ZeroPrice();

            // 2. Calculate ETH value in USD (8 decimals)
            // Formula: (ETH_Amount * ETH_Price_8Dec) / (10 ** ETH_Decimals)
            uint256 value8Dec = (_amount * priceUSD) / (10 ** tokenDecimals);

            // 3. Normalize from 8 Chainlink decimals to 6 internal decimals
            // Formula: value8Dec / 10**(8 - 6) = value8Dec / 100
            amountUSD = value8Dec / (10**(CHAINLINK_DECIMALS - INTERNAL_DECIMALS));
        } else {
            // Case ERC-20 Tokens (e.g., USDC). Assume 1 token = 1 USD (simplification)
            // We need to convert the token's decimals to our 6 internal decimals.
            if (tokenDecimals == INTERNAL_DECIMALS) {
                amountUSD = _amount;
            } else if (tokenDecimals > INTERNAL_DECIMALS) {
                // E.g., Token 18 dec -> Internal 6 dec (Divide by 10^12)
                amountUSD = _amount / (10**(tokenDecimals - INTERNAL_DECIMALS));
            } else {
                // E.g., Token 0 dec -> Internal 6 dec (Multiply by 10^6)
                amountUSD = _amount * (10**(INTERNAL_DECIMALS - tokenDecimals));
            }
        }
    }

    /**
     * @notice Checks if an operation exceeds the total bank capacity.
     */
    function _checkBankCapacity(uint256 _usdValue) internal view {
        if (s_totalDepositedUSD + _usdValue > s_bankCapUSD) {
            revert KipuBankV2__CapExceeded(s_totalDepositedUSD + _usdValue, s_bankCapUSD);
        }
    }

    // =================================================================
    // Deposit Functions
    // =================================================================

    /**
     * @notice Universal deposit function for both ETH and any ERC-20
     * @param _token Address of the token to deposit (address(0) for ETH).
     * @param _amount Amount of token to deposit (msg.value is used if it's ETH).
     */
    function deposit(address _token, uint256 _amount) public payable {
        // CHECKS - Validations
        uint256 amountToDeposit;

        if (_token == NATIVE_TOKEN) {
            amountToDeposit = msg.value;
            if (amountToDeposit == 0) revert KipuBankV2__InvalidAmount();
        } else {
            amountToDeposit = _amount;
            if (amountToDeposit == 0) revert KipuBankV2__InvalidAmount();
        }

        uint256 valueUSD = _calculateUsdValue(_token, amountToDeposit);
        _checkBankCapacity(valueUSD);

        // EFFECTS - State Update
        // Checks-Effects-Interactions Pattern
        unchecked {
            s_balances[msg.sender][_token] += amountToDeposit;
            s_totalDepositedUSD += valueUSD;
        }

        // INTERACTIONS - External Calls (only for ERC-20)
        if (_token != NATIVE_TOKEN) {
            // The user must have called approve() previously
            IERC20(_token).safeTransferFrom(msg.sender, address(this), amountToDeposit);
        }
        
        // ETH is automatically deposited due to 'payable'

        emit Deposit(msg.sender, _token, amountToDeposit, valueUSD);
    }

    /**
     * @notice Fallback/Receive function for direct ETH deposits.
     */
    receive() external payable {
        // Calls the deposit function with the correct parameters.
        // msg.value is automatically appended to the call.
        deposit(NATIVE_TOKEN, msg.value);
    }

    // =================================================================
    // Withdrawal Functions
    // =================================================================

    /**
     * @notice Universal withdrawal of native token (ETH) or ERC-20.
     * @param _token Address of the token to withdraw (address(0) for ETH).
     * @param _amount Amount of token to withdraw.
     */
    function withdraw(address _token, uint256 _amount) external {
        // CHECKS - Validations
        if (_amount == 0) revert KipuBankV2__InvalidAmount();
        if (s_balances[msg.sender][_token] < _amount) revert KipuBankV2__InsufficientFunds(_token, _amount, s_balances[msg.sender][_token]);
        
        uint256 valueUSD = _calculateUsdValue(_token, _amount);

        // EFFECTS - State Update (before external transfer: Anti-Reentrancy!)
        unchecked {
            s_balances[msg.sender][_token] -= _amount;
            s_totalDepositedUSD -= valueUSD;
        }

        // INTERACTIONS - External Transfer (LAST step)
        if (_token == NATIVE_TOKEN) {
            // .call is used for gas-efficiency and failure management.
            (bool success,) = payable(msg.sender).call{value: _amount}("");
            if (!success) revert KipuBankV2__TransferFailed();
        } else {
            IERC20(_token).safeTransfer(msg.sender, _amount);
        }

        emit Withdrawal(msg.sender, _token, _amount, valueUSD);
    }

    // =================================================================
    // Management Functions (MANAGER_ROLE)
    // =================================================================

    /**
     * @notice Sets a new capacity limit for the bank.
     * @param _newCapUSD New limit in USD (with 6 decimals).
     */
    function setBankCap(uint256 _newCapUSD) external onlyRole(MANAGER_ROLE) {
        emit BankCapUpdated(s_bankCapUSD, _newCapUSD);
        s_bankCapUSD = _newCapUSD;
    }

    /**
     * @notice Sets the decimals of an ERC-20 token for accurate accounting.
     * @param _token Address of the token.
     * @param _decimals Number of decimals of the token.
     */
    function setTokenDecimals(address _token, uint8 _decimals) external onlyRole(MANAGER_ROLE) {
        if (_token == NATIVE_TOKEN) revert KipuBankV2__InvalidAmount(); 
        s_tokenDecimals[_token] = _decimals;
        emit TokenDecimalsSet(_token, _decimals);
    }
    
    // =================================================================
    // Read Functions (View)
    // =================================================================

    /**
     * @notice Gets the balance of a specific token for the calling user.
     * @param _token Address of the token.
     * @return Token balance in its native decimals.
     */
    function getBalance(address _token) external view returns (uint256) {
        return s_balances[msg.sender][_token];
    }
    
    /**
     * @notice Gets the remaining capacity of the bank in USD (6 decimals).
     */
    function availableCapacityUSD() external view returns (uint256) {
        if (s_totalDepositedUSD >= s_bankCapUSD) return 0;
        return s_bankCapUSD - s_totalDepositedUSD;
    }
}
