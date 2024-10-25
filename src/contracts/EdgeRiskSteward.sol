// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import './RiskSteward.sol';

/**
 * @title EdgeRiskSteward
 * @author BGD labs
 * @notice Contract to manage the interest rates params within configured bound on aave v3 pool.
 *         To be triggered by the Aave Steward Injector Contract in a automated way via the Edge Risk Oracle.
 */
contract EdgeRiskSteward is RiskSteward {
  using Address for address;

  /**
   * @param poolDataProvider The pool data provider of the pool to be controlled by the steward
   * @param engine the config engine to be used by the steward
   * @param riskCouncil the safe address of the council being able to interact with the steward
   * @param riskConfig the risk configuration to setup for each individual risk param
   */
  constructor(
    IPoolDataProvider poolDataProvider,
    IEngine engine,
    address riskCouncil,
    Config memory riskConfig
  ) RiskSteward(poolDataProvider, engine, riskCouncil, riskConfig) {}

  /// @inheritdoc IRiskSteward
  function updateCaps(IEngine.CapsUpdate[] calldata) external virtual override onlyRiskCouncil {
    revert UpdateNotAllowed();
  }

  /// @inheritdoc IRiskSteward
  function updateCollateralSide(
    IEngine.CollateralUpdate[] calldata
  ) external virtual override onlyRiskCouncil {
    revert UpdateNotAllowed();
  }

  /// @inheritdoc IRiskSteward
  function updateLstPriceCaps(
    PriceCapLstUpdate[] calldata
  ) external virtual override onlyRiskCouncil {
    revert UpdateNotAllowed();
  }

  /// @inheritdoc IRiskSteward
  function updateStablePriceCaps(
    PriceCapStableUpdate[] calldata
  ) external virtual override onlyRiskCouncil {
    revert UpdateNotAllowed();
  }

  function _validateRatesUpdate(IEngine.RateStrategyUpdate[] calldata ratesUpdate) internal view override {
    if (ratesUpdate.length == 0) revert NoZeroUpdates();

    for (uint256 i = 0; i < ratesUpdate.length; i++) {
      address asset = ratesUpdate[i].asset;
      if (_restrictedAddresses[asset]) revert AssetIsRestricted();

      (
        uint256 currentOptimalUsageRatio,
        uint256 currentBaseVariableBorrowRate,
        uint256 currentVariableRateSlope1,
        uint256 currentVariableRateSlope2
      ) = _getInterestRatesForAsset(asset);

      if (
        currentOptimalUsageRatio == ratesUpdate[i].params.optimalUsageRatio ||
        currentBaseVariableBorrowRate == ratesUpdate[i].params.baseVariableBorrowRate ||
        currentVariableRateSlope1 == ratesUpdate[i].params.variableRateSlope1 ||
        currentVariableRateSlope2 == ratesUpdate[i].params.variableRateSlope2
      ) revert NoSameUpdates();

      _validateParamUpdate(
        ParamUpdateValidationInput({
          currentValue: currentOptimalUsageRatio,
          newValue: ratesUpdate[i].params.optimalUsageRatio,
          lastUpdated: _timelocks[asset].optimalUsageRatioLastUpdated,
          riskConfig: _riskConfig.optimalUsageRatio,
          isChangeRelative: false
        })
      );
      _validateParamUpdate(
        ParamUpdateValidationInput({
          currentValue: currentBaseVariableBorrowRate,
          newValue: ratesUpdate[i].params.baseVariableBorrowRate,
          lastUpdated: _timelocks[asset].baseVariableRateLastUpdated,
          riskConfig: _riskConfig.baseVariableBorrowRate,
          isChangeRelative: false
        })
      );
      _validateParamUpdate(
        ParamUpdateValidationInput({
          currentValue: currentVariableRateSlope1,
          newValue: ratesUpdate[i].params.variableRateSlope1,
          lastUpdated: _timelocks[asset].variableRateSlope1LastUpdated,
          riskConfig: _riskConfig.variableRateSlope1,
          isChangeRelative: false
        })
      );
      _validateParamUpdate(
        ParamUpdateValidationInput({
          currentValue: currentVariableRateSlope2,
          newValue: ratesUpdate[i].params.variableRateSlope2,
          lastUpdated: _timelocks[asset].variableRateSlope2LastUpdated,
          riskConfig: _riskConfig.variableRateSlope2,
          isChangeRelative: false
        })
      );
    }
  }

  function _validateParamUpdate(ParamUpdateValidationInput memory validationParam) internal view override {
    if (block.timestamp - validationParam.lastUpdated < validationParam.riskConfig.minDelay)
      revert DebounceNotRespected();
    if (
      !_updateWithinAllowedRange(
        validationParam.currentValue,
        validationParam.newValue,
        validationParam.riskConfig.maxPercentChange,
        validationParam.isChangeRelative
      )
    ) revert UpdateNotInRange();
  }

  function _updateRates(IEngine.RateStrategyUpdate[] calldata ratesUpdate) internal override {
    for (uint256 i = 0; i < ratesUpdate.length; i++) {
      address asset = ratesUpdate[i].asset;
      _timelocks[asset].optimalUsageRatioLastUpdated = uint40(block.timestamp);
      _timelocks[asset].baseVariableRateLastUpdated = uint40(block.timestamp);
      _timelocks[asset].variableRateSlope1LastUpdated = uint40(block.timestamp);
      _timelocks[asset].variableRateSlope2LastUpdated = uint40(block.timestamp);
    }

    address(CONFIG_ENGINE).functionDelegateCall(
      abi.encodeWithSelector(CONFIG_ENGINE.updateRateStrategies.selector, ratesUpdate)
    );
  }
}
