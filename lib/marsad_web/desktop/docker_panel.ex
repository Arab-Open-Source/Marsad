defmodule MarsadWeb.Desktop.DockerPanel do
  @moduledoc "Docker containers panel (function component; events live in DesktopLive)."
  use MarsadWeb, :html

  attr :servers, :list, required: true
  attr :state, :map, required: true

  @tabs [
    %{id: "containers", name: "Containers", icon: "hero-cube"},
    %{id: "images", name: "Images", icon: "hero-photo"},
    %{id: "stacks", name: "Stacks", icon: "hero-squares-2x2"},
    %{id: "activity", name: "Activity", icon: "hero-clock"}
  ]

  def panel(assigns) do
    state =
      Map.merge(
        %{
          server_id: nil,
          data: nil,
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
        assigns.state || %{}
      )

    assigns = assigns |> assign(:state, state) |> assign(:tabs, @tabs)

    ~H"""
    <div id="docker-panel" class="marsad-scroll flex h-full min-h-0 flex-col overflow-y-auto">
      <div class="flex flex-wrap items-center gap-2 border-b border-base-content/10 px-4 py-2.5">
        <span class="acc-soft flex size-7 items-center justify-center rounded-lg">
          <.icon name="hero-cube" class="size-4" />
        </span>
        <form id="docker-server-form" phx-change="docker-server" class="flex items-center gap-1.5">
          <select
            id="docker-server-select"
            name="server_id"
            class="select select-sm select-bordered max-w-44"
            aria-label="Docker host"
          >
            <option value="">Select server…</option>
            <option :for={s <- @servers} value={s.id} selected={@state.server_id == s.id}>
              {s.name}
            </option>
          </select>
        </form>
        <button
          :if={@state.server_id}
          id="docker-refresh"
          phx-click="docker-refresh"
          title="Refresh"
          class="btn btn-xs btn-ghost border border-base-content/15 phx-click-loading:opacity-60"
        >
          <.icon name="hero-arrow-path" class="marsad-spin-target size-3.5" />
        </button>
        <span
          :if={match?({:ok, _}, @state.data)}
          class="ml-auto font-mono text-[11px] text-base-content/50"
        >
          {length(elem(@state.data, 1))} containers
        </span>
      </div>

      <div
        :if={!@state.server_id}
        id="docker-empty"
        class="flex flex-1 items-center justify-center p-8 text-center"
      >
        <div>
          <.icon name="hero-cube" class="mx-auto size-10 text-base-content/30" />
          <p class="mt-2 font-semibold">No server selected</p>
          <p class="text-sm text-base-content/60">Pick a server above to manage Docker containers.</p>
        </div>
      </div>

      <%= if @state.server_id do %>
        <%!-- Tab strip --%>
        <div
          id="docker-tabs"
          role="tablist"
          aria-label="Docker sections"
          class="flex items-center gap-1 overflow-x-auto border-b border-base-content/10 px-3 py-1.5"
        >
          <button
            :for={t <- @tabs}
            id={"docker-tab-#{t.id}"}
            role="tab"
            aria-selected={@state.tab == t.id}
            phx-click="docker-tab"
            phx-value-tab={t.id}
            class={[
              "flex shrink-0 cursor-pointer items-center gap-1.5 rounded-lg px-2.5 py-1.5 text-xs font-medium transition",
              @state.tab == t.id && "acc-soft",
              @state.tab != t.id &&
                "text-base-content/60 hover:bg-base-content/10 hover:text-base-content"
            ]}
          >
            <.icon name={t.icon} class="size-3.5" /> {t.name}
          </button>
          <span
            :if={@state.busy}
            id="docker-busy"
            class="ml-auto flex shrink-0 items-center gap-1.5 text-[11px] text-base-content/60"
          >
            <span class="loading loading-spinner loading-xs" /> {busy_text(@state.busy)}…
          </span>
        </div>

        <%= case @state.tab do %>
          <% "images" -> %>
            <.images_tab state={@state} />
          <% "stacks" -> %>
            <.stacks_tab state={@state} />
          <% "activity" -> %>
            <.activity_tab state={@state} />
          <% _ -> %>
            <.containers_tab state={@state} />
        <% end %>
      <% end %>
    </div>
    """
  end

  # -- containers tab -------------------------------------------------------------

  attr :state, :map, required: true

  defp containers_tab(assigns) do
    entries =
      case assigns.state.data do
        {:ok, containers} ->
          containers
          |> filter_containers(assigns.state.filter, assigns.state.status)
          |> sort_containers(assigns.state.sort)
          |> Enum.map(&Map.put(&1, :badge, status_badge(&1.state, &1.status)))

        _ ->
          []
      end

    assigns = assign(assigns, :entries, entries)

    ~H"""
    <div id="docker-containers">
      <%!-- Filter row (single form: any control re-submits all three) --%>
      <form
        id="docker-filter-form"
        phx-change="docker-filter"
        class="flex flex-wrap items-center gap-2 border-b border-base-content/10 px-4 py-2"
      >
        <label class="flex min-w-40 flex-1 items-center gap-2 rounded-xl border border-base-content/15 bg-base-100 px-2.5 py-1.5 transition focus-within:border-[color:var(--marsad-accent)]">
          <.icon name="hero-magnifying-glass" class="size-3.5 shrink-0 text-base-content/40" />
          <input
            id="docker-filter"
            type="search"
            name="filter"
            value={@state.filter}
            placeholder="Filter containers…"
            phx-debounce="300"
            autocomplete="off"
            class="min-w-0 grow bg-transparent text-xs outline-none placeholder:text-base-content/35"
            aria-label="Filter containers"
          />
          <button
            :if={@state.filter != ""}
            type="button"
            phx-click="docker-clear-filter"
            class="rounded p-0.5 text-base-content/40 hover:text-base-content"
            aria-label="Clear filter"
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </label>
        <select
          id="docker-status"
          name="status"
          class="select select-xs select-bordered"
          aria-label="Container state filter"
        >
          <option value="all" selected={@state.status == "all"}>All states</option>
          <option value="running" selected={@state.status == "running"}>Running</option>
          <option value="exited" selected={@state.status == "exited"}>Stopped</option>
        </select>
        <select
          id="docker-sort"
          name="sort"
          class="select select-xs select-bordered"
          aria-label="Sort containers"
        >
          <option value="name" selected={@state.sort == "name"}>Name</option>
          <option value="state" selected={@state.sort == "state"}>State</option>
          <option value="image" selected={@state.sort == "image"}>Image</option>
        </select>
      </form>

      <%= case @state.data do %>
        <% nil -> %>
          <div class="space-y-0 p-2" aria-label="Loading containers">
            <div :for={_ <- 1..5} class="flex items-center gap-3 px-2 py-2.5">
              <span class="marsad-shimmer size-4 rounded" />
              <span class="marsad-shimmer h-3.5 rounded" style="width: 28%" />
              <span class="marsad-shimmer ml-auto h-3 w-16 rounded" />
            </div>
          </div>
        <% {:error, :docker_unavailable} -> %>
          <div
            role="alert"
            class="m-4 rounded-2xl border border-amber-500/30 bg-amber-500/10 p-5 text-center text-sm"
          >
            <p class="st-warn font-semibold">Docker is unavailable</p>
            <p class="mt-1 text-base-content/60">
              Is Docker installed and the daemon running on this host?
            </p>
          </div>
        <% {:error, reason} -> %>
          <div
            role="alert"
            class="m-4 rounded-2xl border border-red-500/30 bg-red-500/10 p-5 text-center font-mono text-xs"
          >
            {inspect(reason)}
          </div>
        <% {:ok, containers} -> %>
          <div id="docker-list" class="min-h-0 flex-1 overflow-y-auto">
            <p :if={containers == []} class="p-6 text-center text-sm text-base-content/50">
              No containers on this host.
            </p>
            <p
              :if={containers != [] and @entries == []}
              class="p-6 text-center text-sm text-base-content/50"
            >
              No containers match the filter.
            </p>
            <div
              :for={c <- @entries}
              id={"container-#{c.name}"}
              class="border-b border-base-content/[0.06] px-4 py-2.5 transition hover:bg-base-content/[0.04]"
            >
              <div class="flex items-center gap-2.5">
                <div class="min-w-0 flex-1">
                  <p class="flex items-center gap-1.5">
                    <span class="truncate font-mono text-sm font-bold">{c.name}</span>
                    <span
                      class={[
                        "shrink-0 rounded-full px-1.5 py-px text-[10px] font-bold uppercase tracking-wide",
                        badge_tone_class(c.badge.tone)
                      ]}
                      title={c.badge.raw}
                    >
                      {c.badge.label}
                    </span>
                    <span
                      :if={c.badge.pulse}
                      class="size-1.5 shrink-0 animate-pulse rounded-full bg-current opacity-70"
                      aria-hidden="true"
                    />
                  </p>
                  <p class="truncate font-mono text-[11px] text-base-content/50">
                    {c.image}
                  </p>
                  <p
                    class="truncate font-mono text-[11px] text-base-content/40"
                    title={c.badge.raw}
                  >
                    {c.badge.detail}{c.ports != "" && " · #{c.ports}"}
                  </p>
                  <p :if={c.badge.health} class="mt-0.5">
                    <span class={[
                      "rounded-full px-1.5 py-px font-mono text-[10px] font-semibold",
                      badge_tone_class(c.badge.health.tone)
                    ]}>
                      {c.badge.health.label}
                    </span>
                  </p>
                </div>
                <div class="ml-auto flex shrink-0 flex-wrap justify-end gap-1">
                  <button
                    :if={c.state != "running"}
                    phx-click="docker-action"
                    phx-value-action="start"
                    phx-value-name={c.name}
                    title={"Start #{c.name}"}
                    disabled={@state.busy != nil}
                    class="btn btn-xs border-base-content/15 text-emerald-600 hover:bg-emerald-500/10 disabled:opacity-40"
                  >Start</button>
                  <button
                    :if={c.state == "running"}
                    phx-click="docker-action"
                    phx-value-action="stop"
                    phx-value-name={c.name}
                    title={"Stop #{c.name}"}
                    data-confirm={"Stop #{c.name}?"}
                    disabled={@state.busy != nil}
                    class="btn btn-xs border-base-content/15 text-amber-600 hover:bg-amber-500/10 disabled:opacity-40"
                  >Stop</button>
                  <button
                    phx-click="docker-action"
                    phx-value-action="restart"
                    phx-value-name={c.name}
                    title={"Restart #{c.name}"}
                    data-confirm={"Restart #{c.name}?"}
                    disabled={@state.busy != nil}
                    class="btn btn-xs border-base-content/15 hover:bg-base-content/10 disabled:opacity-40"
                  >Restart</button>
                  <button
                    phx-click="docker-action"
                    phx-value-action="remove"
                    phx-value-name={c.name}
                    title={"Remove #{c.name} (stops it first if running)"}
                    data-confirm={"Remove #{c.name}? This stops and deletes the container."}
                    disabled={@state.busy != nil}
                    class="btn btn-xs border-red-500/30 text-red-500 hover:bg-red-500/10 disabled:opacity-40"
                  >Remove</button>
                  <button
                    phx-click="docker-stats"
                    title="Live stats"
                    class="btn btn-xs border-base-content/15 hover:bg-base-content/10"
                  >Stats</button>
                  <button
                    phx-click="docker-inspect"
                    phx-value-name={c.name}
                    title={"Inspect #{c.name}"}
                    class="btn btn-xs border-base-content/15 hover:bg-base-content/10"
                  >Inspect</button>
                  <button
                    phx-click="docker-logs"
                    phx-value-name={c.name}
                    title={"Logs of #{c.name}"}
                    class="btn btn-xs border-base-content/15 hover:bg-base-content/10"
                  >Logs</button>
                </div>
              </div>
            </div>
          </div>
      <% end %>

      <.logs_section state={@state} />
      <.stats_section state={@state} />
      <.inspect_section state={@state} />
    </div>
    """
  end

  defp busy_text(%{action: action, name: name}) do
    past =
      case action do
        "start" -> "Starting"
        "stop" -> "Stopping"
        "restart" -> "Restarting"
        "remove" -> "Removing"
        "remove-image" -> "Removing image"
        "prune" -> "Pruning"
        _ -> "Working"
      end

    if name == "", do: past, else: "#{past} #{name}"
  end

  defp busy_text(_), do: "Working"

  # -- logs section ---------------------------------------------------------------

  attr :state, :map, required: true

  defp logs_section(%{state: %{logs: nil}} = assigns), do: ~H""

  defp logs_section(%{state: %{logs: :loading}} = assigns) do
    ~H"""
    <div class="border-t border-base-content/10 p-4" aria-label="Loading logs">
      <div class="marsad-shimmer h-3.5 rounded" style="width: 40%" />
      <div class="marsad-shimmer mt-2 h-24 rounded-xl" />
    </div>
    """
  end

  defp logs_section(assigns) do
    ~H"""
    <div class="border-t border-base-content/10">
      <div class="flex flex-wrap items-center gap-2 bg-base-content/[0.04] px-4 py-1.5 font-mono text-[11px]">
        <span class="truncate text-base-content/70">logs · {@state.logs.name}</span>
        <form id="docker-logs-tail-form" phx-change="docker-logs-tail" class="flex items-center gap-1">
          <select
            id="docker-logs-tail"
            name="tail"
            class="select select-xs select-bordered"
            aria-label="Log lines"
          >
            <option :for={n <- [50, 100, 200, 500, 1000]} value={n} selected={@state.logs.tail == n}>
              last {n}
            </option>
          </select>
        </form>
        <button
          phx-click="docker-logs-timestamps"
          title="Toggle timestamps"
          aria-pressed={to_string(@state.logs.timestamps)}
          class={[
            "rounded px-1.5 py-0.5 text-[10px] transition",
            @state.logs.timestamps && "acc-soft",
            !@state.logs.timestamps && "text-base-content/50 hover:bg-base-content/10"
          ]}
        >
          timestamps
        </button>
        <label class="flex min-w-24 flex-1 items-center gap-1 rounded-lg border border-base-content/15 bg-base-100 px-2 py-0.5">
          <.icon name="hero-magnifying-glass" class="size-3 shrink-0 text-base-content/40" />
          <input
            id="docker-logs-filter"
            type="search"
            name="filter"
            value={@state.logs.filter}
            placeholder="Filter lines…"
            phx-change="docker-logs-filter"
            phx-debounce="300"
            autocomplete="off"
            class="min-w-0 grow bg-transparent text-[11px] outline-none placeholder:text-base-content/35"
            aria-label="Filter log lines"
          />
        </label>
        <a
          id="docker-logs-download"
          href={
            ~p"/docker/logs/download?server_id=#{@state.server_id}&name=#{@state.logs.name}&timestamps=#{@state.logs.timestamps}"
          }
          download={"#{@state.logs.name}.log"}
          title="Download full logs (newest first, up to 5MB)"
          class="ml-auto flex items-center gap-1 rounded border border-base-content/15 px-1.5 py-0.5 text-[10px] text-base-content/60 transition hover:bg-sky-500/10 hover:text-sky-600"
        >
          <.icon name="hero-arrow-down-tray" class="size-3" /> Download
        </a>
        <button
          id="docker-logs-close"
          phx-click="docker-close-logs"
          class="rounded p-0.5 hover:bg-base-content/10"
          aria-label="Close logs"
        >
          <.icon name="hero-x-mark" class="size-3.5" />
        </button>
      </div>
      <pre
        class="marsad-scroll max-h-56 overflow-auto bg-black/80 p-3 font-mono text-xs leading-relaxed text-slate-200"
        phx-no-curly-interpolation
      ><%= filtered_logs(@state.logs) %></pre>
    </div>
    """
  end

  defp filtered_logs(%{text: text, filter: filter}) do
    filter = String.trim(filter || "")

    if filter == "" do
      text
    else
      text
      |> String.split("\n")
      |> Enum.filter(&String.contains?(String.downcase(&1), String.downcase(filter)))
      |> Enum.join("\n")
    end
  end

  # -- stats section ------------------------------------------------------------------

  attr :state, :map, required: true

  defp stats_section(%{state: %{stats: nil}} = assigns), do: ~H""

  defp stats_section(%{state: %{stats: :loading}} = assigns) do
    ~H"""
    <div class="border-t border-base-content/10 p-4" aria-label="Loading stats">
      <div class="marsad-shimmer h-3.5 rounded" style="width: 35%" />
      <div class="marsad-shimmer mt-2 h-20 rounded-xl" />
    </div>
    """
  end

  defp stats_section(assigns) do
    ~H"""
    <div class="border-t border-base-content/10">
      <div class="flex items-center gap-2 bg-base-content/[0.04] px-4 py-1.5 font-mono text-[11px]">
        <span class="text-base-content/70">live stats · auto-refresh</span>
        <span
          :if={@state.stats_ref}
          class="loading loading-spinner loading-xs"
          aria-label="Refreshing stats"
        />
        <button
          phx-click="docker-stats"
          class="ml-auto rounded p-0.5 hover:bg-base-content/10"
          aria-label="Refresh stats"
        >
          <.icon name="hero-arrow-path" class="size-3.5" />
        </button>
        <button
          phx-click="docker-close-stats"
          class="rounded p-0.5 hover:bg-base-content/10"
          aria-label="Close stats"
        >
          <.icon name="hero-x-mark" class="size-3.5" />
        </button>
      </div>
      <div class="marsad-scroll max-h-64 overflow-auto bg-black/80 p-2">
        <div :if={@state.stats == []} class="p-3 text-center text-xs text-slate-400">
          No stats available (is Docker running?)
        </div>
        <div
          :for={s <- @state.stats || []}
          class="flex items-center gap-2 border-b border-white/5 px-2 py-1.5 font-mono text-xs text-slate-200"
        >
          <span class="min-w-0 flex-1 truncate font-medium">{s.name}</span>
          <span class="rounded bg-white/10 px-1.5 py-0.5 text-[10px]">CPU {s.cpu}</span>
          <span class="rounded bg-white/10 px-1.5 py-0.5 text-[10px]">MEM {s.mem} ({s.mem_usage})</span>
          <span class="hidden text-[10px] text-slate-400 sm:inline">{s.net_io} · {s.block_io}</span>
        </div>
      </div>
    </div>
    """
  end

  # -- inspect section ------------------------------------------------------------------

  attr :state, :map, required: true

  defp inspect_section(%{state: %{inspect: nil}} = assigns), do: ~H""

  defp inspect_section(%{state: %{inspect: :loading}} = assigns) do
    ~H"""
    <div class="border-t border-base-content/10 p-4" aria-label="Loading inspect">
      <div class="marsad-shimmer h-3.5 rounded" style="width: 45%" />
      <div class="marsad-shimmer mt-2 h-32 rounded-xl" />
    </div>
    """
  end

  defp inspect_section(assigns) do
    ~H"""
    <div class="border-t border-base-content/10">
      <div class="flex items-center gap-2 bg-base-content/[0.04] px-4 py-1.5 font-mono text-[11px]">
        <span class="truncate text-base-content/70">inspect · {@state.inspect.name}</span>
        <button
          phx-click="docker-close-inspect"
          class="ml-auto rounded p-0.5 hover:bg-base-content/10"
          aria-label="Close inspect"
        >
          <.icon name="hero-x-mark" class="size-3.5" />
        </button>
      </div>
      <div class="space-y-3 p-4 text-xs">
        <.inspect_facts title="Overview" rows={inspect_overview(@state.inspect.data)} />
        <.inspect_facts title="Mounts" rows={inspect_mounts(@state.inspect.data)} empty="No mounts" />
        <.inspect_facts
          title="Network"
          rows={inspect_networks(@state.inspect.data)}
          empty="No network details"
        />
        <details class="rounded-xl border border-base-content/10">
          <summary class="cursor-pointer px-3 py-2 font-mono text-[11px] text-base-content/60 hover:text-base-content">
            Environment ({length(inspect_env(@state.inspect.data))} vars) · raw JSON
          </summary>
          <div class="border-t border-base-content/10 px-3 py-2">
            <p
              :for={var <- inspect_env(@state.inspect.data)}
              class="truncate font-mono text-[11px] text-base-content/70"
            >
              {var}
            </p>
            <pre
              class="marsad-scroll mt-2 max-h-64 overflow-auto rounded-lg bg-black/80 p-3 font-mono text-[11px] leading-relaxed text-slate-200"
              phx-no-curly-interpolation
            >{Jason.encode!(@state.inspect.data, pretty: true)}</pre>
          </div>
        </details>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :rows, :list, required: true
  attr :empty, :string, required: false, default: nil

  defp inspect_facts(assigns) do
    ~H"""
    <section>
      <h4 class="mb-1.5 text-[11px] font-semibold uppercase tracking-wider text-base-content/50">
        {@title}
      </h4>
      <p :if={@rows == []} class="text-base-content/50">{@empty || "—"}</p>
      <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1">
        <%= for {k, v} <- @rows do %>
          <dt class="font-mono text-base-content/50">{k}</dt>
          <dd class="truncate font-mono" title={v}>{v}</dd>
        <% end %>
      </dl>
    </section>
    """
  end

  @doc "Key facts for the inspect overview card. Pure."
  def inspect_overview(data) when is_map(data) do
    state = Map.get(data, "State", %{})

    [
      {"Id", data |> Map.get("Id", "") |> to_string() |> String.slice(0, 12)},
      {"Image", to_string(Map.get(data, "Image", ""))},
      {"Status", to_string(state["Status"] || "")},
      {"Health", get_in(state, ["Health", "Status"]) |> to_string()},
      {"Restart", get_in(data, ["HostConfig", "RestartPolicy", "Name"]) |> to_string()},
      {"Created", to_string(Map.get(data, "Created", ""))}
    ]
    |> Enum.reject(fn {_, v} -> v == "" end)
  end

  def inspect_overview(_), do: []

  @doc "Environment variables (capped at 50). Pure."
  def inspect_env(data) when is_map(data) do
    data |> get_in(["Config", "Env"]) |> List.wrap() |> Enum.take(50) |> Enum.map(&to_string/1)
  end

  def inspect_env(_), do: []

  @doc "Mounts as `{source → destination}` rows. Pure."
  def inspect_mounts(data) when is_map(data) do
    case Map.get(data, "Mounts") do
      list when is_list(list) ->
        Enum.map(list, fn m ->
          {"#{m["Source"] || "?"} → #{m["Destination"] || "?"}",
           to_string(m["Mode"] || m["RW"] || "")}
        end)

      _ ->
        []
    end
  end

  def inspect_mounts(_), do: []

  @doc "Network facts (ports + networks with IPs). Pure."
  def inspect_networks(data) when is_map(data) do
    settings = Map.get(data, "NetworkSettings", %{})
    ports = settings |> Map.get("Ports", %{}) |> format_ports()
    nets = settings |> Map.get("Networks", %{}) |> format_networks()
    ports ++ nets
  end

  def inspect_networks(_), do: []

  defp format_ports(ports) when is_map(ports) do
    Enum.map(ports, fn {container_port, bindings} ->
      host =
        case bindings do
          [%{"HostIp" => ip, "HostPort" => port} | _] -> "#{ip}:#{port}"
          _ -> "—"
        end

      {"Port #{container_port}", host}
    end)
  end

  defp format_ports(_), do: []

  defp format_networks(nets) when is_map(nets) do
    Enum.map(nets, fn {name, info} ->
      {"Net #{name}", to_string((info || %{})["IPAddress"] || "")}
    end)
  end

  defp format_networks(_), do: []

  # -- images tab -----------------------------------------------------------------

  attr :state, :map, required: true

  defp images_tab(assigns) do
    ~H"""
    <div id="docker-images" class="min-h-0 flex-1 overflow-y-auto">
      <div class="flex flex-wrap items-center gap-2 border-b border-base-content/10 px-4 py-2">
        <span :if={match?({:ok, _}, @state.images)} class="font-mono text-[11px] text-base-content/50">
          {length(elem(@state.images, 1))} images
        </span>
        <span class="ml-auto flex gap-1">
          <button
            phx-click="docker-images-refresh"
            title="Refresh images"
            class="btn btn-xs btn-ghost border border-base-content/15 phx-click-loading:opacity-60"
          >
            <.icon name="hero-arrow-path" class="marsad-spin-target size-3.5" />
          </button>
          <button
            phx-click="docker-prune"
            title="Remove unused images and stopped containers"
            data-confirm="Prune unused images and stopped containers on this host?"
            disabled={@state.busy != nil}
            class="btn btn-xs border-amber-500/30 text-amber-600 hover:bg-amber-500/10 disabled:opacity-40"
          >
            <.icon name="hero-trash" class="size-3.5" /> Prune unused
          </button>
        </span>
      </div>
      <%= case @state.images do %>
        <% nil -> %>
          <p class="p-6 text-center text-sm text-base-content/50">Loading images…</p>
        <% :loading -> %>
          <div class="space-y-0 p-2" aria-label="Loading images">
            <div :for={_ <- 1..4} class="flex items-center gap-3 px-2 py-2.5">
              <span class="marsad-shimmer size-4 rounded" />
              <span class="marsad-shimmer h-3.5 rounded" style="width: 32%" />
              <span class="marsad-shimmer ml-auto h-3 w-16 rounded" />
            </div>
          </div>
        <% {:error, :docker_unavailable} -> %>
          <div
            role="alert"
            class="m-4 rounded-2xl border border-amber-500/30 bg-amber-500/10 p-5 text-center text-sm"
          >
            <p class="st-warn font-semibold">Docker is unavailable</p>
          </div>
        <% {:error, reason} -> %>
          <div
            role="alert"
            class="m-4 rounded-2xl border border-red-500/30 bg-red-500/10 p-5 text-center font-mono text-xs"
          >
            {inspect(reason)}
          </div>
        <% {:ok, images} -> %>
          <p :if={images == []} class="p-6 text-center text-sm text-base-content/50">
            No images on this host.
          </p>
          <div
            :for={img <- images}
            id={"image-#{img.id}"}
            class="flex items-center gap-2.5 border-b border-base-content/[0.06] px-4 py-2.5"
          >
            <span class="flex size-8 shrink-0 items-center justify-center rounded-lg bg-base-content/[0.06]">
              <.icon name="hero-photo" class="size-4 text-base-content/50" />
            </span>
            <div class="min-w-0">
              <p class="truncate font-mono text-sm font-bold">{img.repository}:{img.tag}</p>
              <p class="truncate font-mono text-[11px] text-base-content/50">
                {img.id} · {img.size} · {img.created}
              </p>
            </div>
            <button
              phx-click="docker-rmi"
              phx-value-id={img.id}
              title={"Remove image #{img.repository}:#{img.tag}"}
              data-confirm={"Remove image #{img.repository}:#{img.tag}?"}
              disabled={@state.busy != nil}
              class="btn btn-xs ml-auto shrink-0 border-red-500/30 text-red-500 hover:bg-red-500/10 disabled:opacity-40"
            >Remove</button>
          </div>
      <% end %>
    </div>
    """
  end

  # -- stacks tab -------------------------------------------------------------------

  attr :state, :map, required: true

  defp stacks_tab(assigns) do
    projects =
      case assigns.state.stacks do
        {:ok, list} ->
          Enum.map(list, fn p ->
            badge =
              if String.contains?(to_string(p.status), "running"),
                do: status_badge("running", p.status),
                else: status_badge("", p.status)

            Map.put(p, :badge, badge)
          end)

        _ ->
          nil
      end

    services =
      case assigns.state.stack_services do
        %{services: list} ->
          Enum.map(list, &Map.put(&1, :badge, status_badge(&1.state, &1.status)))

        _ ->
          assigns.state.stack_services
      end

    assigns = assigns |> assign(:projects, projects) |> assign(:services, services)

    ~H"""
    <div id="docker-stacks" class="min-h-0 flex-1 overflow-y-auto">
      <div class="flex items-center gap-2 border-b border-base-content/10 px-4 py-2">
        <p class="text-[11px] text-base-content/50">Compose projects on this host</p>
        <button
          phx-click="docker-stacks-refresh"
          title="Refresh stacks"
          class="btn btn-xs btn-ghost ml-auto border border-base-content/15 phx-click-loading:opacity-60"
        >
          <.icon name="hero-arrow-path" class="marsad-spin-target size-3.5" />
        </button>
      </div>
      <%= case @state.stacks do %>
        <% nil -> %>
          <p class="p-6 text-center text-sm text-base-content/50">Loading stacks…</p>
        <% :loading -> %>
          <div class="space-y-0 p-2" aria-label="Loading stacks">
            <div :for={_ <- 1..3} class="flex items-center gap-3 px-2 py-2.5">
              <span class="marsad-shimmer size-4 rounded" />
              <span class="marsad-shimmer h-3.5 rounded" style="width: 30%" />
            </div>
          </div>
        <% {:error, :compose_unavailable} -> %>
          <div
            role="alert"
            class="m-4 rounded-2xl border border-amber-500/30 bg-amber-500/10 p-5 text-center text-sm"
          >
            <p class="st-warn font-semibold">Compose is unavailable</p>
            <p class="mt-1 text-base-content/60">Docker Compose v2 plugin not found on this host.</p>
          </div>
        <% {:error, reason} -> %>
          <div
            role="alert"
            class="m-4 rounded-2xl border border-red-500/30 bg-red-500/10 p-5 text-center font-mono text-xs"
          >
            {inspect(reason)}
          </div>
        <% {:ok, _} -> %>
          <p :if={@projects == []} class="p-6 text-center text-sm text-base-content/50">
            No compose projects on this host.
          </p>
          <div
            :for={p <- @projects}
            id={"stack-#{p.name}"}
            class="border-b border-base-content/[0.06]"
          >
            <button
              phx-click="docker-stack-toggle"
              phx-value-name={p.name}
              class="flex w-full cursor-pointer items-center gap-2.5 px-4 py-2.5 text-left transition hover:bg-base-content/[0.04]"
              aria-expanded={to_string(@state.expanded_stack == p.name)}
            >
              <span
                class={[
                  "shrink-0 rounded-full px-1.5 py-px text-[10px] font-bold uppercase tracking-wide",
                  badge_tone_class(p.badge.tone)
                ]}
                title={p.badge.raw}
              >
                {p.badge.label}
              </span>
              <span class="min-w-0 flex-1">
                <span class="block truncate font-mono text-sm font-bold">{p.name}</span>
                <span class="block truncate font-mono text-[11px] text-base-content/50">
                  {p.badge.detail} · {p.config}
                </span>
              </span>
              <.icon
                name={
                  if @state.expanded_stack == p.name,
                    do: "hero-chevron-down",
                    else: "hero-chevron-right"
                }
                class="size-4 shrink-0 text-base-content/40"
              />
            </button>
            <%= if @state.expanded_stack == p.name do %>
              <div
                :if={@services == :loading}
                class="space-y-0 px-4 pb-2"
                aria-label="Loading services"
              >
                <div :for={_ <- 1..2} class="flex items-center gap-3 px-2 py-2">
                  <span class="marsad-shimmer size-3 rounded" />
                  <span class="marsad-shimmer h-3 rounded" style="width: 40%" />
                </div>
              </div>
              <%= if is_list(@services) do %>
                <div class="border-t border-base-content/[0.06] bg-base-content/[0.02]">
                  <div
                    :for={s <- @services}
                    class="flex items-center gap-2.5 px-6 py-2"
                  >
                    <span
                      class={[
                        "shrink-0 rounded-full px-1.5 py-px text-[10px] font-bold uppercase tracking-wide",
                        badge_tone_class(s.badge.tone)
                      ]}
                      title={s.badge.raw}
                    >
                      {s.badge.label}
                    </span>
                    <div class="min-w-0 flex-1">
                      <p class="truncate font-mono text-xs font-bold">{s.service}</p>
                      <p class="truncate font-mono text-[10px] text-base-content/50">
                        {s.name} · {s.badge.detail}
                      </p>
                    </div>
                    <button
                      phx-click="docker-compose-action"
                      phx-value-service={s.service}
                      title={"Restart #{s.service}"}
                      data-confirm={"Restart service #{s.service}?"}
                      disabled={@state.busy != nil}
                      class="btn btn-xs border-base-content/15 hover:bg-base-content/10 disabled:opacity-40"
                    >Restart</button>
                  </div>
                </div>
              <% end %>
              <p
                :if={!is_list(@services) and @services != :loading}
                class="px-6 pb-3 text-xs text-base-content/50"
              >
                Services unavailable.
              </p>
            <% end %>
          </div>
      <% end %>
    </div>
    """
  end

  # -- activity tab -------------------------------------------------------------------

  attr :state, :map, required: true

  defp activity_tab(assigns) do
    ~H"""
    <div id="docker-activity" class="min-h-0 flex-1 overflow-y-auto p-4">
      <p :if={@state.audit == []} class="py-8 text-center text-sm text-base-content/50">
        No recorded Docker activity on this host yet.
      </p>
      <ol :if={@state.audit != []} class="space-y-2">
        <li
          :for={entry <- @state.audit}
          class="flex items-start gap-2.5 rounded-xl border border-base-content/10 bg-base-content/[0.03] px-3 py-2"
        >
          <span class={[
            "mt-0.5 size-2 shrink-0 rounded-full",
            entry.action =~ "failed" && "bg-red-500",
            !(entry.action =~ "failed") && "bg-emerald-500"
          ]} />
          <div class="min-w-0 flex-1">
            <p class="truncate font-mono text-xs font-bold">{entry.action} · {entry.container}</p>
            <p
              :if={entry.details not in [nil, ""]}
              class="truncate font-mono text-[11px] text-base-content/50"
            >
              {entry.details}
            </p>
          </div>
          <time class="shrink-0 font-mono text-[10px] text-base-content/40">
            {Calendar.strftime(entry.inserted_at, "%m-%d %H:%M")}
          </time>
        </li>
      </ol>
    </div>
    """
  end

  # -- status badges (unit tested) ------------------------------------------------------------

  @doc """
  Human-friendly status badge for a container or compose service. Pure.

  Turns cryptic Docker strings (`Exited (0) 3 days ago`) into a clear label,
  a tone, an optional pulsing dot and a cleaned detail line. Health
  (`(healthy)` / `(unhealthy)` / `(starting)`) becomes its own pill.
  """
  def status_badge(state, status_text) do
    text = to_string(status_text || "")
    {health, detail} = split_health(text)

    base =
      case String.downcase(to_string(state || "")) do
        "running" -> %{label: "Running", tone: "emerald", pulse: false}
        "exited" -> %{label: "Stopped", tone: "zinc", pulse: false}
        "created" -> %{label: "Created", tone: "sky", pulse: false}
        "restarting" -> %{label: "Restarting", tone: "amber", pulse: true}
        "paused" -> %{label: "Paused", tone: "amber", pulse: false}
        "dead" -> %{label: "Dead", tone: "red", pulse: false}
        "removing" -> %{label: "Removing", tone: "red", pulse: true}
        "" -> %{label: "Unknown", tone: "zinc", pulse: false}
        other -> %{label: String.capitalize(other), tone: "zinc", pulse: false}
      end

    Map.merge(base, %{
      detail: human_detail(base.label, detail),
      health: health_badge(health),
      raw: text
    })
  end

  defp split_health(text) do
    case Regex.run(~r/^(.*?)\s*\((healthy|unhealthy|starting)\)\s*$/, text) do
      [_, rest, health] -> {health, String.trim(rest)}
      _ -> {nil, text}
    end
  end

  defp health_badge(nil), do: nil
  defp health_badge("healthy"), do: %{label: "Healthy", tone: "emerald", pulse: false}
  defp health_badge("unhealthy"), do: %{label: "Unhealthy", tone: "red", pulse: false}
  defp health_badge(_), do: %{label: "Starting", tone: "sky", pulse: true}

  defp human_detail("Stopped", detail) do
    case Regex.run(~r/^Exited \((-?\d+)\)\s*(.*)$/, detail) do
      [_, code, ""] -> "Exit code #{code}"
      [_, code, rest] -> "Exit code #{code} · #{rest}"
      _ when detail == "" -> "Stopped"
      _ -> detail
    end
  end

  defp human_detail(_label, ""), do: "—"
  defp human_detail(_label, detail), do: detail

  @doc "Tailwind classes for a badge tone."
  def badge_tone_class("emerald"),
    do: "bg-emerald-500/15 text-emerald-700 ring-1 ring-emerald-500/30 dark:text-emerald-300"

  def badge_tone_class("red"),
    do: "bg-red-500/15 text-red-600 ring-1 ring-red-500/30 dark:text-red-300"

  def badge_tone_class("amber"),
    do: "bg-amber-500/15 text-amber-700 ring-1 ring-amber-500/30 dark:text-amber-300"

  def badge_tone_class("sky"),
    do: "bg-sky-500/15 text-sky-700 ring-1 ring-sky-500/30 dark:text-sky-300"

  def badge_tone_class(_),
    do: "bg-base-content/10 text-base-content/70 ring-1 ring-base-content/15"

  # -- pure list helpers (unit tested) ----------------------------------------------------

  @doc "Filters containers by name substring + state. Pure."
  def filter_containers(containers, filter, status) do
    query = filter |> to_string() |> String.trim() |> String.downcase()

    Enum.filter(containers, fn c ->
      name_ok? =
        query == "" or
          String.contains?(String.downcase(c.name), query) or
          String.contains?(String.downcase(c.image), query)

      state_ok? =
        case status do
          "running" -> c.state == "running"
          "exited" -> c.state != "running"
          _ -> true
        end

      name_ok? and state_ok?
    end)
  end

  @doc "Sorts containers (running-first for `:state`). Pure."
  def sort_containers(containers, sort) do
    case sort do
      "state" ->
        Enum.sort_by(containers, fn c -> {c.state != "running", String.downcase(c.name)} end)

      "image" ->
        Enum.sort_by(containers, fn c -> {String.downcase(c.image), String.downcase(c.name)} end)

      _ ->
        Enum.sort_by(containers, fn c -> String.downcase(c.name) end)
    end
  end
end
