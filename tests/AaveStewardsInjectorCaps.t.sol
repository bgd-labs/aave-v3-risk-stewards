// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {AaveStewardInjectorCaps, IAaveStewardInjectorCaps} from '../src/contracts/AaveStewardInjectorCaps.sol';
import {AaveV3Arbitrum} from 'aave-address-book/AaveV3Arbitrum.sol';
import './AaveStewardsInjectorBase.t.sol';
import 'forge-std/Test.sol';

contract AaveStewardsInjectorCapsFork_Test is Test {
  RiskOracle _riskOracle = RiskOracle(0x861eeAdB55E41f161F31Acb1BFD4c70E3a964Aed);
  RiskSteward _riskSteward;
  AaveStewardInjectorBase _stewardInjector;

  address _riskOracleOwner = address(20);
  address _stewardsInjectorOwner = address(25);
  address _stewardsInjectorGuardian = address(30);

  function setUp() public {
    vm.createSelectFork(vm.rpcUrl('arbitrum'), 303789699);

    IRiskSteward.RiskParamConfig memory defaultRiskParamConfig = IRiskSteward.RiskParamConfig({
      minDelay: 3 days,
      maxPercentChange: 100_00
    });
    IRiskSteward.Config memory riskConfig = IRiskSteward.Config({
      ltv: defaultRiskParamConfig,
      liquidationThreshold: defaultRiskParamConfig,
      liquidationBonus: defaultRiskParamConfig,
      supplyCap: defaultRiskParamConfig,
      borrowCap: defaultRiskParamConfig,
      debtCeiling: defaultRiskParamConfig,
      baseVariableBorrowRate: defaultRiskParamConfig,
      variableRateSlope1: defaultRiskParamConfig,
      variableRateSlope2: defaultRiskParamConfig,
      optimalUsageRatio: defaultRiskParamConfig,
      priceCapLst: defaultRiskParamConfig,
      priceCapStable: defaultRiskParamConfig
    });

    // setup steward injector
    vm.startPrank(_stewardsInjectorOwner);

    address computedRiskStewardAddress = vm.computeCreateAddress(
      _stewardsInjectorOwner,
      vm.getNonce(_stewardsInjectorOwner) + 1
    );
    _stewardInjector = new AaveStewardInjectorCaps(
      address(_riskOracle),
      address(computedRiskStewardAddress),
      _stewardsInjectorOwner,
      _stewardsInjectorGuardian
    );

    // setup risk steward
    _riskSteward = new RiskSteward(
      (AaveV3Arbitrum.AAVE_PROTOCOL_DATA_PROVIDER),
      IEngine(AaveV3Arbitrum.CONFIG_ENGINE),
      address(_stewardInjector),
      riskConfig
    );
    vm.assertEq(computedRiskStewardAddress, address(_riskSteward));
    vm.stopPrank();

    _addMarket(0xf329e36C7bF6E5E86ce2150875a84Ce77f477375); // aAAVE

    vm.startPrank(AaveV3Arbitrum.ACL_ADMIN);
    AaveV3Arbitrum.ACL_MANAGER.addRiskAdmin(address(_riskSteward));
    vm.stopPrank();
  }

  function test_injection() public {
    assertTrue(_checkAndPerformAutomation());
  }

  function _addMarket(address market) internal {
    address[] memory markets = new address[](1);
    markets[0] = market;

    vm.prank(_stewardsInjectorOwner);
    AaveStewardInjectorCaps(address(_stewardInjector)).addMarkets(markets);
  }

  function _checkAndPerformAutomation() internal virtual returns (bool) {
    (bool shouldRunKeeper, bytes memory performData) = _stewardInjector.checkUpkeep('');
    if (shouldRunKeeper) {
      _stewardInjector.performUpkeep(performData);
    }
    return shouldRunKeeper;
  }
}
