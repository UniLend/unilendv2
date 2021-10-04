pragma solidity 0.8.2;
// SPDX-License-Identifier: MIT

import "./lib/utils/Context.sol";
import "./lib/utils/math/SafeMath.sol";
import "./lib/access/Ownable.sol";




interface IChainlinkAggregator {
  function latestAnswer() external view returns (int256);
}




contract UnilendV2oracle is Ownable {
    using SafeMath for uint256;
    
    address public WETH;
    
    mapping(address => IChainlinkAggregator) private assetsOracles;
    
    event AssetOracleUpdated(address indexed asset, address indexed source);
    
    
    constructor(address weth) {
        WETH = weth;
    }
    
    
    function setAssetOracles(address[] calldata assets, address[] calldata sources) external onlyOwner {
        require(assets.length == sources.length, 'INCONSISTENT_PARAMS_LENGTH');
        
        for (uint256 i = 0; i < assets.length; i++) {
            assetsOracles[assets[i]] = IChainlinkAggregator(sources[i]);
            emit AssetOracleUpdated(assets[i], sources[i]);
        }
    }
    
    function getChainLinkAssetPrice(address asset) public view returns (int256 price) {
        IChainlinkAggregator source = assetsOracles[asset];
        if(address(source) != address(0)){
            price = IChainlinkAggregator(asset).latestAnswer();
        }
    }
    
    
    function getAssetPrice(address token0, address token1, uint amount) public view returns (uint256) {
        int256 price0; int256 price1;
        
        if(token0 == WETH && token1 != WETH){
            price0 = 1 ether;
            price1 = getChainLinkAssetPrice(token1);
            
            if (price1 <= 0) {
                price1 = getUniswapV3Price(token0, token1);
            }
        } 
        else if(token0 != WETH && token1 == WETH){
            price0 = getChainLinkAssetPrice(token0);
            price1 = 1 ether;
            
            if (price0 <= 0) {
                price0 = getUniswapV3Price(token1, token0);
            }
        } 
        else {
            price0 = getChainLinkAssetPrice(token0);
            price1 = getChainLinkAssetPrice(token1);
            
            if (price0 <= 0) {
                price0 = getUniswapV3Price(token1, token0);
            }

            if (price1 <= 0) {
                price1 = getUniswapV3Price(token0, token1);
            }
        }
        
        return (amount.mul(uint256(price1))).div(uint256(price0));
    }
    





    // tmp xxxxxx 
    function getUniswapV3Price(address token0, address token1) public view returns (int256) {
        if(aPrice[token0][token1] > 0){
            return int(aPrice[token0][token1]);
        } else {
            return 1 ether;
        }
    }
    
    mapping(address => mapping(address => uint)) public aPrice;
    function setTokenPrice(address token0, address token1, uint price) public {
        aPrice[token0][token1] = price;
    }
    
}



