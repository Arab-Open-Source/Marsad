defmodule MarsadWeb.ActivityLive do
  @moduledoc "Searchable, filterable fleet-wide audit timeline."

  use MarsadWeb, :live_view

  import Ecto.Query, warn: false

  alias Marsad.AuditLog
  alias Marsad.Fleet
  alias Marsad.Repo

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Activity")
     |> assign(:servers, Fleet.list_servers())
     |> assign(:filters, %{"search" => "", "server_id" => "", "result" => "all"})
     |> assign(:form, to_form(%{"search" => "", "server_id" => "", "result" => "all"}))
     |> assign(:logs, [])}
    |> then(fn {:ok, socket} -> {:ok, load_logs(socket)} end)
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, socket |> apply_filters(filters) |> load_logs()}
  end

  def handle_event("clear-filters", _params, socket) do
    {:noreply,
     socket
     |> apply_filters(%{"search" => "", "server_id" => "", "result" => "all"})
     |> load_logs()}
  end

  defp apply_filters(socket, filters) do
    socket |> assign(:filters, filters) |> assign(:form, to_form(filters))
  end

  defp load_logs(socket) do
    filters = socket.assigns.filters
    search = String.trim(Map.get(filters, "search", ""))
    server_id = Map.get(filters, "server_id", "")
    result = Map.get(filters, "result", "all")

    query =
      AuditLog
      |> join(:left, [a], s in Marsad.Fleet.Server, on: a.server_id == s.id)
      |> order_by([a, _s], desc: a.inserted_at)
      |> limit(200)
      |> preload([a, _s], [:server])

    query =
      if search == "" do
        query
      else
        # SQLite LIKE is case-insensitive for ASCII by default.
        term = "%#{search}%"

        query
        |> where(
          [a, s],
          like(a.action, ^term) or like(a.container, ^term) or
            like(a.details, ^term) or like(s.name, ^term)
        )
      end

    query =
      if server_id == "" do
        query
      else
        case Integer.parse(server_id) do
          {id, _} -> where(query, [a, _s], a.server_id == ^id)
          _ -> query
        end
      end

    query =
      case result do
        "ok" ->
          where(query, [a, _s], not is_nil(a.details) and a.details in ["ok", "success"])

        "failed" ->
          where(query, [a, _s], not is_nil(a.details) and a.details not in ["ok", "success"])

        _ ->
          query
      end

    assign(socket, :logs, Repo.all(query))
  end

  defp result_label(details) when details in [nil, "", "ok", "success"], do: "ok"
  defp result_label(_), do: "failed"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="activity-page" class="mx-auto w-full max-w-6xl px-4 py-8 sm:px-6">
        <div class="flex flex-wrap items-end justify-between gap-4">
          <div>
            <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
              Marsad · Fleet
            </p>
            <h1 class="mt-1 text-3xl font-bold tracking-tight">Activity timeline</h1>
            <p class="mt-1 text-sm text-base-content/60">
              Who did what, where, and when — up to the last 200 events.
            </p>
          </div>
          <.link
            navigate={~p"/desktop"}
            id="activity-back-desktop"
            class="btn btn-ghost border border-base-content/15"
          >
            ← Desktop
          </.link>
        </div>

        <.form
          for={@form}
          id="activity-filters"
          phx-change="filter"
          class="mt-6 flex flex-wrap items-end gap-3 rounded-2xl border border-base-content/10 bg-base-100 p-4"
        >
          <label class="min-w-52 flex-1">
            <span class="mb-1 block text-xs font-medium text-base-content/60">Search</span>
            <.input field={@form[:search]} type="search" placeholder="action, server, details…" />
          </label>
          <label class="w-48">
            <span class="mb-1 block text-xs font-medium text-base-content/60">Server</span>
            <.input
              field={@form[:server_id]}
              type="select"
              options={[{"All servers", ""} | for(s <- @servers, do: {s.name, to_string(s.id)})]}
            />
          </label>
          <label class="w-40">
            <span class="mb-1 block text-xs font-medium text-base-content/60">Result</span>
            <.input
              field={@form[:result]}
              type="select"
              options={[{"All", "all"}, {"Success", "ok"}, {"Failed", "failed"}]}
            />
          </label>
          <button
            type="button"
            id="activity-clear"
            phx-click="clear-filters"
            class="btn btn-ghost btn-sm"
          >Clear</button>
        </.form>

        <div
          id="activity-list"
          class="mt-5 overflow-hidden rounded-2xl border border-base-content/10 bg-base-100"
        >
          <div
            :for={log <- @logs}
            id={"activity-#{log.id}"}
            class="grid grid-cols-[auto_1fr_auto] items-start gap-x-4 gap-y-1 border-b border-base-content/5 px-4 py-3 last:border-0 sm:grid-cols-[110px_150px_1fr_auto]"
          >
            <span class="font-mono text-xs text-base-content/50">{Calendar.strftime(
              log.inserted_at,
              "%m/%d %H:%M:%S"
            )}</span>
            <span class="truncate text-sm font-semibold">{(log.server && log.server.name) ||
              "deleted server"}</span>
            <span class="min-w-0">
              <span class="text-sm">{log.action}</span>
              <span :if={log.container} class="ml-2 font-mono text-xs text-base-content/50">{log.container}</span>
              <span :if={log.details} class="block truncate font-mono text-xs text-base-content/50">{log.details}</span>
            </span>
            <span class={[
              "badge badge-sm",
              result_label(log.details) == "ok" && "badge-success",
              result_label(log.details) == "failed" && "badge-error"
            ]}>
              {result_label(log.details)}
            </span>
          </div>
          <div :if={@logs == []} class="px-4 py-10 text-center text-sm text-base-content/50">
            No activity matches these filters.
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
