// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;


import "./lib/utils/math/SafeMath.sol";
import "./lib/token/ERC20/utils/SafeERC20.sol";
import "./lib/security/ReentrancyGuard.sol";
import "./lib/utils/Counters.sol";


library MathEx {
    function min(uint x, uint y) internal pure returns (uint z) {
        z = x < y ? x : y;
    }

    // babylonian method (https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method)
    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}


contract UnilendV2library {
    using SafeMath for uint256;
    
    function priceScaled(uint _price) internal pure returns (uint){
        uint256 _length = 0;
        uint256 tempI = _price;
        while (tempI != 0) { tempI = tempI/10; _length++; }

        _length = _length.sub(3);
        return (_price.div(10**_length)).mul(10**_length);
    }
    
    function calculateShare(uint _totalShares, uint _totalAmount, uint _amount) internal pure returns (uint){
        if(_totalShares == 0){
            return MathEx.sqrt(_amount.mul( _amount )).sub(10**3);
        } else {
            return (_amount).mul( _totalShares ).div( _totalAmount );
        }
    }
    
    function getShareValue(uint _totalAmount, uint _totalSupply, uint _amount) internal pure returns (uint){
        return ( _amount.mul(_totalAmount) ).div( _totalSupply );
    }
    
    function getShareByValue(uint _totalAmount, uint _totalSupply, uint _valueAmount) internal pure returns (uint){
        return ( _valueAmount.mul(_totalSupply) ).div( _totalAmount );
    }
    
    function calculateInterest(uint _principal, uint _rate, uint _duration) internal pure returns (uint){
        return _principal.mul( _rate.mul(_duration) ).div(10**20);
    }
}


contract UnilendV2transfer {
    using SafeERC20 for IERC20;

    address public token0;
    address public token1;
    address payable public core;

    modifier onlyCore {
        require(
            core == msg.sender,
            "Not Permitted"
        );
        _;
    }

    /**
    * @dev transfers to the user a specific amount from the reserve.
    * @param _reserve the address of the reserve where the transfer is happening
    * @param _user the address of the user receiving the transfer
    * @param _amount the amount being transferred
    **/
    function transferToUser(address _reserve, address payable _user, uint256 _amount) internal {
        require(_user != address(0), "UnilendV1: USER ZERO ADDRESS");
        
        IERC20(_reserve).safeTransfer(_user, _amount);
    }
}


interface IUnilendV2Core {
    function getOraclePrice(address _token0, address _token1, uint _amount) external view returns(uint);
}

interface IUnilendV2InterestRateModel {
    function getCurrentInterestRate(uint totalBorrow, uint availableBorrow) external pure returns (uint);
}



