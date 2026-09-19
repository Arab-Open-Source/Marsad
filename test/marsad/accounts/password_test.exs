defmodule Marsad.Accounts.PasswordTest do
  use ExUnit.Case, async: true

  alias Marsad.Accounts.Password

  test "hash and verify round-trip" do
    hash = Password.hash("correct-horse-1")
    assert String.starts_with?(hash, "pbkdf2$")
    assert Password.verify("correct-horse-1", hash) == true
    assert Password.verify("wrong", hash) == false
  end

  test "verify rejects malformed stored values" do
    assert Password.verify("x", "garbage") == false
    assert Password.verify("x", "pbkdf2$bad$salt$hash") == false
    assert Password.verify("x", nil) == false
    assert Password.verify(nil, "pbkdf2$1$xx$yy") == false
  end

  test "hashes use random salts" do
    assert Password.hash("same") != Password.hash("same")
  end

  test "dummy_verify returns :ok" do
    assert Password.dummy_verify() == :ok
  end
end
