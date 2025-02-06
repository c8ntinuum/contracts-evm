require("@nomicfoundation/hardhat-ethers");
require("@nomicfoundation/hardhat-chai-matchers");

module.exports = {
    networks: {
        hardhat: {
            loggingEnabled: true,
            mining: {
                auto: false,
                interval: 12000
            },
            chainId: 1
        }
    },
    defaultNetwork: "hardhat",
    solidity: {
        compilers: [
            {
                version: "0.5.16",
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 10000
                    }
                }
            },
            {
                version: "0.8.27",
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 10000
                    }
                }
            },
            {
                version: "0.4.18",
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 10000
                    }
                }
            },
            {
                version: "0.6.6",
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 10000
                    }
                }
            }
        ]
    }
};