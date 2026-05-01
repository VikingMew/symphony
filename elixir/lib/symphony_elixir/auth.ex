defmodule SymphonyElixir.Auth do
  @moduledoc """
  Minimal username/password authentication for the local Symphony control plane.
  """

  alias SymphonyElixir.Persistence

  @iterations 210_000
  @salt_bytes 16
  @hash_bytes 32

  @spec enabled?() :: boolean()
  def enabled? do
    auth_config() |> Keyword.get(:enabled, false)
  end

  @spec configured?() :: boolean()
  def configured? do
    configured_user() != nil
  end

  @spec hash_password(String.t()) :: String.t()
  def hash_password(password) when is_binary(password) do
    salt = :crypto.strong_rand_bytes(@salt_bytes)
    hash = pbkdf2(password, salt, @iterations)

    Enum.join(
      [
        "pbkdf2_sha256",
        Integer.to_string(@iterations),
        Base.url_encode64(salt, padding: false),
        Base.url_encode64(hash, padding: false)
      ],
      "$"
    )
  end

  @spec verify(String.t(), String.t()) :: boolean()
  def verify(password, encoded) when is_binary(password) and is_binary(encoded) do
    with ["pbkdf2_sha256", iterations, salt64, hash64] <- String.split(encoded, "$"),
         {iterations, ""} <- Integer.parse(iterations),
         {:ok, salt} <- Base.url_decode64(salt64, padding: false),
         {:ok, expected} <- Base.url_decode64(hash64, padding: false) do
      actual = pbkdf2(password, salt, iterations)
      secure_compare(actual, expected)
    else
      _ -> false
    end
  end

  def verify(_password, _encoded), do: false

  @spec authenticate(String.t(), String.t()) :: {:ok, map()} | {:error, :invalid_credentials | :not_configured}
  def authenticate(username, password) when is_binary(username) and is_binary(password) do
    case configured_user() do
      %{username: ^username, password_hash: password_hash} ->
        if verify(password, password_hash), do: {:ok, %{username: username}}, else: {:error, :invalid_credentials}

      nil ->
        {:error, :not_configured}

      _other ->
        {:error, :invalid_credentials}
    end
  end

  def authenticate(_username, _password), do: {:error, :invalid_credentials}

  defp configured_user do
    config = auth_config()
    config_user(Keyword.get(config, :username), Keyword.get(config, :password_hash), Keyword.get(config, :password))
  end

  defp config_user(username, password_hash, _password)
       when is_binary(username) and is_binary(password_hash) and password_hash != "" do
    %{username: username, password_hash: password_hash}
  end

  defp config_user(username, _password_hash, password)
       when is_binary(username) and is_binary(password) and password != "" do
    %{username: username, password_hash: hash_password(password)}
  end

  defp config_user(username, _password_hash, _password) when is_binary(username) do
    case Persistence.get_user(username) do
      nil -> nil
      user -> %{username: user.username, password_hash: user.password_hash}
    end
  end

  defp config_user(_username, _password_hash, _password), do: nil

  defp auth_config do
    Application.get_env(:symphony_elixir, :auth, [])
  end

  defp pbkdf2(password, salt, iterations) do
    :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, @hash_bytes)
  end

  defp secure_compare(left, right) when byte_size(left) == byte_size(right) do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.reduce(0, fn {a, b}, acc -> Bitwise.bor(acc, Bitwise.bxor(a, b)) end)
    |> Kernel.==(0)
  end

  defp secure_compare(_left, _right), do: false
end
