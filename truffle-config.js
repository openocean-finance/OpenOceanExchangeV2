module.exports = {
    // Uncommenting the defaults below
    // provides for an easier quick-start with Ganache.
    // You can also follow this format for other networks;
    // see <http://truffleframework.com/docs/advanced/configuration>
    // for more details on how to specify configuration options!
    //
    networks: {
        development: {
            host: "127.0.0.1",
            port: 8545,
            network_id: "1",
            networkCheckTimeout: 100000000
        },
        test: {
            url: "https://eth-rpc.openocean.finance",
            // port: 8545,
            network_id: "1",
            networkCheckTimeout: 100000000
        },
        development_bsc: {
            host: "127.0.0.1",
            port: 18545,
            network_id: "*",
            networkCheckTimeout: 100000000
        },
        test_bsc: {
            url: "https://bsc-rpc.openocean.finance",
            // port: 443,
            network_id: "1",
            networkCheckTimeout: 100000000
        }
    },
    compilers: {
        solc: {
            version: '0.6.12',
            settings: {
                optimizer: {
                    enabled: true,
                    runs: 200,
                }
            }
        },
    }
    //
};
