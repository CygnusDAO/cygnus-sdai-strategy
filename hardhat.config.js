// JS
const path = require("path");

require("@nomicfoundation/hardhat-chai-matchers");
require("@nomicfoundation/hardhat-ledger");
require("@nomicfoundation/hardhat-verify");
require("hardhat-contract-sizer");

// process.env
require("dotenv").config({ path: path.resolve(__dirname, "./.env") });

const optimizerSettings = {
    enabled: true,
    runs: 1000000,
    details: {
        // The peephole optimizer is always on if no details are given,
        // use details to switch it off.
        peephole: true,
        // The inliner is always on if no details are given,
        // use details to switch it off.
        inliner: true,
        // The unused jumpdest remover is always on if no details are given,
        // use details to switch it off.
        jumpdestRemover: true,
        // Sometimes re-orders literals in commutative operations.
        orderLiterals: true,
        // Removes duplicate code blocks
        deduplicate: true,
        // Common subexpression elimination, this is the most complicated step but
        // can also provide the largest gain.
        cse: true,
        // Optimize representation of literal numbers and strings in code.
        constantOptimizer: true,
        yulDetails: {
            stackAllocation: true,
            optimizerSteps: "dhfoDgvulfnTUtnIf[xa[r]EscLMcCTUtTOntnfDIulLculVcul[j]Tpeulxa[rul]xa[r]cLgvifCTUca[r]LSsTOtfDnca[r]Iulc]jmul[jul]VcTOculjmul",
        },
    },
};

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
    solidity: {
        compilers: [
            {
                version: "0.8.17",
                settings: {
                    viaIR: true,
                    optimizer: {
                        ...optimizerSettings,
                    },
                    metadata: {
                        bytecodeHash: "none",
                    },
                },
            },
        ],
    },
    defaultNetwork: "localhost",
    networks: {
        // Local
        localhost: {
            url: "http://127.0.0.1:8545/",
            chainId: 31337,
            timeout: 400000000,
        },
        // Mainnet
        mainnet: {
            url: "https://rpc.ankr.com/eth",
            chainId: 1,
        },
    },
    mocha: { timeout: 100000000 },
};
