pragma solidity 0.8.2;
// SPDX-License-Identifier: MIT


import "./lib/utils/math/SafeMath.sol";

contract UnilendV2InterestRateModel {
    using SafeMath for uint256;

    constructor() {

    }

    function getCurrentInterestRate(uint totalBorrow, uint availableBorrow) external pure returns (uint){
        uint uRate;
        if(totalBorrow > 0){
            uRate = (totalBorrow.mul(10**18)).div(availableBorrow.add(totalBorrow));
        }
        uint apy = uint(10).add( uRate.mul(30) );
        return apy.div(2102400); // per block interest
    }

}
