defmodule MarsadWeb.Desktop.SystemdPanel do
  @moduledoc "systemd units panel (function component; events live in DesktopLive)."
  use MarsadWeb, :html

  attr :servers, :list, required: true
  attr :state, :map, required: true
  attr :appearance, :map, required: false, default: %{mode: "dark"}

  def panel(assigns) do
    state = assigns.state || %{}

    assigns =
      assigns
      |> assign_new(:filtered, fn -> [] end)
      |> then(fn a ->
        case Map.get(state, :data) do
          {:ok, units} when is_list(units) ->
            filtered =
              units
              |> filtered_units(Map.get(state, :filter, ""), Map.get(state, :state, "all"))
              |> sorted_units(Map.get(state, :sort, "name"))

            counts = count_states(units)
            assign(a, filtered: filtered, counts: counts, total: length(units))

          _ ->
            assign(a,
              filtered: [],
              counts: %{all: 0, active: 0, failed: 0, inactive: 0},
              total: 0
            )
        end
      end)
      |> assign(:unit_type, Map.get(state, :unit_type, "service"))
      |> assign(:busy, Map.get(state, :busy))
      |> assign(:auto_refresh, Map.get(state, :auto_refresh, false))
      |> assign(:last_refreshed_at, Map.get(state, :last_refreshed_at))
      |> assign(:data_ref, Map.get(state, :data_ref))
      |> assign(:detail, Map.get(state, :detail))
      |> assign(:detail_ref, Map.get(state, :detail_ref))
      |> assign(:create, Map.get(state, :create))
      |> assign(:create_ref, Map.get(state, :create_ref))

    ~H"""
    <div id="systemd-panel" class="marsad-scroll flex h-full min-h-0 flex-col overflow-y-auto">
      <%!-- Header: server select + actions + filter --%>
      <div class="flex flex-wrap items-center gap-2 border-b border-base-content/10 px-4 py-2.5">
        <span class="acc-soft flex size-7 items-center justify-center rounded-lg">
          <.icon name="hero-adjustments-horizontal" class="size-4" />
        </span>
        <form id="systemd-server-form" phx-change="systemd-server" class="flex items-center gap-1.5">
          <select
            id="systemd-server-select"
            name="server_id"
            class="select select-sm select-bordered max-w-44"
            aria-label="systemd host"
          >
            <option value="">Select server…</option>
            <option :for={s <- @servers} value={s.id} selected={Map.get(@state, :server_id) == s.id}>
              {s.name}
            </option>
          </select>
        </form>
        <div :if={Map.get(@state, :server_id) != nil} class="flex items-center gap-1.5">
          <button
            type="button"
            id="systemd-refresh"
            phx-click="systemd-refresh"
            title="Refresh"
            class={[
              "btn btn-xs btn-ghost border border-base-content/15",
              @data_ref && "opacity-60"
            ]}
          >
            <.icon
              name="hero-arrow-path"
              class={["size-3.5", @data_ref && "animate-spin"]}
            />
          </button>
          <button
            type="button"
            phx-click="systemd-daemon-reload"
            title="systemctl daemon-reload"
            class="btn btn-xs border-base-content/15 hover:bg-base-content/10"
          >
            <.icon name="hero-arrow-path-rounded-square" class="size-3.5" />
            <span class="hidden sm:inline">Reload</span>
          </button>
          <button
            type="button"
            phx-click="systemd-show-create"
            title="Create new unit"
            class="btn btn-xs border-base-content/15 hover:bg-base-content/10"
          >
            <.icon name="hero-plus" class="size-3.5" />
            <span class="hidden sm:inline">New unit</span>
          </button>
          <button
            type="button"
            phx-click="systemd-auto-refresh"
            title="Toggle auto-refresh every 15s"
            aria-pressed={to_string(@auto_refresh)}
            class={[
              "btn btn-xs border",
              @auto_refresh && "acc-bg border-0",
              !@auto_refresh && "border-base-content/15 hover:bg-base-content/10"
            ]}
          >
            <.icon name="hero-clock" class="size-3.5" />
            <span class="hidden sm:inline">{if @auto_refresh, do: "Auto: on", else: "Auto: off"}</span>
          </button>
          <span
            :if={@last_refreshed_at}
            class="hidden sm:inline font-mono text-[10px] text-base-content/40"
            title={Calendar.strftime(@last_refreshed_at, "%Y-%m-%d %H:%M:%S UTC")}
          >
            {time_ago(@last_refreshed_at)}
          </span>
          <span
            :if={@busy}
            class="hidden items-center gap-1.5 rounded-full bg-amber-500/10 px-2 py-0.5 font-mono text-[10px] text-amber-700 dark:text-amber-300 sm:flex"
          >
            <span class="size-2 animate-pulse rounded-full bg-amber-500" />
            {busy_label(@busy)}
          </span>
        </div>
        <form
          :if={Map.get(@state, :server_id) != nil}
          id="systemd-filter-form"
          phx-change="systemd-filter"
          class="ml-auto flex items-center gap-1.5"
        >
          <label class="input input-xs flex items-center gap-1.5 w-48 border-base-content/20 focus-within:border-base-content/30">
            <.icon name="hero-magnifying-glass" class="size-3.5 text-base-content/40" />
            <input
              name="filter"
              type="text"
              value={Map.get(@state, :filter, "")}
              placeholder="Search units…"
              aria-label="Filter units"
              phx-debounce="200"
              class="grow bg-transparent outline-none placeholder:text-base-content/40"
            />
            <button
              :if={Map.get(@state, :filter, "") not in [nil, ""]}
              type="button"
              phx-click="systemd-clear-filter"
              class="rounded p-0.5 hover:bg-base-content/10"
              aria-label="Clear filter"
            >
              <.icon name="hero-x-mark" class="size-3" />
            </button>
          </label>
        </form>
      </div>

      <%!-- Type tabs: service / timer / socket --%>
      <div
        :if={Map.get(@state, :server_id) != nil}
        class="flex flex-wrap items-center gap-2 border-b border-base-content/10 bg-base-content/[0.02] px-4 py-1.5"
      >
        <div class="flex items-center gap-1">
          <.type_tab type="service" current={@unit_type} />
          <.type_tab type="timer" current={@unit_type} />
          <.type_tab type="socket" current={@unit_type} />
        </div>
        <span
          :if={Map.get(@state, :server_id) != nil && match?({:ok, _}, Map.get(@state, :data))}
          class="ml-auto flex items-center gap-2 text-[11px] text-base-content/60"
        >
          <span :if={Map.get(@counts, :failed, 0) > 0} class="flex items-center gap-1">
            <span class="size-1.5 rounded-full bg-red-500" /> {@counts.failed} failed
            <button
              type="button"
              phx-click="systemd-action"
              phx-value-action="reset-failed"
              phx-value-name="*"
              title="systemctl reset-failed"
              class="ml-1 rounded bg-red-500/10 px-1.5 py-0.5 text-[10px] font-medium text-red-700 hover:bg-red-500/20 dark:text-red-300"
            >
              Reset failed
            </button>
          </span>
        </span>
      </div>

      <%!-- State pills + counts + sort --%>
      <div
        :if={Map.get(@state, :server_id) != nil && match?({:ok, _}, Map.get(@state, :data))}
        class="flex flex-wrap items-center gap-1.5 border-b border-base-content/10 px-4 py-2"
      >
        <div class="flex items-center gap-1">
          <.state_pill
            state="all"
            current={Map.get(@state, :state, "all")}
            count={@counts.all}
            label="All"
          />
          <.state_pill
            state="active"
            current={Map.get(@state, :state, "all")}
            count={@counts.active}
            label="Active"
          />
          <.state_pill
            state="failed"
            current={Map.get(@state, :state, "all")}
            count={@counts.failed}
            label="Failed"
          />
          <.state_pill
            state="inactive"
            current={Map.get(@state, :state, "all")}
            count={@counts.inactive}
            label="Other"
          />
        </div>
        <span class="ml-auto flex items-center gap-2 text-[11px] text-base-content/60">
          <span class="font-mono">
            <%= if Map.get(@state, :filter, "") not in [nil, ""] or Map.get(@state, :state, "all") != "all" do %>
              {length(@filtered)} / {@total} {String.replace(@unit_type, "service", "units")}
            <% else %>
              {@total} {String.replace(@unit_type, "service", "units")}
            <% end %>
          </span>
          <form id="systemd-sort-form" phx-change="systemd-sort" class="flex items-center gap-1">
            <select
              name="sort"
              aria-label="Sort units"
              class="select select-xs select-bordered h-6 min-h-0 py-0 text-xs"
            >
              <option value="name" selected={Map.get(@state, :sort, "name") == "name"}>
                Name A→Z
              </option>
              <option value="state" selected={Map.get(@state, :sort, "name") == "state"}>
                State
              </option>
            </select>
          </form>
        </span>
      </div>

      <div
        :if={Map.get(@state, :server_id) == nil}
        id="systemd-empty"
        class="flex flex-1 items-center justify-center p-8 text-center"
      >
        <div>
          <.icon name="hero-adjustments-horizontal" class="mx-auto size-10 text-base-content/30" />
          <p class="mt-2 font-semibold">No server selected</p>
          <p class="text-sm text-base-content/60">Pick a server above to manage systemd units.</p>
        </div>
      </div>

      <%= if Map.get(@state, :server_id) != nil do %>
        <%= case Map.get(@state, :data) do %>
          <% nil -> %>
            <div class="space-y-0 p-2" aria-label="Loading units">
              <div :for={_ <- 1..7} class="flex items-center gap-3 px-2 py-2.5">
                <span class="marsad-shimmer size-4 rounded" />
                <span class="marsad-shimmer h-3.5 rounded" style="width: 30%" />
                <span class="marsad-shimmer ml-auto h-3 w-20 rounded" />
              </div>
            </div>
          <% {:error, reason} -> %>
            <div
              role="alert"
              class="m-4 rounded-2xl border border-red-500/30 bg-red-500/10 p-5 text-center font-mono text-xs"
            >
              {inspect(reason)}
            </div>
          <% {:ok, _units} -> %>
            <div id="systemd-list" class="min-h-0 flex-1 overflow-y-auto">
              <p :if={@filtered == []} class="p-6 text-center text-sm text-base-content/50">
                <%= if @total == 0 do %>
                  No {String.replace(@unit_type, "service", "")} units found on this host.
                <% else %>
                  No units match your filters.
                  <button
                    type="button"
                    phx-click="systemd-clear-filter"
                    class="ml-1 underline decoration-dotted underline-offset-2 hover:text-base-content"
                  >
                    Clear search
                  </button>
                  <span :if={Map.get(@state, :state, "all") != "all"}>
                    or
                    <button
                      type="button"
                      phx-click="systemd-state"
                      phx-value-state="all"
                      class="underline decoration-dotted underline-offset-2 hover:text-base-content"
                    >
                      show all
                    </button>
                  </span>
                <% end %>
              </p>
              <div
                :for={u <- @filtered}
                id={"unit-#{u.unit}"}
                class={[
                  "group flex flex-col gap-1.5 border-b px-4 py-2.5 transition",
                  u.active == "failed" &&
                    "border-red-500/20 bg-red-500/[0.04] hover:bg-red-500/[0.06]",
                  u.active != "failed" && "border-base-content/[0.06] hover:bg-base-content/[0.04]"
                ]}
              >
                <div class="flex items-center gap-2.5">
                  <span
                    class={[
                      "size-2 shrink-0 rounded-full",
                      u.active == "active" && "bg-emerald-500",
                      u.active == "failed" && "bg-red-500 animate-pulse",
                      u.active not in ["active", "failed"] && "bg-base-content/30"
                    ]}
                    title={u.active}
                  />
                  <div class="min-w-0 flex-1">
                    <p class="truncate font-mono text-sm font-bold">
                      {raw_highlight(u.unit, Map.get(@state, :filter, ""))}
                    </p>
                    <p class="truncate text-[11px] text-base-content/50">{u.description}</p>
                  </div>
                  <span class={[
                    "hidden shrink-0 rounded-full px-1.5 py-0.5 font-mono text-[10px] font-medium sm:block",
                    u.active == "active" && "bg-emerald-500/10 text-emerald-700 dark:text-emerald-300",
                    u.active == "failed" && "bg-red-500/10 text-red-700 dark:text-red-300",
                    u.active not in ["active", "failed"] && "bg-base-content/10 text-base-content/60"
                  ]}>
                    {u.active} · {u.sub}
                  </span>
                </div>
                <div class="flex flex-wrap items-center gap-1 pl-4">
                  <button
                    :if={u.active != "active"}
                    type="button"
                    phx-click="systemd-action"
                    phx-value-action="start"
                    phx-value-name={u.unit}
                    title={"Start #{u.unit}"}
                    disabled={busy_action?(@busy, u.unit)}
                    class="btn btn-xs border-base-content/15 text-emerald-600 hover:bg-emerald-500/10 disabled:opacity-40"
                  >
                    <.icon name="hero-play" class="size-3" /> Start
                  </button>
                  <button
                    :if={u.active == "active"}
                    type="button"
                    phx-click="systemd-action"
                    phx-value-action="stop"
                    phx-value-name={u.unit}
                    title={"Stop #{u.unit}"}
                    data-confirm={"Stop #{u.unit}?"}
                    disabled={busy_action?(@busy, u.unit)}
                    class="btn btn-xs border-base-content/15 text-amber-600 hover:bg-amber-500/10 disabled:opacity-40"
                  >
                    <.icon name="hero-stop" class="size-3" /> Stop
                  </button>
                  <button
                    type="button"
                    phx-click="systemd-action"
                    phx-value-action="restart"
                    phx-value-name={u.unit}
                    title={"Restart #{u.unit}"}
                    data-confirm={"Restart #{u.unit}?"}
                    disabled={busy_action?(@busy, u.unit)}
                    class="btn btn-xs border-base-content/15 hover:bg-base-content/10 disabled:opacity-40"
                  >
                    <.icon name="hero-arrow-path" class="size-3" /> Restart
                  </button>
                  <button
                    :if={u.active == "failed"}
                    type="button"
                    phx-click="systemd-action"
                    phx-value-action="reset-failed"
                    phx-value-name={u.unit}
                    title="reset-failed"
                    disabled={busy_action?(@busy, u.unit)}
                    class="btn btn-xs border-red-500/20 text-red-600 hover:bg-red-500/10 disabled:opacity-40"
                  >
                    Reset
                  </button>
                  <span class="mx-1 hidden h-4 w-px bg-base-content/10 sm:block" />
                  <button
                    phx-click="systemd-detail"
                    phx-value-name={u.unit}
                    title="Details"
                    type="button"
                    class={[
                      "btn btn-xs border-base-content/15 hover:bg-base-content/10",
                      is_map(@detail) && Map.get(@detail, "Id") == u.unit && "acc-soft border-0"
                    ]}
                  >
                    <.icon name="hero-information-circle" class="size-3.5" /> Info
                  </button>
                  <button
                    type="button"
                    phx-click="systemd-logs"
                    phx-value-name={u.unit}
                    title={"Journal of #{u.unit}"}
                    class="btn btn-xs border-base-content/15 hover:bg-base-content/10"
                  >
                    <.icon name="hero-document-text" class="size-3.5" /> Logs
                  </button>
                  <button
                    type="button"
                    phx-click="systemd-unit-preview"
                    phx-value-name={u.unit}
                    title={"View #{u.unit} file"}
                    class="btn btn-xs border-base-content/15 hover:bg-base-content/10"
                  >
                    <.icon name="hero-code-bracket" class="size-3.5" /> File
                  </button>
                  <div class="ml-auto flex items-center gap-1">
                    <button
                      type="button"
                      phx-click="systemd-action"
                      phx-value-action="enable"
                      phx-value-name={u.unit}
                      title="Enable"
                      disabled={busy_action?(@busy, u.unit)}
                      class="btn btn-xs btn-ghost h-6 min-h-0 px-1.5 text-[11px] text-base-content/60 hover:text-base-content disabled:opacity-40"
                    >Enable</button>
                    <button
                      type="button"
                      phx-click="systemd-action"
                      phx-value-action="disable"
                      phx-value-name={u.unit}
                      title="Disable"
                      disabled={busy_action?(@busy, u.unit)}
                      class="btn btn-xs btn-ghost h-6 min-h-0 px-1.5 text-[11px] text-base-content/60 hover:text-base-content disabled:opacity-40"
                    >Disable</button>
                  </div>
                </div>
              </div>
            </div>
        <% end %>
      <% end %>

      <%!-- Detail drawer --%>
      <div :if={@detail || @detail_ref} class="border-t border-base-content/10">
        <%= cond do %>
          <% @detail == :loading -> %>
            <div class="p-4" aria-label="Loading detail">
              <div class="marsad-shimmer h-3 w-24 rounded" />
              <div class="marsad-shimmer mt-2 h-16 rounded-xl" />
            </div>
          <% is_map(@detail) -> %>
            <div class="bg-base-content/[0.03] px-4 py-3">
              <div class="flex items-center gap-2">
                <span class="font-mono text-xs font-semibold">{Map.get(@detail, "Id", "")}</span>
                <span class={[
                  "rounded-full px-1.5 py-0.5 font-mono text-[10px]",
                  Map.get(@detail, "ActiveState") == "active" &&
                    "bg-emerald-500/10 text-emerald-700 dark:text-emerald-300",
                  Map.get(@detail, "ActiveState") == "failed" &&
                    "bg-red-500/10 text-red-700 dark:text-red-300",
                  Map.get(@detail, "ActiveState") not in ["active", "failed"] &&
                    "bg-base-content/10 text-base-content/60"
                ]}>
                  {Map.get(@detail, "ActiveState", "?")} · {Map.get(@detail, "SubState", "?")}
                </span>
                <button
                  type="button"
                  id="systemd-detail-close"
                  phx-click="systemd-close-detail"
                  class="ml-auto rounded p-1 hover:bg-base-content/10"
                  aria-label="Close detail"
                >
                  <.icon name="hero-x-mark" class="size-3.5" />
                </button>
              </div>
              <dl class="mt-2 grid grid-cols-2 gap-x-4 gap-y-1 font-mono text-[11px] sm:grid-cols-3">
                <div>
                  <dt class="text-base-content/40">Load</dt>
                  <dd>{Map.get(@detail, "LoadState", "-")}</dd>
                </div>
                <div>
                  <dt class="text-base-content/40">UnitFileState</dt>
                  <dd>{Map.get(@detail, "UnitFileState", "-")}</dd>
                </div>
                <div>
                  <dt class="text-base-content/40">MainPID</dt>
                  <dd>{Map.get(@detail, "MainPID", "-")}</dd>
                </div>
                <div>
                  <dt class="text-base-content/40">Memory</dt>
                  <dd>{human_bytes(Map.get(@detail, "MemoryCurrent", ""))}</dd>
                </div>
                <div>
                  <dt class="text-base-content/40">CPU</dt>
                  <dd>{human_nsec(Map.get(@detail, "CPUUsageNSec", ""))}</dd>
                </div>
                <div>
                  <dt class="text-base-content/40">Restarts</dt>
                  <dd>{Map.get(@detail, "NRestarts", "0")}</dd>
                </div>
                <div class="col-span-2 sm:col-span-3">
                  <dt class="text-base-content/40">ActiveEnter</dt>
                  <dd class="truncate">{Map.get(@detail, "ActiveEnterTimestamp", "-")}</dd>
                </div>
              </dl>
              <div class="mt-2 flex flex-wrap gap-1">
                <button
                  type="button"
                  phx-click="systemd-action"
                  phx-value-action="enable"
                  phx-value-name={Map.get(@detail, "Id", "")}
                  class="btn btn-xs border-base-content/15"
                >Enable</button>
                <button
                  type="button"
                  phx-click="systemd-action"
                  phx-value-action="disable"
                  phx-value-name={Map.get(@detail, "Id", "")}
                  class="btn btn-xs border-base-content/15"
                >Disable</button>
                <button
                  type="button"
                  phx-click="systemd-action"
                  phx-value-action="mask"
                  phx-value-name={Map.get(@detail, "Id", "")}
                  class="btn btn-xs border-base-content/15"
                >Mask</button>
                <button
                  type="button"
                  phx-click="systemd-action"
                  phx-value-action="unmask"
                  phx-value-name={Map.get(@detail, "Id", "")}
                  class="btn btn-xs border-base-content/15"
                >Unmask</button>
                <button
                  type="button"
                  phx-click="systemd-logs"
                  phx-value-name={Map.get(@detail, "Id", "")}
                  class="btn btn-xs border-base-content/15"
                >Logs</button>
              </div>
            </div>
          <% true -> %>
            <div />
        <% end %>
      </div>

      <%!-- Logs --%>
      <%= cond do %>
        <% Map.get(@state, :logs) == :loading -> %>
          <div class="border-t border-base-content/10 p-4" aria-label="Loading logs">
            <div class="marsad-shimmer h-3 w-32 rounded" />
            <div class="marsad-shimmer mt-2 h-24 rounded-xl" />
          </div>
        <% is_map(Map.get(@state, :logs)) -> %>
          <% logs = Map.get(@state, :logs) %>
          <div class="border-t border-base-content/10">
            <div class="flex flex-wrap items-center gap-1.5 bg-base-content/[0.04] px-4 py-1.5 font-mono text-[11px]">
              <button
                type="button"
                id="systemd-logs-collapse"
                phx-click="systemd-logs-collapse"
                title={
                  if Map.get(logs, :collapsed, false),
                    do: "Expand journal",
                    else: "Collapse journal"
                }
                aria-expanded={to_string(!Map.get(logs, :collapsed, false))}
                aria-label="Toggle journal visibility"
                class="rounded p-0.5 text-base-content/60 transition hover:bg-base-content/10 hover:text-base-content"
              >
                <.icon
                  name={
                    if Map.get(logs, :collapsed, false),
                      do: "hero-chevron-right",
                      else: "hero-chevron-down"
                  }
                  class="size-3.5"
                />
              </button>
              <span class="truncate text-base-content/70">journal · {logs.name}</span>
              <span class="shrink-0 text-[10px] text-base-content/40">
                {count_lines(logs.text)} lines
              </span>
              <form
                id="systemd-logs-tail-form"
                phx-change="systemd-logs-tail"
                class="ml-2 flex items-center gap-1"
              >
                <select
                  name="tail"
                  aria-label="Lines"
                  class="select select-xs select-bordered h-6 min-h-0 py-0 text-xs"
                >
                  <option
                    :for={n <- [50, 100, 200, 500, 1000]}
                    value={n}
                    selected={Map.get(logs, :tail, 200) == n}
                  >
                    last {n}
                  </option>
                </select>
              </form>
              <form
                id="systemd-logs-priority-form"
                phx-change="systemd-logs-priority"
                class="flex items-center gap-1"
              >
                <select
                  name="priority"
                  aria-label="Priority"
                  class="select select-xs select-bordered h-6 min-h-0 py-0 text-xs"
                >
                  <option value="" selected={Map.get(logs, :priority) in [nil, ""]}>all</option>
                  <option
                    :for={p <- ~w(emerg alert crit err warning notice info debug)}
                    value={p}
                    selected={Map.get(logs, :priority) == p}
                  >
                    {p}
                  </option>
                </select>
              </form>
              <button
                type="button"
                phx-click="systemd-logs-wrap"
                title="Toggle line wrapping"
                aria-pressed={to_string(Map.get(logs, :wrap, false))}
                class={[
                  "rounded px-1.5 py-0.5 text-[10px] transition",
                  Map.get(logs, :wrap, false) && "acc-soft",
                  !Map.get(logs, :wrap, false) && "text-base-content/50 hover:bg-base-content/10"
                ]}
              >
                wrap
              </button>
              <button
                type="button"
                onclick="navigator.clipboard.writeText(document.getElementById('systemd-logs-text').innerText)"
                title="Copy logs"
                class="rounded p-1 text-base-content/60 hover:bg-base-content/10 hover:text-base-content"
              >
                <.icon name="hero-clipboard-document" class="size-3.5" />
              </button>
              <a
                href={
                  if Map.get(logs, :priority) not in [nil, ""] do
                    ~p"/systemd/logs/download?server_id=#{Map.get(@state, :server_id)}&name=#{logs.name}&priority=#{Map.get(logs, :priority)}"
                  else
                    ~p"/systemd/logs/download?server_id=#{Map.get(@state, :server_id)}&name=#{logs.name}"
                  end
                }
                download={"#{logs.name}.log"}
                title="Download full journal (5MB cap)"
                class="rounded p-1 text-base-content/60 hover:bg-base-content/10 hover:text-base-content"
              >
                <.icon name="hero-arrow-down-tray" class="size-3.5" />
              </a>
              <button
                type="button"
                id="systemd-logs-close"
                phx-click="systemd-close-logs"
                class="ml-auto rounded p-0.5 hover:bg-base-content/10"
                aria-label="Close logs"
              >
                <.icon name="hero-x-mark" class="size-3.5" />
              </button>
            </div>
            <div :if={!Map.get(logs, :collapsed, false)} class="relative">
              <form
                id="systemd-logs-filter-form"
                phx-change="systemd-logs-filter"
                class="flex items-center gap-1.5 border-y border-base-content/10 bg-base-100 px-4 py-1"
              >
                <.icon name="hero-magnifying-glass" class="size-3 text-base-content/40" />
                <input
                  type="text"
                  placeholder="Filter log lines…"
                  value={Map.get(logs, :filter, "")}
                  phx-debounce="200"
                  name="filter"
                  class="w-full bg-transparent text-xs outline-none placeholder:text-base-content/40"
                  aria-label="Filter logs"
                />
              </form>
              <pre
                id="systemd-logs-text"
                class={[
                  "marsad-scroll max-h-56 overflow-auto bg-black/85 p-3 font-mono text-[11.5px] leading-relaxed text-slate-100",
                  Map.get(logs, :wrap, false) && "whitespace-pre-wrap break-all"
                ]}
                phx-no-curly-interpolation
              ><%= filtered_log_text(logs) %></pre>
            </div>
            <p
              :if={Map.get(logs, :collapsed, false)}
              class="px-4 py-2 text-[11px] text-base-content/40"
            >
              Collapsed — {count_lines(logs.text)} lines hidden. Expand to read.
            </p>
          </div>
        <% true -> %>
          <div style="display:none" />
      <% end %>

      <%!-- Unit file preview --%>
      <%= cond do %>
        <% Map.get(@state, :unit_preview) == :loading -> %>
          <div class="border-t border-base-content/10 p-4" aria-label="Loading unit file">
            <div class="marsad-shimmer h-3 w-40 rounded" />
            <div class="marsad-shimmer mt-2 h-32 rounded-xl" />
          </div>
        <% is_map(Map.get(@state, :unit_preview)) -> %>
          <% preview = Map.get(@state, :unit_preview) %>
          <div class="border-t border-base-content/10">
            <div class="flex items-center gap-2 bg-base-content/[0.04] px-4 py-1.5 font-mono text-[11px]">
              <span class="truncate text-base-content/70">unit · {preview.name}</span>
              <span class="hidden truncate text-[10px] text-base-content/50 sm:block">{preview.path}</span>
              <span class="ml-auto flex items-center gap-1">
                <span class="hidden text-[10px] text-base-content/40 sm:inline">Ctrl+S to save</span>
                <button
                  data-save-path={preview.path}
                  class="btn btn-xs acc-bg border-0 gap-1"
                  title="Save (Ctrl+S)"
                >
                  <.icon name="hero-check" class="size-3.5" /> Save
                </button>
                <button
                  type="button"
                  id="systemd-unit-close"
                  phx-click="systemd-unit-close"
                  class="rounded p-0.5 hover:bg-base-content/10"
                  aria-label="Close unit preview"
                >
                  <.icon name="hero-x-mark" class="size-3.5" />
                </button>
              </span>
            </div>
            <div class="marsad-code-editor-wrap">
              <textarea
                id={"code-systemd-" <> Base.url_encode64(preview.path, padding: false)}
                phx-hook="CodeEditor"
                phx-update="ignore"
                data-path={preview.path}
                data-language={preview.language || "properties"}
                data-theme={@appearance.mode}
                data-readonly="false"
                class="hidden"
              ><%= preview.full_text || preview.text %></textarea>
            </div>
            <div
              :if={Map.get(preview, :editing, false)}
              class="flex items-center gap-2 border-t border-base-content/10 bg-base-content/[0.02] px-4 py-2"
            >
              <span class="text-xs text-base-content/60">Ctrl+S to save · will run daemon-reload</span>
              <button
                type="button"
                phx-click="request_save"
                phx-value-path={preview.path}
                class="btn btn-xs acc-bg border-0 ml-auto"
              >
                <.icon name="hero-check" class="size-3.5" /> Save
              </button>
            </div>
          </div>
        <% true -> %>
          <div style="display:none" />
      <% end %>

      <div :if={@create} class="border-t border-base-content/10 bg-base-100">
        <div class="flex items-center gap-2 bg-base-content/[0.04] px-4 py-2">
          <span class="font-mono text-xs font-semibold">New unit</span>
          <span class="text-[11px] text-base-content/50">/etc/systemd/system/</span>
          <button
            type="button"
            id="systemd-create-close"
            phx-click="systemd-hide-create"
            class="ml-auto rounded p-1 hover:bg-base-content/10"
            aria-label="Close create"
          >
            <.icon name="hero-x-mark" class="size-3.5" />
          </button>
        </div>
        <form id="systemd-create-form" phx-submit="systemd-create" class="space-y-3 p-4">
          <label class="form-control w-full">
            <span class="label-text text-xs font-medium">Unit name</span>
            <input
              type="text"
              name="name"
              value={Map.get(@create, :name, "")}
              placeholder="myapp.service"
              class="input input-sm input-bordered w-full font-mono text-sm"
              required
              pattern="^[\w@:.+=-]+\.\w+$"
              title="e.g. myapp.service"
            />
            <span class="mt-1 text-[11px] text-base-content/50">Must end with .service / .timer / .socket</span>
          </label>
          <label class="form-control w-full">
            <span class="label-text text-xs font-medium">Unit file content</span>
            <textarea
              name="content"
              rows="14"
              class="textarea textarea-bordered w-full font-mono text-xs leading-relaxed"
              placeholder="[Unit]&#10;Description=..."
              required
            ><%= Map.get(@create, :content, "") %></textarea>
          </label>
          <p
            :if={Map.get(@create, :error)}
            class="rounded bg-red-500/10 px-2 py-1 font-mono text-xs text-red-700 dark:text-red-300"
          >
            {Map.get(@create, :error)}
          </p>
          <div class="flex items-center gap-2">
            <button
              type="submit"
              class={["btn btn-sm acc-bg border-0", @create_ref && "btn-disabled opacity-60"]}
              disabled={@create_ref != nil || @busy != nil}
            >
              {if @create_ref, do: "Creating…", else: "Create"}
            </button>
            <button type="button" phx-click="systemd-hide-create" class="btn btn-sm btn-ghost">
              Cancel
            </button>
            <span class="ml-auto text-[11px] text-base-content/40">Will run daemon-reload</span>
          </div>
        </form>
      </div>
    </div>
    """
  end

  attr :state, :string, required: true
  attr :current, :string, required: true
  attr :count, :integer, required: true
  attr :label, :string, required: true

  defp state_pill(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="systemd-state"
      phx-value-state={@state}
      class={[
        "rounded-full px-2.5 py-1 text-xs font-medium transition",
        @current == @state && "acc-bg shadow",
        @current != @state && "border border-base-content/15 bg-base-100 hover:bg-base-content/5"
      ]}
      aria-pressed={@current == @state}
    >
      {@label} <span class="ml-1 font-mono text-[10px] opacity-70">({@count})</span>
    </button>
    """
  end

  defp type_tab(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="systemd-type"
      phx-value-type={@type}
      class={[
        "rounded-full px-3 py-1 text-xs font-medium transition",
        @current == @type && "acc-bg shadow",
        @current != @type && "border border-base-content/15 bg-base-100 hover:bg-base-content/5"
      ]}
      aria-pressed={to_string(@current == @type)}
    >
      {@type}
    </button>
    """
  end

  defp raw_highlight(text, filter) when filter in [nil, ""], do: Phoenix.HTML.html_escape(text)

  defp raw_highlight(text, filter) do
    pattern = Regex.compile!("(#{Regex.escape(filter)})", "i")

    html =
      text
      |> String.split(pattern, include_captures: true, trim: false)
      |> Enum.map_join("", fn part ->
        esc = part |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

        if String.downcase(part) == String.downcase(filter) and filter != "" do
          ~s(<mark class="rounded bg-amber-300/40 px-0.5 dark:bg-amber-400/30">#{esc}</mark>)
        else
          esc
        end
      end)

    Phoenix.HTML.raw(html)
  end

  defp filtered_units(units, filter, state) do
    units
    |> filter_by_state(state)
    |> filter_by_text(filter)
  end

  defp filter_by_state(units, state) when state in [nil, "", "all"], do: units
  defp filter_by_state(units, "active"), do: Enum.filter(units, &(&1.active == "active"))
  defp filter_by_state(units, "failed"), do: Enum.filter(units, &(&1.active == "failed"))

  defp filter_by_state(units, "inactive"),
    do: Enum.filter(units, &(&1.active not in ["active", "failed"]))

  defp filter_by_state(units, _), do: units

  defp filter_by_text(units, filter) when filter in [nil, ""], do: units

  defp filter_by_text(units, filter) do
    needle = String.downcase(filter)

    Enum.filter(units, fn u ->
      hay = String.downcase("#{u.unit} #{u.description} #{u.active} #{u.sub}")
      String.contains?(hay, needle)
    end)
  end

  defp sorted_units(units, "state") do
    Enum.sort_by(units, fn u ->
      order =
        case u.active do
          "failed" -> 0
          "active" -> 1
          _ -> 2
        end

      {order, String.downcase(u.unit)}
    end)
  end

  defp sorted_units(units, _), do: Enum.sort_by(units, &String.downcase(&1.unit))

  defp count_lines(text) when is_binary(text) do
    text |> String.split("\n", trim: true) |> length()
  end

  defp count_lines(_), do: 0

  defp count_states(units) do
    {active, failed, inactive} =
      Enum.reduce(units, {0, 0, 0}, fn u, {a, f, i} ->
        cond do
          u.active == "active" -> {a + 1, f, i}
          u.active == "failed" -> {a, f + 1, i}
          true -> {a, f, i + 1}
        end
      end)

    %{all: length(units), active: active, failed: failed, inactive: inactive}
  end

  defp busy_label(%{action: action, name: name}) when name not in [nil, "", "*"] do
    "#{action} #{name}…"
  end

  defp busy_label(%{action: action}), do: "#{action}…"
  defp busy_label(_), do: "Working…"

  defp busy_action?(%{name: name, action: _}, unit) when is_binary(name) and name != "" do
    name == unit
  end

  defp busy_action?(%{action: _}, _unit), do: true
  defp busy_action?(_, _), do: false

  defp time_ago(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      true -> Calendar.strftime(dt, "%H:%M:%S")
    end
  end

  defp time_ago(_), do: ""

  defp human_bytes(val) when val in [nil, "", "[not set]"], do: "-"

  defp human_bytes(val) do
    case Integer.parse(to_string(val)) do
      {n, ""} when n >= 1_048_576 -> "#{Float.round(n / 1_048_576, 1)}M"
      {n, ""} when n >= 1024 -> "#{Float.round(n / 1024, 1)}K"
      {n, ""} -> "#{n}B"
      _ -> val
    end
  end

  defp human_nsec(val) when val in [nil, "", "[not set]"], do: "-"

  defp human_nsec(val) do
    case Integer.parse(to_string(val)) do
      {n, ""} when n >= 1_000_000_000 -> "#{Float.round(n / 1_000_000_000, 2)}s"
      {n, ""} when n >= 1_000_000 -> "#{Float.round(n / 1_000_000, 1)}ms"
      {n, ""} -> "#{n}ns"
      _ -> val
    end
  end

  defp filtered_log_text(%{text: text, filter: filter}) when filter not in [nil, ""] do
    needle = String.downcase(filter)

    text
    |> String.split("\n")
    |> Enum.filter(fn line -> String.contains?(String.downcase(line), needle) end)
    |> Enum.join("\n")
  end

  defp filtered_log_text(%{text: text}) when is_binary(text), do: text
  defp filtered_log_text(_), do: ""
end
