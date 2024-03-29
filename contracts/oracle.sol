pragma solidity 0.8.2;
// SPDX-License-Identifier: MIT

import "./lib/utils/Context.sol";
import "./lib/utils/math/SafeMath.sol";
import "./lib/access/Ownable.sol";
import "./lib/token/ERC20/extensions/IERC20Metadata.sol";



interface AggregatorV3Interface {
  function decimals() external view returns (uint8);

  function description() external view returns (string memory);

  function version() external view returns (uint256);

  function getRoundData(uint80 _roundId)
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );

  function latestRoundData()
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );
}




contract UnilendV2oracle is Ownable {
    using SafeMath for uint256;
    
    address public WETH;
    
    mapping(address => AggregatorV3Interface) private assetsOracles;
    
    event AssetOracleUpdated(address indexed asset, address indexed source);
    
    
    constructor(address weth) {
        require(weth != address(0), "UnilendV2: ZERO ADDRESS");
        WETH = weth;
    }
    
    
    function setAssetOracles(address[] calldata assets, address[] calldata sources) external onlyOwner {
        require(assets.length == sources.length, 'INCONSISTENT_PARAMS_LENGTH');
        
        for (uint256 i = 0; i < assets.length; i++) {
            assetsOracles[assets[i]] = AggregatorV3Interface(sources[i]);
            emit AssetOracleUpdated(assets[i], sources[i]);
        }
    }
    
    function getLatestPrice(AggregatorV3Interface priceFeed) public view returns (int) {
        (
            /*uint80 roundID*/,
            int price,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = priceFeed.latestRoundData();
        return price;
    }
    
    function getChainLinkAssetPrice(address asset) public view returns (int256 price) {
        AggregatorV3Interface source = assetsOracles[asset];
        if(address(source) != address(0)){
            price = getLatestPrice(source);
        }
    }
    
    
    function getAssetPrice(address token1, address token0, uint amount) public view returns (uint256 _price) {
        int256 price0; int256 price1;
        uint8 decimals0; uint8 decimals1;
        
        if(token0 == WETH && token1 != WETH){
            price0 = 1 ether;
            price1 = getChainLinkAssetPrice(token1);

            decimals0 = 18;
            decimals1 = IERC20Metadata(token1).decimals();
        } 
        else if(token0 != WETH && token1 == WETH){
            price0 = getChainLinkAssetPrice(token0);
            price1 = 1 ether;

            decimals0 = IERC20Metadata(token0).decimals();
            decimals1 = 18;
        } 
        else {
            price0 = getChainLinkAssetPrice(token0);
            price1 = getChainLinkAssetPrice(token1);

            decimals0 = IERC20Metadata(token0).decimals();
            decimals1 = IERC20Metadata(token1).decimals();
        }
        

        if(price0 > 0 && price1 > 0){
            _price = ( (amount.mul(10**decimals1).mul(uint256(price0))).div(uint256(price1)) ).div(10**decimals0);
        }
    }
    
}



