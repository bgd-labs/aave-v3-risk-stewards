// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAaveV3ConfigEngine as IEngine, IPool} from 'aave-v3-periphery/contracts/v3-config-engine/IAaveV3ConfigEngine.sol';
import {IRiskSteward} from '../src/interfaces/IRiskSteward.sol';
import {ProtocolV3TestBase} from 'aave-helpers/ProtocolV3TestBase.sol';

abstract contract RiskStewardsBase is ProtocolV3TestBase {
  error FailedUpdate();
  IPool immutable POOL;
  IRiskSteward immutable STEWARD;

  uint8 public constant MAX_TX = 5;

  constructor(address pool, address steward) {
    POOL = IPool(pool);
    STEWARD = IRiskSteward(steward);
  }

  function capsUpdates() internal pure virtual returns (IEngine.CapsUpdate[] memory);

  function collateralsUpdates() public view virtual returns (IEngine.CollateralUpdate[] memory) {}

  function rateStrategiesUpdates()
    public
    view
    virtual
    returns (IEngine.RateStrategyUpdate[] memory)
  {}

  function lstPriceCapsUpdates() public view virtual returns (IRiskSteward.PriceCapLstUpdate[] memory) {}

  function stablePriceCapsUpdates() public view virtual returns (IRiskSteward.PriceCapStableUpdate[] memory) {}

  function name() internal pure virtual returns (string memory);

  /**
   * @notice This script doesn't broadcast as it's intended to be used via safe
   */
  function run(bool broadcastToSafe) external {
    vm.startPrank(STEWARD.RISK_COUNCIL());
    bytes[] memory callDatas = _simulateAndGenerateDiff();
    vm.stopPrank();

    if (callDatas.length > 1) emit log_string('** multiple calldatas emitted, please execute them all **');
    emit log_string('safe address');
    emit log_address(STEWARD.RISK_COUNCIL());
    emit log_string('steward address:');
    emit log_address(address(STEWARD));

    for (uint8 i = 0; i < callDatas.length; i++) {
      emit log_string('calldata:');
      emit log_bytes(callDatas[i]);

      if (broadcastToSafe) {
        _sendToSafe(callDatas[i]);
      }
    }
  }

  function _simulateAndGenerateDiff() internal returns (bytes[] memory) {
    bytes[] memory callDatas = new bytes[](MAX_TX);
    uint8 txCount;

    string memory pre = string(abi.encodePacked('pre_', name()));
    string memory post = string(abi.encodePacked('post_', name()));

    IEngine.CapsUpdate[] memory capUpdates = capsUpdates();
    IEngine.CollateralUpdate[] memory collateralUpdates = collateralsUpdates();
    IEngine.RateStrategyUpdate[] memory rateUpdates = rateStrategiesUpdates();
    IRiskSteward.PriceCapLstUpdate[] memory lstPriceCapUpdates = lstPriceCapsUpdates();
    IRiskSteward.PriceCapStableUpdate[] memory stablePriceCapUpdates = stablePriceCapsUpdates();

    createConfigurationSnapshot(pre, POOL);

    if (capUpdates.length != 0) {
      callDatas[txCount] = abi.encodeWithSelector(
        IRiskSteward.updateCaps.selector,
        capUpdates
      );
      (bool success, bytes memory resultData) = address(STEWARD).call(callDatas[txCount]);
      _verifyCallResult(success, resultData);
      txCount++;
    }

    if (collateralUpdates.length != 0) {
      callDatas[txCount] = abi.encodeWithSelector(
        IRiskSteward.updateCollateralSide.selector,
        collateralUpdates
      );
      (bool success, bytes memory resultData) = address(STEWARD).call(callDatas[txCount]);
      _verifyCallResult(success, resultData);
      txCount++;
    }

    if (rateUpdates.length != 0) {
      callDatas[txCount] = abi.encodeWithSelector(
        IRiskSteward.updateRates.selector,
        rateUpdates
      );
      (bool success, bytes memory resultData) = address(STEWARD).call(callDatas[txCount]);
      _verifyCallResult(success, resultData);
      txCount++;
    }

    if (lstPriceCapUpdates.length != 0) {
      callDatas[txCount] = abi.encodeWithSelector(
        IRiskSteward.updateLstPriceCaps.selector,
        rateUpdates
      );
      (bool success, bytes memory resultData) = address(STEWARD).call(callDatas[txCount]);
      _verifyCallResult(success, resultData);
      txCount++;
    }

    if (stablePriceCapUpdates.length != 0) {
      callDatas[txCount] = abi.encodeWithSelector(
        IRiskSteward.updateStablePriceCaps.selector,
        stablePriceCapUpdates
      );
      (bool success, bytes memory resultData) = address(STEWARD).call(callDatas[txCount]);
      _verifyCallResult(success, resultData);
      txCount++;
    }

    createConfigurationSnapshot(post, POOL);
    diffReports(pre, post);

    // we defined the callDatas with MAX_TX size, we now squash it to the number of txs
    assembly {
      mstore(callDatas, txCount)
    }
    return callDatas;
  }

  function _sendToSafe(bytes memory callDatas) internal {
    string[] memory inputs = new string[](8);
    inputs[0] = 'npx';
    inputs[1] = 'ts-node';
    inputs[2] = 'scripts/safe-helper.ts';
    inputs[3] = vm.toString(STEWARD.RISK_COUNCIL());
    inputs[4] = vm.toString(address(STEWARD));
    inputs[5] = vm.toString(callDatas);
    inputs[6] = vm.toString(block.chainid);
    inputs[7] = 'Call';
    vm.ffi(inputs);
  }

  function _verifyCallResult(
    bool success,
    bytes memory returnData
  ) private pure returns (bytes memory) {
    if (success) {
      return returnData;
    } else {
      // Look for revert reason and bubble it up if present
      if (returnData.length > 0) {
        // The easiest way to bubble the revert reason is using memory via assembly

        // solhint-disable-next-line no-inline-assembly
        assembly {
          let returndata_size := mload(returnData)
          revert(add(32, returnData), returndata_size)
        }
      } else {
        revert FailedUpdate();
      }
    }
  }
}