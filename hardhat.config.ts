import 'hardhat-deploy';
import '@nomiclabs/hardhat-ethers';
import '@eth-optimism/plugins/hardhat/compiler';
import { HardhatUserConfig } from 'hardhat/types';

import "@matterlabs/hardhat-zksync-deploy";
import "@matterlabs/hardhat-zksync-solc";

import networks from './hardhat.network';

const config: HardhatUserConfig = {
    zksolc: {
        version: "1.3.5",
        compilerSource: "binary",
        settings: {
        },
    },
    solidity: {
        version: '0.8.9',
        settings: {
            optimizer: {
                enabled: true,
                runs: 200,
            },
        },
    },
    networks,
    namedAccounts: {
        deployer: {
            default: 0,
        },
    },
    paths: {
        sources: 'contracts',
    },
    ovm: {
        solcVersion: '0.6.12',
    }
};
export default config;
