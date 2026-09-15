defmodule MarsadWeb.Desktop.DockerPanel do
  @moduledoc "Docker containers panel (function component; events live in DesktopLive)."
  use MarsadWeb, :html

  attr :servers, :list, required: true
  attr :state, :map, required: true

  def panel(assigns) do
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
        <button
          :if={@state.server_id}
          phx-click="docker-stats"
          title="Live stats (docker stats --no-stream)"
          class="btn btn-xs border-base-content/15 hover:bg-base-content/10"
        >
          <.icon name="hero-chart-bar" class="size-3.5" /> Stats
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
              <div
                :for={c <- containers}
                id={"container-#{c.name}"}
                class="border-b border-base-content/[0.06] px-4 py-2.5 transition hover:bg-base-content/[0.04]"
              >
                <div class="flex items-center gap-2.5">
                  <span
                    class={[
                      "size-2 shrink-0 rounded-full",
                      c.state == "running" && "bg-emerald-500",
                      c.state == "exited" && "bg-base-content/30",
                      c.state not in ["running", "exited"] && "bg-amber-500"
                    ]}
                    title={c.state}
                  />
                  <div class="min-w-0">
                    <p class="truncate font-mono text-sm font-bold">{c.name}</p>
                    <p class="truncate font-mono text-[11px] text-base-content/50">
                      {c.image} · {c.status}
                    </p>
                    <p :if={c.ports != ""} class="truncate font-mono text-[11px] text-base-content/40">
                      {c.ports}
                    </p>
                  </div>
                  <div class="ml-auto flex shrink-0 gap-1">
                    <button
                      :if={c.state != "running"}
                      phx-click="docker-action"
                      phx-value-action="start"
                      phx-value-name={c.name}
                      title={"Start #{c.name}"}
                      class="btn btn-xs border-base-content/15 text-emerald-600 hover:bg-emerald-500/10"
                    >Start</button>
                    <button
                      :if={c.state == "running"}
                      phx-click="docker-action"
                      phx-value-action="stop"
                      phx-value-name={c.name}
                      title={"Stop #{c.name}"}
                      data-confirm={"Stop #{c.name}?"}
                      class="btn btn-xs border-base-content/15 text-amber-600 hover:bg-amber-500/10"
                    >Stop</button>
                    <button
                      phx-click="docker-action"
                      phx-value-action="restart"
                      phx-value-name={c.name}
                      title={"Restart #{c.name}"}
                      data-confirm={"Restart #{c.name}?"}
                      class="btn btn-xs border-base-content/15 hover:bg-base-content/10"
                    >Restart</button>
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
      <% end %>

      <div :if={@state.logs} class="border-t border-base-content/10">
        <div class="flex items-center gap-2 bg-base-content/[0.04] px-4 py-1.5 font-mono text-[11px]">
          <span class="truncate text-base-content/70">logs · {@state.logs.name}</span>
          <button
            id="docker-logs-close"
            phx-click="docker-close-logs"
            class="ml-auto rounded p-0.5 hover:bg-base-content/10"
            aria-label="Close logs"
          >
            <.icon name="hero-x-mark" class="size-3.5" />
          </button>
        </div>
        <pre
          class="marsad-scroll max-h-56 overflow-auto bg-black/80 p-3 font-mono text-xs leading-relaxed text-slate-200"
          phx-no-curly-interpolation
        >{@state.logs.text}</pre>
      </div>

      <div :if={@state[:stats]} class="border-t border-base-content/10">
        <div class="flex items-center gap-2 bg-base-content/[0.04] px-4 py-1.5 font-mono text-[11px]">
          <span class="text-base-content/70">live stats · docker stats --no-stream</span>
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

      <div :if={@state[:inspect]} class="border-t border-base-content/10">
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
        <pre
          class="marsad-scroll max-h-64 overflow-auto bg-black/80 p-3 font-mono text-[11px] leading-relaxed text-slate-200"
          phx-no-curly-interpolation
        >{@state.inspect.data}</pre>
      </div>
    </div>
    """
  end
end
