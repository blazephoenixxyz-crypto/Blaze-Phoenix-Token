// SPDX-License-Identifier: MIT
// Blaze Phoenix Token — BZPX
pragma solidity =0.8.28;

/**
 * @title Blaze Phoenix Token
 * @notice ERC-20 token — 1,000,000,000 BZPX, 18 decimals. Fixed supply, no mint after deploy,
 *         no owner, no admin functions.
 */
contract BlazePhoenix {

    // ──────────────────────────── ERC-20 state ───────────────────────────── //

    string  public constant name     = "Blaze Phoenix";
    string  public constant symbol   = "BZPX";
    uint8   public constant decimals = 18;

    uint256 private _totalSupply;

    mapping(address => uint256)                     private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // ──────────────────────────── Events ─────────────────────────────────── //

    event Transfer(address indexed from,    address indexed to,      uint256 value);
    event Approval(address indexed owner,   address indexed spender, uint256 value);

    // ──────────────────────────── Errors ─────────────────────────────────── //

    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error ERC20InvalidSender(address sender);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InvalidSpender(address spender);
    error ERC20InvalidApprover(address approver);

    // ──────────────────────────── Constructor ────────────────────────────── //

    /// @param recipient  Wallet that receives the entire supply on deploy.
    constructor(address recipient) {
        if (recipient == address(0)) revert ERC20InvalidReceiver(address(0));
        uint256 supply = 1_000_000_000 * 10 ** 18;   // 1 billion BZPX
        _totalSupply          = supply;
        _balances[recipient]  = supply;
        emit Transfer(address(0), recipient, supply);
    }

    // ──────────────────────────── ERC-20 view ────────────────────────────── //

    function totalSupply() public view returns (uint256) { return _totalSupply; }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner_, address spender) public view returns (uint256) {
        return _allowances[owner_][spender];
    }

    // ──────────────────────────── ERC-20 mutate ──────────────────────────── //

    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    /// @notice Increase allowance without the approve-race condition.
    function increaseAllowance(address spender, uint256 addedValue) public returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender] + addedValue);
        return true;
    }

    /// @notice Decrease allowance safely.
    function decreaseAllowance(address spender, uint256 subtractedValue) public returns (bool) {
        uint256 current = _allowances[msg.sender][spender];
        if (subtractedValue > current)
            revert ERC20InsufficientAllowance(spender, current, subtractedValue);
        unchecked {
            _approve(msg.sender, spender, current - subtractedValue);
        }
        return true;
    }

    /// @notice Burn tokens from caller's own balance.
    function burn(uint256 amount) public {
        uint256 bal = _balances[msg.sender];
        if (bal < amount) revert ERC20InsufficientBalance(msg.sender, bal, amount);
        unchecked {
            _balances[msg.sender] = bal - amount;
            _totalSupply         -= amount;
        }
        emit Transfer(msg.sender, address(0), amount);
    }

    // ──────────────────────────── Internal helpers ─────────────────────── //

    function _transfer(address from, address to, uint256 amount) internal {
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        if (to   == address(0)) revert ERC20InvalidReceiver(address(0));

        uint256 fromBal = _balances[from];
        if (fromBal < amount) revert ERC20InsufficientBalance(from, fromBal, amount);
        unchecked {
            _balances[from]  = fromBal - amount;
            _balances[to]   += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _approve(address owner_, address spender, uint256 amount) internal {
        if (owner_  == address(0)) revert ERC20InvalidApprover(address(0));
        if (spender == address(0)) revert ERC20InvalidSpender(address(0));
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    function _spendAllowance(address owner_, address spender, uint256 amount) internal {
        uint256 current = _allowances[owner_][spender];
        if (current != type(uint256).max) {
            if (current < amount)
                revert ERC20InsufficientAllowance(spender, current, amount);
            unchecked { _allowances[owner_][spender] = current - amount; }
        }
    }
}
