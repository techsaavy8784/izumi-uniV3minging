// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.4;

// Uncomment if needed.
import "hardhat/console.sol";

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "../libraries/AmountMath.sol";
import "../libraries/LogPowMath.sol";
import "../libraries/MulDivMath.sol";

import "./interfaces.sol";
import "../utils.sol";
import "../multicall.sol";

contract MiningOneSide is Ownable, Multicall {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    struct MiningInfo {
        uint256 amountLock;
        uint256 vLiquidity;
        uint256 lastTouchAccRewardPerShareX128;
        uint256 uniPositionID;
        uint128 uniLiquidity;
        bool isUniPositionIDExternal;
    }

    address public tokenLock;
    address public tokenUni;
    uint24 public fee;

    struct RewardInfo {
        address token;
        address provider;
        uint256 tokenPerBlock;
        uint256 endBlock;
        uint256 startBlock;
        uint256 BONUS_MULTIPLIER;
    }

    uint256 totalVLiquidity;
    uint256 accRewardPerShareX128;
    uint256 lastRewardBlock;

    RewardInfo public rewardInfo;

    uint256 public miningNum = 0;

    address public nftManager;
    address public uniFactory;
    uint256 internal constant sqrt2A = 141421;
    uint256 internal constant sqrt2B = 100000;

    mapping(uint256 => address) public miningOwner;
    mapping(uint256 => MiningInfo) public miningInfos;
    mapping(address => EnumerableSet.UintSet) private addr2MiningIDs;

    event Mint(
        uint256 indexed miningID,
        address indexed owner,
        uint256 vLiquidity,
        uint256 amountLock
    );
    event Collect(
        uint256 indexed miningID,
        address indexed recipient,
        uint256 amountUni,
        uint256 amountLock,
        uint256 amountReward
    );
    event Withdraw(
        uint256 indexed miningID,
        address indexed recipient,
        uint256 amountUni,
        uint256 amountLock,
        uint256 amountReward
    );

    constructor(
        address tokenUniAddr,
        address tokenLockAddr,
        uint24 swapFee,
        address nfPositionManager,
        RewardInfo memory rewardInfoParams
    ) {
        tokenUni = tokenUniAddr;
        tokenLock = tokenLockAddr;
        fee = swapFee;

        nftManager = nfPositionManager;
        address weth = INonfungiblePositionManager(nfPositionManager).WETH9();
        require(weth != tokenUniAddr, "weth not supported!");
        require(weth != tokenLockAddr, "weth not supported!");
        uniFactory = INonfungiblePositionManager(nfPositionManager).factory();

        rewardInfo = rewardInfoParams;
        lastRewardBlock = rewardInfoParams.startBlock;
        require(
            rewardInfoParams.startBlock < rewardInfoParams.endBlock,
            "start < end"
        );

        totalVLiquidity = 0;
        accRewardPerShareX128 = 0;
    }

    modifier checkMiningOwner(uint256 miningID) {
        require(miningOwner[miningID] == msg.sender, "Not Owner!");
        _;
    }

    function setRewardProvider(address rewardProvider) external onlyOwner {
        rewardInfo.provider = rewardProvider;
    }

    function setRewardEndBlock(uint256 rewardEndBlock) external onlyOwner {
        require(block.number <= rewardInfo.endBlock, "Finished!");
        if (rewardEndBlock >= block.number) {
            rewardInfo.endBlock = block.number;
        }
    }

    function _updateGlobalReward() private {
        if (block.number <= lastRewardBlock) {
            return;
        }
        if (lastRewardBlock >= rewardInfo.endBlock) {
            return;
        }
        uint256 currBlockNumber = block.number;
        if (currBlockNumber > rewardInfo.endBlock) {
            currBlockNumber = rewardInfo.endBlock;
        }
        if (totalVLiquidity == 0) {
            lastRewardBlock = currBlockNumber;
            return;
        }
        uint256 multiplier = (currBlockNumber - lastRewardBlock) *
            rewardInfo.BONUS_MULTIPLIER;
        uint256 tokenReward = multiplier * rewardInfo.tokenPerBlock;
        accRewardPerShareX128 += MulDivMath.mulDivFloor(
            tokenReward,
            FixedPoints.Q128,
            totalVLiquidity
        );
        lastRewardBlock = currBlockNumber;
    }

    function _newMiningInfo(
        MiningInfo storage miningInfo,
        uint256 amountLock,
        uint256 vLiquidity
    ) private {
        _updateGlobalReward();

        miningInfo.amountLock = amountLock;
        miningInfo.vLiquidity = vLiquidity;
        // todo: whether need ceil?
        miningInfo.lastTouchAccRewardPerShareX128 = accRewardPerShareX128;
    }

    function getMiningIDList(address user)
        external
        view
        returns (uint256[] memory)
    {
        EnumerableSet.UintSet storage ids = addr2MiningIDs[user];
        // push could not be used in memory array
        // we set the miningIDList into a fixed-length array rather than dynamic
        uint256[] memory miningIDList = new uint256[](ids.length());
        for (uint256 i = 0; i < ids.length(); i++) {
            miningIDList[i] = ids.at(i);
        }
        return miningIDList;
    }

    function _pendingReward(uint256 miningID)
        private
        view
        returns (uint256 amountReward)
    {
        MiningInfo memory miningInfo = miningInfos[miningID];
        amountReward = MulDivMath.mulDivFloor(
            miningInfo.vLiquidity,
            accRewardPerShareX128 - miningInfo.lastTouchAccRewardPerShareX128,
            FixedPoints.Q128
        );
    }

    function pendingReward(uint256 miningID)
        external
        returns (uint256 amountReward)
    {
        _updateGlobalReward();
        amountReward = _pendingReward(miningID);
    }

    function pendingRewards(address user)
        external
        returns (uint256 amountRewards)
    {
        amountRewards = 0;
        EnumerableSet.UintSet storage ids = addr2MiningIDs[user];
        _updateGlobalReward();

        for (uint256 i = 0; i < ids.length(); i++) {
            amountRewards += _pendingReward(ids.at(i));
        }
    }

    function _collect(
        address recipient,
        MiningInfo storage miningInfo,
        bool emergency
    ) private returns (uint256 amountReward) {
        _updateGlobalReward();
        amountReward = MulDivMath.mulDivFloor(
            miningInfo.vLiquidity,
            accRewardPerShareX128 - miningInfo.lastTouchAccRewardPerShareX128,
            FixedPoints.Q128
        );
        if (amountReward > 0) {
            if (!emergency) {
                IERC20(rewardInfo.token).safeTransferFrom(
                    rewardInfo.provider,
                    recipient,
                    amountReward
                );
            } else {
                // check provider's balance and allowance
                uint256 allowance = IERC20(rewardInfo.token).allowance(
                    rewardInfo.provider,
                    address(this)
                );
                uint256 balance = IERC20(rewardInfo.token).balanceOf(
                    rewardInfo.provider
                );
                uint256 actualAmountReward = amountReward;
                if (allowance > actualAmountReward) {
                    actualAmountReward = allowance;
                }
                if (balance > actualAmountReward) {
                    actualAmountReward = balance;
                }
                // call transferFrom
                (bool success, bytes memory data) = rewardInfo.token.call(
                    abi.encodeWithSelector(
                        IERC20.transferFrom.selector,
                        rewardInfo.provider,
                        recipient,
                        actualAmountReward
                    )
                );
                if (success && (data.length == 0 || abi.decode(data, (bool)))) {
                    amountReward = actualAmountReward;
                } else {
                    amountReward = 0;
                }
            }
        }
        miningInfo.lastTouchAccRewardPerShareX128 = accRewardPerShareX128;
    }

    function _withdraw(
        address recipient,
        MiningInfo storage miningInfo,
        bool emergency
    ) private returns (uint256 amountReward, uint256 amountLock) {
        _updateGlobalReward();
        // first, collect rewarded tokens
        amountReward = _collect(recipient, miningInfo, emergency);
        // second, refund locked tokens
        amountLock = miningInfo.amountLock;
        if (amountLock > 0) {
            IERC20(tokenLock).safeTransfer(recipient, amountLock);
        }
        // third, clear miningInfo
        miningInfo.amountLock = 0;
        miningInfo.vLiquidity = 0;
    }

    function _getTickPrice(address pool)
        private
        view
        returns (int24 tick, uint160 sqrtPriceX96)
    {
        (
            uint160 sqrtPriceX96_,
            int24 tick_,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        ) = IUniswapV3Pool(pool).slot0();
        tick = tick_;
        sqrtPriceX96 = sqrtPriceX96_;
    }

    function _tickFloor(int24 tick, int24 tickSpacing)
        private
        pure
        returns (int24)
    {
        int24 c = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) {
            c = c - 1;
        }
        c = c * tickSpacing;
        return c;
    }

    function _tickUpper(int24 tick, int24 tickSpacing)
        private
        pure
        returns (int24)
    {
        int24 c = tick / tickSpacing;
        if (tick > 0 && tick % tickSpacing != 0) {
            c = c + 1;
        }
        c = c * tickSpacing;
        return c;
    }

    struct TickRange {
        int24 tickLeft;
        int24 tickRight;
        uint160 sqrtPriceX96;
    }

    function _getTickRange() private view returns (TickRange memory tickRange) {
        address pool = IUniswapV3Factory(uniFactory).getPool(
            tokenLock,
            tokenUni,
            fee
        );
        require(pool != address(0), "No Uniswap Pool!");
        int24 tick;
        (tick, tickRange.sqrtPriceX96) = _getTickPrice(pool);
        int24 tickSpacing = IUniswapV3Factory(uniFactory).feeAmountTickSpacing(
            fee
        );
        if (tokenUni < tokenLock) {
            // price is tokenLock / tokenUni
            // tokenUni is X
            tickRange.tickLeft = tick + 1;
            uint256 sqrtDoublePriceX96 = (uint256(tickRange.sqrtPriceX96) *
                sqrt2A) / sqrt2B;
            require(uint160(sqrtDoublePriceX96) == sqrtDoublePriceX96, "2p O");
            tickRange.tickRight = LogPowMath.getLogSqrtPriceFloor(
                uint160(sqrtDoublePriceX96)
            );
            tickRange.tickLeft = _tickUpper(tickRange.tickLeft, tickSpacing);
            tickRange.tickRight = _tickUpper(tickRange.tickRight, tickSpacing);
        } else {
            // price is tokenUni / tokenLock
            // tokenUni is Y
            tickRange.tickRight = tick;
            uint256 sqrtHalfPriceX96 = (uint256(tickRange.sqrtPriceX96) *
                sqrt2B) / sqrt2A;
            require(uint160(sqrtHalfPriceX96) == sqrtHalfPriceX96, "p/2 O");
            tickRange.tickLeft = LogPowMath.getLogSqrtPriceFloor(
                uint160(sqrtHalfPriceX96)
            );
            tickRange.tickLeft = _tickFloor(tickRange.tickLeft, tickSpacing);
            tickRange.tickRight = _tickFloor(tickRange.tickRight, tickSpacing);
        }
        require(tickRange.tickLeft < tickRange.tickRight, "L<R");
    }

    function _getAmountLock(uint160 sqrtPriceX96, uint256 amountUni)
        private
        view
        returns (uint256 amountLock)
    {
        uint256 priceX96 = MulDivMath.mulDivCeil(
            sqrtPriceX96,
            sqrtPriceX96,
            FixedPoints.Q96
        );
        if (tokenUni < tokenLock) {
            // price is tokenLock / tokenUni
            amountLock = MulDivMath.mulDivCeil(
                amountUni,
                priceX96,
                FixedPoints.Q96
            );
        } else {
            amountLock = MulDivMath.mulDivCeil(
                amountUni,
                FixedPoints.Q96,
                priceX96
            );
        }
    }

    function _mintUniswapParam(
        uint256 amountUni,
        int24 tickLeft,
        int24 tickRight,
        uint256 deadline
    )
        private
        view
        returns (INonfungiblePositionManager.MintParams memory params)
    {
        params.fee = fee;
        params.tickLower = tickLeft;
        params.tickUpper = tickRight;
        params.deadline = deadline;
        params.recipient = address(this);
        if (tokenUni < tokenLock) {
            params.token0 = tokenUni;
            params.token1 = tokenLock;
            params.amount0Desired = amountUni;
            params.amount1Desired = 0;
            params.amount0Min = 1;
            params.amount1Min = 0;
        } else {
            params.token0 = tokenLock;
            params.token1 = tokenUni;
            params.amount0Desired = 0;
            params.amount1Desired = amountUni;
            params.amount0Min = 0;
            params.amount1Min = 1;
        }
    }

    function _collectUniswapParam(uint256 uniPositionID, address recipient)
        private
        pure
        returns (INonfungiblePositionManager.CollectParams memory params)
    {
        params.tokenId = uniPositionID;
        params.recipient = recipient;
        params.amount0Max = 0xffffffffffffffffffffffffffffffff;
        params.amount1Max = 0xffffffffffffffffffffffffffffffff;
    }

    function _withdrawUniswapParam(
        uint256 uniPositionID,
        uint128 liquidity,
        uint256 deadline
    )
        private
        pure
        returns (
            INonfungiblePositionManager.DecreaseLiquidityParams memory params
        )
    {
        params.tokenId = uniPositionID;
        params.liquidity = liquidity;
        params.amount0Min = 0;
        params.amount1Min = 0;
        params.deadline = deadline;
    }

    struct PositionData {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    function _getPositionData(uint256 uniPositionID)
        private
        view
        returns (PositionData memory posData)
    {
        (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee_,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = INonfungiblePositionManager(nftManager).positions(uniPositionID);
        posData.token0 = token0;
        posData.token1 = token1;
        posData.fee = fee_;
        posData.tickLower = tickLower;
        posData.tickUpper = tickUpper;
        posData.liquidity = liquidity;
    }

    function _checkNFTAndGetAmountUni(
        uint256 uniPositionID,
        TickRange memory requiredTickRange
    ) private view returns (uint256 amountUni) {
        PositionData memory posData = _getPositionData(uniPositionID);
        // range of nft should cover required range
        require(posData.tickLower < posData.tickUpper, "L<R");
        require(posData.tickLower <= requiredTickRange.tickLeft, "TL");
        require(posData.tickUpper >= requiredTickRange.tickRight, "TU");
        // liquidity of nft should >0
        require(posData.liquidity > 0, "L>0");

        uint160 sqrtPriceAX96 = LogPowMath.getSqrtPrice(
            requiredTickRange.tickLeft
        );
        uint160 sqrtPriceBX96 = LogPowMath.getSqrtPrice(
            requiredTickRange.tickRight
        );
        if (tokenUni < tokenLock) {
            // tokenUni is token0
            amountUni = AmountMath.getAmount0ForLiquidity(
                sqrtPriceAX96,
                sqrtPriceBX96,
                posData.liquidity
            );
        } else {
            // tokenUni is token1
            amountUni = AmountMath.getAmount1ForLiquidity(
                sqrtPriceAX96,
                sqrtPriceBX96,
                posData.liquidity
            );
        }
    }

    function mintWithExistingNFT(uint256 uniPositionID, uint256 uniMultiplier)
        external
        returns (uint256 miningID)
    {
        require(uniMultiplier < 3, "M<3");
        IERC721(nftManager).safeTransferFrom(
            msg.sender,
            address(this),
            uniPositionID
        );

        TickRange memory tickRange = _getTickRange();
        uint256 amountUni = _checkNFTAndGetAmountUni(uniPositionID, tickRange);
        uint256 amountLock = _getAmountLock(
            tickRange.sqrtPriceX96,
            amountUni * uniMultiplier
        );

        IERC20(tokenLock).safeTransferFrom(
            address(msg.sender),
            address(this),
            amountLock
        );

        miningID = miningNum++;
        MiningInfo storage miningInfo = miningInfos[miningID];
        miningInfo.isUniPositionIDExternal = true;

        _newMiningInfo(miningInfo, amountLock, amountUni * uniMultiplier);

        addr2MiningIDs[msg.sender].add(miningID);
        miningOwner[miningID] = msg.sender;

        emit Mint(miningID, address(msg.sender), amountUni, amountLock);
    }

    function mint(
        uint256 amountUni,
        uint256 uniMultiplier,
        uint256 deadline
    ) external returns (uint256 miningID) {
        require(uniMultiplier < 3, "M<3");

        IERC20(tokenUni).safeTransferFrom(
            address(msg.sender),
            address(this),
            amountUni
        );

        TickRange memory tickRange = _getTickRange();
        uint256 amountLock = _getAmountLock(
            tickRange.sqrtPriceX96,
            amountUni * uniMultiplier
        );
        IERC20(tokenLock).safeTransferFrom(
            address(msg.sender),
            address(this),
            amountLock
        );

        miningID = miningNum++;
        MiningInfo storage miningInfo = miningInfos[miningID];

        IERC20(tokenUni).safeApprove(nftManager, amountUni);
        INonfungiblePositionManager.MintParams
            memory uniParams = _mintUniswapParam(
                amountUni,
                tickRange.tickLeft,
                tickRange.tickRight,
                deadline
            );
        uint256 actualAmountUni;

        miningInfo.isUniPositionIDExternal = false;

        if (tokenUni < tokenLock) {
            uint256 amount1;
            (
                miningInfo.uniPositionID,
                miningInfo.uniLiquidity,
                actualAmountUni,
                amount1
            ) = INonfungiblePositionManager(nftManager).mint(uniParams);
            require(actualAmountUni <= amountUni, "Uniswap ActualUni Exceed!");
            require(amount1 == 0, "Uniswap No AmountStaking!");
        } else {
            uint256 amount0;
            (
                miningInfo.uniPositionID,
                miningInfo.uniLiquidity,
                amount0,
                actualAmountUni
            ) = INonfungiblePositionManager(nftManager).mint(uniParams);
            require(actualAmountUni <= amountUni, "Uniswap ActualUni Exceed!");
            require(amount0 == 0, "Uniswap No AmountStaking!");
        }
        IERC20(tokenUni).safeApprove(nftManager, 0);
        if (actualAmountUni < amountUni) {
            // refund
            IERC20(tokenUni).safeTransfer(
                address(msg.sender),
                amountUni - actualAmountUni
            );
        }
        _newMiningInfo(miningInfo, amountLock, actualAmountUni * uniMultiplier);

        addr2MiningIDs[msg.sender].add(miningID);
        miningOwner[miningID] = msg.sender;

        emit Mint(miningID, address(msg.sender), actualAmountUni, amountLock);
    }

    function collect(uint256 miningID, address recipient)
        external
        checkMiningOwner(miningID)
        returns (
            uint256 amountUni,
            uint256 amountLock,
            uint256 amountReward
        )
    {
        if (recipient == address(0)) {
            recipient = msg.sender;
        }
        MiningInfo storage miningInfo = miningInfos[miningID];

        amountReward = _collect(recipient, miningInfo, false);

        INonfungiblePositionManager.CollectParams
            memory params = _collectUniswapParam(
                miningInfo.uniPositionID,
                recipient
            );

        if (tokenUni < tokenLock) {
            (amountUni, amountLock) = INonfungiblePositionManager(nftManager)
                .collect(params);
        } else {
            (amountLock, amountUni) = INonfungiblePositionManager(nftManager)
                .collect(params);
        }

        emit Collect(miningID, recipient, amountUni, amountLock, amountReward);
    }

    function withdraw(
        uint256 miningID,
        address recipient,
        uint256 deadline,
        bool emergency
    )
        external
        checkMiningOwner(miningID)
        returns (
            uint256 amountUni,
            uint256 amountLock,
            uint256 amountReward
        )
    {
        if (recipient == address(0)) {
            recipient = msg.sender;
        }
        MiningInfo storage miningInfo = miningInfos[miningID];

        uint256 amountUniFromSwap = 0;
        uint256 amountLockFromSwap = 0;

        if (!miningInfo.isUniPositionIDExternal) {
            INonfungiblePositionManager.DecreaseLiquidityParams
                memory decUniParams = _withdrawUniswapParam(
                    miningInfo.uniPositionID,
                    miningInfo.uniLiquidity,
                    deadline
                );
            INonfungiblePositionManager.CollectParams
                memory collectUniParams = _collectUniswapParam(
                    miningInfo.uniPositionID,
                    recipient
                );
            if (tokenUni < tokenLock) {
                INonfungiblePositionManager(nftManager).decreaseLiquidity(
                    decUniParams
                );
                (
                    amountUniFromSwap,
                    amountLockFromSwap
                ) = INonfungiblePositionManager(nftManager).collect(
                    collectUniParams
                );
            } else {
                INonfungiblePositionManager(nftManager).decreaseLiquidity(
                    decUniParams
                );
                (
                    amountLockFromSwap,
                    amountUniFromSwap
                ) = INonfungiblePositionManager(nftManager).collect(
                    collectUniParams
                );
            }
        } else {
            IERC721(nftManager).safeTransferFrom(
                address(this),
                recipient,
                miningInfo.uniPositionID
            );
        }
        miningInfo.uniLiquidity = 0;

        (amountReward, amountLock) = _withdraw(
            recipient,
            miningInfo,
            emergency
        );

        amountUni = amountUniFromSwap;
        amountLock += amountLockFromSwap;

        addr2MiningIDs[msg.sender].remove(miningID);
        emit Withdraw(miningID, recipient, amountUni, amountLock, amountReward);
    }
}