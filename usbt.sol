// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*//////////////////////////////////////////////////////////////
                            INTERFACES
//////////////////////////////////////////////////////////////*/
interface ITRC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);

    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

interface ITRC20Metadata is ITRC20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

interface IStableToken is ITRC20Metadata {
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
}

/*//////////////////////////////////////////////////////////////
                    USBT (TRC20)
    - Mint/Burn (minter role)
    - Global pause
    - Max sell/swap amount to AMM 
    - Sell fee (only on AMM sells)
    - Buy with USDT (mint on buy)
    - Supply cap
    - Withdraw sell fees + USDT + rescue any TRC20
//////////////////////////////////////////////////////////////*/
contract USBT is IStableToken {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    error NotOwner();
    error NotMinter();
    error NotPauser();
    error ZeroAddress();
    error BalanceTooLow();
    error AllowanceTooLow();
    error Paused();
    error CapExceeded();
    error InvalidRate();
    error TransferFailed();
    error FeeTooHigh();
    error AmountZero();
    error FeatureDisabled();
    error MaxSellExceeded();

    /*//////////////////////////////////////////////////////////////
                                METADATA
    //////////////////////////////////////////////////////////////*/
    string public override name;
    string public override symbol;
    uint8 public immutable override decimals;

    /*//////////////////////////////////////////////////////////////
                                ERC20 STORAGE
    //////////////////////////////////////////////////////////////*/
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    /*//////////////////////////////////////////////////////////////
                                ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/
    address public owner;
    mapping(address => bool) public isMinter;
    mapping(address => bool) public isPauser;

    /*//////////////////////////////////////////////////////////////
                                GLOBAL PAUSE
    //////////////////////////////////////////////////////////////*/
    bool public paused;

    /*//////////////////////////////////////////////////////////////
                            AMM / SELL CONTROL
    //////////////////////////////////////////////////////////////*/
    mapping(address => bool) public isAMM;
    mapping(address => bool) public isSellLockExempt;

    // Max sell amount to AMM in token smallest units
    // Example for 18 decimals:
    // 5000 tokens = 5000 * 10**18
    // 0 means unlimited
    bool public maxSellEnabled = true;
    uint256 public maxSellAmount;

    /*//////////////////////////////////////////////////////////////
                                SUPPLY CAP
    //////////////////////////////////////////////////////////////*/
    uint256 public cap; // 0 = unlimited

    /*//////////////////////////////////////////////////////////////
                            SELL FEE (only on AMM sells)
    //////////////////////////////////////////////////////////////*/
    bool public sellFeeEnabled = true;
    uint256 public sellFeeBps = 500; // 5% default
    uint256 public collectedSellFees;

    /*//////////////////////////////////////////////////////////////
                                BUY WITH USDT
    //////////////////////////////////////////////////////////////*/
    bool public buyWithUSDTEnabled = true;
    address public usdt;
    uint8 public usdtDecimals;

    // 5-decimal precision
    // 1:1 => 100000
    // 2.5 => 250000
    // 0.75 => 75000
    uint256 public exchangeRate;
    uint256 public constant RATE_PRECISION = 100000;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    event OwnerTransferred(address indexed oldOwner, address indexed newOwner);
    event MinterUpdated(address indexed minter, bool enabled);
    event PauserUpdated(address indexed pauser, bool enabled);
    event PausedUpdated(bool paused);
    event AMMUpdated(address indexed amm, bool enabled);
    event SellLockExemptUpdated(address indexed account, bool exempt);

    event MaxSellEnabledUpdated(bool enabled);
    event MaxSellAmountUpdated(uint256 amount);

    event CapUpdated(uint256 cap_);

    event SellFeeEnabledUpdated(bool enabled);
    event SellFeeUpdated(uint256 feeBps);
    event SellFeesWithdrawn(address indexed to, uint256 amount);

    event BuyWithUSDTEnabledUpdated(bool enabled);
    event USDTUpdated(address indexed usdt, uint8 decimals_);
    event ExchangeRateUpdated(uint256 newRate);
    event TokensPurchased(address indexed buyer, uint256 usdtAmount, uint256 tokenAmount);

    event ExternalTokenWithdrawn(address indexed token, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyMinter() {
        if (!isMinter[msg.sender]) revert NotMinter();
        _;
    }

    modifier onlyPauser() {
        if (!isPauser[msg.sender] && msg.sender != owner) revert NotPauser();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        address _owner,
        uint256 _cap,
        address _usdt,
        uint256 _exchangeRate,
        uint256 _maxSellAmount
    ) {
        if (_owner == address(0)) revert ZeroAddress();
        if (_usdt == address(0)) revert ZeroAddress();
        if (_exchangeRate == 0) revert InvalidRate();

        name = _name;
        symbol = _symbol;
        decimals = _decimals;

        owner = _owner;
        cap = _cap;

        usdt = _usdt;
        usdtDecimals = _safeDecimals(_usdt);
        exchangeRate = _exchangeRate;

        maxSellAmount = _maxSellAmount;

        isSellLockExempt[_owner] = true;
        isSellLockExempt[address(this)] = true;

        emit CapUpdated(_cap);
        emit OwnerTransferred(address(0), _owner);
        emit SellLockExemptUpdated(_owner, true);

        emit USDTUpdated(_usdt, usdtDecimals);
        emit ExchangeRateUpdated(_exchangeRate);

        emit SellFeeUpdated(sellFeeBps);
        emit SellFeeEnabledUpdated(sellFeeEnabled);

        emit MaxSellAmountUpdated(_maxSellAmount);
        emit MaxSellEnabledUpdated(maxSellEnabled);

        emit BuyWithUSDTEnabledUpdated(buyWithUSDTEnabled);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN CONTROLS
    //////////////////////////////////////////////////////////////*/
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setPaused(bool _paused) external onlyPauser {
        paused = _paused;
        emit PausedUpdated(_paused);
    }

    function setMinter(address minter, bool enabled) external onlyOwner {
        if (minter == address(0)) revert ZeroAddress();
        isMinter[minter] = enabled;
        emit MinterUpdated(minter, enabled);
    }

    function setPauser(address pauser, bool enabled) external onlyOwner {
        if (pauser == address(0)) revert ZeroAddress();
        isPauser[pauser] = enabled;
        emit PauserUpdated(pauser, enabled);
    }

    function setAMM(address amm, bool enabled) external onlyOwner {
        if (amm == address(0)) revert ZeroAddress();
        isAMM[amm] = enabled;
        emit AMMUpdated(amm, enabled);
    }

    function setAMMBatch(address[] calldata amms, bool enabled) external onlyOwner {
        for (uint256 i = 0; i < amms.length; i++) {
            if (amms[i] == address(0)) revert ZeroAddress();
            isAMM[amms[i]] = enabled;
            emit AMMUpdated(amms[i], enabled);
        }
    }

    function setSellLockExempt(address account, bool exempt) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        isSellLockExempt[account] = exempt;
        emit SellLockExemptUpdated(account, exempt);
    }

    function setCap(uint256 newCap) external onlyOwner {
        if (newCap != 0 && newCap < totalSupply) revert CapExceeded();
        cap = newCap;
        emit CapUpdated(newCap);
    }

    function setSellFeeEnabled(bool enabled) external onlyOwner {
        sellFeeEnabled = enabled;
        emit SellFeeEnabledUpdated(enabled);
    }

    function setSellFeeBps(uint256 feeBps) external onlyOwner {
        if (feeBps > 1000) revert FeeTooHigh(); // max 10%
        sellFeeBps = feeBps;
        emit SellFeeUpdated(feeBps);
    }

    function setMaxSellEnabled(bool enabled) external onlyOwner {
        maxSellEnabled = enabled;
        emit MaxSellEnabledUpdated(enabled);
    }

    function setMaxSellAmount(uint256 amount) external onlyOwner {
        maxSellAmount = amount;
        emit MaxSellAmountUpdated(amount);
    }

    function setBuyWithUSDTEnabled(bool enabled) external onlyOwner {
        buyWithUSDTEnabled = enabled;
        emit BuyWithUSDTEnabledUpdated(enabled);
    }

    function setUSDT(address newUsdt) external onlyOwner {
        if (newUsdt == address(0)) revert ZeroAddress();
        usdt = newUsdt;
        usdtDecimals = _safeDecimals(newUsdt);
        emit USDTUpdated(newUsdt, usdtDecimals);
    }

    function setExchangeRate(uint256 newRate) external onlyOwner {
        if (newRate == 0) revert InvalidRate();
        exchangeRate = newRate;
        emit ExchangeRateUpdated(newRate);
    }

    /*//////////////////////////////////////////////////////////////
                                ERC20
    //////////////////////////////////////////////////////////////*/
    function approve(address spender, uint256 value) external override whenNotPaused returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) external whenNotPaused returns (bool) {
        _approve(msg.sender, spender, allowance[msg.sender][spender] + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external whenNotPaused returns (bool) {
        uint256 current = allowance[msg.sender][spender];
        if (current < subtractedValue) revert AllowanceTooLow();
        _approve(msg.sender, spender, current - subtractedValue);
        return true;
    }

    function transfer(address to, uint256 value) external override whenNotPaused returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external override whenNotPaused returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < value) revert AllowanceTooLow();

        if (allowed != type(uint256).max) {
            _approve(from, msg.sender, allowed - value);
        }

        _transfer(from, to, value);
        return true;
    }

    function _approve(address owner_, address spender, uint256 value) internal {
        if (owner_ == address(0) || spender == address(0)) revert ZeroAddress();
        allowance[owner_][spender] = value;
        emit Approval(owner_, spender, value);
    }

    function _transfer(address from, address to, uint256 value) internal {
    if (from == address(0) || to == address(0)) revert ZeroAddress();
    if (value == 0) revert AmountZero();

    bool isSellToAMM = isAMM[to] && !isSellLockExempt[from];

    uint256 fee = 0;

    if (sellFeeEnabled && sellFeeBps != 0 && isSellToAMM) {
        fee = (value * sellFeeBps) / 10000;
    }

    uint256 totalRequired = value + fee;
    if (balanceOf[from] < totalRequired) revert BalanceTooLow();

    // Max sell check on what AMM receives
    if (maxSellEnabled && isSellToAMM && maxSellAmount != 0 && value > maxSellAmount) {
        revert MaxSellExceeded();
    }

    unchecked {
        balanceOf[from] -= totalRequired;  
        balanceOf[to] += value;

        if (fee != 0) {
            balanceOf[address(this)] += fee; 
        }
    }

    if (fee != 0) {
        collectedSellFees += fee;
        emit Transfer(from, address(this), fee); 
    }

    emit Transfer(from, to, value);
}

    /*//////////////////////////////////////////////////////////////
                            MINT / BURN
    //////////////////////////////////////////////////////////////*/
    function _mint(address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert AmountZero();
        if (cap != 0 && totalSupply + amount > cap) revert CapExceeded();

        totalSupply += amount;
        balanceOf[to] += amount;

        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        if (from == address(0)) revert ZeroAddress();
        if (amount == 0) revert AmountZero();
        if (balanceOf[from] < amount) revert BalanceTooLow();

        unchecked {
            balanceOf[from] -= amount;
            totalSupply -= amount;
        }

        emit Transfer(from, address(0), amount);
    }

    function mint(address to, uint256 amount) external override onlyMinter whenNotPaused {
        _mint(to, amount);
    }

    function burn(uint256 amount) external override onlyMinter whenNotPaused {
        _burn(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        BUY TOKENS WITH USDT
    //////////////////////////////////////////////////////////////*/
    function previewBuyTokens(uint256 usdtAmount) external view returns (uint256) {
        return _calcTokensOut(usdtAmount);
    }

    function buyTokens(uint256 usdtAmount) external whenNotPaused returns (uint256 tokenAmount) {
        if (!buyWithUSDTEnabled) revert FeatureDisabled();
        if (usdtAmount == 0) revert AmountZero();
        if (exchangeRate == 0) revert InvalidRate();

        bool success = ITRC20(usdt).transferFrom(msg.sender, address(this), usdtAmount);
        if (!success) revert TransferFailed();

        tokenAmount = _calcTokensOut(usdtAmount);
        if (tokenAmount == 0) revert AmountZero();

        _mint(msg.sender, tokenAmount);

        emit TokensPurchased(msg.sender, usdtAmount, tokenAmount);
        return tokenAmount;
    }

    function _calcTokensOut(uint256 usdtAmount) internal view returns (uint256) {
        uint256 tokenScale = 10 ** uint256(decimals);
        uint256 usdtScale = 10 ** uint256(usdtDecimals);
        uint256 numerator = usdtAmount * exchangeRate;

        return (numerator * tokenScale) / (RATE_PRECISION * usdtScale);
    }

    /*//////////////////////////////////////////////////////////////
                            WITHDRAW / RESCUE
    //////////////////////////////////////////////////////////////*/
    function withdrawSellFees(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert AmountZero();
        require(amount <= collectedSellFees, "exceeds collected");
        if (balanceOf[address(this)] < amount) revert BalanceTooLow();

        collectedSellFees -= amount;

        unchecked {
            balanceOf[address(this)] -= amount;
            balanceOf[to] += amount;
        }

        emit Transfer(address(this), to, amount);
        emit SellFeesWithdrawn(to, amount);
    }

    function withdrawUSDT(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert AmountZero();

        bool success = ITRC20(usdt).transfer(to, amount);
        if (!success) revert TransferFailed();

        emit ExternalTokenWithdrawn(usdt, to, amount);
    }

    function withdrawExternalToken(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert AmountZero();

        bool success = ITRC20(token).transfer(to, amount);
        if (!success) revert TransferFailed();

        emit ExternalTokenWithdrawn(token, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/
    function _safeDecimals(address token) internal view returns (uint8) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (success && data.length >= 32) {
            return uint8(uint256(bytes32(data)));
        }
        return 6;
    }
}