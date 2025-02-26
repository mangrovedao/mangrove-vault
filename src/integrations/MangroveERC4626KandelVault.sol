import {MangroveVault, AbstractKandelSeeder} from "../MangroveVault.sol";

contract MangroveERC4626KandelVault is MangroveVault {
  constructor(
    AbstractKandelSeeder _seeder,
    address _BASE,
    address _QUOTE,
    uint256 _tickSpacing,
    uint8 _decimals,
    string memory name,
    string memory symbol,
    address _oracle,
    address _owner
  ) MangroveVault(_seeder, _BASE, _QUOTE, _tickSpacing, _decimals, name, symbol, _oracle, _owner) {}

  /// @notice Sets the vault for a given token.
  /// @dev This function can only be called by the admin.
  /// @param token The token for which the vault is being set.
  /// @param vault The vault to be set for the token.
  function setVaultForToken(IERC20 token, IERC4626 vault) external virtual onlyAdmin {
    ERC4626Router(vaults[token]).setVaultForToken(token, vault);
  }

  /// @notice Allows the admin to withdraw tokens from the vault.
  /// @dev This function can only be called by the admin.
  /// @param token The token to be withdrawn.
  /// @param amount The amount of tokens to be withdrawn.
  /// @param recipient The address to which the tokens will be sent.
  function adminWithdrawTokens(IERC20 token, uint amount, address recipient) public onlyAdmin {
    kandel.adminWithdrawTokens(token, amount, recipient);
  }

  /// @notice Allows the admin to withdraw native tokens from the vault.
  /// @dev This function can only be called by the admin.
  /// @param amount The amount of native tokens to be withdrawn.
  /// @param recipient The address to which the native tokens will be sent.
  function adminWithdrawNative(uint amount, address recipient) public onlyAdmin {
    kandel.adminWithdrawNative(amount, recipient);
  }
}
