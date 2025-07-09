// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract LiquidityToken is ERC20 {
    address public immutable factory;
    
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        factory = msg.sender;
    }
    
    function mint(address to, uint256 amount) external {
        require(msg.sender == factory, "Only factory");
        _mint(to, amount);
    }
    
    function burn(address from, uint256 amount) external {
        require(msg.sender == factory, "Only factory");
        _burn(from, amount);
    }
}

library SwapMath {
    uint256 public constant BASIS_POINTS = 10000;
    
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 feeRate
    ) internal pure returns (uint256) {
        require(amountIn > 0, "Insufficient input");
        require(reserveIn > 0 && reserveOut > 0, "Insufficient liquidity");
        
        uint256 amountInWithFee = amountIn * (BASIS_POINTS - feeRate);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * BASIS_POINTS) + amountInWithFee;
        
        return numerator / denominator;
    }
    
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 feeRate
    ) internal pure returns (uint256) {
        require(amountOut > 0, "Insufficient output");
        require(reserveIn > 0 && reserveOut > 0, "Insufficient liquidity");
        
        uint256 numerator = reserveIn * amountOut * BASIS_POINTS;
        uint256 denominator = (reserveOut - amountOut) * (BASIS_POINTS - feeRate);
        
        return (numerator / denominator) + 1;
    }
    
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}

