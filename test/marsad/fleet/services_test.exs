defmodule Marsad.Fleet.ServicesTest do
  use ExUnit.Case, async: true

  alias Marsad.Fleet.Services

  @docker_ps """
  {"Command":"\\"nginx -g 'daemon off;'\\"","CreatedAt":"2026-09-01","ID":"a1b2c3d4e5f6","Image":"nginx:latest","Labels":"","LocalVolumes":"0","Mounts":"","Names":"web","Networks":"bridge","Ports":"0.0.0.0:80->80/tcp","RunningFor":"2 weeks ago","Size":"0B","State":"running","Status":"Up 2 weeks"}
  {"ID":"f6e5d4c3b2a1","Image":"redis:7","Names":"cache","State":"exited","Status":"Exited (0) 3 days ago","Ports":""}
  not-json-at-all
  """

  @systemctl """
  cron.service                loaded    active   running Daemon to run/SC
  docker.service              loaded    active   running Docker Application Container Engine
  nginx.service               loaded    failed   failed  A high performance web server
  """

  test "parse_docker_ps/1 extracts containers, skips garbage" do
    assert [
             %{name: "web", image: "nginx:latest", state: "running", id: "a1b2c3d4e5f6"},
             %{name: "cache", state: "exited"}
           ] = Services.parse_docker_ps(@docker_ps)
  end

  test "parse_systemctl/1 extracts units" do
    assert [
             %{unit: "cron.service", active: "active", sub: "running"},
             %{unit: "docker.service", active: "active", sub: "running"},
             %{unit: "nginx.service", active: "failed", sub: "failed"}
           ] = Services.parse_systemctl(@systemctl)
  end

  test "nginx file helpers confine paths and parse listings" do
    assert {:ok, "/etc/nginx/nginx.conf"} = Services.nginx_file_path("/etc/nginx/nginx.conf")

    assert {:ok, "/etc/nginx/sites-enabled/a"} =
             Services.nginx_file_path("/etc/nginx/conf.d/../sites-enabled/a")

    assert {:error, :outside_nginx_root} = Services.nginx_file_path("/etc/passwd")
    assert {:error, :outside_nginx_root} = Services.nginx_file_path("/etc/nginx/../../etc/shadow")
    assert {:error, :outside_nginx_root} = Services.nginx_file_path(nil)

    assert [
             %{path: "/etc/nginx/nginx.conf", size: 1447},
             %{path: "/etc/nginx/sites-enabled/app", size: 890}
           ] =
             Services.parse_nginx_files(
               "/etc/nginx/nginx.conf|1447\n/etc/nginx/sites-enabled/app|890\ngarbage\n"
             )
  end

  test "validate_name/1 blocks shell injection" do
    assert :ok = Services.validate_name("nginx.service")
    assert :ok = Services.validate_name("web-1_2.0")
    assert {:error, :invalid_name} = Services.validate_name("a; rm -rf /")
    assert {:error, :invalid_name} = Services.validate_name("a b")
    assert {:error, :invalid_name} = Services.validate_name("$(id)")
    assert {:error, :invalid_name} = Services.validate_name("")
    assert {:error, :invalid_name} = Services.validate_name(nil)
  end

  test "docker_action/3 and friends reject bad actions/names without SSH" do
    assert {:error, :invalid_name} = Services.docker_action(1, "start", "evil;cmd")
    assert {:error, :invalid_name} = Services.systemd_action(1, "stop", "a b")
    assert {:error, :invalid_name} = Services.docker_logs(1, "`id`")
  end
end
