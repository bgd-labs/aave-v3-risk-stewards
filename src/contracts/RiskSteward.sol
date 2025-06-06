// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ReserveConfiguration, DataTypes} from 'aave-v3-origin/src/contracts/protocol/libraries/configuration/ReserveConfiguration.sol';
import {IPool} from 'aave-address-book/AaveV3.sol';
import {Address} from 'openzeppelin-contracts/contracts/utils/Address.sol';
import {SafeCast} from 'openzeppelin-contracts/contracts/utils/math/SafeCast.sol';
import {EngineFlags} from 'aave-v3-origin/src/contracts/extensions/v3-config-engine/EngineFlags.sol';
import {Ownable} from 'openzeppelin-contracts/contracts/access/Ownable.sol';
import {Strings} from 'openzeppelin-contracts/contracts/utils/Strings.sol';
import {IAaveV3ConfigEngine as IEngine} from 'aave-v3-origin/src/contracts/extensions/v3-config-engine/IAaveV3ConfigEngine.sol';
import {IRiskSteward} from '../interfaces/IRiskSteward.sol';
import {IDefaultInterestRateStrategyV2} from 'aave-v3-origin/src/contracts/interfaces/IDefaultInterestRateStrategyV2.sol';
import {IPriceCapAdapter} from 'aave-capo/interfaces/IPriceCapAdapter.sol';
import {IPriceCapAdapterStable} from 'aave-capo/interfaces/IPriceCapAdapterStable.sol';
import {IPendlePriceCapAdapter} from 'aave-capo/interfaces/IPendlePriceCapAdapter.sol';

/**
 * @title RiskSteward
 * @author BGD labs
 * @notice Contract to manage the risk params within configured bound on aave v3 pool:
 *         This contract can update the following risk params: caps, ltv, liqThreshold, liqBonus, debtCeiling, interest rates params.
 */