contract DecentralizedExchange is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    
    struct Pool {
        address tokenA;
        address tokenB;
        uint256 reserveA;
        uint256 reserveB;
        uint256 totalSupply;
        address liquidityToken;
        uint256 feeRate;
    }
    
    mapping(bytes32 => Pool) public pools;
    mapping(address => mapping(address => bytes32)) public getPoolId;
    bytes32[] public allPools;
    
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    uint256 public defaultFeeRate = 30; // 0.3%
    
    event PoolCreated(bytes32 indexed poolId, address indexed tokenA, address indexed tokenB, address liquidityToken);
    event LiquidityAdded(bytes32 indexed poolId, address indexed provider, uint256 amountA, uint256 amountB, uint256 liquidity);
    event LiquidityRemoved(bytes32 indexed poolId, address indexed provider, uint256 amountA, uint256 amountB, uint256 liquidity);
    event Swap(bytes32 indexed poolId, address indexed user, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);
    
    constructor() Ownable(msg.sender) {}
    
    modifier poolExists(bytes32 poolId) {
        require(pools[poolId].tokenA != address(0), "Pool does not exist");
        _;
    }
    
    function createPool(address tokenA, address tokenB, uint256 feeRate) external returns (bytes32 poolId) {
        require(tokenA != tokenB, "Identical tokens");
        require(tokenA != address(0) && tokenB != address(0), "Zero address");
        require(feeRate <= 1000, "Fee rate too high");
        
        if (tokenA > tokenB) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        
        poolId = keccak256(abi.encodePacked(tokenA, tokenB));
        require(pools[poolId].tokenA == address(0), "Pool exists");
        
        string memory lpName = string(abi.encodePacked("LP-", _getTokenSymbol(tokenA), "-", _getTokenSymbol(tokenB)));
        LiquidityToken liquidityToken = new LiquidityToken(lpName, lpName);
        
        pools[poolId] = Pool({
            tokenA: tokenA,
            tokenB: tokenB,
            reserveA: 0,
            reserveB: 0,
            totalSupply: 0,
            liquidityToken: address(liquidityToken),
            feeRate: feeRate > 0 ? feeRate : defaultFeeRate
        });
        
        getPoolId[tokenA][tokenB] = poolId;
        getPoolId[tokenB][tokenA] = poolId;
        allPools.push(poolId);
        
        emit PoolCreated(poolId, tokenA, tokenB, address(liquidityToken));
    }
    
    function addLiquidity(
        bytes32 poolId,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external poolExists(poolId) nonReentrant returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        require(block.timestamp <= deadline, "Deadline exceeded");
        
        Pool storage pool = pools[poolId];
        
        (amountA, amountB) = _addLiquidity(poolId, amountADesired, amountBDesired, amountAMin, amountBMin);
        
        IERC20(pool.tokenA).safeTransferFrom(msg.sender, address(this), amountA);
        IERC20(pool.tokenB).safeTransferFrom(msg.sender, address(this), amountB);
        
        liquidity = _mint(poolId, to);
        
        emit LiquidityAdded(poolId, to, amountA, amountB, liquidity);
    }
    
    function removeLiquidity(
        bytes32 poolId,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external poolExists(poolId) nonReentrant returns (uint256 amountA, uint256 amountB) {
        require(block.timestamp <= deadline, "Deadline exceeded");
        
        Pool storage pool = pools[poolId];
        
        LiquidityToken(pool.liquidityToken).burn(msg.sender, liquidity);
        
        uint256 totalSupply = pool.totalSupply;
        amountA = (liquidity * pool.reserveA) / totalSupply;
        amountB = (liquidity * pool.reserveB) / totalSupply;
        
        require(amountA >= amountAMin, "Insufficient A");
        require(amountB >= amountBMin, "Insufficient B");
        
        pool.reserveA -= amountA;
        pool.reserveB -= amountB;
        pool.totalSupply -= liquidity;
        
        IERC20(pool.tokenA).safeTransfer(to, amountA);
        IERC20(pool.tokenB).safeTransfer(to, amountB);
        
        emit LiquidityRemoved(poolId, to, amountA, amountB, liquidity);
    }
    
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256[] memory amounts) {
        require(block.timestamp <= deadline, "Deadline exceeded");
        require(path.length >= 2, "Invalid path");
        
        amounts = getAmountsOut(amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "Insufficient output");
        
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amounts[0]);
        _swap(amounts, path, to);
    }
    
    function _addLiquidity(
        bytes32 poolId,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal view returns (uint256 amountA, uint256 amountB) {
        Pool storage pool = pools[poolId];
        
        if (pool.reserveA == 0 && pool.reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = (amountADesired * pool.reserveB) / pool.reserveA;
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, "Insufficient B");
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = (amountBDesired * pool.reserveA) / pool.reserveB;
                require(amountAOptimal >= amountAMin, "Insufficient A");
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }
    
    function _mint(bytes32 poolId, address to) internal returns (uint256 liquidity) {
        Pool storage pool = pools[poolId];
        
        uint256 balanceA = IERC20(pool.tokenA).balanceOf(address(this));
        uint256 balanceB = IERC20(pool.tokenB).balanceOf(address(this));
        uint256 amountA = balanceA - pool.reserveA;
        uint256 amountB = balanceB - pool.reserveB;
        
        uint256 totalSupply = pool.totalSupply;
        
        if (totalSupply == 0) {
            liquidity = SwapMath.sqrt(amountA * amountB) - MINIMUM_LIQUIDITY;
            LiquidityToken(pool.liquidityToken).mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            liquidity = _min((amountA * totalSupply) / pool.reserveA, (amountB * totalSupply) / pool.reserveB);
        }
        
        require(liquidity > 0, "Insufficient liquidity");
        
        LiquidityToken(pool.liquidityToken).mint(to, liquidity);
        
        pool.reserveA = balanceA;
        pool.reserveB = balanceB;
        pool.totalSupply += liquidity;
    }
    
    function _swap(uint256[] memory amounts, address[] memory path, address to) internal {
        for (uint256 i = 0; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            uint256 amountOut = amounts[i + 1];
            
            bytes32 poolId = getPoolId[input][output];
            Pool storage pool = pools[poolId];
            
            address recipient = i < path.length - 2 ? address(this) : to;
            
            if (input == pool.tokenA) {
                pool.reserveA += amounts[i];
                pool.reserveB -= amountOut;
            } else {
                pool.reserveB += amounts[i];
                pool.reserveA -= amountOut;
            }
            
            IERC20(output).safeTransfer(recipient, amountOut);
            
            emit Swap(poolId, msg.sender, input, output, amounts[i], amountOut);
        }
    }
    
    function getAmountsOut(uint256 amountIn, address[] memory path) public view returns (uint256[] memory amounts) {
        require(path.length >= 2, "Invalid path");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        
        for (uint256 i = 0; i < path.length - 1; i++) {
            bytes32 poolId = getPoolId[path[i]][path[i + 1]];
            Pool storage pool = pools[poolId];
            require(pool.tokenA != address(0), "Pool does not exist");
            
            (uint256 reserveIn, uint256 reserveOut) = path[i] == pool.tokenA
                ? (pool.reserveA, pool.reserveB)
                : (pool.reserveB, pool.reserveA);
            
            amounts[i + 1] = SwapMath.getAmountOut(amounts[i], reserveIn, reserveOut, pool.feeRate);
        }
    }
    
    function getPool(bytes32 poolId) external view returns (Pool memory) {
        return pools[poolId];
    }
    
    function getPoolByTokens(address tokenA, address tokenB) external view returns (bytes32 poolId, Pool memory pool) {
        poolId = getPoolId[tokenA][tokenB];
        pool = pools[poolId];
    }
    
    function setDefaultFeeRate(uint256 newFeeRate) external onlyOwner {
        require(newFeeRate <= 1000, "Fee rate too high");
        defaultFeeRate = newFeeRate;
    }
    
    function _getTokenSymbol(address token) internal view returns (string memory) {
        try IERC20Metadata(token).symbol() returns (string memory symbol) {
            return symbol;
        } catch {
            return "TKN";
        }
    }
    
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}