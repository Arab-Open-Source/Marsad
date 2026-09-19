defmodule MarsadWeb.Desktop.PanelsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MarsadWeb.Desktop.DockerPanel
  alias MarsadWeb.Desktop.NginxPanel
  alias MarsadWeb.Desktop.SystemdPanel

  defp servers, do: [%{id: 1, name: "prod-1"}]

  defp docker_state(overrides \\ %{}) do
    Map.merge(
      %{server_id: nil, data: nil, logs: nil, stats: nil, inspect: nil},
      overrides
    )
  end

  defp systemd_state(overrides \\ %{}) do
    Map.merge(
      %{
        server_id: nil,
        data: nil,
        filter: "",
        state: "all",
        sort: "name",
        logs: nil,
        unit_preview: nil
      },
      overrides
    )
  end

  defp nginx_state(overrides \\ %{}) do
    Map.merge(
      %{
        server_id: nil,
        status: nil,
        config: nil,
        error_log: nil,
        files: nil,
        files_error: false,
        files_filter: "",
        file_preview: nil,
        certs: nil,
        certs_ref: nil,
        error_log_collapsed: false
      },
      overrides
    )
  end

  test "docker panel empty, loading, data and error states" do
    html = render_component(&DockerPanel.panel/1, servers: [], state: docker_state())
    assert html =~ "docker-empty"

    html =
      render_component(&DockerPanel.panel/1,
        servers: servers(),
        state: docker_state(%{server_id: 1, data: nil})
      )

    assert html =~ "Loading containers"

    containers = [
      %{id: "abc", name: "web", image: "nginx", state: "running", status: "Up", ports: "80"}
    ]

    html =
      render_component(&DockerPanel.panel/1,
        servers: servers(),
        state: docker_state(%{server_id: 1, data: {:ok, containers}})
      )

    assert html =~ "web"
    assert html =~ "1 containers"

    html =
      render_component(&DockerPanel.panel/1,
        servers: servers(),
        state: docker_state(%{server_id: 1, data: {:error, :docker_unavailable}})
      )

    assert html =~ "docker-panel"
  end

  test "systemd panel empty, data, filter and error states" do
    html = render_component(&SystemdPanel.panel/1, servers: [], state: systemd_state())
    assert html =~ "systemd-empty"

    units = [
      %{
        unit: "nginx.service",
        load: "loaded",
        active: "active",
        sub: "running",
        description: "web"
      },
      %{
        unit: "cron.service",
        load: "loaded",
        active: "failed",
        sub: "failed",
        description: "cron"
      }
    ]

    html =
      render_component(&SystemdPanel.panel/1,
        servers: servers(),
        state: systemd_state(%{server_id: 1, data: {:ok, units}})
      )

    assert html =~ "nginx.service"
    assert html =~ "cron.service"

    html =
      render_component(&SystemdPanel.panel/1,
        servers: servers(),
        state: systemd_state(%{server_id: 1, data: {:ok, units}, filter: "nginx"})
      )

    assert html =~ "nginx.service"

    html =
      render_component(&SystemdPanel.panel/1,
        servers: servers(),
        state: systemd_state(%{server_id: 1, data: {:error, "boom"}})
      )

    assert html =~ "systemd-panel"
  end

  test "systemd journal collapses, counts and wraps" do
    logs = %{name: "nginx.service", text: "a\nb\nc", collapsed: false, wrap: false}

    html =
      render_component(&SystemdPanel.panel/1,
        servers: servers(),
        state: systemd_state(%{server_id: 1, data: {:ok, []}, logs: logs})
      )

    assert html =~ "systemd-logs-collapse"
    assert html =~ "3 lines"
    refute html =~ "whitespace-pre-wrap"

    shut =
      render_component(&SystemdPanel.panel/1,
        servers: servers(),
        state:
          systemd_state(%{
            server_id: 1,
            data: {:ok, []},
            logs: %{logs | collapsed: true, wrap: false}
          })
      )

    assert shut =~ "3 lines hidden"
    refute shut =~ "whitespace-pre-wrap"

    wrapped =
      render_component(&SystemdPanel.panel/1,
        servers: servers(),
        state:
          systemd_state(%{
            server_id: 1,
            data: {:ok, []},
            logs: %{logs | collapsed: false, wrap: true}
          })
      )

    assert wrapped =~ "whitespace-pre-wrap"
  end

  test "nginx error log collapses, counts and closes" do
    render = fn state ->
      render_component(&NginxPanel.panel/1, servers: servers(), state: nginx_state(state))
    end

    html = render.(%{server_id: 1, error_log: "e1\ne2"})
    assert html =~ "nginx-log-collapse"
    assert html =~ "2 lines"
    assert html =~ "nginx-log-close"

    shut = render.(%{server_id: 1, error_log: "e1\ne2", error_log_collapsed: true})
    assert shut =~ "2 lines hidden"
  end

  test "nginx panel empty, status and error states" do
    html = render_component(&NginxPanel.panel/1, servers: [], state: nginx_state())
    assert html =~ "nginx-empty"

    html =
      render_component(&NginxPanel.panel/1,
        servers: servers(),
        state:
          nginx_state(%{
            server_id: 1,
            status: {:ok, %{active: "active", test_ok?: true, test_output: "ok"}},
            files: [%{path: "/etc/nginx/nginx.conf", size: 100}]
          })
      )

    assert html =~ "nginx.conf"

    html =
      render_component(&NginxPanel.panel/1,
        servers: servers(),
        state: nginx_state(%{server_id: 1, status: {:error, "down"}})
      )

    assert html =~ "nginx-panel"
  end

  test "nginx certs section covers all states" do
    render = fn state ->
      render_component(&NginxPanel.panel/1, servers: servers(), state: nginx_state(state))
    end

    assert render.(%{server_id: 1}) =~ "Check certificates"

    assert render.(%{server_id: 1, certs: :loading}) =~ "Checking certificates"

    assert render.(%{server_id: 1, certs: {:error, :boom}}) =~ "Check failed"

    assert render.(%{server_id: 1, certs: {:ok, []}}) =~ "No HTTPS vhosts"

    now = DateTime.utc_now()

    certs = [
      %{
        domain: "ok.example.com",
        port: 443,
        wildcard?: false,
        expires_at: DateTime.add(now, 90 * 86_400, :second),
        days_left: 90,
        status: :ok,
        note: "expires in 90d"
      },
      %{
        domain: "soon.example.com",
        port: 443,
        wildcard?: false,
        expires_at: DateTime.add(now, 5 * 86_400, :second),
        days_left: 5,
        status: :critical,
        note: "expires in 5d"
      },
      %{
        domain: "wild.example.com",
        port: 8443,
        wildcard?: true,
        expires_at: nil,
        days_left: nil,
        status: :unknown,
        note: "check failed"
      }
    ]

    html = render.(%{server_id: 1, certs: {:ok, certs}})
    assert html =~ "ok.example.com"
    assert html =~ "1 critical"
    assert html =~ "expires in 5d"
    assert html =~ "(wildcard)"
    assert html =~ "check failed"
  end
end
