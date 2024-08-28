// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AaveV3EthereumLidoAssets} from 'aave-address-book/AaveV3EthereumLido.sol';
import {IAaveV3ConfigEngine as IEngine} from 'aave-v3-periphery/contracts/v3-config-engine/IAaveV3ConfigEngine.sol';
import {EngineFlags} from 'aave-v3-periphery/contracts/v3-config-engine/EngineFlags.sol';
import {RiskStewardsEthereumLido} from '../../../scripts/networks/RiskStewardsEthereumLido.s.sol';

// make run-script network=mainnet contract_path=src/contracts/examples/EthereumLidoExample.s.sol:EthereumLidoExample broadcast=false
contract EthereumLidoExample is RiskStewardsEthereumLido {
  /**
   * @return string name identifier used for the diff
   */
  function name() internal pure override returns (string memory) {
    return 'ethereumlido_example';
  }

  /**
   * @return IEngine.CapsUpdate[] capUpdates to be performed
   */
  function capsUpdates() internal pure override returns (IEngine.CapsUpdate[] memory) {
    IEngine.CapsUpdate[] memory capUpdates = new IEngine.CapsUpdate[](1);
    capUpdates[0] = IEngine.CapsUpdate(
      AaveV3EthereumLidoAssets.wstETH_UNDERLYING,
      700_000,
      EngineFlags.KEEP_CURRENT
    );
    return capUpdates;
  }
}