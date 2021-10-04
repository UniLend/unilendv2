const V2Pool = artifacts.require("UnilendV2Pool")
const V2Core = artifacts.require("UnilendV2Core")
const V2Position = artifacts.require("UnilendV2Position")
const UnilendInterestRateModel = artifacts.require("UnilendV2InterestRateModel")
const UnilendV2oracle = artifacts.require("UnilendV2oracle")


module.exports = async function(deployer) {
  deployer
  .then(async () => {
    
    // Deploy pool contract
    await deployer.deploy(V2Pool)
    const V2PoolContract = await V2Pool.deployed()
    console.log("UnilendV2 Pool contract deployement done:", V2PoolContract.address)

    // Deploy core contract
    await deployer.deploy(V2Core, V2PoolContract.address)
    const V2CoreContract = await V2Core.deployed()
    console.log("UnilendV2 Core contract deployement done:", V2CoreContract.address)

    // Deploy interestRate contract
    await deployer.deploy(UnilendInterestRateModel)
    const IUnilendInterestRateModelContract = await UnilendInterestRateModel.deployed()
    console.log("UnilendV2 InterestRateModel contract deployement done:", IUnilendInterestRateModelContract.address)


    // Deploy position contract
    let weth = V2PoolContract.address
    await deployer.deploy(UnilendV2oracle, weth)
    const v2oracleContract = await UnilendV2oracle.deployed()
    console.log("UnilendV2 oracle contract deployement done:", v2oracleContract.address)


    // Deploy oracle contract
    await deployer.deploy(V2Position, V2CoreContract.address)
    const v2PositionContract = await V2Position.deployed()
    console.log("UnilendV2 position contract deployement done:", v2PositionContract.address)


    // set position address
    await V2CoreContract.setPositionAddress(v2PositionContract.address)
    console.log("Position Address Set...");

    // set oracle address
    await V2CoreContract.setOracleAddress(v2oracleContract.address)
    console.log("Oracle Address Set...");

  })
}
