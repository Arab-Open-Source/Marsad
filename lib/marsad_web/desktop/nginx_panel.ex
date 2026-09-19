defmodule MarsadWeb.Desktop.NginxPanel do
  @moduledoc "nginx management panel (function component; events live in DesktopLive)."
  use MarsadWeb, :html

  attr :servers, :list, required: true
  attr :state, :map, required: true
  attr :appearance, :map, required: false, default: %{mode: "dark"}

  def panel(assigns) do
    assigns = assign(assigns, :files_filter, Map.get(assigns.state, :files_filter, ""))
    filtered = filtered_files(Map.get(assigns.state, :files), assigns.files_filter)

    assigns = assign(assigns, :filtered_files, filtered)

    ~H"""
    <div id="nginx-panel" class="marsad-scroll flex h-full min-h-0 flex-col overflow-y-auto">
      <div class="flex flex-wrap items-center gap-2 border-b border-base-content/10 px-4 py-2.5">
        <span class="acc-soft flex size-7 items-center justify-center rounded-lg">
          <.icon name="hero-globe-alt" class="size-4" />
        </span>
        <form id="nginx-server-form" phx-change="nginx-server" class="flex items-center gap-1.5">
          <select
            id="nginx-server-select"
            name="server_id"
            class="select select-sm select-bordered max-w-44"
            aria-label="nginx host"
          >
            <option value="">Select server…</option>
            <option :for={s <- @servers} value={s.id} selected={@state.server_id == s.id}>
              {s.name}
            </option>
          </select>
        </form>
        <button
          :if={@state.server_id}
          id="nginx-refresh"
          phx-click="nginx-refresh"
          title="Refresh status"
          class="btn btn-xs btn-ghost border border-base-content/15 phx-click-loading:opacity-60"
        >
          <.icon name="hero-arrow-path" class="marsad-spin-target size-3.5" />
        </button>
      </div>

      <div
        :if={!@state.server_id}
        id="nginx-empty"
        class="flex flex-1 items-center justify-center p-8 text-center"
      >
        <div>
          <.icon name="hero-globe-alt" class="mx-auto size-10 text-base-content/30" />
          <p class="mt-2 font-semibold">No server selected</p>
          <p class="text-sm text-base-content/60">Pick a server above to manage nginx.</p>
        </div>
      </div>

      <%= if @state.server_id do %>
        <div class="space-y-2.5 p-4">
          <%= case @state.status do %>
            <% nil -> %>
              <div class="marsad-shimmer h-24 rounded-2xl" aria-label="Loading status" />
            <% {:error, reason} -> %>
              <div
                role="alert"
                class="rounded-2xl border border-red-500/30 bg-red-500/10 p-4 text-center font-mono text-xs"
              >
                {inspect(reason)}
              </div>
            <% {:ok, st} -> %>
              <div class={[
                "rounded-2xl border p-4",
                st.active == "active" && "border-base-content/10 bg-base-content/[0.03]",
                st.active == "not-installed" && "border-amber-500/30 bg-amber-500/10",
                st.active not in ["active", "not-installed"] &&
                  "border-base-content/10 bg-base-content/[0.03]"
              ]}>
                <div class="flex flex-wrap items-center gap-2">
                  <span
                    class={[
                      "size-2.5 rounded-full",
                      st.active == "active" && "bg-emerald-500",
                      st.active == "not-installed" && "bg-amber-500",
                      st.active not in ["active", "not-installed"] && "bg-red-500"
                    ]}
                    title={"service #{st.active}"}
                  />
                  <p class="font-mono text-sm font-bold">
                    nginx · {if st.active == "not-installed", do: "not installed", else: st.active}
                  </p>
                  <span class={[
                    "ml-auto rounded-full px-2 py-0.5 text-[11px] font-medium",
                    st.test_ok? && "bg-emerald-500/10 st-online",
                    !st.test_ok? && st.active == "not-installed" && "bg-amber-500/10 st-warn",
                    !st.test_ok? && st.active != "not-installed" && "bg-red-500/10 st-offline"
                  ]}>
                    {cond do
                      st.active == "not-installed" -> "not installed"
                      st.test_ok? -> "config valid"
                      true -> "config invalid"
                    end}
                  </span>
                </div>
                <p
                  :if={st.active == "not-installed"}
                  class="mt-2 rounded-lg bg-amber-500/10 px-2.5 py-2 text-xs leading-relaxed text-amber-800 dark:text-amber-200"
                >
                  nginx غير مثبت على هذا السيرفر. ثبّته بـ:
                  <code class="rounded bg-black/10 px-1 py-0.5 font-mono text-[11px]">sudo apt update && sudo apt install -y nginx</code>
                </p>
                <pre
                  class="mt-2 max-h-28 overflow-auto rounded-xl bg-black/85 p-2.5 font-mono text-[11.5px] leading-relaxed text-slate-100"
                  phx-no-curly-interpolation
                >{st.test_output}</pre>
                <div class="mt-3 flex flex-wrap gap-1.5">
                  <button
                    phx-click="nginx-action"
                    phx-value-action="test"
                    class="btn btn-xs border-base-content/15 hover:bg-base-content/10"
                  >
                    Test config
                  </button>
                  <button
                    phx-click="nginx-action"
                    phx-value-action="reload"
                    class="btn btn-xs gap-1 acc-bg border-0"
                  >
                    Reload
                  </button>
                  <button
                    phx-click="nginx-action"
                    phx-value-action="restart"
                    data-confirm="Restart nginx? Active connections will drop."
                    class="btn btn-xs border-base-content/15 text-amber-600 hover:bg-amber-500/10"
                  >
                    Restart
                  </button>
                </div>
              </div>
          <% end %>

          <.certs_section state={@state} />

          <div class="rounded-2xl border border-base-content/10 bg-base-content/[0.03] p-4">
            <div class="flex items-center gap-2">
              <p class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                Configuration
              </p>
              <button
                id="nginx-config-load"
                phx-click="nginx-config"
                class="btn btn-xs ml-auto border-base-content/15"
              >
                {if @state.config, do: "Reload", else: "Load"} full config
              </button>
            </div>
            <div :if={@state.config} class="mt-2 marsad-code-editor-wrap">
              <textarea
                id={"code-nginx-config-" <> to_string(@state.server_id)}
                phx-hook="CodeEditor"
                phx-update="ignore"
                data-path="nginx_full_config"
                data-language="nginx"
                data-theme={@appearance.mode}
                data-readonly="true"
                class="hidden"
              ><%= @state.config %></textarea>
            </div>
          </div>

          <div class="rounded-2xl border border-base-content/10 bg-base-content/[0.03] p-4">
            <div class="flex flex-wrap items-center gap-2">
              <p class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                Config files
              </p>
              <span :if={@state.files} class="ml-auto font-mono text-[11px] text-base-content/50">
                {length(@filtered_files)} / {length(@state.files)} files
              </span>
              <button
                id="nginx-files-load"
                phx-click="nginx-files"
                class="btn btn-xs ml-auto border-base-content/15 sm:ml-0"
              >
                {if @state.files, do: "Reload", else: "List"} /etc/nginx files
              </button>
            </div>
            <form
              :if={@state.files}
              id="nginx-files-filter-form"
              phx-change="nginx-files-filter"
              class="mt-2"
            >
              <label class="input input-xs flex items-center gap-1.5 w-full border-base-content/15">
                <.icon name="hero-magnifying-glass" class="size-3.5 text-base-content/40" />
                <input
                  name="filter"
                  type="text"
                  value={@files_filter}
                  placeholder="Filter by path…"
                  aria-label="Filter nginx files"
                  phx-debounce="200"
                  class="grow bg-transparent outline-none placeholder:text-base-content/40"
                />
                <button
                  :if={@files_filter not in [nil, ""]}
                  type="button"
                  phx-click="nginx-files-clear-filter"
                  class="rounded p-0.5 hover:bg-base-content/10"
                  aria-label="Clear filter"
                >
                  <.icon name="hero-x-mark" class="size-3" />
                </button>
              </label>
            </form>
            <p
              :if={@state.files == nil and @state.files_error}
              class="p-3 text-center text-xs text-base-content/50"
            >
              Could not list files — is nginx installed on this host?
            </p>
            <div
              :if={@state.files}
              id="nginx-files-list"
              class="mt-2 max-h-72 divide-y divide-base-content/[0.06] overflow-y-auto"
            >
              <button
                :for={f <- @filtered_files}
                phx-click="nginx-file-preview"
                phx-value-path={f.path}
                class="flex w-full cursor-pointer items-center gap-2 rounded px-2 py-1.5 text-left font-mono text-[11px] transition hover:bg-base-content/[0.06]"
              >
                <.icon name="hero-document-text" class="size-3.5 shrink-0 text-base-content/40" />
                <span class="min-w-0 flex-1 truncate">{f.path}</span>
                <span class="shrink-0 text-base-content/40">{format_kb(f.size)}</span>
              </button>
              <p :if={@state.files == []} class="p-3 text-center text-xs text-base-content/50">
                No files found.
              </p>
              <p
                :if={@filtered_files == [] and @state.files != []}
                class="p-3 text-center text-xs text-base-content/50"
              >
                No files match "<span class="font-mono">{@files_filter}</span>" —
                <button
                  phx-click="nginx-files-clear-filter"
                  class="underline decoration-dotted underline-offset-2 hover:text-base-content"
                >clear</button>
              </p>
            </div>
            <div
              :if={@state.file_preview}
              class="mt-2 border border-base-content/10 rounded-b-xl overflow-hidden"
            >
              <div class="flex items-center gap-2 bg-base-content/[0.04] px-3 py-1.5 font-mono text-[11px]">
                <span class="truncate text-base-content/70">{@state.file_preview.path}</span>
                <span class="ml-auto flex items-center gap-1">
                  <span class="hidden text-\[10px\] text-base-content/40 sm:inline">Ctrl\+S to save</span>
                  <button
                    data-save-path={@state.file_preview.path}
                    class="btn btn-xs acc-bg border-0 gap-1"
                    title="Save \(Ctrl\+S\)"
                  >
                    <.icon name="hero-check" class="size-3\.5" /> Save
                  </button>
                  <button
                    id="nginx-file-close"
                    phx-click="nginx-file-close"
                    class="rounded p-0.5 hover:bg-base-content/10"
                    aria-label="Close file preview"
                  >
                    <.icon name="hero-x-mark" class="size-3.5" />
                  </button>
                </span>
              </div>
              <div class="marsad-code-editor-wrap">
                <textarea
                  id={"code-nginx-" <> Base.url_encode64(@state.file_preview.path, padding: false)}
                  phx-hook="CodeEditor"
                  phx-update="ignore"
                  data-path={@state.file_preview.path}
                  data-language={@state.file_preview.language || "nginx"}
                  data-theme={@appearance.mode}
                  data-readonly="false"
                  class="hidden"
                ><%= @state.file_preview.full_text || @state.file_preview.text %></textarea>
              </div>
              <div
                :if={Map.get(@state.file_preview, :editing, false)}
                class="flex items-center gap-2 border-t border-base-content/10 bg-base-content/[0.02] px-3 py-2"
              >
                <span class="text-xs text-base-content/60">Ctrl+S to save</span>
                <button
                  phx-click="request_save"
                  phx-value-path={@state.file_preview.path}
                  class="btn btn-xs acc-bg border-0 ml-auto"
                >
                  <.icon name="hero-check" class="size-3.5" /> Save
                </button>
              </div>
            </div>
          </div>

          <div class="rounded-2xl border border-base-content/10 bg-base-content/[0.03] p-4">
            <div class="flex items-center gap-2">
              <p class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                Error log
              </p>
              <button
                id="nginx-log-load"
                phx-click="nginx-logs"
                class="btn btn-xs ml-auto border-base-content/15"
              >
                {if @state.error_log, do: "Reload", else: "Load"} last 100 lines
              </button>
            </div>
            <div :if={@state.error_log} class="mt-2 marsad-code-editor-wrap">
              <textarea
                id={"code-nginx-log-" <> to_string(@state.server_id)}
                phx-hook="CodeEditor"
                phx-update="ignore"
                data-path="nginx_error_log"
                data-language="shell"
                data-theme={@appearance.mode}
                data-readonly="true"
                class="hidden"
              ><%= @state.error_log %></textarea>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp format_kb(bytes) when is_integer(bytes) and bytes >= 1024,
    do: "#{Float.round(bytes / 1024, 1)}K"

  defp format_kb(bytes) when is_integer(bytes), do: "#{bytes}B"
  defp format_kb(_), do: "—"

  # -- certificates section ---------------------------------------------------------

  attr :state, :map, required: true

  defp certs_section(assigns) do
    ~H"""
    <div id="nginx-certs" class="rounded-2xl border border-base-content/10 bg-base-content/[0.03] p-4">
      <div class="flex flex-wrap items-center gap-2">
        <p class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
          Certificates
        </p>
        <span :if={match?({:ok, _}, @state.certs)} class="flex items-center gap-1.5">
          <.cert_summary_pill summary={Marsad.Fleet.Services.cert_summary(elem(@state.certs, 1))} />
        </span>
        <button
          id="nginx-certs-check"
          phx-click="nginx-check-certs"
          class="btn btn-xs ml-auto border-base-content/15 phx-click-loading:opacity-60"
        >
          <.icon name="hero-shield-check" class="marsad-spin-target size-3.5" />
          {if @state.certs, do: "Recheck", else: "Check certificates"}
        </button>
      </div>
      <%= case @state.certs do %>
        <% nil -> %>
          <p class="mt-2 text-xs leading-relaxed text-base-content/50">
            Checks every HTTPS vhost's live certificate expiry (warn ≤ 30 days, critical ≤ 14 days).
          </p>
        <% :loading -> %>
          <div class="mt-2 space-y-1.5" aria-label="Checking certificates">
            <div :for={_ <- 1..3} class="flex items-center gap-3">
              <span class="marsad-shimmer size-4 shrink-0 rounded-full" />
              <span class="marsad-shimmer h-3.5 rounded" style="width: 45%" />
              <span class="marsad-shimmer ml-auto h-3 w-20 rounded" />
            </div>
          </div>
        <% {:error, reason} -> %>
          <p
            role="alert"
            class="mt-2 rounded-xl border border-red-500/30 bg-red-500/10 px-3 py-2 font-mono text-xs"
          >
            Check failed: {inspect(reason)}
          </p>
        <% {:ok, []} -> %>
          <p class="mt-2 text-xs text-base-content/60">
            No HTTPS vhosts found in this nginx config — nothing to check.
          </p>
        <% {:ok, certs} -> %>
          <ul class="mt-2 space-y-1.5">
            <li
              :for={c <- certs}
              class="flex items-center gap-2.5 rounded-xl border border-base-content/10 bg-base-100 px-3 py-2"
            >
              <span class={["size-2 shrink-0 rounded-full", cert_dot(c.status)]} title={c.note} />
              <div class="min-w-0 flex-1">
                <p class="truncate font-mono text-xs font-bold">
                  {c.domain}{c.wildcard? && " (wildcard)"}
                </p>
                <p class="truncate font-mono text-[11px] text-base-content/50">
                  :{c.port} · {cert_expiry(c)}
                </p>
              </div>
              <span class={[
                "shrink-0 rounded-full px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide",
                cert_tone(c.status)
              ]}>
                {cert_label(c)}
              </span>
            </li>
          </ul>
      <% end %>
    </div>
    """
  end

  attr :summary, :map, required: true

  defp cert_summary_pill(assigns) do
    ~H"""
    <span
      :if={@summary.critical > 0}
      class="rounded-full bg-red-500/15 px-2 py-0.5 text-[10px] font-bold text-red-600 dark:text-red-300"
    >
      {@summary.critical} critical
    </span>
    <span
      :if={@summary.critical == 0 and @summary.warning > 0}
      class="rounded-full bg-amber-500/15 px-2 py-0.5 text-[10px] font-bold text-amber-700 dark:text-amber-300"
    >
      expiring soon
    </span>
    <span
      :if={@summary.critical == 0 and @summary.warning == 0}
      class="rounded-full bg-emerald-500/15 px-2 py-0.5 text-[10px] font-bold text-emerald-700 dark:text-emerald-300"
    >
      all valid
    </span>
    """
  end

  defp cert_dot(:critical), do: "bg-red-500"
  defp cert_dot(:warning), do: "bg-amber-500"
  defp cert_dot(:unknown), do: "bg-base-content/30"
  defp cert_dot(_), do: "bg-emerald-500"

  defp cert_tone(:critical),
    do: "bg-red-500/15 text-red-600 ring-1 ring-red-500/30 dark:text-red-300"

  defp cert_tone(:warning),
    do: "bg-amber-500/15 text-amber-700 ring-1 ring-amber-500/30 dark:text-amber-300"

  defp cert_tone(:unknown),
    do: "bg-base-content/10 text-base-content/60 ring-1 ring-base-content/15"

  defp cert_tone(_),
    do: "bg-emerald-500/15 text-emerald-700 ring-1 ring-emerald-500/30 dark:text-emerald-300"

  defp cert_label(%{status: :critical, note: note}), do: note
  defp cert_label(%{status: :warning, note: note}), do: note
  defp cert_label(%{status: :unknown}), do: "check failed"
  defp cert_label(%{days_left: days}), do: "#{days}d left"

  defp cert_expiry(%{expires_at: nil}), do: "expiry unknown"
  defp cert_expiry(%{expires_at: %DateTime{} = dt}), do: Calendar.strftime(dt, "%Y-%m-%d")
  defp cert_expiry(_), do: "expiry unknown"

  defp filtered_files(nil, _), do: nil
  defp filtered_files(files, filter) when filter in [nil, ""], do: files

  defp filtered_files(files, filter) do
    needle = String.downcase(filter)
    Enum.filter(files, fn f -> String.contains?(String.downcase(f.path), needle) end)
  end
end
