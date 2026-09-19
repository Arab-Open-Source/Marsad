defmodule MarsadWeb.Desktop.DockerPanelTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MarsadWeb.Desktop.DockerPanel

  defp servers, do: [%{id: 1, name: "prod-1"}]

  defp state(overrides) do
    Map.merge(
      %{
        server_id: 1,
        data: {:ok, []},
        tab: "containers",
        filter: "",
        status: "all",
        sort: "name",
        logs: nil,
        stats: nil,
        inspect: nil,
        busy: nil,
        images: nil,
        stacks: nil,
        expanded_stack: nil,
        stack_services: nil,
        audit: []
      },
      overrides
    )
  end

  test "status_badge translates docker states plainly" do
    assert %{label: "Running", tone: "emerald", pulse: false, health: nil} =
             DockerPanel.status_badge("running", "Up 2 hours")

    assert %{label: "Stopped", detail: "Exit code 0 · 3 days ago"} =
             DockerPanel.status_badge("exited", "Exited (0) 3 days ago")

    assert %{label: "Stopped", detail: "Exit code 137"} =
             DockerPanel.status_badge("exited", "Exited (137)")

    assert %{label: "Created", tone: "sky"} = DockerPanel.status_badge("created", "Created")
    assert %{label: "Restarting", pulse: true} = DockerPanel.status_badge("restarting", "")
    assert %{label: "Paused", tone: "amber"} = DockerPanel.status_badge("paused", "")
    assert %{label: "Dead", tone: "red"} = DockerPanel.status_badge("dead", "")
    assert %{label: "Removing", pulse: true} = DockerPanel.status_badge("removing", "")
    assert %{label: "Weird", tone: "zinc"} = DockerPanel.status_badge("weird", "")
    assert %{label: "Unknown"} = DockerPanel.status_badge(nil, nil)
  end

  test "status_badge splits health into its own pill" do
    assert %{label: "Running", detail: "Up 2 hours", health: %{label: "Healthy", tone: "emerald"}} =
             DockerPanel.status_badge("running", "Up 2 hours (healthy)")

    assert %{health: %{label: "Unhealthy", tone: "red"}} =
             DockerPanel.status_badge("running", "Up 1 minute (unhealthy)")

    assert %{health: %{label: "Starting", pulse: true}} =
             DockerPanel.status_badge("running", "Up 5 seconds (starting)")
  end

  test "badge_tone_class distinguishes tones" do
    classes = Enum.map(~w(emerald red amber sky zinc), &DockerPanel.badge_tone_class/1)
    assert Enum.all?(classes, &is_binary/1)
    assert Enum.uniq(classes) == classes
    assert DockerPanel.badge_tone_class("bogus") == DockerPanel.badge_tone_class("zinc")
  end

  test "rows show badges and health pills" do
    containers = [
      %{
        id: "a1",
        name: "web",
        image: "nginx",
        state: "running",
        status: "Up 2 hours (healthy)",
        ports: ""
      },
      %{
        id: "b2",
        name: "dead",
        image: "x",
        state: "exited",
        status: "Exited (1) yesterday",
        ports: ""
      }
    ]

    html =
      render_component(&DockerPanel.panel/1,
        servers: servers(),
        state: state(%{data: {:ok, containers}})
      )

    assert html =~ "Running"
    assert html =~ "Healthy"
    assert html =~ "Stopped"
    assert html =~ "Exit code 1"
  end

  test "filter_containers matches name/image and state" do
    list = [
      %{name: "web", image: "nginx:latest", state: "running", status: "Up", ports: ""},
      %{name: "cache", image: "redis:7", state: "exited", status: "Exited", ports: ""}
    ]

    assert length(DockerPanel.filter_containers(list, "", "all")) == 2
    assert [%{name: "web"}] = DockerPanel.filter_containers(list, "WEB", "all")
    assert [%{name: "cache"}] = DockerPanel.filter_containers(list, "redis", "all")
    assert [%{name: "web"}] = DockerPanel.filter_containers(list, "", "running")
    assert [%{name: "cache"}] = DockerPanel.filter_containers(list, "", "exited")
    assert DockerPanel.filter_containers(list, "zzz", "all") == []
  end

  test "sort_containers orders by key" do
    list = [
      %{name: "web", image: "nginx", state: "running"},
      %{name: "cache", image: "redis", state: "exited"}
    ]

    assert [%{name: "cache"}, %{name: "web"}] = DockerPanel.sort_containers(list, "name")
    assert [%{name: "web"}, %{name: "cache"}] = DockerPanel.sort_containers(list, "state")
    assert [%{name: "web"}, %{name: "cache"}] = DockerPanel.sort_containers(list, "image")
    assert [%{name: "cache"}, %{name: "web"}] = DockerPanel.sort_containers(list, "bogus")
  end

  test "inspect helpers extract sections defensively" do
    assert DockerPanel.inspect_overview(%{}) == []
    assert DockerPanel.inspect_overview(nil) == []
    assert DockerPanel.inspect_env(nil) == []
    assert DockerPanel.inspect_mounts(%{}) == []
    assert DockerPanel.inspect_networks(nil) == []

    data = %{
      "Id" => "abc123def456789",
      "Image" => "nginx:latest",
      "Created" => "2026-01-01",
      "State" => %{"Status" => "running", "Health" => %{"Status" => "healthy"}},
      "HostConfig" => %{"RestartPolicy" => %{"Name" => "always"}},
      "Config" => %{"Env" => ["A=1", "B=2"]},
      "Mounts" => [%{"Source" => "/srv", "Destination" => "/app", "Mode" => "rw"}],
      "NetworkSettings" => %{
        "Ports" => %{"80/tcp" => [%{"HostIp" => "0.0.0.0", "HostPort" => "8080"}]},
        "Networks" => %{"bridge" => %{"IPAddress" => "172.17.0.2"}}
      }
    }

    overview = DockerPanel.inspect_overview(data)
    assert {"Id", "abc123def456"} in overview
    assert {"Health", "healthy"} in overview
    assert {"Restart", "always"} in overview
    assert DockerPanel.inspect_env(data) == ["A=1", "B=2"]
    assert [{"/srv → /app", "rw"}] = DockerPanel.inspect_mounts(data)

    assert [{"Port 80/tcp", "0.0.0.0:8080"}, {"Net bridge", "172.17.0.2"}] =
             DockerPanel.inspect_networks(data)
  end

  test "containers tab renders filter row, rows and remove buttons" do
    containers = [
      %{id: "a1", name: "web", image: "nginx", state: "running", status: "Up 2h", ports: "80"},
      %{id: "b2", name: "cache", image: "redis", state: "exited", status: "Exited", ports: ""}
    ]

    html =
      render_component(&DockerPanel.panel/1,
        servers: servers(),
        state: state(%{data: {:ok, containers}})
      )

    assert html =~ "docker-filter"
    assert html =~ "container-web"
    assert html =~ "Remove"
    assert html =~ "docker-tab-images"
  end

  test "filter narrows the rendered list" do
    containers = [
      %{id: "a1", name: "web", image: "nginx", state: "running", status: "Up", ports: ""},
      %{id: "b2", name: "cache", image: "redis", state: "exited", status: "Exited", ports: ""}
    ]

    html =
      render_component(&DockerPanel.panel/1,
        servers: servers(),
        state: state(%{data: {:ok, containers}, filter: "web"})
      )

    assert html =~ "container-web"
    refute html =~ "container-cache"
  end

  test "logs section has a download link with current options" do
    logs = %{
      name: "web",
      text: "hi",
      tail: 200,
      timestamps: true,
      filter: "",
      collapsed: false,
      wrap: false
    }

    html =
      render_component(&DockerPanel.panel/1,
        servers: servers(),
        state: state(%{data: {:ok, []}, logs: logs})
      )

    assert html =~ "/docker/logs/download?server_id=1"
    assert html =~ "name=web"
    assert html =~ "timestamps=true"
  end

  test "logs collapse hides body and wrap toggles class" do
    base = %{name: "web", text: "a\nb\nc", tail: 200, timestamps: false, filter: ""}

    open =
      render_component(&DockerPanel.panel/1,
        servers: servers(),
        state: state(%{data: {:ok, []}, logs: Map.merge(base, %{collapsed: false, wrap: false})})
      )

    assert open =~ "docker-logs-collapse"
    assert open =~ "3 lines"
    refute open =~ "whitespace-pre-wrap"

    shut =
      render_component(&DockerPanel.panel/1,
        servers: servers(),
        state: state(%{data: {:ok, []}, logs: Map.merge(base, %{collapsed: true, wrap: false})})
      )

    assert shut =~ "3 lines hidden"
    refute shut =~ "whitespace-pre-wrap"

    wrapped =
      render_component(&DockerPanel.panel/1,
        servers: servers(),
        state: state(%{data: {:ok, []}, logs: Map.merge(base, %{collapsed: false, wrap: true})})
      )

    assert wrapped =~ "whitespace-pre-wrap"
  end

  test "logs section honors tail, timestamps toggle and line filter" do
    logs = %{
      name: "web",
      text: "INFO started\nERROR boom\nINFO done",
      tail: 200,
      timestamps: false,
      filter: "error",
      collapsed: false,
      wrap: false
    }

    html =
      render_component(&DockerPanel.panel/1,
        servers: servers(),
        state: state(%{data: {:ok, []}, logs: logs})
      )

    assert html =~ "ERROR boom"
    refute html =~ "INFO started"
    assert html =~ "timestamps"
  end

  test "images tab renders rows, prune and rmi" do
    images = [
      %{repository: "nginx", tag: "latest", id: "abc123", size: "188MB", created: "2 weeks ago"}
    ]

    html =
      render_component(&DockerPanel.panel/1,
        servers: servers(),
        state: state(%{tab: "images", images: {:ok, images}})
      )

    assert html =~ "docker-images"
    assert html =~ "nginx:latest"
    assert html =~ "Prune unused"
    assert html =~ "image-abc123"
  end

  test "stacks tab renders projects and expanded services" do
    projects = [%{name: "shop", status: "running(2)", config: "/srv/shop/compose.yml"}]
    services = [%{name: "shop-web-1", service: "web", state: "running", status: "Up", ports: ""}]

    html =
      render_component(&DockerPanel.panel/1,
        servers: servers(),
        state: state(%{tab: "stacks", stacks: {:ok, projects}})
      )

    assert html =~ "stack-shop"

    html =
      render_component(&DockerPanel.panel/1,
        servers: servers(),
        state:
          state(%{
            tab: "stacks",
            stacks: {:ok, projects},
            expanded_stack: "shop",
            stack_services: %{project: "shop", services: services}
          })
      )

    assert html =~ "shop-web-1"
  end

  test "activity tab renders audit entries" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    audit = [
      %{action: "docker_start", container: "web", details: "ok", inserted_at: now, server_id: 1},
      %{
        action: "docker_stop failed",
        container: "db",
        details: "boom",
        inserted_at: now,
        server_id: 1
      }
    ]

    html =
      render_component(&DockerPanel.panel/1,
        servers: servers(),
        state: state(%{tab: "activity", audit: audit})
      )

    assert html =~ "docker-activity"
    assert html =~ "docker_start"
  end

  test "busy indicator appears during actions" do
    html =
      render_component(&DockerPanel.panel/1,
        servers: servers(),
        state: state(%{data: {:ok, []}, busy: %{action: "restart", name: "web"}})
      )

    assert html =~ "docker-busy"
    assert html =~ "Restarting web"
  end
end
