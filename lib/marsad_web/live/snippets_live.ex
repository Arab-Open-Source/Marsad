defmodule MarsadWeb.SnippetsLive do
  @moduledoc "Saved commands/runbooks with variables and multi-server execution."

  use MarsadWeb, :live_view

  alias Marsad.Fleet
  alias Marsad.Snippets
  alias Marsad.Snippets.Snippet

  @empty %{
    "name" => "",
    "description" => "",
    "category" => "general",
    "command" => "",
    "variables" => ""
  }

  @impl true
  def mount(params, _session, socket) do
    snippets = Snippets.list_snippets()

    selected =
      if id = params["run"],
        do: Enum.find(snippets, &("#{&1.id}" == "#{id}")),
        else: List.first(snippets)

    {:ok,
     socket
     |> assign(:page_title, "Runbooks")
     |> assign(:snippets, snippets)
     |> assign(:servers, Fleet.list_servers())
     |> assign(:selected, selected)
     |> assign(:form, to_form(@empty))
     |> assign(:editing_id, nil)
     |> assign(:show_form, false)
     |> assign(:values, %{})
     |> assign(:targets, %{})
     |> assign(:run_form, to_form(%{}))
     |> assign(:results, nil)
     |> assign(:run_busy, false)}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, to_form(@empty))
     |> assign(:editing_id, nil)
     |> assign(:show_form, true)}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.snippets, &("#{&1.id}" == "#{id}")) do
      nil ->
        {:noreply, socket}

      snippet ->
        attrs = %{
          "name" => snippet.name,
          "description" => snippet.description || "",
          "category" => snippet.category || "general",
          "command" => snippet.command,
          "variables" => snippet.variables || ""
        }

        {:noreply,
         socket
         |> assign(:form, to_form(attrs))
         |> assign(:editing_id, snippet.id)
         |> assign(:show_form, true)}
    end
  end

  def handle_event("cancel-form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_form, false)
     |> assign(:form, to_form(@empty))
     |> assign(:editing_id, nil)}
  end

  def handle_event("save", %{"snippet" => attrs}, socket) do
    attrs = Map.put_new(attrs, "variables", "")

    result =
      if id = socket.assigns.editing_id do
        Snippets.update_snippet(Snippets.get_snippet!(id), attrs)
      else
        Snippets.create_snippet(attrs)
      end

    case result do
      {:ok, snippet} ->
        {:noreply,
         socket
         |> assign(:snippets, Snippets.list_snippets())
         |> assign(:selected, snippet)
         |> assign(:show_form, false)
         |> assign(:editing_id, nil)
         |> assign(:form, to_form(@empty))
         |> assign(:values, %{})
         |> put_flash(:info, "Runbook #{snippet.name} saved.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset))
         |> put_flash(:error, "Could not save: #{inspect(changeset.errors)}")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.snippets, &("#{&1.id}" == "#{id}")) do
      nil ->
        {:noreply, socket}

      snippet ->
        {:ok, _} = Snippets.delete_snippet(snippet)
        snippets = Snippets.list_snippets()

        {:noreply,
         socket
         |> assign(:snippets, snippets)
         |> assign(
           :selected,
           if(socket.assigns.selected && socket.assigns.selected.id == snippet.id,
             do: List.first(snippets),
             else: socket.assigns.selected
           )
         )
         |> put_flash(:info, "Runbook #{snippet.name} deleted.")}
    end
  end

  def handle_event("select", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.snippets, &("#{&1.id}" == "#{id}")) do
      nil ->
        {:noreply, socket}

      snippet ->
        {:noreply,
         socket |> assign(:selected, snippet) |> assign(:values, %{}) |> assign(:results, nil)}
    end
  end

  def handle_event("run-input", params, socket) do
    values = for {k, v} <- params, k not in ["_csrf_token", "servers"], into: %{}, do: {k, v}

    targets =
      Map.get(params, "servers", %{}) |> Map.new(fn {k, v} -> {k, v != "false" and v != nil} end)

    {:noreply, socket |> assign(:values, values) |> assign(:targets, targets)}
  end

  def handle_event("run", _params, socket) do
    snippet = socket.assigns.selected

    if is_nil(snippet) do
      {:noreply, put_flash(socket, :error, "Select a runbook first.")}
    else
      command = Snippets.render(snippet.command, socket.assigns.values)

      server_ids =
        socket.assigns.targets
        |> Enum.filter(fn {_id, on?} -> on? end)
        |> Enum.map(fn {id, _} -> id end)

      if server_ids == [] do
        {:noreply, put_flash(socket, :error, "Select at least one server.")}
      else
        lv = self()
        servers = socket.assigns.servers
        ref = make_ref()

        Task.start(fn ->
          results =
            server_ids
            |> Task.async_stream(
              fn sid ->
                server = Enum.find(servers, &("#{&1.id}" == "#{sid}"))

                case Fleet.exec(String.to_integer(sid), command, 30_000) do
                  {:ok, result} ->
                    %{
                      server: (server && server.name) || sid,
                      ok: true,
                      output: result.stdout <> result.stderr
                    }

                  {:error, reason} ->
                    %{
                      server: (server && server.name) || sid,
                      ok: false,
                      output: "error: #{inspect(reason)}"
                    }
                end
              end,
              timeout: 45_000,
              ordered: true
            )
            |> Enum.map(fn {:ok, result} -> result end)

          send(lv, {:run_done, ref, results})
        end)

        {:noreply, socket |> assign(:run_busy, true) |> assign(:results, nil)}
      end
    end
  end

  @impl true
  def handle_info({:run_done, _ref, results}, socket) do
    {:noreply, socket |> assign(:run_busy, false) |> assign(:results, results)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="snippets-page" class="mx-auto w-full max-w-7xl px-4 py-8 sm:px-6">
        <div class="flex flex-wrap items-end justify-between gap-4">
          <div>
            <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
              Marsad · Fleet
            </p>
            <h1 class="mt-1 text-3xl font-bold tracking-tight">Runbooks</h1>
            <p class="mt-1 text-sm text-base-content/60">
              Reusable commands with variables — run them on one or many servers.
            </p>
          </div>
          <div class="flex gap-2">
            <button id="snippet-new" phx-click="new" class="btn btn-primary gap-2">
              <.icon name="hero-plus" class="size-4" /> New runbook
            </button>
            <.link
              navigate={~p"/desktop"}
              id="snippets-back-desktop"
              class="btn btn-ghost border border-base-content/15"
            >← Desktop</.link>
          </div>
        </div>

        <%= if @show_form do %>
          <.form
            for={@form}
            id="snippet-form"
            phx-submit="save"
            class="mt-6 grid gap-4 rounded-2xl border border-base-content/10 bg-base-100 p-5 md:grid-cols-2"
          >
            <label>
              <span class="mb-1 block text-xs font-medium text-base-content/60">Name</span>
              <.input field={@form[:name]} placeholder="e.g. Check disk usage" />
            </label>
            <label>
              <span class="mb-1 block text-xs font-medium text-base-content/60">Category</span>
              <.input field={@form[:category]} placeholder="general" />
            </label>
            <label class="md:col-span-2">
              <span class="mb-1 block text-xs font-medium text-base-content/60">Description</span>
              <.input field={@form[:description]} placeholder="What does this runbook do?" />
            </label>
            <label class="md:col-span-2">
              <span class="mb-1 block text-xs font-medium text-base-content/60">Command — use {"{{name}}"} for variables</span>
              <.input field={@form[:command]} type="textarea" rows={4} class="font-mono" />
            </label>
            <label class="md:col-span-2">
              <span class="mb-1 block text-xs font-medium text-base-content/60">Variables (auto-detected from command, or comma-separated)</span>
              <.input field={@form[:variables]} placeholder="host, path" />
            </label>
            <div class="flex gap-2 md:col-span-2">
              <button type="submit" id="snippet-save" class="btn btn-primary btn-sm">Save</button>
              <button
                type="button"
                id="snippet-cancel"
                phx-click="cancel-form"
                class="btn btn-ghost btn-sm"
              >Cancel</button>
            </div>
          </.form>
        <% end %>

        <div class="mt-6 grid gap-5 lg:grid-cols-[320px_1fr]">
          <%!-- Runbook list --%>
          <div
            id="snippet-list"
            class="h-fit overflow-hidden rounded-2xl border border-base-content/10 bg-base-100"
          >
            <div
              :for={snippet <- @snippets}
              id={"snippet-#{snippet.id}"}
              class={[
                "flex items-start gap-2 border-b border-base-content/5 p-3 last:border-0",
                @selected && @selected.id == snippet.id && "bg-[color:var(--marsad-accent)]/10"
              ]}
            >
              <button phx-click="select" phx-value-id={snippet.id} class="min-w-0 flex-1 text-left">
                <span class="block truncate text-sm font-semibold">{snippet.name}</span>
                <span class="block truncate text-xs text-base-content/50">{snippet.description}</span>
              </button>
              <button
                id={"snippet-edit-#{snippet.id}"}
                phx-click="edit"
                phx-value-id={snippet.id}
                title="Edit"
                class="rounded p-1 text-base-content/50 hover:bg-base-content/10"
              >
                <.icon name="hero-pencil" class="size-3.5" />
              </button>
              <button
                id={"snippet-delete-#{snippet.id}"}
                phx-click="delete"
                phx-value-id={snippet.id}
                title="Delete"
                class="rounded p-1 text-base-content/50 hover:bg-error/10 hover:text-error"
              >
                <.icon name="hero-trash" class="size-3.5" />
              </button>
            </div>
            <div :if={@snippets == []} class="p-6 text-center text-sm text-base-content/50">
              No runbooks saved yet.
            </div>
          </div>

          <%!-- Run panel --%>
          <div
            :if={@selected}
            id="snippet-run-panel"
            class="rounded-2xl border border-base-content/10 bg-base-100 p-5"
          >
            <h2 class="text-xl font-semibold">{@selected.name}</h2>
            <p :if={@selected.description} class="mt-1 text-sm text-base-content/60">
              {@selected.description}
            </p>
            <pre class="mt-4 overflow-x-auto rounded-xl bg-base-200/70 p-3 font-mono text-xs"><code>{@selected.command}</code></pre>

            <.form
              for={@run_form}
              id="snippet-run-form"
              phx-change="run-input"
              phx-submit="run"
              class="mt-5 grid gap-4"
            >
              <div>
                <span class="mb-2 block text-xs font-semibold uppercase tracking-wide text-base-content/50">Target servers</span>
                <div class="flex flex-wrap gap-3">
                  <label
                    :for={server <- @servers}
                    class="flex items-center gap-2 rounded-lg border border-base-content/10 px-3 py-1.5 text-sm"
                  >
                    <input
                      type="checkbox"
                      name={"servers[#{server.id}]"}
                      value="true"
                      checked={Map.get(@targets, to_string(server.id), false)}
                      class="checkbox checkbox-sm checkbox-primary"
                    />
                    {server.name}
                  </label>
                  <span :if={@servers == []} class="text-sm text-base-content/50">No servers configured.</span>
                </div>
              </div>

              <div :if={Snippet.variable_list(@selected) != []} class="grid gap-3 sm:grid-cols-2">
                <label :for={var <- Snippet.variable_list(@selected)}>
                  <span class="mb-1 block font-mono text-xs text-base-content/60">{var}</span>
                  <input
                    type="text"
                    name={var}
                    value={Map.get(@values, var, "")}
                    placeholder={var}
                    class="input input-bordered input-sm w-full font-mono"
                  />
                </label>
              </div>

              <div>
                <button
                  type="submit"
                  id="snippet-run"
                  phx-disable-with="Running…"
                  class="btn btn-primary btn-sm gap-2"
                  disabled={@run_busy}
                >
                  <.icon name="hero-play" class="size-4" /> Run on selected servers
                </button>
              </div>
            </.form>

            <div :if={@results} id="snippet-results" class="mt-5 space-y-3">
              <div
                :for={result <- @results}
                class="rounded-xl border border-base-content/10 bg-base-200/40 p-3"
              >
                <div class="mb-1 flex items-center justify-between">
                  <span class="text-sm font-semibold">{result.server}</span>
                  <span class={[
                    "badge badge-sm",
                    result.ok && "badge-success",
                    !result.ok && "badge-error"
                  ]}>
                    {if result.ok, do: "ok", else: "failed"}
                  </span>
                </div>
                <pre class="max-h-72 overflow-auto whitespace-pre-wrap font-mono text-xs text-base-content/70"><code>{result.output}</code></pre>
              </div>
            </div>
          </div>

          <div
            :if={!@selected}
            class="rounded-2xl border border-dashed border-base-content/20 p-10 text-center text-sm text-base-content/50"
          >
            Select a runbook to run it.
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
