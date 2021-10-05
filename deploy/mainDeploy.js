const { namedAccounts } = require('../hardhat.config');

const getChainId = (chainName) => {
  switch (chainName) {
    case 'rskmainnet':
      return 30;
    case 'rsktestnet':
      return 31;
    case 'rskregtest':
      return 33;
    case 'ganache':
      return 1337;
    case 'hardhat':
      return 1337;
    default:
      return 'Unknown';
  }
};

async function main() {
  const [deployer] = await ethers.getSigners();
  const parseEther = ethers.utils.parseEther;
  const config = {
    initialExchangeRateMantissa: parseEther('0.02'),
    liquidationIncentiveMantissa: parseEther('0.07'),
    closeFactorMantissa: parseEther('0.5'),
    compSpeed: 0,
    markets: {
      rif: {
        reserveFactor: parseEther('0.25'),
        collateralFactor: parseEther('0.65'),
        baseBorrowRate: parseEther('0.08'),
        multiplier: parseEther('0.03'),
      },
      doc: {
        reserveFactor: parseEther('0.50'),
        collateralFactor: parseEther('0.70'),
        baseBorrowRate: parseEther('0.08'),
        multiplier: parseEther('0.02'),
        jumpMultiplier: parseEther('0.55'),
        kink: parseEther('0.90'),
      },
      rdoc: {
        reserveFactor: parseEther('0.50'),
        collateralFactor: parseEther('0.75'),
        baseBorrowRate: parseEther('0.001'),
        multiplier: parseEther('0.00470588235'),
        jumpMultiplier: parseEther('0.00588'),
        kink: parseEther('0.85'),
      },
      usdt: {
        reserveFactor: parseEther('0.55'),
        collateralFactor: parseEther('0.75'),
        baseBorrowRate: parseEther('0.08'),
        multiplier: parseEther('0.01'),
        jumpMultiplier: parseEther('0.35'),
        kink: parseEther('0.80'),
      },
      rbtc: {
        reserveFactor: parseEther('0.20'),
        collateralFactor: parseEther('0.75'),
        baseBorrowRate: parseEther('0.02'),
        multiplier: parseEther('0.1'),
      },
      sat: {
        reserveFactor: parseEther('0.30'),
        collateralFactor: parseEther('0.50'),
        baseBorrowRate: parseEther('0.08'),
        promisedBaseReturnRate: parseEther('0.04'),
        optimal: parseEther('0.5'),
        borrowRateSlope: parseEther('0.04'),
        supplyRateSlope: parseEther('0.02'),
      },
    },
  };
  // console.log('\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~');
  // console.log('Tropykus Contracts - Deploy Script');
  // console.log('~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n');

  const chainId = await getChainId(process.env.HARDHAT_NETWORK);
  // console.log(`Network = ${chainId}`);
  // console.log(`Deployer = ${deployer.address}`);
  const multiSigWalletContract = await ethers.getContractFactory('MultiSigWallet');
  const multiSig = await multiSigWalletContract.deploy([deployer.address], 1);
  await multiSig.deployTransaction.wait();
  console.log(`MultiSig = '${multiSig.address}'`);
  const priceOracleProxyContract = await ethers.getContractFactory('PriceOracleProxy');
  const priceOracleProxyDeploy = await priceOracleProxyContract.deploy(deployer.address);
  await priceOracleProxyDeploy.deployTransaction.wait();
  console.log(`PriceOracleProxy = '${priceOracleProxyDeploy.address}';`);
  const unitrollerContract = await ethers.getContractFactory('Unitroller');
  const unitrollerDeployed = await unitrollerContract.deploy();
  await unitrollerDeployed.deployTransaction.wait();
  const comptrollerContract = await ethers.getContractFactory('ComptrollerG6');
  const comptrollerDeployed = await comptrollerContract.deploy();
  await comptrollerDeployed.deployTransaction.wait();

  // console.log('\n~~~~~~~~~~~~~~~~~~~~~~~~ TOKENS ~~~~~~~~~~~~~~~~~~~~~~~~');
  const standardTokenContract = await ethers.getContractFactory('StandardToken');
  let rifToken = {
    address: namedAccounts.rif[chainId],
  };
  let docToken = {
    address: namedAccounts.doc[chainId],
  };
  let usdtToken = {
    address: namedAccounts.usdt[chainId],
  };
  if (chainId !== 31 && chainId !== 30) {
    rifToken = await standardTokenContract.deploy(parseEther('2000000'), 'Test RIF Tropykus', 18, 'tRIF');
    await rifToken.deployTransaction.wait();
  }
  docToken = await standardTokenContract.deploy(parseEther('2000000'), 'Test DOC Tropykus', 18, 'tDOC');
  await docToken.deployTransaction.wait();
  const rdocToken = await standardTokenContract.deploy(parseEther('2000000'), 'Test RDOC Tropykus', 18, 'tRDOC');
  await rdocToken.deployTransaction.wait();
  usdtToken = await standardTokenContract.deploy(parseEther('2000000'), 'Test rUSDT Tropykus', 18, 'trUSDT');
  await usdtToken.deployTransaction.wait();
  console.log(`RIF = '${rifToken.address}';`);
  console.log(`DOC = '${docToken.address}';`);
  console.log(`RDOC = '${rdocToken.address}';`);
  console.log(`USDT = '${usdtToken.address}';`);
  // console.log('~~~~~~~~~~~~~~~~~~~~~~~~ /TOKENS ~~~~~~~~~~~~~~~~~~~~~~~~\n');

  // console.log('\n~~~~~~~~~~~~~~~~~~~~~~~~ ORACLES ~~~~~~~~~~~~~~~~~~~~~~~~');
  const mockPriceProviderMoC = await ethers.getContractFactory('MockPriceProviderMoC');
  let rifOracle = {
    address: namedAccounts.rifOracle[chainId],
  };
  let rbtcOracle = {
    address: namedAccounts.rbtcOracle[chainId],
  };
  if (chainId !== 31 && chainId !== 30) {
    rifOracle = await mockPriceProviderMoC.deploy(deployer.address, parseEther('0.33'));
    await rifOracle.deployTransaction.wait();
    rbtcOracle = await mockPriceProviderMoC.deploy(deployer.address, parseEther('34000'));
    await rbtcOracle.deployTransaction.wait();
  }
  const docOracle = await mockPriceProviderMoC.deploy(deployer.address, parseEther('1.1'));
  await docOracle.deployTransaction.wait();
  const rdocOracle = await mockPriceProviderMoC.deploy(deployer.address, parseEther('9.9998'));
  await rdocOracle.deployTransaction.wait();
  const usdtOracle = await mockPriceProviderMoC.deploy(deployer.address, parseEther('1.05'));
  await usdtOracle.deployTransaction.wait();
  console.log(`RIFOracle = '${rifOracle.address}';`);
  console.log(`RBTCOracle = '${rbtcOracle.address}';`);
  console.log(`DOCOracle = '${docOracle.address}';`);
  console.log(`RDOCOracle = '${rdocOracle.address}';`);
  console.log(`USDTOracle = '${usdtOracle.address}';`);
  // console.log('~~~~~~~~~~~~~~~~~~~~~~~~ /ORACLES ~~~~~~~~~~~~~~~~~~~~~~~~\n');

  //console.log('\n~~~~~~~~~~~~~~~~~~~~~~~~ ADAPTERS ~~~~~~~~~~~~~~~~~~~~~~~~');
  const priceOracleAdapterMoc = await ethers.getContractFactory('PriceOracleAdapterMoc');
  const rbtcPriceOracleAdapterMoC = await priceOracleAdapterMoc.deploy(deployer.address, rbtcOracle.address);
  await rbtcPriceOracleAdapterMoC.deployTransaction.wait();
  const satPriceOracleAdapterMoC = await priceOracleAdapterMoc.deploy(deployer.address, rbtcOracle.address);
  await satPriceOracleAdapterMoC.deployTransaction.wait();
  const rifPriceOracleAdapterMoC = await priceOracleAdapterMoc.deploy(deployer.address, rifOracle.address);
  await rifPriceOracleAdapterMoC.deployTransaction.wait();
  const docPriceOracleAdapterMoC = await priceOracleAdapterMoc.deploy(deployer.address, docOracle.address);
  await docPriceOracleAdapterMoC.deployTransaction.wait();
  const rdocPriceOracleAdapterMoC = await priceOracleAdapterMoc.deploy(deployer.address, rdocOracle.address);
  await rdocPriceOracleAdapterMoC.deployTransaction.wait();
  const usdtPriceOracleAdapterMoC = await priceOracleAdapterMoc.deploy(deployer.address, usdtOracle.address);
  await usdtPriceOracleAdapterMoC.deployTransaction.wait();
  console.log(`RBTCAdapter = '${rbtcPriceOracleAdapterMoC.address}';`);
  console.log(`SATAdapter = '${satPriceOracleAdapterMoC.address}';`);
  console.log(`RIFAdapter = '${rifPriceOracleAdapterMoC.address}';`);
  console.log(`DOCAdapter = '${docPriceOracleAdapterMoC.address}';`);
  console.log(`RDOCAdapter = '${rdocPriceOracleAdapterMoC.address}';`);
  console.log(`USDTAdapter = '${usdtPriceOracleAdapterMoC.address}';`);
  // console.log('~~~~~~~~~~~~~~~~~~~~~~~~ /ADAPTERS ~~~~~~~~~~~~~~~~~~~~~~~~\n');

  // console.log('\n~~~~~~~~~~~~~~~~~~ INTEREST RATE MODELS ~~~~~~~~~~~~~~~~~~');
  const whitePaperInterestRateModel = await ethers.getContractFactory('WhitePaperInterestRateModel');
  const jumpInterestRateModelV2 = await ethers.getContractFactory('JumpRateModelV2');
  const hurricaneInterestRateModel = await ethers.getContractFactory('HurricaneInterestRateModel');
  const { rif, doc, rdoc, usdt, rbtc, sat } = config.markets;
  const rifInterestRateModel = await whitePaperInterestRateModel.deploy(rif.baseBorrowRate, rif.multiplier);
  await rifInterestRateModel.deployTransaction.wait();
  const docInterestRateModel = await jumpInterestRateModelV2.deploy(doc.baseBorrowRate, doc.multiplier, doc.jumpMultiplier, doc.kink, deployer.address);
  await docInterestRateModel.deployTransaction.wait();
  const rdocInterestRateModel = await jumpInterestRateModelV2.deploy(rdoc.baseBorrowRate, rdoc.multiplier, rdoc.jumpMultiplier, rdoc.kink, deployer.address);
  await rdocInterestRateModel.deployTransaction.wait();
  const usdtInterestRateModel = await jumpInterestRateModelV2.deploy(usdt.baseBorrowRate, usdt.multiplier, usdt.jumpMultiplier, usdt.kink, deployer.address);
  await usdtInterestRateModel.deployTransaction.wait();
  const rbtcInterestRateModel = await whitePaperInterestRateModel.deploy(rbtc.baseBorrowRate, rbtc.multiplier);
  await rbtcInterestRateModel.deployTransaction.wait();
  const satInterestRateModel = await hurricaneInterestRateModel.deploy(sat.baseBorrowRate, sat.promisedBaseReturnRate, sat.optimal, sat.borrowRateSlope, sat.supplyRateSlope);
  await satInterestRateModel.deployTransaction.wait();
  console.log(`RIFInterestRateModel = '${rifInterestRateModel.address}';`);
  console.log(`DOCInterestRateModel = '${docInterestRateModel.address}';`);
  console.log(`RDOCInterestRateModel = '${rdocInterestRateModel.address}';`);
  console.log(`USDTInterestRateModel = '${usdtInterestRateModel.address}';`);
  console.log(`RBTCInterestRateModel = '${rbtcInterestRateModel.address}';`);
  console.log(`SATInterestRateModel = '${satInterestRateModel.address}';`);
  // console.log('~~~~~~~~~~~~~~~~~~ /INTEREST RATE MODELS ~~~~~~~~~~~~~~~~~\n');

  // console.log('\n~~~~~~~~~~~~~~~~~~~~ MARKETS cTOKENS ~~~~~~~~~~~~~~~~~~~');
  const cErc20Immutable = await ethers.getContractFactory('CErc20Immutable');
  const cRBTCContract = await ethers.getContractFactory('CRBTC');
  const cRDOCContract = await ethers.getContractFactory('CRDOC');
  const cRIFdeployed = await cErc20Immutable.deploy(rifToken.address, comptrollerDeployed.address, rifInterestRateModel.address, config.initialExchangeRateMantissa, 'Tropykus kRIF', 'kRIF', 18, deployer.address);
  await cRIFdeployed.deployTransaction.wait();
  const cDOCdeployed = await cErc20Immutable.deploy(docToken.address, comptrollerDeployed.address, docInterestRateModel.address, config.initialExchangeRateMantissa, 'Tropykus kDOC', 'kDOC', 18, deployer.address);
  await cDOCdeployed.deployTransaction.wait();
  const cRDOCdeployed = await cRDOCContract.deploy(rdocToken.address, comptrollerDeployed.address, rdocInterestRateModel.address, config.initialExchangeRateMantissa, 'Tropykus kRDOC', 'kRDOC', 18, deployer.address);
  await cRDOCdeployed.deployTransaction.wait();
  const cUSDTdeployed = await cErc20Immutable.deploy(usdtToken.address, comptrollerDeployed.address, usdtInterestRateModel.address, config.initialExchangeRateMantissa, 'Tropykus kUSDT', 'kUSDT', 18, deployer.address);
  await cUSDTdeployed.deployTransaction.wait();
  const cRBTCdeployed = await cRBTCContract.deploy(comptrollerDeployed.address, rbtcInterestRateModel.address, config.initialExchangeRateMantissa, 'Tropykus kRBTC', 'kRBTC', 18, deployer.address);
  await cRBTCdeployed.deployTransaction.wait();
  const cSATdeployed = await cRBTCContract.deploy(comptrollerDeployed.address, satInterestRateModel.address, config.initialExchangeRateMantissa, 'Tropykus kSAT', 'kSAT', 18, deployer.address);
  await cSATdeployed.deployTransaction.wait();

  console.log(`cRIF = '${cRIFdeployed.address}';`);
  console.log(`cDOC = '${cDOCdeployed.address}';`);
  console.log(`cRDOC = '${cRDOCdeployed.address}';`);
  console.log(`cUSDT = '${cUSDTdeployed.address}';`);
  console.log(`cRBTC = '${cRBTCdeployed.address}';`);
  console.log(`cSAT = '${cSATdeployed.address}';`);

  // console.log('~~~~~~~~~~~~~~~~~~~~ /MARKETS cTOKENS ~~~~~~~~~~~~~~~~~~~~\n');

  const tropykusLensContract = await ethers.getContractFactory('TropykusLens');
  const tropykusLens = await tropykusLensContract.deploy();
  await tropykusLens.deployTransaction.wait();
  console.log(`TropykusLens = '${tropykusLens.address}';`);

  // console.log('\n~~~~~~~~~~~~~~~~~ UNITROLLER & COMPTROLLER ~~~~~~~~~~~~~~~~');
  const unitroller = await ethers.getContractAt('Unitroller', unitrollerDeployed.address, deployer);
  console.log(`Unitroller = '${unitroller.address}';`);
  const comptroller = await ethers.getContractAt('ComptrollerG6', comptrollerDeployed.address, deployer);
  console.log(`Comptroller = '${comptroller.address}';`);
  await unitroller._setPendingImplementation(comptroller.address).then((tx) => tx.wait());
  await comptroller._become(unitroller.address).then((tx) => tx.wait());
  await comptroller._setPriceOracle(priceOracleProxyDeploy.address).then((tx) => tx.wait());
  await comptroller._setCloseFactor(config.closeFactorMantissa).then((tx) => tx.wait());
  await comptroller._setLiquidationIncentive(config.liquidationIncentiveMantissa).then((tx) => tx.wait());
  // console.log('~~~~~~~~~~~~~~~~~ /UNITROLLER & COMPTROLLER ~~~~~~~~~~~~~~~~\n');

  const priceOracleProxy = await ethers.getContractAt('PriceOracleProxy', priceOracleProxyDeploy.address, deployer);
  await priceOracleProxy.setAdapterToToken(cRIFdeployed.address, rifPriceOracleAdapterMoC.address).then((tx) => tx.wait());
  await priceOracleProxy.setAdapterToToken(cDOCdeployed.address, docPriceOracleAdapterMoC.address).then((tx) => tx.wait());
  await priceOracleProxy.setAdapterToToken(cRDOCdeployed.address, rdocPriceOracleAdapterMoC.address).then((tx) => tx.wait());
  await priceOracleProxy.setAdapterToToken(cUSDTdeployed.address, usdtPriceOracleAdapterMoC.address).then((tx) => tx.wait());
  await priceOracleProxy.setAdapterToToken(cRBTCdeployed.address, rbtcPriceOracleAdapterMoC.address).then((tx) => tx.wait());
  await priceOracleProxy.setAdapterToToken(cSATdeployed.address, satPriceOracleAdapterMoC.address).then((tx) => tx.wait());

  await comptroller._supportMarket(cRIFdeployed.address).then((tx) => tx.wait());
  await comptroller._supportMarket(cDOCdeployed.address).then((tx) => tx.wait());
  await comptroller._supportMarket(cRDOCdeployed.address).then((tx) => tx.wait());
  await comptroller._supportMarket(cUSDTdeployed.address).then((tx) => tx.wait());
  await comptroller._supportMarket(cRBTCdeployed.address).then((tx) => tx.wait());
  await comptroller._supportMarket(cSATdeployed.address).then((tx) => tx.wait());

  await comptroller._setCollateralFactor(cRIFdeployed.address, rif.collateralFactor).then((tx) => tx.wait());
  await comptroller._setCollateralFactor(cDOCdeployed.address, doc.collateralFactor).then((tx) => tx.wait());
  await comptroller._setCollateralFactor(cRDOCdeployed.address, rdoc.collateralFactor).then((tx) => tx.wait());
  await comptroller._setCollateralFactor(cUSDTdeployed.address, usdt.collateralFactor).then((tx) => tx.wait());
  await comptroller._setCollateralFactor(cRBTCdeployed.address, rbtc.collateralFactor).then((tx) => tx.wait());
  await comptroller._setCollateralFactor(cSATdeployed.address, sat.collateralFactor).then((tx) => tx.wait());

  await comptroller._setCompRate(config.compSpeed);

  const cRIF = await ethers.getContractAt('CErc20Immutable', cRIFdeployed.address, deployer);
  const cDOC = await ethers.getContractAt('CErc20Immutable', cDOCdeployed.address, deployer);
  const cRDOC = await ethers.getContractAt('CRDOC', cRDOCdeployed.address, deployer);
  const cUSDT = await ethers.getContractAt('CErc20Immutable', cUSDTdeployed.address, deployer);
  const cRBTC = await ethers.getContractAt('CRBTC', cRBTCdeployed.address, deployer);
  const cSAT = await ethers.getContractAt('CRBTC', cSATdeployed.address, deployer);
  await cRIF._setReserveFactor(rif.reserveFactor).then((tx) => tx.wait());
  await cDOC._setReserveFactor(doc.reserveFactor).then((tx) => tx.wait());
  await cRDOC._setReserveFactor(rdoc.reserveFactor).then((tx) => tx.wait());
  await cUSDT._setReserveFactor(usdt.reserveFactor).then((tx) => tx.wait());
  await cRBTC._setReserveFactor(rbtc.reserveFactor).then((tx) => tx.wait());
  await cSAT._setReserveFactor(sat.reserveFactor).then((tx) => tx.wait());

  await comptroller.setMarketCapThreshold(parseEther('0.8')).then((tx) => tx.wait());
  console.log('// Finished')
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
