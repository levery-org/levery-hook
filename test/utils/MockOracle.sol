// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

contract MockOracle {
    uint80 private roundID;
    int256 private answer;
    uint256 private startedAt;
    uint256 private updatedAt;
    uint80 private answeredInRound;
    address private admin;
    uint8 private _decimals;

    constructor() {
        admin = msg.sender;
        // Initial mock values
        roundID = 1;
        answer = 3000 * 10 ** 8;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        answeredInRound = 1;
        _decimals = 8;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call this function");
        _;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundID, answer, startedAt, updatedAt, answeredInRound);
    }

    function setLatestRoundData(
        uint80 _roundID,
        int256 _answer,
        uint256 _startedAt,
        uint256 _updatedAt,
        uint80 _answeredInRound
    ) external onlyAdmin {
        roundID = _roundID;
        answer = _answer;
        startedAt = _startedAt;
        updatedAt = _updatedAt;
        answeredInRound = _answeredInRound;
    }
}
