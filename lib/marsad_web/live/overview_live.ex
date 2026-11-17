defmodule MarsadWeb.OverviewLive do
  @moduledoc "Fleet-wide landing page: server health, latest metrics and recent activity."

  use MarsadWeb, :live_view

  import Ecto.Query, warn: false

  alias Marsad.AuditLog
  alias Marsad.Fleet
  alias Marsad.Metrics
  alias Marsad.Repo

  @impl true
  def mount(_params, _session, socket) do
    servers = Fleet.list_servers()

    audits =
      Repo.all(from a in AuditLog, order_by: [desc: a.inserted_at], limit: 8, preload: :server)

    latest =
      Map.new(
        for server <- servers,
            do: {server.id, Metrics.list_snapshots(server.id, limit: 1) |> List.first()}
      )

    {:ok,
     socket
     |> assign(:page_title, "Fleet Overview")
     |> assign(:servers, servers)
     |> assign(:audits, audits)
     |> assign(:latest, latest)}
  end

  defp pct(nil, _total), do: nil
  defp pct(_used, nil), do: nil
  defp pct(used, total) when total > 0, do: round(used / total * 100)
  defp pct(_, _), do: nil

  defp load_pct(snapshot) when is_nil(snapshot), do: nil

  defp load_pct(snapshot) do
    cores = max(snapshot.cores || 1, 1)
    round(min((snapshot.load1 || 0) / cores * 100, 200))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="overview-page" class="mx-auto w-full max-w-7xl px-4 py-8 sm:px-6">
        <div class="flex flex-wrap items-end justify-between gap-4">
          <div>
            <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
              Marsad · Fleet
            </p>
            <h1 class="mt-1 text-3xl font-bold tracking-tight">Fleet overview</h1>
            <p class="mt-1 text-sm text-base-content/60">
              Status at a glance across {@servers |> length()} managed servers.
            </p>
          </div>
          <div class="flex gap-2">
            <.link navigate={~p"/desktop"} id="overview-open-desktop" class="btn btn-primary gap-2">
              <.icon name="hero-command-line" class="size-4" /> Open desktop
            </.link>
            <.link
              navigate={~p"/snippets"}
              id="overview-open-snippets"
              class="btn btn-ghost border border-base-content/15"
            >
              Runbooks
            </.link>
            <.link
              navigate={~p"/activity"}
              id="overview-open-activity"
              class="btn btn-ghost border border-base-content/15"
            >
              Activity
            </.link>
          </div>
        </div>

        <%!-- Server cards --%>
        <div class="mt-8 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <div
            :for={server <- @servers}
            id={"overview-server-#{server.id}"}
            class="card border border-base-content/10 bg-base-100 shadow-lg"
          >
            <div class="card-body gap-3">
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <h2 class="truncate text-base font-semibold">{server.name}</h2>
                  <p class="truncate font-mono text-xs text-base-content/50">
                    {server.username}@{server.host}:{server.port}
                  </p>
                </div>
                <span class={[
                  "badge gap-1.5",
                  server.status == "online" && "badge-success",
                  server.status == "offline" && "badge-error",
                  server.status not in ["online", "offline"] && "badge-ghost"
                ]}>
                  <span class="size-1.5 rounded-full bg-current"></span>{server.status || "unknown"}
                </span>
              </div>

              <% snap = Map.get(@latest, server.id) %>
              <div class="grid grid-cols-3 gap-2 text-center">
                <div class="rounded-xl bg-base-200/60 p-2">
                  <p class="text-[10px] uppercase tracking-wide text-base-content/50">CPU</p>
                  <p class="font-mono text-sm font-semibold">{load_pct(snap) || "—"}%</p>
                </div>
                <div class="rounded-xl bg-base-200/60 p-2">
                  <p class="text-[10px] uppercase tracking-wide text-base-content/50">Disk</p>
                  <p class="font-mono text-sm font-semibold">
                    {pct(snap && snap.disk_used_mb, snap && snap.disk_total_mb) || "—"}%
                  </p>
                </div>
                <div class="rounded-xl bg-base-200/60 p-2">
                  <p class="text-[10px] uppercase tracking-wide text-base-content/50">RAM</p>
                  <p class="font-mono text-sm font-semibold">
                    {pct(snap && snap.mem_used_mb, snap && snap.mem_total_mb) || "—"}%
                  </p>
                </div>
              </div>

              <div class="flex items-center justify-between text-[11px] text-base-content/50">
                <span>
                  Last seen:
                  <%= if server.last_seen_at do %>
                    {Calendar.strftime(server.last_seen_at, "%m/%d %H:%M")}
                  <% else %>
                    never
                  <% end %>
                </span>
                <.link
                  navigate={~p"/desktop?open=terminal&server=#{server.id}"}
                  id={"overview-terminal-#{server.id}"}
                  class="link link-primary"
                >
                  Open terminal →
                </.link>
              </div>
            </div>
          </div>

          <div
            :if={@servers == []}
            id="overview-empty"
            class="card col-span-full border border-dashed border-base-content/20 bg-base-100/50"
          >
            <div class="card-body items-center text-center">
              <.icon name="hero-server-stack" class="size-10 text-base-content/30" />
              <h2 class="text-lg font-semibold">No servers yet</h2>
              <p class="text-sm text-base-content/60">
                Add a server from the desktop's Servers app to get started.
              </p>
              <.link navigate={~p"/desktop?open=servers"} class="btn btn-primary btn-sm mt-2">Add a server</.link>
            </div>
          </div>
        </div>

        <%!-- Recent activity --%>
        <div class="mt-8">
          <div class="mb-3 flex items-center justify-between">
            <h2 class="text-lg font-semibold">Recent activity</h2>
            <.link
              navigate={~p"/activity"}
              id="overview-all-activity"
              class="link link-primary text-sm"
            >
              View all →
            </.link>
          </div>
          <div
            id="overview-activity"
            class="overflow-hidden rounded-2xl border border-base-content/10 bg-base-100"
          >
            <div
              :for={log <- @audits}
              id={"overview-activity-#{log.id}"}
              class="flex items-center gap-3 border-b border-base-content/5 px-4 py-3 text-sm last:border-0"
            >
              <span class="size-2 shrink-0 rounded-full bg-[color:var(--marsad-accent)]"></span>
              <span class="font-mono text-xs text-base-content/50">
                {log.inserted_at |> Calendar.strftime("%m/%d %H:%M")}
              </span>
              <span class="font-semibold">{(log.server && log.server.name) || "deleted server"}</span>
              <span class="text-base-content/70">{log.action}</span>
              <span :if={log.container} class="truncate font-mono text-xs text-base-content/50">{log.container}</span>
            </div>
            <div :if={@audits == []} class="px-4 py-8 text-center text-sm text-base-content/50">
              No activity recorded yet.
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
