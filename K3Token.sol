// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@openzeppelin/token/ERC20/extensions/ERC20Permit.sol";
import "./interfaces/IPlayerWorld.sol";

/**
 * @title K3Token
 * @dev Implementation of the Kredit3 Token.
 * Kredit3 Token is a ERC20 token with:
 *
 *    - a cap of 1 billion tokens,
 *    - 1 decimal,
 *    - 3% fee on each `mint`/`burn` to the feeTo address,
 *    - mint price is `integral(price(x), x=a..b) , price(x) = ln(0.00000002*x+1)/25 ` (a, b) is the mint range.
 *    - only player can mint if total supply is less than 10M.
 *    - player can mint at most 100K K3 if total supply is less than 10M.
 */
contract K3Token is ERC20Permit {
    event Mint(address indexed to, uint256 amount, uint256 price);
    event Burn(address indexed from, uint256 amount, uint256 price);

    uint256 private constant f64 = 1 << 64;
    uint256 public constant cap = 1_000_000_000 * 1e18; // 1 billion
    uint256 private constant FEE_RATE = 3; // 3%
    address public immutable feeTo;
    address public immutable controller;

    constructor(address controller_, address feeTo_) ERC20Permit("Kredit3 Token") ERC20("Kredit3 Token", "K3") {
        require(controller_ != address(0), "K3: controller is zero address");
        require(feeTo_ != address(0), "K3: feeTo is zero address");
        feeTo = feeTo_;
        controller = controller_;
        _mint(address(this), 1e18); // mint 1 K3 to this contract
    }

    // @dev returns the price of minting `amount` K3 and fee.
    function getMintPrice(uint256 amount) public view returns (uint256 price, uint256 fee) {
        uint256 total = totalSupply();
        price = _cumulativeSum(total, total + amount);
        fee = 0; // ignore
    }

    // @dev returns the price of burning `amount` K3 and fee.
    function getBurnPrice(uint256 amount) public view returns (uint256 price, uint256 fee) {
        uint256 total = totalSupply();
        require(total >= amount, "K3: amount is too high");
        price = _cumulativeSum(total - amount, total);
        fee = 0; // ignore
    }

    /**
     * @dev Mint K3 to `msg.sender` at price `getMintPrice(amount)`.
     *
     *   1. msg.sender MUST pay at least `getMintPrice(amount)`.
     *      The excess bnb will be returned to `msg.sender`.
     *   2. msg.sender's K3 MUST be less than 100000 and sender MUST be a player if total supply is less than 10_000_000.
     * @param amount The amount of K3 to mint.
     */
    function mint(uint256 amount) external payable {
        require(amount >= 1e16, "K3: mint amount must be >= 0.01");

        uint256 total = totalSupply();
        require(total + amount <= cap, "K3: cap exceeded");

        (uint256 price,) = getMintPrice(amount);
        require(price > 0, "K3: price is zero");
        require(msg.value >= price, "K3: insufficient payment");
        uint256 fee = amount * FEE_RATE / 100;
        _mint(feeTo, fee);
        _mint(msg.sender, amount - fee);

        if (msg.value > price) _safeTransferETH(msg.sender, msg.value - price);

        emit Mint(msg.sender, amount, price);
    }

    /**
     * @dev Burn `amount` K3 from `msg.sender` at price `getBurnPrice(amount)`.
     */
    function burn(uint256 amount) external {
        require(amount > 0, "K3: amount is zero");

        uint256 fee = amount * FEE_RATE / 100;
        uint256 burnAmount = amount - fee;
        (uint256 price,) = getBurnPrice(burnAmount);
        require(price > 0, "K3: price is zero");
        _transfer(msg.sender, feeTo, fee);
        _burn(msg.sender, burnAmount);
        _safeTransferETH(msg.sender, price);
        emit Burn(msg.sender, amount, price);
    }

    // @dev calculate the value of K3 at range [a, b]
    //      price(x) = ln(0.00000002*x+1) * 25
    // cumulative sum = integral(price(x), x=a..b)
    function _cumulativeSum(uint256 a, uint256 b) internal pure returns (uint256) {
        require(a <= b, "K3: invalid range");
        uint256 a64 = a * f64 / 1e18 / 50000000 + f64;
        uint256 b64 = b * f64 / 1e18 / 50000000 + f64;
        uint256 a18 = a / 50000000 + 1e18;
        uint256 b18 = b / 50000000 + 1e18;
        return (a18 + b18 * _lnX64(b64) / f64 - b18 - a18 * _lnX64(a64) / f64) * 1250000000;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0) && to != address(this) && to != feeTo) {
            _requireIsPlayer(to);

            // if total supply is less than 10M,  player can mint at most 100K K3.
            if (totalSupply() <= 10_000_000 * 1e18) {
                require(balanceOf(to) + value <= 100_000 * 1e18, "K3: your balance is too high");
            }
        }
        super._update(from, to, value);
    }

    /**
     * Calculate natural logarithm of x.  Revert if x <= 0.
     *
     * @param x signed 64.64-bit fixed point number
     * @return signed 64.64-bit fixed point number
     */
    function _lnX64(uint256 x) internal pure returns (uint256) {
        unchecked {
            return _log_2(x) * 0xB17217F7D1CF79ABC9E3B39803F2F6AF >> 128;
        }
    }

    /**
     * Calculate binary logarithm of x.  Revert if x <= 0.
     *
     * @param x signed 64.64-bit fixed point number
     * @return signed 64.64-bit fixed point number
     */
    function _log_2(uint256 x) internal pure returns (uint256) {
        unchecked {
            require(x > 0 && x <= 1 << 128);

            int256 msb = 0;
            int256 xc = int256(x);
            if (xc >= 0x10000000000000000) {
                xc >>= 64;
                msb += 64;
            }
            if (xc >= 0x100000000) {
                xc >>= 32;
                msb += 32;
            }
            if (xc >= 0x10000) {
                xc >>= 16;
                msb += 16;
            }
            if (xc >= 0x100) {
                xc >>= 8;
                msb += 8;
            }
            if (xc >= 0x10) {
                xc >>= 4;
                msb += 4;
            }
            if (xc >= 0x4) {
                xc >>= 2;
                msb += 2;
            }
            if (xc >= 0x2) msb += 1; // No need to shift xc anymore

            int256 result = msb - 64 << 64;
            uint256 ux = x << uint256(127 - msb);
            for (int256 bit = 0x8000000000000000; bit > 0; bit >>= 1) {
                ux *= ux;
                uint256 b = ux >> 255;
                ux >>= 127 + b;
                result += bit * int256(b);
            }
            assert(result >= 0);
            return uint256(result);
        }
    }

    function _safeTransferETH(address to, uint256 amount) internal {
        if (amount == 0) return;
        require(address(this).balance >= amount, "K3: insufficient balance");
        require(to != address(0), "K3: transfer to zero address");
        bool success;
        assembly {
            // Transfer the ETH and store if it succeeded or not.
            success := call(gas(), to, amount, 0, 0, 0, 0)
        }
        require(success, "K3: MAP transfer failed");
    }

    function _requireIsPlayer(address player) private view {
        // check if msg.sender is a player and ignore error
        try IPlayerWorld(controller).isPlayer(player) returns (bool yes) {
            require(yes, "K3: receiver are not a player");
        } catch {}
    }
}
