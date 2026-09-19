defmodule MarsadWeb.Desktop.SystemdPanel do
  @moduledoc "systemd units panel (function component; events live in DesktopLive)."
  use MarsadWeb, :html

  attr :servers, :list, required: true
  attr :state, :map, required: true
  attr :appearance, :map, required: false, default: %{mode: "dark"}

  def panel(assigns) do
    assigns =
      assigns
      |> assign_new(:filtered, fn -> [] end)
      |> then(fn a ->
        case a.state.data do
          {:ok, units} ->
            filtered =
              units
              |> filtered_units(a.state.filter, Map.get(a.state, :state, "all"))
              |> sorted_units(Map.get(a.state, :sort, "name"))

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

    ~H"""
    <div id="systemd-panel" class="marsad-scroll flex h-full min-h-0 flex-col overflow-y-auto">
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
            <option :for={s <- @servers} value={s.id} selected={@state.server_id == s.id}>
              {s.name}
            </option>
          </select>
        </form>
        <button
          :if={@state.server_id}
          id="systemd-refresh"
          phx-click="systemd-refresh"
          title="Refresh"
          class="btn btn-xs btn-ghost border border-base-content/15 phx-click-loading:opacity-60"
        >
          <.icon name="hero-arrow-path" class="marsad-spin-target size-3.5" />
        </button>
        <form
          :if={@state.server_id}
          id="systemd-filter-form"
          phx-change="systemd-filter"
          class="ml-auto flex items-center gap-1.5"
        >
          <label class="input input-xs flex items-center gap-1.5 w-48 border-base-content/20 focus-within:border-base-content/30">
            <.icon name="hero-magnifying-glass" class="size-3.5 text-base-content/40" />
            <input
              name="filter"
              type="text"
              value={@state.filter}
              placeholder="Search units…"
              aria-label="Filter units"
              phx-debounce="200"
              class="grow bg-transparent outline-none placeholder:text-base-content/40"
            />
            <button
              :if={@state.filter not in [nil, ""]}
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

      <div
        :if={@state.server_id && match?({:ok, _}, @state.data)}
        class="flex flex-wrap items-center gap-1.5 border-b border-base-content/10 bg-base-content/[0.02] px-4 py-2"
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
            <%= if @state.filter not in [nil, ""] or Map.get(@state, :state, "all") != "all" do %>
              {length(@filtered)} / {@total} units
            <% else %>
              {@total} units
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
        :if={!@state.server_id}
        id="systemd-empty"
        class="flex flex-1 items-center justify-center p-8 text-center"
      >
        <div>
          <.icon name="hero-adjustments-horizontal" class="mx-auto size-10 text-base-content/30" />
          <p class="mt-2 font-semibold">No server selected</p>
          <p class="text-sm text-base-content/60">Pick a server above to manage systemd services.</p>
        </div>
      </div>

      <%= if @state.server_id do %>
        <%= case @state.data do %>
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
                  No service units found on this host.
                <% else %>
                  No units match your filters.
                  <button
                    phx-click="systemd-clear-filter"
                    class="ml-1 underline decoration-dotted underline-offset-2 hover:text-base-content"
                  >
                    Clear search
                  </button>
                  <span :if={Map.get(@state, :state, "all") != "all"}>
                    or
                    <button
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
                class="group border-b border-base-content/[0.06] px-4 py-2 transition hover:bg-base-content/[0.04]"
              >
                <div class="flex items-center gap-2.5">
                  <span
                    class={[
                      "size-2 shrink-0 rounded-full",
                      u.active == "active" && "bg-emerald-500",
                      u.active == "failed" && "bg-red-500",
                      u.active not in ["active", "failed"] && "bg-base-content/30"
                    ]}
                    title={u.active}
                  />
                  <div class="min-w-0 flex-1">
                    <p class="truncate font-mono text-sm font-bold">
                      {highlight_match(u.unit, @state.filter)}
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
                  <span class="hidden shrink-0 font-mono text-[11px] text-base-content/50 sm:hidden">{u.sub}</span>
                  <div class="flex shrink-0 gap-1">
                    <button
                      :if={u.active != "active"}
                      phx-click="systemd-action"
                      phx-value-action="start"
                      phx-value-name={u.unit}
                      title={"Start #{u.unit}"}
                      class="btn btn-xs border-base-content/15 text-emerald-600 hover:bg-emerald-500/10"
                    >Start</button>
                    <button
                      :if={u.active == "active"}
                      phx-click="systemd-action"
                      phx-value-action="stop"
                      phx-value-name={u.unit}
                      title={"Stop #{u.unit}"}
                      data-confirm={"Stop #{u.unit}?"}
                      class="btn btn-xs border-base-content/15 text-amber-600 hover:bg-amber-500/10"
                    >Stop</button>
                    <button
                      phx-click="systemd-action"
                      phx-value-action="restart"
                      phx-value-name={u.unit}
                      title={"Restart #{u.unit}"}
                      data-confirm={"Restart #{u.unit}?"}
                      class="btn btn-xs border-base-content/15 hover:bg-base-content/10"
                    >Restart</button>
                    <button
                      phx-click="systemd-logs"
                      phx-value-name={u.unit}
                      title={"Journal of #{u.unit}"}
                      class="btn btn-xs border-base-content/15 hover:bg-base-content/10"
                    >Logs</button>
                    <button
                      phx-click="systemd-unit-preview"
                      phx-value-name={u.unit}
                      title={"View #{u.unit} file"}
                      class="btn btn-xs border-base-content/15 hover:bg-base-content/10"
                    >View</button>
                  </div>
                </div>
              </div>
            </div>
        <% end %>
      <% end %>

      <div :if={@state.logs} class="border-t border-base-content/10">
        <div class="flex items-center gap-2 bg-base-content/[0.04] px-4 py-1.5 font-mono text-[11px]">
          <button
            id="systemd-logs-collapse"
            phx-click="systemd-logs-collapse"
            title={
              if Map.get(@state.logs, :collapsed, false),
                do: "Expand journal",
                else: "Collapse journal"
            }
            aria-expanded={to_string(!Map.get(@state.logs, :collapsed, false))}
            aria-label="Toggle journal visibility"
            class="rounded p-0.5 text-base-content/60 transition hover:bg-base-content/10 hover:text-base-content"
          >
            <.icon
              name={
                if Map.get(@state.logs, :collapsed, false),
                  do: "hero-chevron-right",
                  else: "hero-chevron-down"
              }
              class="size-3.5"
            />
          </button>
          <span class="truncate text-base-content/70">journal · {@state.logs.name}</span>
          <span class="shrink-0 text-[10px] text-base-content/40">
            {count_lines(@state.logs.text)} lines
          </span>
          <button
            phx-click="systemd-logs-wrap"
            title="Toggle line wrapping"
            aria-pressed={to_string(Map.get(@state.logs, :wrap, false))}
            class={[
              "rounded px-1.5 py-0.5 text-[10px] transition",
              Map.get(@state.logs, :wrap, false) && "acc-soft",
              !Map.get(@state.logs, :wrap, false) && "text-base-content/50 hover:bg-base-content/10"
            ]}
          >
            wrap
          </button>
          <button
            id="systemd-logs-close"
            phx-click="systemd-close-logs"
            class="ml-auto rounded p-0.5 hover:bg-base-content/10"
            aria-label="Close logs"
          >
            <.icon name="hero-x-mark" class="size-3.5" />
          </button>
        </div>
        <pre
          :if={!Map.get(@state.logs, :collapsed, false)}
          class={[
            "marsad-scroll max-h-56 overflow-auto bg-black/85 p-3 font-mono text-[11.5px] leading-relaxed text-slate-100",
            Map.get(@state.logs, :wrap, false) && "whitespace-pre-wrap break-all"
          ]}
          phx-no-curly-interpolation
        ><%= @state.logs.text %></pre>
        <p
          :if={Map.get(@state.logs, :collapsed, false)}
          class="px-4 py-2 text-[11px] text-base-content/40"
        >
          Collapsed — {count_lines(@state.logs.text)} lines hidden. Expand to read.
        </p>
      </div>

      <div :if={@state.unit_preview} class="border-t border-base-content/10">
        <div class="flex items-center gap-2 bg-base-content/[0.04] px-4 py-1.5 font-mono text-[11px]">
          <span class="truncate text-base-content/70">unit · {@state.unit_preview.name}</span>
          <span class="text-[10px] text-base-content/50">{@state.unit_preview.path}</span>
          <span class="ml-auto flex items-center gap-1">
            <span class="hidden text-[10px] text-base-content/40 sm:inline">Ctrl+S to save</span>
            <button
              data-save-path={@state.unit_preview.path}
              class="btn btn-xs acc-bg border-0 gap-1"
              title="Save (Ctrl+S)"
            >
              <.icon name="hero-check" class="size-3.5" /> Save
            </button>
            <button
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
            id={"code-systemd-" <> Base.url_encode64(@state.unit_preview.path, padding: false)}
            phx-hook="CodeEditor"
            phx-update="ignore"
            data-path={@state.unit_preview.path}
            data-language={@state.unit_preview.language || "properties"}
            data-theme={@appearance.mode}
            data-readonly="false"
            class="hidden"
          ><%= @state.unit_preview.full_text || @state.unit_preview.text %></textarea>
        </div>
        <div
          :if={Map.get(@state.unit_preview, :editing, false)}
          class="flex items-center gap-2 border-t border-base-content/10 bg-base-content/[0.02] px-4 py-2"
        >
          <span class="text-xs text-base-content/60">Ctrl+S to save · will run daemon-reload</span>
          <button
            phx-click="request_save"
            phx-value-path={@state.unit_preview.path}
            class="btn btn-xs acc-bg border-0 ml-auto"
          >
            <.icon name="hero-check" class="size-3.5" /> Save
          </button>
        </div>
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

  defp highlight_match(text, filter) when filter in [nil, ""], do: text

  defp highlight_match(text, filter) do
    # Simple inline highlight: wrap matching substring with <mark> via phx-no-curly-interpolation-safe split.
    # For now we just return text; full highlight could be done client-side. Keeping server simple.
    text
    |> String.split(~r/(#{Regex.escape(filter)})/i, include_captures: true, trim: false)
    |> Enum.map(fn part ->
      if String.downcase(part) == String.downcase(filter) and filter != "" do
        # Will be escaped by HEEx, but we want mark; use raw via Phoenix.HTML.raw would need.
        # Keep plain for now to avoid XSS; highlight is best-effort.
        part
      else
        part
      end
    end)
    |> Enum.join("")
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
end
