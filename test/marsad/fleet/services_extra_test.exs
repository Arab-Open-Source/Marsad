defmodule Marsad.Fleet.ServicesExtraTest do
  use ExUnit.Case, async: true

  alias Marsad.Fleet.Services

  test "validate_name allow-list" do
    assert Services.validate_name("web-1") == :ok
    assert Services.validate_name("nginx.service") == :ok
    assert Services.validate_name("a@b:c+=,~-") == :ok
    assert Services.validate_name("") == {:error, :invalid_name}
    assert Services.validate_name("a b") == {:error, :invalid_name}
    assert Services.validate_name("a;b") == {:error, :invalid_name}
    assert Services.validate_name("$(rm)") == {:error, :invalid_name}
    assert Services.validate_name(nil) == {:error, :invalid_name}
    assert Services.validate_name(123) == {:error, :invalid_name}
  end

  test "parse_docker_stats extracts rows, skips garbage" do
    out = """
    {"Container":"abc123def456","Name":"web","CPUPerc":"1.2%","MemPerc":"3.4%","MemUsage":"10MiB / 1GiB","NetIO":"1kB / 2kB","BlockIO":"0B / 0B","PIDs":"3"}
    garbage
    """

    assert [%{name: "web", cpu: "1.2%", mem: "3.4%"}] = Services.parse_docker_stats(out)
    assert Services.parse_docker_stats("") == []
  end

  test "parse_systemctl tolerates short rows and garbage" do
    assert [%{unit: "a.service", description: ""}] =
             Services.parse_systemctl("a.service loaded active running\n")

    assert [%{unit: "b.service", description: ""}] =
             Services.parse_systemctl("b.service loaded active running")

    assert Services.parse_systemctl("only-two-parts") == []
    assert Services.parse_systemctl("") == []
  end

  test "parse_nginx_files skips bad sizes" do
    assert Services.parse_nginx_files("/a|10\n/b|-5\n/c|xx\nno-pipe\n") == [
             %{path: "/a", size: 10}
           ]
  end

  test "kill_process validates pid without touching SSH" do
    assert {:error, :invalid_pid} = Services.kill_process(1, "0")
    assert {:error, :invalid_pid} = Services.kill_process(1, "-5")
    assert {:error, :invalid_pid} = Services.kill_process(1, "not-a-pid")
    assert {:error, :invalid_pid} = Services.kill_process(1, "99999999")
  end

  test "docker/systemd/nginx actions reject invalid names without SSH" do
    assert {:error, :invalid_name} = Services.docker_action(1, "start", "bad name")
    assert {:error, :invalid_name} = Services.docker_logs(1, "bad;name")
    assert {:error, :invalid_name} = Services.docker_inspect(1, "")
    assert {:error, :invalid_name} = Services.systemd_action(1, "start", "a b")
    assert {:error, :invalid_name} = Services.systemd_logs(1, "$(x)")
    assert {:error, :invalid_name} = Services.systemd_unit_file(1, "a|b")
    assert {:error, :outside_nginx_root} = Services.nginx_file(1, "/etc/passwd")
  end
end
