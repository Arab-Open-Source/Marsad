defmodule Marsad.Fleet.ServicesDockerTest do
  use Marsad.DataCase, async: false

  alias Marsad.Fleet.Services

  test "action_past maps actions to English past tense" do
    assert Services.action_past("start") == "started"
    assert Services.action_past("stop") == "stopped"
    assert Services.action_past("restart") == "restarted"
    assert Services.action_past("remove") == "removed"
    assert "start" in Services.docker_actions()
  end

  test "docker_action rejects unknown actions without SSH" do
    assert Services.docker_action(1, "rm", "web") == {:error, :invalid_action}
    assert Services.docker_action(1, "delete", "web") == {:error, :invalid_action}
    assert Services.compose_action(1, "/x/y.yml", "explode", "web") == {:error, :invalid_action}
  end

  test "parse_docker_images extracts rows, skips garbage" do
    out = """
    {"Repository":"nginx","Tag":"latest","ID":"abc123def456","CreatedSince":"2 weeks ago","Size":"188MB"}
    {"Repository":"redis","Tag":"7","ID":"f6e5d4","CreatedAt":"2026-01-01","Size":"117MB"}
    not-json
    """

    assert [
             %{repository: "nginx", tag: "latest", id: "abc123def456", size: "188MB"},
             %{repository: "redis", tag: "7"}
           ] = Services.parse_docker_images(out)

    assert Services.parse_docker_images("") == []
  end

  test "parse_compose_json handles arrays and line-delimited objects" do
    array = ~s([{"Name":"shop","Status":"running","ConfigFiles":"/srv/shop/compose.yml"}])

    assert [%{name: "shop", status: "running", config: "/srv/shop/compose.yml"}] =
             Services.parse_compose_json(array, fn m ->
               %{name: m["Name"], status: m["Status"], config: m["ConfigFiles"]}
             end)

    lines = ~s({"Name":"a","Status":"exited"}\ngarbage\n)
    assert [%{name: "a"}] = Services.parse_compose_json(lines, fn m -> %{name: m["Name"]} end)
    assert Services.parse_compose_json("garbage\n", fn m -> m end) == []
    assert Services.parse_compose_json("", fn m -> m end) == []
  end

  test "audit trail records and lists newest-first" do
    {:ok, server} =
      Marsad.Fleet.create_server(%{
        name: "audit-#{System.unique_integer([:positive])}",
        host: "127.0.0.1",
        port: 22,
        username: "root",
        auth_type: "password"
      })

    assert Services.list_audit(server.id) == []

    assert :ok = Services.audit(server.id, "docker_start", "web", "ok")
    assert :ok = Services.audit(server.id, "docker_stop", "web", "ok")

    [first, second] = Services.list_audit(server.id)
    assert first.action == "docker_stop"
    assert second.action == "docker_start"
    assert first.server_id == server.id

    assert Services.list_audit(-999) == []
    assert Services.list_audit(server.id, 1) |> length() == 1
  end

  test "docker_logs validates names without SSH" do
    assert Services.docker_logs(1, "bad name") == {:error, :invalid_name}
    assert Services.docker_rmi(1, "bad name") == {:error, :invalid_name}
    assert Services.docker_logs_download(1, "bad name") == {:error, :invalid_name}
    assert Services.max_log_download() == 5_000_000
  end
end
