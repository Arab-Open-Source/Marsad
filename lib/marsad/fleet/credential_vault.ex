defmodule Marsad.Fleet.CredentialVault do
  @moduledoc """
  Minimal at-rest encryption for SSH secrets (passwords / private keys).

  Uses AES-256-GCM from OTP `:crypto`. The key is read from the
  `:marsad, :vault_key` application env (base64, 32 bytes). In dev/test a
  non-secret fallback key is used so the app boots with zero setup.

  > Production / single-executable builds MUST set `MARSAD_VAULT_KEY`
  > (or the Burrito first-run screen) — losing the key means losing the
  > stored credentials. A future step may swap this module for Cloak
  > without changing callers (`seal/1`, `open/1`).
  """

  @version "v1"
  @iv_bytes 12

  @doc "Encrypts a plaintext secret, returns an opaque sealed string."
  @spec seal(binary()) :: binary()
  def seal(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(@iv_bytes)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, "", true)
    Enum.join([@version, Base.encode64(iv), Base.encode64(ciphertext <> tag)], ".")
  end

  @doc "Decrypts a value produced by `seal/1`. Returns `{:ok, plaintext}` or `:error`."
  @spec open(binary()) :: {:ok, binary()} | :error
  def open(@version <> _ = sealed) do
    with [@version, iv_b64, ct_b64] <- String.split(sealed, ".", parts: 3),
         {:ok, iv} <- Base.decode64(iv_b64),
         {:ok, ct_tag} <- Base.decode64(ct_b64),
         true <- byte_size(ct_tag) > 16 do
      total = byte_size(ct_tag)
      ciphertext = binary_part(ct_tag, 0, total - 16)
      tag = binary_part(ct_tag, total - 16, 16)

      case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ciphertext, "", tag, false) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  def open(_), do: :error

  defp key do
    case Application.get_env(:marsad, :vault_key) do
      nil ->
        default_key()

      b64 when is_binary(b64) ->
        case Base.decode64(b64) do
          {:ok, bytes} when byte_size(bytes) == 32 -> bytes
          _ -> raise "Invalid :marsad, :vault_key — expected base64 of 32 bytes"
        end
    end
  end

  # Dev/test convenience only. Never rely on this in production.
  defp default_key, do: :crypto.hash(:sha256, "marsad-dev-vault-key-NOT-FOR-PRODUCTION")
end
