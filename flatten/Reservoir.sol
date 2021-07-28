// Dependency file: contracts/EIP20Interface.sol

// SPDX-License-Identifier: UNLICENSED
// pragma solidity >=0.8.4;

/**
 * @title ERC 20 Token Standard Interface
 *  https://eips.ethereum.org/EIPS/eip-20
 */
interface EIP20Interface {
    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function decimals() external view returns (uint8);

    /**
     * @notice Get the total number of tokens in circulation
     * @return The supply of tokens
     */
    function totalSupply() external view returns (uint256);

    /**
     * @notice Gets the balance of the specified address
     * @param owner The address from which the balance will be retrieved
     * @return balance The balance
     */
    function balanceOf(address owner) external view returns (uint256 balance);

    /**
     * @notice Transfer `amount` tokens from `msg.sender` to `dst`
     * @param dst The address of the destination account
     * @param amount The number of tokens to transfer
     * @return success Whether or not the transfer succeeded
     */
    function transfer(address dst, uint256 amount)
        external
        returns (bool success);

    /**
     * @notice Transfer `amount` tokens from `src` to `dst`
     * @param src The address of the source account
     * @param dst The address of the destination account
     * @param amount The number of tokens to transfer
     * @return success Whether or not the transfer succeeded
     */
    function transferFrom(
        address src,
        address dst,
        uint256 amount
    ) external returns (bool success);

    /**
     * @notice Approve `spender` to transfer up to `amount` from `src`
     * @dev This will overwrite the approval amount for `spender`
     *  and is subject to issues noted [here](https://eips.ethereum.org/EIPS/eip-20#approve)
     * @param spender The address of the account which may transfer tokens
     * @param amount The number of tokens that are approved (-1 means infinite)
     * @return success Whether or not the approval succeeded
     */
    function approve(address spender, uint256 amount)
        external
        returns (bool success);

    /**
     * @notice Get the current allowance from `owner` for `spender`
     * @param owner The address of the account which owns the tokens to be spent
     * @param spender The address of the account which may transfer tokens
     * @return remaining The number of tokens allowed to be spent (-1 means infinite)
     */
    function allowance(address owner, address spender)
        external
        view
        returns (uint256 remaining);

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 amount
    );
}


// Root file: contracts/Reservoir.sol

pragma solidity >=0.8.4;

/**
 * @title Reservoir Contract
 * @notice Distributes a token to a different contract at a fixed rate.
 * @dev This contract must be poked via the `drip()` function every so often.
 * @author tropykus
 */
contract Reservoir {
    /// @notice The block number when the Reservoir started (immutable)
    uint256 public dripStart;

    /// @notice Tokens per block that to drip to target (immutable)
    uint256 public dripRate;

    /// @notice Reference to token to drip (immutable)
    EIP20Interface public token;

    /// @notice Target to receive dripped tokens (immutable)
    address public target;

    /// @notice Amount that has already been dripped
    uint256 public dripped;

    /**
     * @notice Constructs a Reservoir
     * @param dripRate_ Numer of tokens per block to drip
     * @param token_ The token to drip
     * @param target_ The recipient of dripped tokens
     */
    constructor(
        uint256 dripRate_,
        EIP20Interface token_,
        address target_
    ) {
        dripStart = block.number;
        dripRate = dripRate_;
        token = token_;
        target = target_;
        dripped = 0;
    }

    /**
     * @notice Drips the maximum amount of tokens to match the drip rate since inception
     * @dev Note: this will only drip up to the amount of tokens available.
     * @return The amount of tokens dripped in this call
     */
    function drip() public returns (uint256) {
        // First, read storage into memory
        EIP20Interface token_ = token;
        uint256 reservoirBalance_ = token_.balanceOf(address(this)); // TODO: Verify this is a static call
        uint256 dripRate_ = dripRate;
        uint256 dripStart_ = dripStart;
        uint256 dripped_ = dripped;
        address target_ = target;
        uint256 blockNumber_ = block.number;

        // Next, calculate intermediate values
        uint256 dripTotal_ = mul(
            dripRate_,
            blockNumber_ - dripStart_,
            "dripTotal overflow"
        );
        uint256 deltaDrip_ = sub(dripTotal_, dripped_, "deltaDrip underflow");
        uint256 toDrip_ = min(reservoirBalance_, deltaDrip_);
        uint256 drippedNext_ = add(dripped_, toDrip_, "tautological");

        // Finally, write new `dripped` value and transfer tokens to target
        dripped = drippedNext_;
        token_.transfer(target_, toDrip_);

        return toDrip_;
    }

    /* Internal helper functions for safe math */

    function add(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, errorMessage);
        return c;
    }

    function sub(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;
        return c;
    }

    function mul(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }
        uint256 c = a * b;
        require(c / a == b, errorMessage);
        return c;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a <= b) {
            return a;
        } else {
            return b;
        }
    }
}

// import "contracts/EIP20Interface.sol";