contract RiskSteward is Ownable, IRiskSteward {
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
  using Strings for string;
  using Address for address;
  using SafeCast for uint256;
  using SafeCast for int256;

  /// @inheritdoc IRiskSteward
  IEngine public immutable CONFIG_ENGINE;

  /// @inheritdoc IRiskSteward
  IPool public immutable POOL;

  /// @inheritdoc IRiskSteward
  address public immutable RISK_COUNCIL;

  uint256 internal constant BPS_MAX = 100_00;

  Config internal _riskConfig;

  mapping(address => Debounce) internal _timelocks;

  mapping(uint8 => EModeDebounce) internal _eModeTimelocks;

  mapping(address => bool) internal _restrictedAddresses;

  mapping(uint8 => bool) internal _restrictedEModes;

  /**
   * @dev Modifier preventing anyone, but the council to update risk params.
   */
  modifier onlyRiskCouncil() {
    if (RISK_COUNCIL != msg.sender) revert InvalidCaller();
    _;
  }

  /**
   * @param pool The aave pool to be controlled by the steward
   * @param engine the config engine to be used by the steward
   * @param riskCouncil the safe address of the council being able to interact with the steward
   * @param owner the owner of the risk steward being able to set configs and mark items as restricted
   * @param riskConfig the risk configuration to setup for each individual risk param
   */
  constructor(
    address pool,
    address engine,
    address riskCouncil,
    address owner,
    Config memory riskConfig
  ) Ownable(owner) {
    POOL = IPool(pool);
    CONFIG_ENGINE = IEngine(engine);
    RISK_COUNCIL = riskCouncil;
    _riskConfig = riskConfig;
  }

  /// @inheritdoc IRiskSteward
  function updateCaps(IEngine.CapsUpdate[] calldata capsUpdate) external virtual onlyRiskCouncil {
    _validateCapsUpdate(capsUpdate);
    _updateCaps(capsUpdate);
  }

  /// @inheritdoc IRiskSteward
  function updateRates(
    IEngine.RateStrategyUpdate[] calldata ratesUpdate
  ) external virtual onlyRiskCouncil {
    _validateRatesUpdate(ratesUpdate);
    _updateRates(ratesUpdate);
  }

  /// @inheritdoc IRiskSteward
  function updateCollateralSide(
    IEngine.CollateralUpdate[] calldata collateralUpdates
  ) external virtual onlyRiskCouncil {
    _validateCollateralsUpdate(collateralUpdates);
    _updateCollateralSide(collateralUpdates);
  }

  /// @inheritdoc IRiskSteward
  function updateEModeCategories(
    IEngine.EModeCategoryUpdate[] calldata eModeCategoryUpdates
  ) external virtual onlyRiskCouncil {
    _validateEModeCategoryUpdate(eModeCategoryUpdates);
    _updateEModeCategories(eModeCategoryUpdates);
  }

  /// @inheritdoc IRiskSteward
  function updateLstPriceCaps(
    PriceCapLstUpdate[] calldata priceCapUpdates
  ) external virtual onlyRiskCouncil {
    _validatePriceCapUpdate(priceCapUpdates);
    _updateLstPriceCaps(priceCapUpdates);
  }

  /// @inheritdoc IRiskSteward
  function updateStablePriceCaps(
    PriceCapStableUpdate[] calldata priceCapUpdates
  ) external virtual onlyRiskCouncil {
    _validatePriceCapStableUpdate(priceCapUpdates);
    _updateStablePriceCaps(priceCapUpdates);
  }

  /// @inheritdoc IRiskSteward
  function updatePendleDiscountRates(
    DiscountRatePendleUpdate[] calldata discountRateUpdates
  ) external virtual onlyRiskCouncil {
    _validatePendleDiscountRateUpdate(discountRateUpdates);
    _updatePendleDiscountRates(discountRateUpdates);
  }

  /// @inheritdoc IRiskSteward
  function getTimelock(address asset) external view returns (Debounce memory) {
    return _timelocks[asset];
  }

  /// @inheritdoc IRiskSteward
  function getEModeTimelock(uint8 eModeCategoryId) external view returns (EModeDebounce memory) {
    return _eModeTimelocks[eModeCategoryId];
  }

  /// @inheritdoc IRiskSteward
  function setRiskConfig(Config calldata riskConfig) external onlyOwner {
    _riskConfig = riskConfig;
    emit RiskConfigSet(riskConfig);
  }

  /// @inheritdoc IRiskSteward
  function getRiskConfig() external view returns (Config memory) {
    return _riskConfig;
  }

  /// @inheritdoc IRiskSteward
  function isAddressRestricted(address contractAddress) external view returns (bool) {
    return _restrictedAddresses[contractAddress];
  }

  /// @inheritdoc IRiskSteward
  function setAddressRestricted(address contractAddress, bool isRestricted) external onlyOwner {
    _restrictedAddresses[contractAddress] = isRestricted;
    emit AddressRestricted(contractAddress, isRestricted);
  }

  /// @inheritdoc IRiskSteward
  function isEModeCategoryRestricted(uint8 eModeCategoryId) external view returns (bool) {
    return _restrictedEModes[eModeCategoryId];
  }

  /// @inheritdoc IRiskSteward
  function setEModeCategoryRestricted(uint8 eModeCategoryId, bool isRestricted) external onlyOwner {
    _restrictedEModes[eModeCategoryId] = isRestricted;
    emit EModeRestricted(eModeCategoryId, isRestricted);
  }

  /**
   * @notice method to validate the caps update
   * @param capsUpdate list containing the new supply, borrow caps of the assets
   */
  function _validateCapsUpdate(IEngine.CapsUpdate[] calldata capsUpdate) internal view {
    if (capsUpdate.length == 0) revert NoZeroUpdates();

    for (uint256 i = 0; i < capsUpdate.length; i++) {
      address asset = capsUpdate[i].asset;

      if (_restrictedAddresses[asset]) revert AssetIsRestricted();
      if (capsUpdate[i].supplyCap == 0 || capsUpdate[i].borrowCap == 0)
        revert InvalidUpdateToZero();

      (uint256 currentBorrowCap, uint256 currentSupplyCap) = POOL.getConfiguration(asset).getCaps();

      _validateParamUpdate(
        ParamUpdateValidationInput({
          currentValue: currentSupplyCap,
          newValue: capsUpdate[i].supplyCap,
          lastUpdated: _timelocks[asset].supplyCapLastUpdated,
          riskConfig: _riskConfig.capConfig.supplyCap,
          isChangeRelative: true
        })
      );
      _validateParamUpdate(
        ParamUpdateValidationInput({
          currentValue: currentBorrowCap,
          newValue: capsUpdate[i].borrowCap,
          lastUpdated: _timelocks[asset].borrowCapLastUpdated,
          riskConfig: _riskConfig.capConfig.borrowCap,
          isChangeRelative: true
        })
      );
    }
  }

  /**
   * @notice method to validate the interest rates update
   * @param ratesUpdate list containing the new interest rates params of the assets
   */
  function _validateRatesUpdate(IEngine.RateStrategyUpdate[] calldata ratesUpdate) internal view {
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

      _validateParamUpdate(
        ParamUpdateValidationInput({
          currentValue: currentOptimalUsageRatio,
          newValue: ratesUpdate[i].params.optimalUsageRatio,
          lastUpdated: _timelocks[asset].optimalUsageRatioLastUpdated,
          riskConfig: _riskConfig.rateConfig.optimalUsageRatio,
          isChangeRelative: false
        })
      );
      _validateParamUpdate(
        ParamUpdateValidationInput({
          currentValue: currentBaseVariableBorrowRate,
          newValue: ratesUpdate[i].params.baseVariableBorrowRate,
          lastUpdated: _timelocks[asset].baseVariableRateLastUpdated,
          riskConfig: _riskConfig.rateConfig.baseVariableBorrowRate,
          isChangeRelative: false
        })
      );
      _validateParamUpdate(
        ParamUpdateValidationInput({
          currentValue: currentVariableRateSlope1,
          newValue: ratesUpdate[i].params.variableRateSlope1,
          lastUpdated: _timelocks[asset].variableRateSlope1LastUpdated,
          riskConfig: _riskConfig.rateConfig.variableRateSlope1,
          isChangeRelative: false
        })
      );
      _validateParamUpdate(
        ParamUpdateValidationInput({
          currentValue: currentVariableRateSlope2,
          newValue: ratesUpdate[i].params.variableRateSlope2,
          lastUpdated: _timelocks[asset].variableRateSlope2LastUpdated,
          riskConfig: _riskConfig.rateConfig.variableRateSlope2,
          isChangeRelative: false
        })
      );
    }
  }

  /**
   * @notice method to validate the collaterals update
   * @param collateralUpdates list containing the new collateral updates of the assets
   */
  function _validateCollateralsUpdate(
    IEngine.CollateralUpdate[] calldata collateralUpdates
  ) internal view virtual {
    if (collateralUpdates.length == 0) revert NoZeroUpdates();

    for (uint256 i = 0; i < collateralUpdates.length; i++) {
      address asset = collateralUpdates[i].asset;

      if (_restrictedAddresses[asset]) revert AssetIsRestricted();
      if (collateralUpdates[i].liqProtocolFee != EngineFlags.KEEP_CURRENT)
        revert ParamChangeNotAllowed();
      if (
        collateralUpdates[i].ltv == 0 ||
        collateralUpdates[i].liqThreshold == 0 ||
        collateralUpdates[i].liqBonus == 0 ||
        collateralUpdates[i].debtCeiling == 0
      ) revert InvalidUpdateToZero();

      DataTypes.ReserveConfigurationMap memory configuration = POOL.getConfiguration(asset);
      (
        uint256 currentLtv,
        uint256 currentLiquidationThreshold,
        uint256 currentLiquidationBonus,
        ,

      ) = configuration.getParams();
      uint256 currentDebtCeiling = configuration.getDebtCeiling();

      _validateParamUpdate(
        ParamUpdateValidationInput({
          currentValue: currentLtv,
          newValue: collateralUpdates[i].ltv,
          lastUpdated: _timelocks[asset].ltvLastUpdated,
          riskConfig: _riskConfig.collateralConfig.ltv,
          isChangeRelative: false
        })
      );
      _validateParamUpdate(
        ParamUpdateValidationInput({
          currentValue: currentLiquidationThreshold,
          newValue: collateralUpdates[i].liqThreshold,
          lastUpdated: _timelocks[asset].liquidationThresholdLastUpdated,
          riskConfig: _riskConfig.collateralConfig.liquidationThreshold,
          isChangeRelative: false
        })
      );
      _validateParamUpdate(
        ParamUpdateValidationInput({
          currentValue: currentLiquidationBonus - 100_00, // as the definition is 100% + x%, and config engine takes into account x% for simplicity.
          newValue: collateralUpdates[i].liqBonus,
          lastUpdated: _timelocks[asset].liquidationBonusLastUpdated,
          riskConfig: _riskConfig.collateralConfig.liquidationBonus,
          isChangeRelative: false
        })
      );
      _validateParamUpdate(
        ParamUpdateValidationInput({
          currentValue: currentDebtCeiling / 100, // as the definition is with 2 decimals, and config engine does not take the decimals into account.
          newValue: collateralUpdates[i].debtCeiling,
          lastUpdated: _timelocks[asset].debtCeilingLastUpdated,
          riskConfig: _riskConfig.collateralConfig.debtCeiling,
          isChangeRelative: true
        })
      );
    }
  }

  /**
   * @notice method to validate the eMode category update
   * @param eModeCategoryUpdates list containing the new eMode category updates
   */
  function _validateEModeCategoryUpdate(
    IEngine.EModeCategoryUpdate[] calldata eModeCategoryUpdates
  ) internal view {
    if (eModeCategoryUpdates.length == 0) revert NoZeroUpdates();

    for (uint256 i = 0; i < eModeCategoryUpdates.length; i++) {
      uint8 eModeId = eModeCategoryUpdates[i].eModeCategory;
      if (_restrictedEModes[eModeId]) revert EModeIsRestricted();
      if (!eModeCategoryUpdates[i].label.equal(EngineFlags.KEEP_CURRENT_STRING))
        revert ParamChangeNotAllowed();

      if (
        eModeCategoryUpdates[i].ltv == 0 ||
        eModeCategoryUpdates[i].liqThreshold == 0 ||
        eModeCategoryUpdates[i].liqBonus == 0
      ) revert InvalidUpdateToZero();

      DataTypes.CollateralConfig memory currentEmodeConfig = POOL.getEModeCategoryCollateralConfig(eModeId);

      _validateParamUpdate(
        ParamUpdateValidationInput({
          currentValue: currentEmodeConfig.ltv,
          newValue: eModeCategoryUpdates[i].ltv,
          lastUpdated: _eModeTimelocks[eModeId].eModeLtvLastUpdated,
          riskConfig: _riskConfig.eModeConfig.ltv,
          isChangeRelative: false
        })
      );
      _validateParamUpdate(
        ParamUpdateValidationInput({
          currentValue: currentEmodeConfig.liquidationThreshold,
          newValue: eModeCategoryUpdates[i].liqThreshold,
          lastUpdated: _eModeTimelocks[eModeId].eModeLiquidationThresholdLastUpdated,
          riskConfig: _riskConfig.eModeConfig.liquidationThreshold,
          isChangeRelative: false
        })
      );
      _validateParamUpdate(
        ParamUpdateValidationInput({
          currentValue: currentEmodeConfig.liquidationBonus - 100_00, // as the definition is 100% + x%, and config engine takes into account x% for simplicity.
          newValue: eModeCategoryUpdates[i].liqBonus,
          lastUpdated: _eModeTimelocks[eModeId].eModeLiquidationBonusLastUpdated,
          riskConfig: _riskConfig.eModeConfig.liquidationBonus,
          isChangeRelative: false
        })
      );
    }
  }

  /**
   * @notice method to validate the oracle price caps update
   * @param priceCapsUpdate list containing the new price cap params for the oracles
   */
  function _validatePriceCapUpdate(PriceCapLstUpdate[] calldata priceCapsUpdate) internal view {
    if (priceCapsUpdate.length == 0) revert NoZeroUpdates();

    for (uint256 i = 0; i < priceCapsUpdate.length; i++) {
      address oracle = priceCapsUpdate[i].oracle;

      if (_restrictedAddresses[oracle]) revert OracleIsRestricted();
      if (
        priceCapsUpdate[i].priceCapUpdateParams.snapshotRatio == 0 ||
        priceCapsUpdate[i].priceCapUpdateParams.snapshotTimestamp == 0 ||
        priceCapsUpdate[i].priceCapUpdateParams.maxYearlyRatioGrowthPercent == 0
      ) revert InvalidUpdateToZero();

      // get current rate
      uint256 currentMaxYearlyGrowthPercent = IPriceCapAdapter(oracle)
        .getMaxYearlyGrowthRatePercent();
      uint104 currentRatio = IPriceCapAdapter(oracle).getRatio().toUint256().toUint104();

      // check that snapshotRatio is less or equal than current one
      if (priceCapsUpdate[i].priceCapUpdateParams.snapshotRatio > currentRatio)
        revert UpdateNotInRange();

      _validateParamUpdate(
        ParamUpdateValidationInput({
          currentValue: currentMaxYearlyGrowthPercent,
          newValue: priceCapsUpdate[i].priceCapUpdateParams.maxYearlyRatioGrowthPercent,
          lastUpdated: _timelocks[oracle].priceCapLastUpdated,
          riskConfig: _riskConfig.priceCapConfig.priceCapLst,
          isChangeRelative: true
        })
      );
    }
  }

  /**
   * @notice method to validate the oracle stable price caps update
   * @param priceCapsUpdate list containing the new price cap values for the oracles
   */
  function _validatePriceCapStableUpdate(
    PriceCapStableUpdate[] calldata priceCapsUpdate
  ) internal view {
    if (priceCapsUpdate.length == 0) revert NoZeroUpdates();

    for (uint256 i = 0; i < priceCapsUpdate.length; i++) {
      address oracle = priceCapsUpdate[i].oracle;

      if (_restrictedAddresses[oracle]) revert OracleIsRestricted();
      if (priceCapsUpdate[i].priceCap == 0) revert InvalidUpdateToZero();

      // get current rate
      int256 currentPriceCap = IPriceCapAdapterStable(oracle).getPriceCap();

      _validateParamUpdate(
        ParamUpdateValidationInput({
          currentValue: currentPriceCap.toUint256(),
          newValue: priceCapsUpdate[i].priceCap,
          lastUpdated: _timelocks[oracle].priceCapLastUpdated,
          riskConfig: _riskConfig.priceCapConfig.priceCapStable,
          isChangeRelative: true
        })
      );
    }
  }

  /**
   * @notice method to validate the pendle oracle discount rate update
   * @param discountRateUpdate list containing the new discount rate values for the pendle oracles
   */
  function _validatePendleDiscountRateUpdate(
    DiscountRatePendleUpdate[] calldata discountRateUpdate
  ) internal view {
    if (discountRateUpdate.length == 0) revert NoZeroUpdates();

    for (uint256 i = 0; i < discountRateUpdate.length; i++) {
      address oracle = discountRateUpdate[i].oracle;

      if (_restrictedAddresses[oracle]) revert OracleIsRestricted();
      if (discountRateUpdate[i].discountRate == 0) revert InvalidUpdateToZero();

      // get current rate
      uint256 currentDiscount = IPendlePriceCapAdapter(oracle).discountRatePerYear();

      _validateParamUpdate(
        ParamUpdateValidationInput({
          currentValue: currentDiscount,
          newValue: discountRateUpdate[i].discountRate,
          lastUpdated: _timelocks[oracle].priceCapLastUpdated,
          riskConfig: _riskConfig.priceCapConfig.discountRatePendle,
          isChangeRelative: false
        })
      );
    }
  }

  /**
   * @notice method to validate the risk param update is within the allowed bound and the debounce is respected
   * @param validationParam struct containing values used for validation of the risk param update
   */
  function _validateParamUpdate(ParamUpdateValidationInput memory validationParam) internal view {
    if (validationParam.newValue == EngineFlags.KEEP_CURRENT) return;

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

  /**
   * @notice method to update the borrow / supply caps using the config engine and updates the debounce
   * @param capsUpdate list containing the new supply, borrow caps of the assets
   */
  function _updateCaps(IEngine.CapsUpdate[] calldata capsUpdate) internal {
    for (uint256 i = 0; i < capsUpdate.length; i++) {
      address asset = capsUpdate[i].asset;

      if (capsUpdate[i].supplyCap != EngineFlags.KEEP_CURRENT) {
        _timelocks[asset].supplyCapLastUpdated = uint40(block.timestamp);
      }

      if (capsUpdate[i].borrowCap != EngineFlags.KEEP_CURRENT) {
        _timelocks[asset].borrowCapLastUpdated = uint40(block.timestamp);
      }
    }

    address(CONFIG_ENGINE).functionDelegateCall(
      abi.encodeWithSelector(CONFIG_ENGINE.updateCaps.selector, capsUpdate)
    );
  }

  /**
   * @notice method to update the interest rates params using the config engine and updates the debounce
   * @param ratesUpdate list containing the new interest rates params of the assets
   */
  function _updateRates(IEngine.RateStrategyUpdate[] calldata ratesUpdate) internal {
    for (uint256 i = 0; i < ratesUpdate.length; i++) {
      address asset = ratesUpdate[i].asset;

      if (ratesUpdate[i].params.optimalUsageRatio != EngineFlags.KEEP_CURRENT) {
        _timelocks[asset].optimalUsageRatioLastUpdated = uint40(block.timestamp);
      }

      if (ratesUpdate[i].params.baseVariableBorrowRate != EngineFlags.KEEP_CURRENT) {
        _timelocks[asset].baseVariableRateLastUpdated = uint40(block.timestamp);
      }

      if (ratesUpdate[i].params.variableRateSlope1 != EngineFlags.KEEP_CURRENT) {
        _timelocks[asset].variableRateSlope1LastUpdated = uint40(block.timestamp);
      }

      if (ratesUpdate[i].params.variableRateSlope2 != EngineFlags.KEEP_CURRENT) {
        _timelocks[asset].variableRateSlope2LastUpdated = uint40(block.timestamp);
      }
    }

    address(CONFIG_ENGINE).functionDelegateCall(
      abi.encodeWithSelector(CONFIG_ENGINE.updateRateStrategies.selector, ratesUpdate)
    );
  }

  /**
   * @notice method to update the collateral side params using the config engine and updates the debounce
   * @param collateralUpdates list containing the new collateral updates of the assets
   */
  function _updateCollateralSide(IEngine.CollateralUpdate[] calldata collateralUpdates) internal {
    for (uint256 i = 0; i < collateralUpdates.length; i++) {
      address asset = collateralUpdates[i].asset;

      if (collateralUpdates[i].ltv != EngineFlags.KEEP_CURRENT) {
        _timelocks[asset].ltvLastUpdated = uint40(block.timestamp);
      }

      if (collateralUpdates[i].liqThreshold != EngineFlags.KEEP_CURRENT) {
        _timelocks[asset].liquidationThresholdLastUpdated = uint40(block.timestamp);
      }

      if (collateralUpdates[i].liqBonus != EngineFlags.KEEP_CURRENT) {
        _timelocks[asset].liquidationBonusLastUpdated = uint40(block.timestamp);
      }

      if (collateralUpdates[i].debtCeiling != EngineFlags.KEEP_CURRENT) {
        _timelocks[asset].debtCeilingLastUpdated = uint40(block.timestamp);
      }
    }

    address(CONFIG_ENGINE).functionDelegateCall(
      abi.encodeWithSelector(CONFIG_ENGINE.updateCollateralSide.selector, collateralUpdates)
    );
  }

  /**
   * @notice method to update the eMode category params using the config engine and updates the debounce
   * @param eModeCategoryUpdates list containing the new eMode category params of the eMode category id
   */
  function _updateEModeCategories(IEngine.EModeCategoryUpdate[] calldata eModeCategoryUpdates) internal {
    for (uint256 i = 0; i < eModeCategoryUpdates.length; i++) {
      uint8 eModeId = eModeCategoryUpdates[i].eModeCategory;

      if (eModeCategoryUpdates[i].ltv != EngineFlags.KEEP_CURRENT) {
        _eModeTimelocks[eModeId].eModeLtvLastUpdated = uint40(block.timestamp);
      }

      if (eModeCategoryUpdates[i].liqThreshold != EngineFlags.KEEP_CURRENT) {
        _eModeTimelocks[eModeId].eModeLiquidationThresholdLastUpdated = uint40(block.timestamp);
      }

      if (eModeCategoryUpdates[i].liqBonus != EngineFlags.KEEP_CURRENT) {
        _eModeTimelocks[eModeId].eModeLiquidationBonusLastUpdated = uint40(block.timestamp);
      }
    }

    address(CONFIG_ENGINE).functionDelegateCall(
      abi.encodeWithSelector(CONFIG_ENGINE.updateEModeCategories.selector, eModeCategoryUpdates)
    );
  }

  /**
   * @notice method to update the oracle price caps update
   * @param priceCapsUpdate list containing the new price cap params for the oracles
   */
  function _updateLstPriceCaps(PriceCapLstUpdate[] calldata priceCapsUpdate) internal {
    for (uint256 i = 0; i < priceCapsUpdate.length; i++) {
      address oracle = priceCapsUpdate[i].oracle;

      _timelocks[oracle].priceCapLastUpdated = uint40(block.timestamp);

      IPriceCapAdapter(oracle).setCapParameters(priceCapsUpdate[i].priceCapUpdateParams);

      if (IPriceCapAdapter(oracle).isCapped()) revert InvalidPriceCapUpdate();
    }
  }

  /**
   * @notice method to update the oracle stable price caps update
   * @param priceCapsUpdate list containing the new price cap values for the oracles
   */
  function _updateStablePriceCaps(PriceCapStableUpdate[] calldata priceCapsUpdate) internal {
    for (uint256 i = 0; i < priceCapsUpdate.length; i++) {
      address oracle = priceCapsUpdate[i].oracle;

      _timelocks[oracle].priceCapLastUpdated = uint40(block.timestamp);

      IPriceCapAdapterStable(oracle).setPriceCap(priceCapsUpdate[i].priceCap.toInt256());
    }
  }

  /**
   * @notice method to update the pendle oracle discount rate
   * @param discountRateUpdate list containing the new discount rate values for the pendle oracles
   */
  function _updatePendleDiscountRates(DiscountRatePendleUpdate[] calldata discountRateUpdate) internal {
    for (uint256 i = 0; i < discountRateUpdate.length; i++) {
      address oracle = discountRateUpdate[i].oracle;

      _timelocks[oracle].priceCapLastUpdated = uint40(block.timestamp);

      IPendlePriceCapAdapter(oracle).setDiscountRatePerYear(discountRateUpdate[i].discountRate.toUint64());
    }
  }

  /**
   * @notice method to fetch the current interest rate params of the asset
   * @param asset the address of the underlying asset
   * @return optimalUsageRatio the current optimal usage ratio of the asset
   * @return baseVariableBorrowRate the current base variable borrow rate of the asset
   * @return variableRateSlope1 the current variable rate slope 1 of the asset
   * @return variableRateSlope2 the current variable rate slope 2 of the asset
   */
  function _getInterestRatesForAsset(
    address asset
  )
    internal
    view
    returns (
      uint256 optimalUsageRatio,
      uint256 baseVariableBorrowRate,
      uint256 variableRateSlope1,
      uint256 variableRateSlope2
    )
  {
    address rateStrategyAddress = POOL.getReserveData(asset).interestRateStrategyAddress;
    IDefaultInterestRateStrategyV2.InterestRateData
      memory interestRateData = IDefaultInterestRateStrategyV2(rateStrategyAddress)
        .getInterestRateDataBps(asset);
    return (
      interestRateData.optimalUsageRatio,
      interestRateData.baseVariableBorrowRate,
      interestRateData.variableRateSlope1,
      interestRateData.variableRateSlope2
    );
  }

  /**
   * @notice Ensures the risk param update is within the allowed range
   * @param from current risk param value
   * @param to new updated risk param value
   * @param maxPercentChange the max percent change allowed
   * @param isChangeRelative true, if maxPercentChange is relative in value, false if maxPercentChange
   *        is absolute in value.
   * @return bool true, if difference is within the maxPercentChange
   */
  function _updateWithinAllowedRange(
    uint256 from,
    uint256 to,
    uint256 maxPercentChange,
    bool isChangeRelative
  ) internal pure returns (bool) {
    // diff denotes the difference between the from and to values, ensuring it is a positive value always
    uint256 diff = from > to ? from - to : to - from;

    // maxDiff denotes the max permitted difference on both the upper and lower bounds, if the maxPercentChange is relative in value
    // we calculate the max permitted difference using the maxPercentChange and the from value, otherwise if the maxPercentChange is absolute in value
    // the max permitted difference is the maxPercentChange itself
    uint256 maxDiff = isChangeRelative ? (maxPercentChange * from) / BPS_MAX : maxPercentChange;

    if (diff > maxDiff) return false;
    return true;
  }
}
