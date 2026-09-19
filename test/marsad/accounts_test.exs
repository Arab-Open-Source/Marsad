defmodule Marsad.AccountsTest do
  use Marsad.DataCase, async: false

  alias Marsad.Accounts

  test "register first admin and reject second" do
    assert Accounts.admin_exists?() == false

    assert {:ok, admin} =
             Accounts.register_admin(%{"username" => "root", "password" => "supersecret1"})

    assert admin.username == "root"
    assert Accounts.admin_exists?() == true

    assert {:error, :already_setup} =
             Accounts.register_admin(%{"username" => "x", "password" => "supersecret1"})
  end

  test "rejects short password" do
    assert {:error, %Ecto.Changeset{}} =
             Accounts.register_admin(%{"username" => "root", "password" => "short"})
  end

  test "authenticate verifies password" do
    {:ok, admin} =
      Accounts.register_admin(%{"username" => "admin", "password" => "correct-horse-1"})

    assert {:ok, found} = Accounts.authenticate("admin", "correct-horse-1")
    assert found.id == admin.id
    assert {:error, :invalid_credentials} = Accounts.authenticate("admin", "wrong")
    assert {:error, :invalid_credentials} = Accounts.authenticate("missing", "whatever")
  end

  test "update password and reset" do
    {:ok, admin} =
      Accounts.register_admin(%{"username" => "operator", "password" => "oldpassword1"})

    assert {:ok, _} = Accounts.update_password(admin, %{"password" => "newpassword1"})
    assert {:ok, _} = Accounts.authenticate("operator", "newpassword1")
    assert {:error, :invalid_credentials} = Accounts.authenticate("operator", "oldpassword1")

    :ok = Accounts.reset_all()
    assert Accounts.admin_exists?() == false
  end
end
