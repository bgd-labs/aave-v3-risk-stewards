// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IRiskOracle} from './dependencies/IRiskOracle.sol';
import {IRiskSteward} from '../interfaces/IRiskSteward.sol';
import {IAaveStewardInjector, AutomationCompatibleInterface} from '../interfaces/IAaveStewardInjector.sol';
import {IAaveV3ConfigEngine as IEngine} from 'aave-v3-origin/src/contracts/extensions/v3-config-engine/IAaveV3ConfigEngine.sol';
import {Ownable} from 'openzeppelin-contracts/contracts/access/Ownable.sol';

/**
 * @title AaveStewardInjector
 * @author BGD Labs
 * @notice Contract to perform automation on risk steward using the edge risk oracle.
 *         The contract only permits for injecting rate updates for the whitelisted asset.
 * @dev Aave chainlink automation-keeper-compatible contract to:
 *      - check if updates from edge risk oracles can be injected into risk steward.
 *      - injectes risk updates on the risk steward if all conditions are met.
 */
contract AaveStewardInjector is Ownable, IAaveStewardInjector {
  /// @inheritdoc IAaveStewardInjector
  address public immutable RISK_ORACLE;

  /// @inheritdoc IAaveStewardInjector
  address public immutable RISK_STEWARD;

  /// @inheritdoc IAaveStewardInjector
  address public immutable WHITELISTED_ASSET;

  /// @inheritdoc IAaveStewardInjector
  string public constant WHITELISTED_UPDATE_TYPE = 'RateStrategyUpdate';

  /**
   * @inheritdoc IAaveStewardInjector
   * @dev after an update is added on the risk oracle, the update is only valid from the timestamp it was added
   *      on the risk oracle plus the expiration time, after which the update cannot be injected into the risk steward.
   */
  uint256 public constant EXPIRATION_PERIOD = 6 hours;

  mapping(uint256 => bool) internal _isUpdateIdExecuted;
  mapping(uint256 => bool) internal _disabledUpdates;

  /**
   * @param riskOracle address of the edge risk oracle contract.
   * @param riskSteward address of the risk steward contract.
   * @param guardian address of the guardian / owner of the stewards injector.
   * @param whitelistedAsset address of the whitelisted asset for which update can be injected.
   */
  constructor(
    address riskOracle,
    address riskSteward,
    address guardian,
    address whitelistedAsset
  ) Ownable(guardian) {
    RISK_ORACLE = riskOracle;
    RISK_STEWARD = riskSteward;
    WHITELISTED_ASSET = whitelistedAsset;
  }

  /**
   * @inheritdoc AutomationCompatibleInterface
   * @dev run off-chain, checks if the latest update from risk oracle should be injected on risk steward
   */
  function checkUpkeep(bytes memory) public view virtual override returns (bool, bytes memory) {
    IRiskOracle.RiskParameterUpdate memory updateRiskParams = IRiskOracle(RISK_ORACLE)
      .getLatestUpdateByParameterAndMarket(WHITELISTED_UPDATE_TYPE, WHITELISTED_ASSET);

    if (_canUpdateBeInjected(updateRiskParams)) return (true, '');

    return (false, '');
  }

  /**
   * @inheritdoc AutomationCompatibleInterface
   * @dev executes injection of the latest update from the risk oracle into the risk steward.
   */
  function performUpkeep(bytes calldata) external override {
    IRiskOracle.RiskParameterUpdate memory updateRiskParams = IRiskOracle(RISK_ORACLE)
      .getLatestUpdateByParameterAndMarket(WHITELISTED_UPDATE_TYPE, WHITELISTED_ASSET);

    if (!_canUpdateBeInjected(updateRiskParams)) {
      revert UpdateCannotBeInjected();
    }

    IRiskSteward(RISK_STEWARD).updateRates(_repackRateUpdate(updateRiskParams));
    _isUpdateIdExecuted[updateRiskParams.updateId] = true;

    emit ActionSucceeded(updateRiskParams.updateId);
  }

  /// @inheritdoc IAaveStewardInjector
  function isDisabled(uint256 updateId) public view returns (bool) {
    return _disabledUpdates[updateId];
  }

  /// @inheritdoc IAaveStewardInjector
  function disableUpdateById(uint256 updateId, bool disabled) external onlyOwner {
    _disabledUpdates[updateId] = disabled;
    emit UpdateDisabled(updateId, disabled);
  }

  /// @inheritdoc IAaveStewardInjector
  function isUpdateIdExecuted(uint256 updateid) public view returns (bool) {
    return _isUpdateIdExecuted[updateid];
  }

  /**
   * @notice method to check if the update from risk oracle could be injected into the risk steward.
   * @dev only allow injecting interest rate updates for the whitelisted asset.
   * @param updateRiskParams struct containing the risk param update from the risk oralce to check if it can be injected.
   * @return true if the update could be injected to the risk steward, false otherwise.
   */
  function _canUpdateBeInjected(
    IRiskOracle.RiskParameterUpdate memory updateRiskParams
  ) internal view returns (bool) {
    return (!isUpdateIdExecuted(updateRiskParams.updateId) &&
      (updateRiskParams.timestamp + EXPIRATION_PERIOD > block.timestamp) &&
      updateRiskParams.market == WHITELISTED_ASSET &&
      keccak256(bytes(updateRiskParams.updateType)) == keccak256(bytes(WHITELISTED_UPDATE_TYPE)) &&
      !isDisabled(updateRiskParams.updateId));
  }

  /**
   * @notice method to repack update params from the risk oracle to the format of risk steward.
   * @param riskParams the risk update param from the edge risk oracle.
   * @return the repacked risk update in the format of the risk steward.
   */
  function _repackRateUpdate(
    IRiskOracle.RiskParameterUpdate memory riskParams
  ) internal pure returns (IEngine.RateStrategyUpdate[] memory) {
    IEngine.RateStrategyUpdate[] memory rateUpdate = new IEngine.RateStrategyUpdate[](1);
    rateUpdate[0].asset = riskParams.market;
    rateUpdate[0].params = abi.decode(riskParams.newValue, (IEngine.InterestRateInputData));
    return rateUpdate;
  }
}
