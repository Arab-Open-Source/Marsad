defmodule Marsad.FleetPureTest do
  use Marsad.DataCase, async: false

  alias Marsad.Fleet

  test "remote_join normalizes dots without escaping root" do
    assert Fleet.remote_join("/a/b", "c") == "/a/b/c"
    assert Fleet.remote_join("/a/b", "/x/y") == "/x/y"
    assert Fleet.remote_join("/a/b", "../c") == "/a/c"
    assert Fleet.remote_join("/a", "../../..") == "/"
    assert Fleet.remote_join("/", "..") == "/"
    assert Fleet.remote_join("/a/b", "./c") == "/a/b/c"
  end

  test "remote_parent handles root and nesting" do
    assert Fleet.remote_parent("/") == "/"
    assert Fleet.remote_parent("/a") == "/"
    assert Fleet.remote_parent("/a/b") == "/a"
    assert Fleet.remote_parent("/a/b/c") == "/a/b"
  end

  test "remote_segments builds breadcrumbs" do
    assert Fleet.remote_segments("/") == []
    assert Fleet.remote_segments("/a/b") == [{"a", "/a"}, {"b", "/a/b"}]
  end

  test "open_secret and mark_seen/mark_offline lifecycle" do
    {:ok, server} =
      Fleet.create_server(%{
        name: "pure-#{System.unique_integer([:positive])}",
        host: "127.0.0.1",
        port: 22,
        username: "root",
        auth_type: "password",
        secret: "s3cr3t"
      })

    assert {:ok, "s3cr3t"} = Fleet.open_secret(server)
    assert {:ok, nil} = Fleet.open_secret(%Marsad.Fleet.Server{secret_encrypted: nil})

    assert {:ok, seen} = Fleet.mark_seen(server, "fp:123")
    assert seen.status == "online"
    assert seen.host_fingerprint == "fp:123"

    assert {:ok, off} = Fleet.mark_offline(seen)
    assert off.status == "offline"
  end

  test "create keeps old secret when blank, update stops session" do
    {:ok, server} =
      Fleet.create_server(%{
        name: "keep-#{System.unique_integer([:positive])}",
        host: "127.0.0.1",
        port: 22,
        username: "root",
        auth_type: "password",
        secret: "first"
      })

    {:ok, updated} = Fleet.update_server(server, %{"name" => "renamed"})
    assert updated.name == "renamed"
    assert {:ok, "first"} = Fleet.open_secret(updated)

    {:ok, rotated} = Fleet.update_server(updated, %{"secret" => "second"})
    assert {:ok, "second"} = Fleet.open_secret(rotated)
  end

  test "ensure_session errors for missing server" do
    assert {:error, :server_not_found} = Fleet.ensure_session(-123_456)
  end

  test "delete removes server" do
    {:ok, server} =
      Fleet.create_server(%{
        name: "del-#{System.unique_integer([:positive])}",
        host: "127.0.0.1",
        port: 22,
        username: "root",
        auth_type: "password"
      })

    assert {:ok, _} = Fleet.delete_server(server)
    assert Fleet.get_server(server.id) == nil
  end
end
