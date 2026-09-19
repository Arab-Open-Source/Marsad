defmodule Marsad.FleetTest do
  use Marsad.DataCase, async: false

  alias Marsad.Fleet
  alias Marsad.Fleet.CredentialVault

  describe "CredentialVault" do
    test "seal/open round-trips and rejects tampering" do
      sealed = CredentialVault.seal("s3cr3t")
      assert {:ok, "s3cr3t"} = CredentialVault.open(sealed)
      assert :error = CredentialVault.open(sealed <> "tampered")
      assert :error = CredentialVault.open("garbage")
    end
  end

  describe "remote paths" do
    test "remote_join/2 normalizes . and .. without escaping root" do
      assert Fleet.remote_join("/a/b", "c") == "/a/b/c"
      assert Fleet.remote_join("/a/b", "../c") == "/a/c"
      assert Fleet.remote_join("/a", "../../etc") == "/etc"
      assert Fleet.remote_join("/", "..") == "/"
      assert Fleet.remote_join("/a/b", "/abs") == "/abs"
    end

    test "remote_parent/1 and remote_segments/1" do
      assert Fleet.remote_parent("/a/b") == "/a"
      assert Fleet.remote_parent("/") == "/"
      assert Fleet.remote_segments("/a/b") == [{"a", "/a"}, {"b", "/a/b"}]
      assert Fleet.remote_segments("/") == []
    end
  end

  describe "servers" do
    @valid %{
      name: "prod-1",
      host: "203.0.113.10",
      port: 22,
      username: "root",
      auth_type: "password",
      secret: "hunter2"
    }

    test "create_server/1 seals the secret and open_secret/1 recovers it" do
      assert {:ok, server} = Fleet.create_server(@valid)
      assert server.secret_encrypted != "hunter2"
      assert {:ok, "hunter2"} = Fleet.open_secret(server)
    end

    test "create_server/1 requires name/host/username" do
      assert {:error, changeset} = Fleet.create_server(%{})
      assert %{name: [_ | _], host: [_ | _], username: [_ | _]} = errors_on(changeset)
    end

    test "update_server/1 without :secret keeps the old sealed secret" do
      assert {:ok, server} = Fleet.create_server(@valid)
      assert {:ok, updated} = Fleet.update_server(server, %{name: "prod-2"})
      assert updated.secret_encrypted == server.secret_encrypted
      assert {:ok, "hunter2"} = Fleet.open_secret(updated)
    end

    test "delete_server/1 removes the server" do
      assert {:ok, server} = Fleet.create_server(@valid)
      assert {:ok, _} = Fleet.delete_server(server)
      assert Fleet.get_server(server.id) == nil
    end
  end
end
