import {CodeArtifact, FEATURE, FeatureModule} from '../types';
import {RateStrategyUpdate} from './types';
import {
  assetsSelectPrompt,
  translateAssetToAssetLibUnderlying,
} from '../prompts/assetsSelectPrompt';
import {percentPrompt, translateJsPercentToSol} from '../prompts/percentPrompt';

export async function fetchRateStrategyParamsV3(required?: boolean) {
  return {
    optimalUtilizationRate: await percentPrompt({
      message: 'optimalUtilizationRate',
      required,
    }),
    baseVariableBorrowRate: await percentPrompt({
      message: 'baseVariableBorrowRate',
      required,
    }),
    variableRateSlope1: await percentPrompt({
      message: 'variableRateSlope1',
      required,
    }),
    variableRateSlope2: await percentPrompt({
      message: 'variableRateSlope2',
      required,
    }),
  };
}

export const rateUpdatesV3: FeatureModule<RateStrategyUpdate[]> = {
  value: FEATURE.RATE_UPDATE_V3,
  description: 'RateStrategiesUpdates',
  async cli({pool}) {
    console.log(`Fetching information for RatesUpdate on ${pool}`);
    const assets = await assetsSelectPrompt({
      message: 'Select the assets you want to amend',
      pool,
    });
    const response: RateStrategyUpdate[] = [];
    for (const asset of assets) {
      console.log(`Fetching info for ${asset}`);
      response.push({asset, params: await fetchRateStrategyParamsV3()});
    }
    return response;
  },
  build({pool, cfg}) {
    const response: CodeArtifact = {
      code: {
        fn: [
          `function rateStrategiesUpdates()
          public
          pure
          override
          returns (IAaveV3ConfigEngine.RateStrategyUpdate[] memory)
        {
          IAaveV3ConfigEngine.RateStrategyUpdate[] memory rateStrategies = new IAaveV3ConfigEngine.RateStrategyUpdate[](${
            cfg.length
          });
          ${cfg
            .map(
              (cfg, ix) => `rateStrategies[${ix}] = IAaveV3ConfigEngine.RateStrategyUpdate({
                  asset: ${translateAssetToAssetLibUnderlying(cfg.asset, pool)},
                  params: IAaveV3ConfigEngine.InterestRateInputData({
                    optimalUsageRatio: ${translateJsPercentToSol(
                      cfg.params.optimalUtilizationRate,
                    )},
                    baseVariableBorrowRate: ${translateJsPercentToSol(
                      cfg.params.baseVariableBorrowRate,
                    )},
                    variableRateSlope1: ${translateJsPercentToSol(cfg.params.variableRateSlope1)},
                    variableRateSlope2: ${translateJsPercentToSol(cfg.params.variableRateSlope2)}
                  })
                });`,
            )
            .join('\n')}


          return rateStrategies;
        }`,
        ],
      },
    };
    return response;
  },
};
