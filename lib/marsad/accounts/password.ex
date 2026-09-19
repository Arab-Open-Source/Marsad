defmodule Marsad.Accounts.Password do
  @moduledoc "PBKDF2-HMAC-SHA256 password hashing via OTP `:crypto` (no extra deps)."

  @salt_bytes 16
  @hash_bytes 32

  # Fast in test, strong in dev/prod. Overridable via config.
  defp iterations, do: Application.get_env(:marsad, :pbkdf2_iterations, 190_000)

  def hash(password) when is_binary(password) do
    salt = :crypto.strong_rand_bytes(@salt_bytes)
    iters = iterations()
    hash = :crypto.pbkdf2_hmac(:sha256, password, salt, iters, @hash_bytes)

    Enum.join(
      ["pbkdf2", Integer.to_string(iters), Base.encode64(salt), Base.encode64(hash)],
      "$"
    )
  end

  def verify(password, stored) when is_binary(password) and is_binary(stored) do
    with ["pbkdf2", iter_s, salt_b64, hash_b64] <- String.split(stored, "$"),
         {iters, ""} <- Integer.parse(iter_s),
         {:ok, salt} <- Base.decode64(salt_b64),
         {:ok, expected} <- Base.decode64(hash_b64) do
      actual = :crypto.pbkdf2_hmac(:sha256, password, salt, iters, byte_size(expected))
      compare(actual, expected)
    else
      _ -> false
    end
  end

  def verify(_, _), do: false

  def dummy_verify do
    salt = :crypto.strong_rand_bytes(@salt_bytes)
    :crypto.pbkdf2_hmac(:sha256, "dummy", salt, 1_000, @hash_bytes)
    :ok
  end

  defp compare(a, b) when byte_size(a) != byte_size(b), do: false

  defp compare(a, b) do
    :crypto.hash_equals(a, b)
  rescue
    _ -> fallback_compare(a, b)
  catch
    _, _ -> fallback_compare(a, b)
  end

  defp fallback_compare(a, b) do
    import Bitwise

    a_bytes = :binary.bin_to_list(a)
    b_bytes = :binary.bin_to_list(b)

    diff =
      Enum.zip(a_bytes, b_bytes)
      |> Enum.reduce(0, fn {x, y}, acc -> acc ||| bxor(x, y) end)

    diff == 0
  end
end