contract UnilendV2Pool is UnilendV2library, UnilendV2transfer {
    using SafeMath for uint256;
    
    bool initialized;
    address public interestRateAddress;
    uint public lastUpdated;

    uint8 ltv;  // loan to value
    uint8 lb;   // liquidation bonus
    uint8 rf;   // reserve factor
    uint64 public constant HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 1e18;

    tM public token0Data;
    tM public token1Data;
    mapping(uint => pM) public positionData;
    
    struct pM {
        uint token0lendShare;
        uint token1lendShare;
        uint token0borrowShare;
        uint token1borrowShare;
    }
    
    struct tM {
        uint totalLendShare;
        uint totalBorrowShare;
        uint totalBorrow;
    }
    


    // /**
    // * @dev emitted on lend
    // * @param _positionID the id of position NFT
    // * @param _amount the amount to be deposited for token
    // * @param _timestamp the timestamp of the action
    // **/
    event Lend( address indexed _asset, uint256 indexed _positionID, uint256 _amount, uint256 _token_amount );
    event Redeem( address indexed _asset, uint256 indexed _positionID, uint256 _token_amount, uint256 _amount );
    event InterestUpdate( uint256 _newRate0, uint256 _newRate1, uint256 totalBorrows0, uint256 totalBorrows1 );
    event Borrow( address indexed _asset, uint256 indexed _positionID, uint256 _amount, uint256 totalBorrows, address _recipient );
    event RepayBorrow( address indexed _asset, uint256 indexed _positionID, uint256 _amount, uint256 totalBorrows, address _payer );
    event LiquidateBorrow( address indexed _asset, uint256 indexed _positionID, uint256 indexed _toPositionID, uint repayAmount, uint seizeTokens );
    event LiquidationPriceUpdate( uint256 indexed _positionID, uint256 _price, uint256 _last_price, uint256 _amount );

    event NewMarketInterestRateModel(address oldInterestRateModel, address newInterestRateModel);
    event NewLTV(uint oldLTV, uint newLTV);
    event NewLB(uint oldLB, uint newLB);
    event NewRF(uint oldRF, uint newRF);


    constructor() {
        core = payable(msg.sender);
    }
    
    function init(
        address _token0, 
        address _token1,
        address _interestRate,
        uint8 _ltv,
        uint8 _lb,
        uint8 _rf
    ) external {
        require(!initialized, "UnilendV2: POOL ALREADY INIT");

        initialized = true;
        
        token0 = _token0;
        token1 = _token1;
        interestRateAddress = _interestRate;
        core = payable(msg.sender);
        
        ltv = _ltv;
        lb = _lb;
        rf = _rf;
    }
    
    
    function getLTV() external view returns (uint) { return ltv; }
    function getLB() external view returns (uint) { return lb; }
    function getRF() external view returns (uint) { return rf; }
    
    function checkHealthFactorLtv(uint _nftID) internal view {
        (uint256 _healthFactor0, uint256 _healthFactor1) = userHealthFactorLtv(_nftID);
        require(_healthFactor0 > HEALTH_FACTOR_LIQUIDATION_THRESHOLD, "Low Ltv HealthFactor0");
        require(_healthFactor1 > HEALTH_FACTOR_LIQUIDATION_THRESHOLD, "Low Ltv HealthFactor1");
    }

    function getInterestRate(uint _totalBorrow, uint _availableBorrow) public view returns (uint) {
        return IUnilendV2InterestRateModel(interestRateAddress).getCurrentInterestRate(_totalBorrow, _availableBorrow);
    }
    
    function getAvailableLiquidity0() public view returns (uint _available) {
        tM memory _tm0 = token0Data;

        uint totalBorrow = _tm0.totalBorrow;
        uint totalLiq = totalBorrow.add( IERC20(token0).balanceOf(address(this)) );
        uint maxAvail = ( totalLiq.mul( uint(100).sub(rf) ) ).div(100);

        if(maxAvail > totalBorrow){
            _available = maxAvail.sub(totalBorrow);
        }
    }
    
    function getAvailableLiquidity1() public view returns (uint _available) {
        tM memory _tm1 = token1Data;

        uint totalBorrow = _tm1.totalBorrow;
        uint totalLiq = totalBorrow.add( IERC20(token1).balanceOf(address(this)) );
        uint maxAvail = ( totalLiq.mul( uint(100).sub(rf) ) ).div(100);

        if(maxAvail > totalBorrow){
            _available = maxAvail.sub(totalBorrow);
        }
    }

    function userHealthFactorLtv(uint _nftID) public view returns (uint256 _healthFactor0, uint256 _healthFactor1) {
        (uint _lendBalance0, uint _borrowBalance0) = userBalanceOftoken0(_nftID);
        (uint _lendBalance1, uint _borrowBalance1) = userBalanceOftoken1(_nftID);
        
        if (_borrowBalance0 == 0){
            _healthFactor0 = type(uint256).max;
        } 
        else {
            uint collateralBalance = IUnilendV2Core(core).getOraclePrice(token1, token0, _lendBalance1);
            _healthFactor0 = (collateralBalance.mul(ltv).mul(1e18).div(100)).div(_borrowBalance0);
        }
        
        
        if (_borrowBalance1 == 0){
            _healthFactor1 = type(uint256).max;
        } 
        else {
            uint collateralBalance = IUnilendV2Core(core).getOraclePrice(token0, token1, _lendBalance0);
            _healthFactor1 = (collateralBalance.mul(ltv).mul(1e18).div(100)).div(_borrowBalance1);
        }
        
    }

    function userHealthFactor(uint _nftID) public view returns (uint256 _healthFactor0, uint256 _healthFactor1) {
        (uint _lendBalance0, uint _borrowBalance0) = userBalanceOftoken0(_nftID);
        (uint _lendBalance1, uint _borrowBalance1) = userBalanceOftoken1(_nftID);
        
        if (_borrowBalance0 == 0){
            _healthFactor0 = type(uint256).max;
        } 
        else {
            uint collateralBalance = IUnilendV2Core(core).getOraclePrice(token1, token0, _lendBalance1);
            _healthFactor0 = (collateralBalance.mul(uint(100).sub(lb)).mul(1e18).div(100)).div(_borrowBalance0);
        }
        
        
        if (_borrowBalance1 == 0){
            _healthFactor1 = type(uint256).max;
        } 
        else {
            uint collateralBalance = IUnilendV2Core(core).getOraclePrice(token0, token1, _lendBalance0);
            _healthFactor1 = (collateralBalance.mul(uint(100).sub(lb)).mul(1e18).div(100)).div(_borrowBalance1);
        }
        
    }
    
    function userBalanceOftoken0(uint _nftID) public view returns (uint _lendBalance0, uint _borrowBalance0) {
        pM memory _positionMt = positionData[_nftID];
        tM memory _tm0 = token0Data;
        
        uint _totalBorrow = _tm0.totalBorrow;
        if(block.number > lastUpdated){
            uint interestRate0 = getInterestRate(_tm0.totalBorrow, getAvailableLiquidity0());
            _totalBorrow = _totalBorrow.add( calculateInterest(_tm0.totalBorrow, interestRate0, (block.number - lastUpdated)) );
        }
        
        if(_positionMt.token0lendShare > 0){
            uint tokenBalance0 = IERC20(token0).balanceOf(address(this));
            uint _totTokenBalance0 = tokenBalance0.add(_totalBorrow);
            _lendBalance0 = getShareValue(_totTokenBalance0, _tm0.totalLendShare, _positionMt.token0lendShare);
        }
        
        if(_positionMt.token0borrowShare > 0){
            _borrowBalance0 = getShareValue( _totalBorrow, _tm0.totalBorrowShare, _positionMt.token0borrowShare);
        }
    }
    
    function userBalanceOftoken1(uint _nftID) public view returns (uint _lendBalance1, uint _borrowBalance1) {
        pM memory _positionMt = positionData[_nftID];
        tM memory _tm1 = token1Data;
        
        uint _totalBorrow = _tm1.totalBorrow;
        if(block.number > lastUpdated){
            uint interestRate1 = getInterestRate(_tm1.totalBorrow, getAvailableLiquidity1());
            _totalBorrow = _totalBorrow.add( calculateInterest(_tm1.totalBorrow, interestRate1, (block.number - lastUpdated)) );
        }
        
        if(_positionMt.token1lendShare > 0){
            uint tokenBalance1 = IERC20(token1).balanceOf(address(this));
            uint _totTokenBalance1 = tokenBalance1.add(_totalBorrow);
            _lendBalance1 = getShareValue(_totTokenBalance1, _tm1.totalLendShare, _positionMt.token1lendShare);
        }
        
        if(_positionMt.token1borrowShare > 0){
            _borrowBalance1 = getShareValue( _totalBorrow, _tm1.totalBorrowShare, _positionMt.token1borrowShare);
        }
    }

    function userBalanceOftokens(uint _nftID) public view returns (uint _lendBalance0, uint _borrowBalance0, uint _lendBalance1, uint _borrowBalance1) {
        (_lendBalance0, _borrowBalance0) = userBalanceOftoken0(_nftID);
        (_lendBalance1, _borrowBalance1) = userBalanceOftoken1(_nftID);
    }

    function userSharesOftoken0(uint _nftID) public view returns (uint _lendShare0, uint _borrowShare0) {
        pM memory _positionMt = positionData[_nftID];

        return (_positionMt.token0lendShare, _positionMt.token0borrowShare);
    }

    function userSharesOftoken1(uint _nftID) public view returns (uint _lendShare1, uint _borrowShare1) {
        pM memory _positionMt = positionData[_nftID];

        return (_positionMt.token1lendShare, _positionMt.token1borrowShare);
    }

    function userSharesOftokens(uint _nftID) public view returns (uint _lendShare0, uint _borrowShare0, uint _lendShare1, uint _borrowShare1) {
        pM memory _positionMt = positionData[_nftID];

        return (_positionMt.token0lendShare, _positionMt.token0borrowShare, _positionMt.token1lendShare, _positionMt.token1borrowShare);
    }

    function poolData() external view returns (
        uint _totalLendShare0, 
        uint _totalBorrowShare0, 
        uint _totalBorrow0,
        uint _totalBalance0, 
        uint _totalAvailableLiquidity0, 
        uint _totalLendShare1, 
        uint _totalBorrowShare1, 
        uint _totalBorrow1,
        uint _totalBalance1, 
        uint _totalAvailableLiquidity1
    ) {
        tM storage _tm0 = token0Data;
        tM storage _tm1 = token1Data;

        return (
            _tm0.totalLendShare, 
            _tm0.totalBorrowShare, 
            _tm0.totalBorrow,
            IERC20(token0).balanceOf(address(this)),
            getAvailableLiquidity0(),
            _tm1.totalLendShare, 
            _tm1.totalBorrowShare, 
            _tm1.totalBorrow,
            IERC20(token1).balanceOf(address(this)),
            getAvailableLiquidity1()
        );
    }




    function setInterestRateAddress(address _address) public onlyCore {
        emit NewMarketInterestRateModel(interestRateAddress, _address);
        interestRateAddress = _address;
    }

    function setLTV(uint8 _number) public onlyCore {
        emit NewLTV(ltv, _number);
        ltv = _number;
    }

    function setLB(uint8 _number) public onlyCore {
        emit NewLB(lb, _number);
        lb = _number;
    }

    function setRF(uint8 _number) public onlyCore {
        emit NewRF(rf, _number);
        rf = _number;
    }
    
    function accrueInterest() public {
        uint remainingBlocks = block.number - lastUpdated;
        
        if(remainingBlocks > 0){
            tM storage _tm0 = token0Data;
            tM storage _tm1 = token1Data;

            uint interestRate0 = getInterestRate(_tm0.totalBorrow, getAvailableLiquidity0());
            uint interestRate1 = getInterestRate(_tm1.totalBorrow, getAvailableLiquidity1());

            _tm0.totalBorrow = _tm0.totalBorrow.add( calculateInterest(_tm0.totalBorrow, interestRate0, remainingBlocks) );
            _tm1.totalBorrow = _tm1.totalBorrow.add( calculateInterest(_tm1.totalBorrow, interestRate1, remainingBlocks) );
            
            lastUpdated = block.number;

            emit InterestUpdate(interestRate0, interestRate1, _tm0.totalBorrow, _tm1.totalBorrow);
        }
    }

    function transferFlashLoanProtocolFee(address _distributorAddress, address _token, uint256 _amount) external onlyCore {
        transferToUser(_token, payable(_distributorAddress), _amount);
    }
    
    function processFlashLoan(address _receiver, int _amount) external onlyCore {
        accrueInterest();

        //transfer funds to the receiver
        if(_amount < 0){
            transferToUser(token0, payable(_receiver), uint(-_amount));
        } 
        
        if(_amount > 0){
            transferToUser(token1, payable(_receiver), uint(_amount));
        } 
    }
    
    function _mintLPposition(uint _nftID, uint tok_amount0, uint tok_amount1) internal {
        pM storage _positionMt = positionData[_nftID];
        
        if(tok_amount0 > 0){
            tM storage _tm0 = token0Data;
            
            _positionMt.token0lendShare = _positionMt.token0lendShare.add(tok_amount0);
            _tm0.totalLendShare = _tm0.totalLendShare.add(tok_amount0);
        }
        
        if(tok_amount1 > 0){
            tM storage _tm1 = token1Data;
            
            _positionMt.token1lendShare = _positionMt.token1lendShare.add(tok_amount1);
            _tm1.totalLendShare = _tm1.totalLendShare.add(tok_amount1);
        }
    }
    
    
    function _burnLPposition(uint _nftID, uint tok_amount0, uint tok_amount1) internal {
        pM storage _positionMt = positionData[_nftID];
        
        if(tok_amount0 > 0){
            tM storage _tm0 = token0Data;
            
            _positionMt.token0lendShare = _positionMt.token0lendShare.sub(tok_amount0);
            _tm0.totalLendShare = _tm0.totalLendShare.sub(tok_amount0);
        }
        
        if(tok_amount1 > 0){
            tM storage _tm1 = token1Data;
            
            _positionMt.token1lendShare = _positionMt.token1lendShare.sub(tok_amount1);
            _tm1.totalLendShare = _tm1.totalLendShare.sub(tok_amount1);
        }
    }
    
    
    function _mintBposition(uint _nftID, uint tok_amount0, uint tok_amount1) internal {
        pM storage _positionMt = positionData[_nftID];
        
        if(tok_amount0 > 0){
            tM storage _tm0 = token0Data;
            
            _positionMt.token0borrowShare = _positionMt.token0borrowShare.add(tok_amount0);
            _tm0.totalBorrowShare = _tm0.totalBorrowShare.add(tok_amount0);
        }
        
        if(tok_amount1 > 0){
            tM storage _tm1 = token1Data;
            
            _positionMt.token1borrowShare = _positionMt.token1borrowShare.add(tok_amount1);
            _tm1.totalBorrowShare = _tm1.totalBorrowShare.add(tok_amount1);
        }
    }
    
    
    function _burnBposition(uint _nftID, uint tok_amount0, uint tok_amount1) internal {
        pM storage _positionMt = positionData[_nftID];
        
        if(tok_amount0 > 0){
            tM storage _tm0 = token0Data;
            
            _positionMt.token0borrowShare = _positionMt.token0borrowShare.sub(tok_amount0);
            _tm0.totalBorrowShare = _tm0.totalBorrowShare.sub(tok_amount0);
        }
        
        if(tok_amount1 > 0){
            tM storage _tm1 = token1Data;
            
            _positionMt.token1borrowShare = _positionMt.token1borrowShare.sub(tok_amount1);
            _tm1.totalBorrowShare = _tm1.totalBorrowShare.sub(tok_amount1);
        }
    }
    
    
    // --------
    
    
    function lend(uint _nftID, int amount) external onlyCore returns(uint) {
        uint ntokens0; uint ntokens1;
        
        if(amount < 0){
            tM storage _tm0 = token0Data;
            
            uint tokenBalance0 = IERC20(token0).balanceOf(address(this));
            uint _totTokenBalance0 = tokenBalance0.add(_tm0.totalBorrow);
            ntokens0 = calculateShare(_tm0.totalLendShare, _totTokenBalance0.sub(uint(-amount)), uint(-amount));
            if(_tm0.totalLendShare == 0){
                _mintLPposition(0, 10**3, 0);
            }
            require(ntokens0 > 0, 'Insufficient Liquidity Minted');

            emit Lend(token0, _nftID, uint(-amount), ntokens0);
        }
        
        if(amount > 0){
            tM storage _tm1 = token1Data;
            
            uint tokenBalance1 = IERC20(token1).balanceOf(address(this));
            uint _totTokenBalance1 = tokenBalance1.add(_tm1.totalBorrow);
            ntokens1 = calculateShare(_tm1.totalLendShare, _totTokenBalance1.sub(uint(amount)), uint(amount));
            if(_tm1.totalLendShare == 0){
                _mintLPposition(0, 0, 10**3);
            }
            require(ntokens1 > 0, 'Insufficient Liquidity Minted');

            emit Lend(token1, _nftID, uint(amount), ntokens1);
        }
        
        _mintLPposition(_nftID, ntokens0, ntokens1);

        return 0;
    }
    
    
    function redeem(uint _nftID, int tok_amount, address _receiver) external onlyCore returns(int _amount) {
        accrueInterest();
        
        pM storage _positionMt = positionData[_nftID];
        
        if(tok_amount < 0){
            require(_positionMt.token0lendShare >= uint(-tok_amount), "Balance Exceeds Requested");
            
            tM storage _tm0 = token0Data;
            
            uint tokenBalance0 = IERC20(token0).balanceOf(address(this));
            uint _totTokenBalance0 = tokenBalance0.add(_tm0.totalBorrow);
            uint poolAmount = getShareValue(_totTokenBalance0, _tm0.totalLendShare, uint(-tok_amount));
            
            _amount = -int(poolAmount);

            require(tokenBalance0 >= poolAmount, "Not enough Liquidity");
            
            _burnLPposition(_nftID, uint(-tok_amount), 0);

            // check if _healthFactorLtv > 1
            checkHealthFactorLtv(_nftID);
            
            transferToUser(token0, payable(_receiver), poolAmount);

            emit Redeem(token0, _nftID, uint(-tok_amount), poolAmount);
        }
        
        if(tok_amount > 0){
            require(_positionMt.token1lendShare >= uint(tok_amount), "Balance Exceeds Requested");
            
            tM storage _tm1 = token1Data;
            
            uint tokenBalance1 = IERC20(token1).balanceOf(address(this));
            uint _totTokenBalance1 = tokenBalance1.add(_tm1.totalBorrow);
            uint poolAmount = getShareValue(_totTokenBalance1, _tm1.totalLendShare, uint(tok_amount));
            
            _amount = int(poolAmount);

            require(tokenBalance1 >= poolAmount, "Not enough Liquidity");
            
            _burnLPposition(_nftID, 0, uint(tok_amount));

            // check if _healthFactorLtv > 1
            checkHealthFactorLtv(_nftID);
            
            transferToUser(token1, payable(_receiver), poolAmount);

            emit Redeem(token1, _nftID, uint(tok_amount), poolAmount);
        }

    }
    
    
    function redeemUnderlying(uint _nftID, int _amount, address _receiver) external onlyCore returns(int rtAmount) {
        accrueInterest();
        
        pM storage _positionMt = positionData[_nftID];
        
        if(_amount < 0){
            tM storage _tm0 = token0Data;
            
            uint tokenBalance0 = IERC20(token0).balanceOf(address(this));
            uint _totTokenBalance0 = tokenBalance0.add(_tm0.totalBorrow);
            uint tok_amount0 = getShareByValue(_totTokenBalance0, _tm0.totalLendShare, uint(-_amount));
            
            require(tok_amount0 > 0, 'Insufficient Liquidity Burned');
            require(_positionMt.token0lendShare >= tok_amount0, "Balance Exceeds Requested");
            require(tokenBalance0 >= uint(-_amount), "Not enough Liquidity");
            
            _burnLPposition(_nftID, tok_amount0, 0);

            // check if _healthFactorLtv > 1
            checkHealthFactorLtv(_nftID);
            
            transferToUser(token0, payable(_receiver), uint(-_amount));
            
            rtAmount = -int(tok_amount0);

            emit Redeem(token0, _nftID, tok_amount0, uint(-_amount));
        }
        
        if(_amount > 0){
            tM storage _tm1 = token1Data;
            
            uint tokenBalance1 = IERC20(token1).balanceOf(address(this));
            uint _totTokenBalance1 = tokenBalance1.add(_tm1.totalBorrow);
            uint tok_amount1 = getShareByValue(_totTokenBalance1, _tm1.totalLendShare, uint(_amount));
            
            require(tok_amount1 > 0, 'Insufficient Liquidity Burned');
            require(_positionMt.token1lendShare >= tok_amount1, "Balance Exceeds Requested");
            require(tokenBalance1 >= uint(_amount), "Not enough Liquidity");
            
            _burnLPposition(_nftID, 0, tok_amount1);

            // check if _healthFactorLtv > 1
            checkHealthFactorLtv(_nftID);
            
            transferToUser(token1, payable(_receiver), uint(_amount));
            
            rtAmount = int(tok_amount1);

            emit Redeem(token1, _nftID, tok_amount1, uint(_amount));
        }

    }
    
    
    function borrow(uint _nftID, int amount, address payable _recipient) external onlyCore {
        accrueInterest();

        if(amount < 0){
            tM storage _tm0 = token0Data;
            
            uint ntokens0 = calculateShare(_tm0.totalBorrowShare, _tm0.totalBorrow, uint(-amount));
            if(_tm0.totalBorrowShare == 0){
                _mintBposition(0, 10**3, 0);
            }
            require(ntokens0 > 0, 'Insufficient Borrow0 Liquidity Minted');
            
            _mintBposition(_nftID, ntokens0, 0);
            
            _tm0.totalBorrow = _tm0.totalBorrow.add(uint(-amount));

            // check if _healthFactorLtv > 1
            checkHealthFactorLtv(_nftID);
            
            transferToUser(token0, payable(_recipient), uint(-amount));

            emit Borrow(token0, _nftID, uint(-amount), _tm0.totalBorrow, _recipient);
        }
        
        if(amount > 0){
            tM storage _tm1 = token1Data;
            
            uint ntokens1 = calculateShare(_tm1.totalBorrowShare, _tm1.totalBorrow, uint(amount));
            if(_tm1.totalBorrowShare == 0){
                _mintBposition(0, 0, 10**3);
            }
            require(ntokens1 > 0, 'Insufficient Borrow1 Liquidity Minted');
            
            _mintBposition(_nftID, 0, ntokens1);
            
            _tm1.totalBorrow = _tm1.totalBorrow.add(uint(amount));

            // check if _healthFactorLtv > 1
            checkHealthFactorLtv(_nftID);
            
            transferToUser(token1, payable(_recipient), uint(amount));

            emit Borrow(token1, _nftID, uint(amount), _tm1.totalBorrow, _recipient);
        }

    }
    
    
    function repay(uint _nftID, int amount, address _payer) external onlyCore returns(int _rAmount) {
        accrueInterest();

        pM storage _positionMt = positionData[_nftID];
        
        if(amount < 0){
            tM storage _tm0 = token0Data;
            
            uint _totalBorrow = _tm0.totalBorrow;
            uint _totalLiability = getShareValue( _totalBorrow, _tm0.totalBorrowShare, _positionMt.token0borrowShare ) ;
            
            if(uint(-amount) > _totalLiability){
                amount = -int(_totalLiability);
                
                _burnBposition(_nftID, _positionMt.token0borrowShare, 0);
                
                _tm0.totalBorrow = _tm0.totalBorrow.sub(_totalLiability);
            } 
            else {
                uint amountToShare = getShareByValue( _totalBorrow, _tm0.totalBorrowShare, uint(-amount) );
                
                _burnBposition(_nftID, amountToShare, 0);
                
                _tm0.totalBorrow = _tm0.totalBorrow.sub(uint(-amount));
            }
            
            _rAmount = amount;

            emit RepayBorrow(token0, _nftID, uint(-amount), _tm0.totalBorrow, _payer);
        }
        
        if(amount > 0){
            tM storage _tm1 = token1Data;
            
            uint _totalBorrow = _tm1.totalBorrow;
            uint _totalLiability = getShareValue( _totalBorrow, _tm1.totalBorrowShare, _positionMt.token1borrowShare) ;
            
            if(uint(amount) > _totalLiability){
                amount = int(_totalLiability);
                
                _burnBposition(_nftID, 0, _positionMt.token1borrowShare);
                
                _tm1.totalBorrow = _tm1.totalBorrow.sub(_totalLiability);
            } 
            else {
                uint amountToShare = getShareByValue( _totalBorrow, _tm1.totalBorrowShare, uint(amount) );
                
                _burnBposition(_nftID, 0, amountToShare);
                
                _tm1.totalBorrow = _tm1.totalBorrow.sub(uint(amount));
            }
            
            _rAmount = amount;

            emit RepayBorrow(token1, _nftID, uint(amount), _tm1.totalBorrow, _payer);
        }

    }



    function liquidateInternal(uint _nftID, int amount, uint _toNftID) internal returns(int liquidatedAmount, int totReceiveAmount)  {
        accrueInterest();

        tM storage _tm0 = token0Data;
        tM storage _tm1 = token1Data;

        if(amount < 0){
            
            (, uint _borrowBalance0) = userBalanceOftoken0(_nftID);
            (uint _lendBalance1, ) = userBalanceOftoken1(_nftID);
            
            uint _healthFactor = type(uint256).max;
            if (_borrowBalance0 > 0){
                uint collateralBalance = IUnilendV2Core(core).getOraclePrice(token1, token0, _lendBalance1);
                _healthFactor = (collateralBalance.mul(uint(100).sub(lb)).mul(1e18).div(100)).div(_borrowBalance0);
            }
            
            if(_healthFactor < HEALTH_FACTOR_LIQUIDATION_THRESHOLD){
                uint procAmountIN;
                uint recAmountIN;
                if(_borrowBalance0 <= uint(-amount)){
                    procAmountIN = _borrowBalance0;
                    recAmountIN = _lendBalance1;
                } 
                else {
                    procAmountIN = uint(-amount);
                    recAmountIN = (_lendBalance1.mul( procAmountIN )).div(_borrowBalance0);
                }


                uint amountToShare0 = getShareByValue( _tm0.totalBorrow, _tm0.totalBorrowShare, procAmountIN );
                _burnBposition(_nftID, amountToShare0, 0);
                _tm0.totalBorrow = _tm0.totalBorrow.sub(procAmountIN); // remove borrow amount

                
                uint _totTokenBalance1 =  IERC20(token1).balanceOf(address(this)).add(_tm1.totalBorrow);
                uint amountToShare1 = getShareByValue( _totTokenBalance1, _tm1.totalLendShare, recAmountIN );
                _burnLPposition(_nftID, 0, amountToShare1);

                if(_toNftID > 0){
                    _mintLPposition(_toNftID, 0, amountToShare1);
                }

                // tot amount to be deposit from liquidator
                liquidatedAmount = -int(procAmountIN);
                totReceiveAmount = int(recAmountIN);


                if(liquidatedAmount < 0){
                    emit LiquidateBorrow(token0, _nftID, _toNftID, uint(-liquidatedAmount), recAmountIN);
                }

            }
        }


        if(amount > 0){

            (uint _lendBalance0, ) = userBalanceOftoken0(_nftID);
            (, uint _borrowBalance1) = userBalanceOftoken1(_nftID);
            
            uint _healthFactor = type(uint256).max;
            if (_borrowBalance1 > 0){
                uint collateralBalance = IUnilendV2Core(core).getOraclePrice(token0, token1, _lendBalance0);
                _healthFactor = (collateralBalance.mul(uint(100).sub(lb)).mul(1e18).div(100)).div(_borrowBalance1);
            }
            
            if(_healthFactor < HEALTH_FACTOR_LIQUIDATION_THRESHOLD){
                uint procAmountIN;
                uint recAmountIN;
                if(_borrowBalance1 <= uint(amount)){
                    procAmountIN = _borrowBalance1;
                    recAmountIN = _lendBalance0;
                } 
                else {
                    procAmountIN = uint(amount);
                    recAmountIN = (_lendBalance0.mul( procAmountIN )).div(_borrowBalance1);
                }


                uint amountToShare1 = getShareByValue( _tm1.totalBorrow, _tm1.totalBorrowShare, procAmountIN );
                _burnBposition(_nftID, 0, amountToShare1);
                _tm1.totalBorrow = _tm1.totalBorrow.sub(procAmountIN); // remove borrow amount

                
                uint _totTokenBalance0 =  IERC20(token0).balanceOf(address(this)).add(_tm0.totalBorrow);
                uint amountToShare0 = getShareByValue( _totTokenBalance0, _tm0.totalLendShare, recAmountIN );
                _burnLPposition(_nftID, amountToShare0, 0);

                if(_toNftID > 0){
                    _mintLPposition(_toNftID, amountToShare0, 0);
                }


                // tot liquidated amount to be deposit from liquidator
                liquidatedAmount = int(procAmountIN);
                totReceiveAmount = -int(recAmountIN);
                

                if(liquidatedAmount > 0){
                    emit LiquidateBorrow(token1, _nftID, _toNftID, uint(liquidatedAmount), recAmountIN);
                }

            }
        }
        
    }


    function liquidate(uint _nftID, int amount, address _receiver, uint _toNftID) external onlyCore returns(int liquidatedAmount)  {
        accrueInterest();
        
        int recAmountIN;
        (liquidatedAmount, recAmountIN) = liquidateInternal(_nftID, amount, _toNftID);

        if(_toNftID == 0){
            if(recAmountIN < 0){
                transferToUser(token0, payable(_receiver), uint(-recAmountIN));
            }

            if(recAmountIN > 0){
                transferToUser(token1, payable(_receiver), uint(recAmountIN));
            }
        }
        
    }


    function liquidateMulti(uint[] calldata _nftIDs, int[] calldata amounts, address _receiver, uint _toNftID) external onlyCore returns(int liquidatedAmountTotal)  {
        accrueInterest();
        
        int liquidatedAmount;
        int recAmountIN;
        int recAmountINtotal;

        for (uint i=0; i<_nftIDs.length; i++) {
        
            (liquidatedAmount, recAmountIN) = liquidateInternal(_nftIDs[i], amounts[i], _toNftID);

            liquidatedAmountTotal = liquidatedAmountTotal + liquidatedAmount;
            recAmountINtotal = recAmountINtotal + recAmountIN;
        }


        if(_toNftID == 0){
            if(recAmountINtotal < 0){
                transferToUser(token0, payable(_receiver), uint(-recAmountINtotal));
            }

            if(recAmountINtotal > 0){
                transferToUser(token1, payable(_receiver), uint(recAmountINtotal));
            }
        }

    }
    
}
