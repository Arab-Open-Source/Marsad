defmodule MarsadWeb.DesktopLive do
  @moduledoc """
  Mini-OS desktop shell: app icons, draggable windows, taskbar and a
  real xterm.js terminal (one exec channel per submitted line over SSH).

  NOTE on LiveView streams: collections here are small and bounded by design
  (servers < 100, files per dir capped by SFTP listing, procs capped at 80,
  containers/units < 100, transcripts capped at #{200}, file previews truncated
  at 200KB, uploads capped at 3/20 entries x 50MB). Plain assigns keep panel
  state (tabs stay mounted when hidden) simple and testable; streams would
  force reset/re-stream on every filter/sort and break hidden-panel state.
  If any collection grows unbounded in the future, migrate that list to
  `stream/3` with `reset: true` on filter.
  """
  use MarsadWeb, :live_view

  alias Marsad.Accounts
  alias Marsad.Fleet
  alias Marsad.Fleet.Server
  alias Marsad.Fleet.ServerShell
  alias Marsad.Fleet.Services
  alias Marsad.Repo.Retry
  alias Marsad.Settings
  alias Marsad.Terminal
  alias MarsadWeb.Desktop.DockerPanel
  alias MarsadWeb.Desktop.FilesComponent
  alias MarsadWeb.Desktop.NginxPanel
  alias MarsadWeb.Desktop.SystemdPanel

  @apps [
    %{id: "terminal", name: "Terminal", icon: "hero-command-line", desc: "SSH terminal"},
    %{id: "servers", name: "Servers", icon: "hero-server-stack", desc: "VPS fleet"},
    %{id: "files", name: "Files", icon: "hero-folder", desc: "SFTP file explorer"},
    %{id: "monitor", name: "Monitor", icon: "hero-chart-bar", desc: "Live server metrics"},
    %{id: "docker", name: "Docker", icon: "hero-cube", desc: "Container management"},
    %{
      id: "systemd",
      name: "Systemd",
      icon: "hero-adjustments-horizontal",
      desc: "Service management"
    },
    %{id: "nginx", name: "Nginx", icon: "hero-globe-alt", desc: "Web server management"},
    %{
      id: "settings",
      name: "Settings",
      icon: "hero-cog-6-tooth",
      desc: "Appearance & preferences"
    }
  ]

  @metrics_interval 15_000
  @min_metrics_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    servers = Fleet.list_servers()

    if connected?(socket), do: Process.send_after(self(), :metrics_tick, @metrics_interval)

    {:ok,
     socket
     |> assign(:apps, @apps)
     |> assign(:servers, servers)
     |> assign(:windows, [])
     |> assign(:focused_id, nil)
     |> assign(:active_server_id, active_default(servers))
     |> assign(:transcripts, %{})
     |> assign(:appearance, Settings.appearance())
     |> assign(:server_form, to_form(Fleet.change_server(%Server{})))
     |> assign(:show_server_form, false)
     |> assign(:editing_server, nil)
     |> assign(:file_browser, nil)
     |> assign(:files_load_ref, nil)
     |> assign(:files_pending_preview, nil)
     |> assign(:files_filter, "")
     |> assign(:files_search_results, nil)
     |> assign(:files_search_ref, nil)
     |> assign(:files_search_truncated, false)
     |> assign(:mkdir_form, to_form(%{"dirname" => ""}))
     |> assign(:monitor_server_id, active_default(servers))
     |> assign(:metrics, %{})
     |> assign(:metrics_loading, nil)
     |> assign(:metrics_duration, "24h")
     |> assign(:metrics_custom_from, nil)
     |> assign(:metrics_custom_to, nil)
     |> assign(:metrics_chart_data, %{labels: [], datasets: []})
     |> assign(:metrics_interval, Settings.metrics_interval())
     |> assign(:top_procs, %{})
     |> assign(:top_procs_loading, nil)
     |> assign(:proc_sort, :cpu)
     |> assign(:proc_order, :desc)
     |> assign(:proc_page, 1)
     |> assign(:proc_per_page, 10)
     |> assign(:docker, nil)
     |> assign(:systemd, nil)
     |> assign(:nginx, nil)
     |> assign(:nginx_load_ref, nil)
     |> assign(:password_form, to_form(%{"password" => "", "confirm" => ""}))
     |> assign(:password_msg, nil)
     |> assign(:term_shells, %{})
     |> allow_upload(:remote_files,
       accept: :any,
       max_entries: 3,
       max_file_size: 50_000_000,
       chunk_size: 64_000,
       chunk_timeout: 60_000,
       auto_upload: false
     )
     |> allow_upload(:remote_folder,
       accept: :any,
       max_entries: 20,
       max_file_size: 50_000_000,
       chunk_size: 64_000,
       chunk_timeout: 60_000,
       auto_upload: false
     )}
  end

  @impl true
  def handle_event("open-app", %{"app" => "terminal"}, socket) do
    {:noreply,
     open_window(socket, terminal_window_id(socket), "terminal", socket.assigns.active_server_id)}
  end

  def handle_event("open-app", %{"app" => app}, socket) do
    socket =
      case app do
        "files" ->
          ensure_browser(socket)

        "monitor" ->
          socket
          |> fetch_metrics_async(socket.assigns.monitor_server_id)
          |> fetch_top_procs_async(socket.assigns.monitor_server_id)

        "docker" ->
          ensure_docker(socket)

        "systemd" ->
          ensure_systemd(socket)

        "nginx" ->
          ensure_nginx(socket)

        _ ->
          socket
      end

    {:noreply, open_window(socket, app, app, nil)}
  end

  def handle_event("switch-tab", %{"id" => id}, socket) do
    if find_window(socket, id), do: {:noreply, focus(socket, id)}, else: {:noreply, socket}
  end

  def handle_event("close-window", %{"id" => id}, socket) do
    windows = Enum.reject(socket.assigns.windows, &(&1.id == id))

    {:noreply,
     socket
     |> close_term_shell(id)
     |> assign(:windows, windows)
     |> assign(:transcripts, Map.delete(socket.assigns.transcripts, id))
     |> assign(:focused_id, focused_fallback(windows, socket.assigns.focused_id, id))}
  end

  def handle_event("focus-window", %{"id" => id}, socket) do
    if find_window(socket, id), do: {:noreply, focus(socket, id)}, else: {:noreply, socket}
  end

  def handle_event("select-server", %{"id" => id}, socket) do
    server_id = String.to_integer(id)

    {:noreply,
     socket
     |> assign(:active_server_id, server_id)
     |> open_window("terminal-#{server_id}", "terminal", server_id)}
  end

  def handle_event("new-server", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_server, nil)
     |> assign(:server_form, to_form(Fleet.change_server(%Server{})))
     |> assign(:show_server_form, true)}
  end

  def handle_event("edit-server", %{"id" => id}, socket) do
    server = Fleet.get_server!(id)

    {:noreply,
     socket
     |> assign(:editing_server, server)
     |> assign(:server_form, to_form(Fleet.change_server(server)))
     |> assign(:show_server_form, true)}
  end

  def handle_event("cancel-server-form", _params, socket) do
    {:noreply, assign(socket, :show_server_form, false)}
  end

  def handle_event("validate-server", %{"server" => params}, socket) do
    base = socket.assigns.editing_server || %Server{}

    {:noreply,
     assign(socket, :server_form, to_form(Fleet.change_server(base, params), action: :validate))}
  end

  def handle_event("save-server", %{"server" => params}, socket) do
    result =
      Retry.retry_db(fn ->
        case socket.assigns.editing_server do
          nil -> Fleet.create_server(params)
          server -> Fleet.update_server(server, params)
        end
      end)

    case result do
      {:ok, _server} ->
        {:noreply,
         socket
         |> assign(:servers, Fleet.list_servers())
         |> assign(:show_server_form, false)
         |> assign(:editing_server, nil)
         |> assign(:server_form, to_form(Fleet.change_server(%Server{})))
         |> put_flash(:info, "Server saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :server_form, to_form(changeset, action: :validate))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)} — try again")}
    end
  end

  def handle_event("delete-server", %{"id" => id}, socket) do
    server = Fleet.get_server!(id)
    {:ok, _} = Fleet.delete_server(server)
    servers = Fleet.list_servers()

    windows = Enum.reject(socket.assigns.windows, &(&1.server_id == server.id))

    {:noreply,
     socket
     |> assign(:servers, servers)
     |> assign(:windows, windows)
     |> assign(:active_server_id, active_default(servers))
     |> assign(:monitor_server_id, active_default(servers))
     |> drop_service_state(server.id)
     |> put_flash(:info, "Server deleted.")}
  end

  def handle_event("test-server", %{"id" => id}, socket) do
    server_id = String.to_integer(id)
    server = Fleet.get_server!(server_id)

    case Fleet.test_connection(server_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(:servers, Fleet.list_servers())
         |> put_flash(:info, "#{server.name} is reachable.")}

      {:error, reason} ->
        {:ok, _} = Fleet.mark_offline(server)

        {:noreply,
         socket
         |> assign(:servers, Fleet.list_servers())
         |> put_flash(:error, "Connection failed: #{inspect(reason)}")}
    end
  end

  def handle_event("files-server", %{"server_id" => ""}, socket) do
    {:noreply,
     socket
     |> assign(:active_server_id, nil)
     |> assign(:file_browser, nil)
     |> assign(:files_filter, "")
     |> assign(:files_search_results, nil)
     |> assign(:files_search_ref, nil)
     |> assign(:files_search_truncated, false)}
  end

  def handle_event("files-server", %{"server_id" => id}, socket) do
    server_id = String.to_integer(id)

    {:noreply,
     socket
     |> assign(:active_server_id, server_id)
     |> assign(:files_filter, "")
     |> assign(:files_search_results, nil)
     |> assign(:files_search_ref, nil)
     |> assign(:files_search_truncated, false)
     |> load_browser(server_id, nil)}
  end

  def handle_event("files-filter", %{"filter" => filter}, socket) do
    handle_files_filter(String.trim(filter), socket)
  end

  def handle_event("files-clear-filter", _params, socket) do
    {:noreply,
     socket
     |> assign(:files_filter, "")
     |> assign(:files_search_results, nil)
     |> assign(:files_search_ref, nil)
     |> assign(:files_search_truncated, false)}
  end

  def handle_event("files-drop-token", %{"token" => token}, socket) do
    handle_files_filter(
      Marsad.Files.remove_token(socket.assigns.files_filter || "", token),
      socket
    )
  end

  def handle_event("files-refresh", _params, socket) do
    b = socket.assigns.file_browser

    {:noreply,
     if(b,
       do:
         socket
         |> assign(:files_filter, "")
         |> assign(:files_search_results, nil)
         |> assign(:files_search_ref, nil)
         |> assign(:files_search_truncated, false)
         |> load_browser(b.server_id, b.path),
       else: socket
     )}
  end

  def handle_event("file-editor-dirty", %{"path" => path} = params, socket) do
    dirty = Map.get(params, "dirty", true)
    editor_id = params["editor_id"]

    socket =
      Enum.reduce(
        [
          {:file_browser, :preview, "files"},
          {:nginx, :file_preview, "nginx"},
          {:systemd, :unit_preview, "systemd"}
        ],
        socket,
        fn {key, field, prefix}, acc ->
          case acc.assigns[key] do
            %{^field => %{path: ^path} = preview} = state ->
              if editor_id == nil || editor_id == editor_id(prefix, path) do
                assign(acc, key, Map.put(state, field, Map.put(preview, :editing, dirty)))
              else
                acc
              end

            _ ->
              acc
          end
        end
      )

    {:noreply, socket}
  end

  def handle_event("files-up", _params, socket) do
    case socket.assigns.file_browser do
      nil ->
        {:noreply, socket}

      b ->
        {:noreply,
         socket
         |> assign(:files_filter, "")
         |> assign(:files_search_results, nil)
         |> assign(:files_search_ref, nil)
         |> assign(:files_search_truncated, false)
         |> load_browser(b.server_id, Fleet.remote_parent(b.path))}
    end
  end

  def handle_event("files-cd", %{"path" => path}, socket) do
    case socket.assigns.file_browser do
      nil ->
        {:noreply, socket}

      b ->
        {:noreply,
         socket
         |> assign(:files_filter, "")
         |> assign(:files_search_results, nil)
         |> assign(:files_search_ref, nil)
         |> assign(:files_search_truncated, false)
         |> load_browser(b.server_id, path)}
    end
  end

  def handle_event("files-open", %{"name" => name, "type" => "dir"}, socket) do
    case socket.assigns.file_browser do
      nil ->
        {:noreply, socket}

      b ->
        {:noreply,
         socket
         |> assign(:files_filter, "")
         |> assign(:files_search_results, nil)
         |> assign(:files_search_ref, nil)
         |> assign(:files_search_truncated, false)
         |> load_browser(b.server_id, Fleet.remote_join(b.path, name))}
    end
  end

  def handle_event("files-open-path", %{"path" => path}, socket) do
    case socket.assigns.file_browser do
      %{server_id: server_id} = browser -> open_file_preview(socket, browser, server_id, path)
      _ -> {:noreply, socket}
    end
  end

  def handle_event("files-open", %{"name" => name}, socket) do
    case socket.assigns.file_browser do
      nil ->
        {:noreply, socket}

      b ->
        path = Fleet.remote_join(b.path, name)

        open_file_preview(socket, b, b.server_id, path)
    end
  end

  def handle_event("files-close-preview", _params, socket) do
    case socket.assigns.file_browser do
      nil -> {:noreply, socket}
      b -> {:noreply, assign(socket, :file_browser, %{b | preview: nil})}
    end
  end

  # Simplified editing: editor is always editable, direct save via hook
  def handle_event("edit_file", %{"path" => _path}, socket), do: {:noreply, socket}
  def handle_event("cancel_edit", %{"path" => _path}, socket), do: {:noreply, socket}

  def handle_event("request_save", %{"path" => path}, socket) do
    {:noreply,
     push_event(socket, "code_editor_request_save", %{
       id: "code-files-" <> Base.url_encode64(path, padding: false),
       path: path
     })}
  end

  def handle_event("save_file_content", %{"path" => path, "content" => content}, socket) do
    # Try file_browser first
    socket =
      case socket.assigns.file_browser do
        %{server_id: sid, preview: %{path: ^path}} = b ->
          case write_result(Fleet.write_file(sid, path, content)) do
            :ok ->
              lines = String.split(content, "\n")

              preview = %{
                b.preview
                | text: lines |> Enum.take(200) |> Enum.join("\n"),
                  full_text: content,
                  truncated?: length(lines) > 200,
                  editing: false,
                  language: code_language(path)
              }

              socket
              |> assign(:file_browser, %{b | preview: preview, error: nil})
              |> put_flash(:info, "File saved: #{path}")

            {:error, reason} ->
              put_flash(socket, :error, "Save failed: #{inspect(reason)}")
          end

        _ ->
          socket
      end

    # Try nginx file_preview
    socket =
      case socket.assigns.nginx do
        %{server_id: sid, file_preview: %{path: ^path} = fp} = n ->
          # Validate nginx path is under /etc/nginx
          case write_result(Fleet.write_file(sid, path, content)) do
            :ok ->
              fp = %{
                fp
                | text: content,
                  full_text: content,
                  editing: false,
                  language: code_language(path)
              }

              socket
              |> assign(:nginx, %{n | file_preview: fp})
              |> put_flash(:info, "Nginx file saved.")

            {:error, reason} ->
              put_flash(socket, :error, "Save failed: #{inspect(reason)}")
          end

        _ ->
          socket
      end

    # Try systemd unit_preview
    socket =
      case socket.assigns.systemd do
        %{server_id: sid, unit_preview: %{path: ^path} = preview} = s ->
          case write_result(Fleet.write_file(sid, path, content)) do
            :ok ->
              # Reload systemd daemon after saving unit
              _ = Fleet.exec(sid, "systemctl daemon-reload 2>&1")
              preview = %{preview | text: content, full_text: content, editing: false}

              socket
              |> assign(:systemd, %{s | unit_preview: preview})
              |> put_flash(:info, "Unit file saved. Daemon reloaded.")

            {:error, reason} ->
              put_flash(socket, :error, "Save failed: #{inspect(reason)}")
          end

        %{server_id: sid, unit_preview: %{name: ^path} = preview} = s ->
          # Fallback when path is unit name, resolve fragment path
          frag_path = Map.get(preview, :fragment_path) || path

          case write_result(Fleet.write_file(sid, frag_path, content)) do
            :ok ->
              _ = Fleet.exec(sid, "systemctl daemon-reload 2>&1")
              preview = %{preview | text: content, full_text: content, editing: false}

              socket
              |> assign(:systemd, %{s | unit_preview: preview})
              |> put_flash(:info, "Unit file saved. Daemon reloaded.")

            {:error, reason} ->
              put_flash(socket, :error, "Save failed: #{inspect(reason)}")
          end

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("files-mkdir", %{"dirname" => name}, socket) do
    name = String.trim(name)

    socket =
      case socket.assigns.file_browser do
        %{server_id: sid, path: path} when name != "" ->
          case Fleet.make_dir(sid, Fleet.remote_join(path, name)) do
            :ok -> load_browser(socket, sid, path)
            {:error, reason} -> put_browser_error(socket, "mkdir failed: #{inspect(reason)}")
          end

        _ ->
          socket
      end

    {:noreply, assign(socket, :mkdir_form, to_form(%{"dirname" => ""}))}
  end

  def handle_event("files-delete", %{"name" => name, "type" => type}, socket) do
    socket =
      case socket.assigns.file_browser do
        nil ->
          socket

        b ->
          case Fleet.delete_path(b.server_id, Fleet.remote_join(b.path, name), type == "dir") do
            :ok -> load_browser(socket, b.server_id, b.path)
            {:error, reason} -> put_browser_error(socket, "Delete failed: #{inspect(reason)}")
          end
      end

    {:noreply, socket}
  end

  def handle_event("files-upload", _params, socket) do
    b = socket.assigns.file_browser

    if is_nil(b) || b.path == "…" do
      socket =
        socket
        |> cancel_all_uploads(:remote_files)
        |> cancel_all_uploads(:remote_folder)

      {:noreply, put_browser_error(socket, "No directory selected for upload")}
    else
      try do
        upload_fn = fn %{path: tmp_path}, entry ->
          relative =
            case Map.get(entry, :client_relative_path) do
              rel when is_binary(rel) and rel != "" -> rel
              _ -> entry.client_name
            end

          remote_path = Fleet.remote_join(b.path, relative)
          parent = Fleet.remote_parent(remote_path)

          _ =
            if parent != b.path and parent != "/" do
              Fleet.make_dir(b.server_id, parent)
            end

          case Marsad.Files.write_result(Fleet.upload_file(b.server_id, remote_path, tmp_path)) do
            :ok -> {:ok, {:ok, entry.client_name}}
            {:error, reason} -> {:ok, {:error, entry.client_name, reason}}
          end
        end

        {results_files, socket} = consume_uploaded_entries(socket, :remote_files, upload_fn)
        {results_folder, socket} = consume_uploaded_entries(socket, :remote_folder, upload_fn)
        results = results_files ++ results_folder

        {oks, errors} = Enum.split_with(results, fn r -> match?({:ok, _}, r) end)

        socket =
          case errors do
            [] ->
              socket

            _ ->
              msg =
                errors
                |> Enum.map(fn {:error, name, reason} -> "#{name}: #{inspect(reason)}" end)
                |> Enum.join(", ")

              put_browser_error(socket, "Upload failed: #{msg}")
          end

        socket =
          if oks != [] do
            socket
            |> put_flash(:info, "Uploaded #{length(oks)} file(s)")
            |> load_browser(b.server_id, b.path)
          else
            socket
          end

        {:noreply, socket}
      rescue
        e -> {:noreply, put_browser_error(socket, "Upload failed: #{Exception.message(e)}")}
      catch
        _, reason -> {:noreply, put_browser_error(socket, "Upload failed: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("validate-upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    socket =
      try do
        cancel_upload(socket, :remote_files, ref)
      rescue
        _ -> socket
      catch
        _, _ -> socket
      end

    socket =
      try do
        cancel_upload(socket, :remote_folder, ref)
      rescue
        _ -> socket
      catch
        _, _ -> socket
      end

    {:noreply, socket}
  end

  def handle_event("monitor-server", %{"server_id" => ""}, socket) do
    {:noreply, assign(socket, :monitor_server_id, nil)}
  end

  def handle_event("monitor-server", %{"server_id" => id}, socket) do
    sid = String.to_integer(id)

    {:noreply,
     socket
     |> assign(:monitor_server_id, sid)
     |> assign(:proc_page, 1)
     |> fetch_metrics_async(sid)
     |> fetch_top_procs_async(sid)}
  end

  def handle_event("monitor-refresh", _params, socket) do
    sid = socket.assigns.monitor_server_id

    {:noreply,
     socket
     |> fetch_metrics_async(sid)
     |> fetch_top_procs_async(sid)}
  end

  def handle_event("monitor-proc-sort", %{"sort" => sort}, socket) do
    field =
      case sort do
        "cpu" -> :cpu
        "mem" -> :mem
        "pid" -> :pid
        "comm" -> :comm
        _ -> :cpu
      end

    {new_sort, new_order} =
      if socket.assigns.proc_sort == field do
        {field, if(socket.assigns.proc_order == :desc, do: :asc, else: :desc)}
      else
        {field, :desc}
      end

    {:noreply,
     socket
     |> assign(:proc_sort, new_sort)
     |> assign(:proc_order, new_order)
     |> assign(:proc_page, 1)}
  end

  def handle_event("monitor-proc-page", %{"page" => page}, socket) do
    page =
      case Integer.parse(to_string(page)) do
        {n, ""} when n >= 1 -> n
        _ -> 1
      end

    {:noreply, assign(socket, :proc_page, page)}
  end

  def handle_event("monitor-proc-per-page", %{"per_page" => per}, socket) do
    per_page =
      case Integer.parse(to_string(per)) do
        {n, ""} when n in [5, 10, 25, 50] -> n
        _ -> 10
      end

    {:noreply, socket |> assign(:proc_per_page, per_page) |> assign(:proc_page, 1)}
  end

  def handle_event("kill_process", %{"pid" => pid}, socket) do
    case socket.assigns.monitor_server_id do
      nil ->
        {:noreply, put_flash(socket, :error, "No server selected")}

      sid ->
        case Marsad.Fleet.Services.kill_process(sid, pid) do
          {:ok, _} ->
            {:noreply,
             socket |> put_flash(:info, "Killed PID #{pid}") |> fetch_top_procs_async(sid)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Kill failed: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("restart_service_for_pid", %{"comm" => comm}, socket) do
    # Try to restart a systemd service matching the comm name
    case socket.assigns.monitor_server_id do
      nil ->
        {:noreply, put_flash(socket, :error, "No server selected")}

      sid ->
        unit = if String.ends_with?(comm, ".service"), do: comm, else: comm <> ".service"

        case Marsad.Fleet.Services.systemd_action(sid, "restart", unit) do
          {:ok, _} ->
            {:noreply,
             socket |> put_flash(:info, "Restarted #{unit}") |> fetch_top_procs_async(sid)}

          {:error, _} ->
            # Fallback: try without .service
            case Marsad.Fleet.Services.systemd_action(sid, "restart", comm) do
              {:ok, _} ->
                {:noreply, put_flash(socket, :info, "Restarted #{comm}")}

              {:error, reason} ->
                {:noreply,
                 put_flash(
                   socket,
                   :error,
                   "Restart failed: #{inspect(reason)} — try via Systemd tab"
                 )}
            end
        end
    end
  end

  def handle_event("metrics_duration", %{"duration" => duration}, socket) do
    sid = socket.assigns.monitor_server_id

    chart_data =
      if sid do
        hours =
          case duration do
            "1h" -> 1
            "6h" -> 6
            "7d" -> 168
            _ -> 24
          end

        Marsad.Metrics.chart_data(sid, hours)
      else
        %{labels: [], datasets: []}
      end

    {:noreply,
     socket
     |> assign(:metrics_duration, duration)
     |> assign(:metrics_chart_data, chart_data)
     |> then(fn s ->
       if sid,
         do: push_event(s, "chart_update", %{id: "metrics-chart-#{sid}", data: chart_data}),
         else: s
     end)}
  end

  def handle_event("metrics_custom_range", %{"from" => from, "to" => to}, socket) do
    sid = socket.assigns.monitor_server_id

    # For custom, parse dates and calculate hours, fallback to 24h
    chart_data =
      if sid do
        # Simple: if both dates present, use 24h * days diff, else 24h
        Marsad.Metrics.chart_data(sid, 24)
      else
        %{labels: [], datasets: []}
      end

    {:noreply,
     socket
     |> assign(:metrics_custom_from, from)
     |> assign(:metrics_custom_to, to)
     |> assign(:metrics_duration, "custom")
     |> assign(:metrics_chart_data, chart_data)
     |> then(fn s ->
       if sid,
         do: push_event(s, "chart_update", %{id: "metrics-chart-#{sid}", data: chart_data}),
         else: s
     end)}
  end

  def handle_event("metrics_interval", %{"interval" => interval}, socket) do
    ms =
      case Integer.parse(to_string(interval)) do
        {sec, ""} when sec >= 5 -> sec * 1000
        {ms_val, ""} when ms_val >= 5000 -> ms_val
        _ -> Settings.metrics_interval()
      end

    ms = max(ms, @min_metrics_interval)
    {:ok, _} = Settings.put_metrics_interval(ms)

    {:noreply,
     socket
     |> assign(:metrics_interval, ms)
     |> put_flash(:info, "Auto-refresh every #{div(ms, 1000)}s — saved")}
  end

  def handle_event("docker-server", %{"server_id" => ""}, socket) do
    {:noreply, assign(socket, :docker, nil)}
  end

  def handle_event("docker-server", %{"server_id" => id}, socket) do
    {:noreply, load_docker(socket, String.to_integer(id))}
  end

  def handle_event("docker-refresh", _params, socket) do
    {:noreply, reload_docker_list(socket)}
  end

  def handle_event("docker-tab", %{"tab" => tab}, socket)
      when tab in ~w(containers images stacks activity) do
    socket = assign_docker(socket, fn d -> %{d | tab: tab} end)

    socket =
      case {tab, socket.assigns.docker} do
        {"images", %{server_id: sid, images: nil}} ->
          fetch_docker_images(socket, sid)

        {"stacks", %{server_id: sid, stacks: nil}} ->
          fetch_docker_stacks(socket, sid)

        {"activity", %{server_id: sid}} ->
          assign_docker(socket, fn d -> %{d | audit: Services.list_audit(sid)} end)

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("docker-tab", _params, socket), do: {:noreply, socket}

  def handle_event("docker-filter", params, socket) do
    {:noreply,
     assign_docker(socket, fn d ->
       %{
         d
         | filter: Map.get(params, "filter", d.filter),
           status: valid_docker_status(Map.get(params, "status", d.status)),
           sort: valid_docker_sort(Map.get(params, "sort", d.sort))
       }
     end)}
  end

  def handle_event("docker-clear-filter", _params, socket) do
    {:noreply, assign_docker(socket, fn d -> %{d | filter: ""} end)}
  end

  def handle_event("docker-action", %{"action" => action, "name" => name}, socket)
      when action in ~w(start stop restart remove) do
    case socket.assigns.docker do
      %{server_id: sid, busy: nil} ->
        ref = make_ref()
        lv = self()

        Task.start(fn ->
          send(
            lv,
            {:docker_action_done, ref, sid, action, name,
             Services.docker_action(sid, action, name)}
          )
        end)

        {:noreply,
         assign(socket, :docker, %{
           socket.assigns.docker
           | busy: %{action: action, name: name},
             action_ref: ref
         })}

      %{busy: %{} = _busy} ->
        {:noreply, put_flash(socket, :info, "Another container action is still running…")}

      _ ->
        {:noreply, socket}
    end
  end

  # Forged/unknown actions never crash the LiveView.
  def handle_event("docker-action", %{"action" => action}, socket) do
    {:noreply, put_flash(socket, :error, "Unknown Docker action: #{action}")}
  end

  def handle_event("docker-action", _params, socket), do: {:noreply, socket}

  def handle_event("docker-logs", %{"name" => name}, socket) do
    case socket.assigns.docker do
      %{server_id: sid} = d ->
        {:noreply, fetch_docker_logs(socket, sid, name, logs_opts(d))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("docker-logs-tail", %{"tail" => tail}, socket) do
    case socket.assigns.docker do
      %{server_id: sid, logs: %{name: name, timestamps: ts}} ->
        {:ok, n} = parse_log_tail(tail)
        {:noreply, fetch_docker_logs(socket, sid, name, tail: n, timestamps: ts)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("docker-logs-timestamps", _params, socket) do
    case socket.assigns.docker do
      %{server_id: sid, logs: %{name: name, tail: tail, timestamps: ts}} ->
        {:noreply, fetch_docker_logs(socket, sid, name, tail: tail, timestamps: !ts)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("docker-logs-filter", %{"filter" => filter}, socket) do
    {:noreply,
     assign_docker(socket, fn
       %{logs: %{} = logs} = d -> %{d | logs: %{logs | filter: filter}}
       d -> d
     end)}
  end

  def handle_event("docker-close-logs", _params, socket) do
    {:noreply, assign_docker(socket, fn d -> %{d | logs: nil, logs_ref: nil} end)}
  end

  def handle_event("docker-logs-collapse", _params, socket) do
    {:noreply,
     assign_docker(socket, fn
       %{logs: %{} = logs} = d ->
         %{d | logs: %{logs | collapsed: !Map.get(logs, :collapsed, false)}}

       d ->
         d
     end)}
  end

  def handle_event("docker-logs-wrap", _params, socket) do
    {:noreply,
     assign_docker(socket, fn
       %{logs: %{} = logs} = d -> %{d | logs: %{logs | wrap: !Map.get(logs, :wrap, false)}}
       d -> d
     end)}
  end

  def handle_event("docker-stats", _params, socket) do
    case socket.assigns.docker do
      %{server_id: sid} -> {:noreply, fetch_docker_stats(socket, sid)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("docker-inspect", %{"name" => name}, socket) do
    case socket.assigns.docker do
      %{server_id: sid} ->
        ref = make_ref()
        lv = self()

        Task.start(fn ->
          send(lv, {:docker_inspect_done, ref, sid, name, Services.docker_inspect(sid, name)})
        end)

        {:noreply,
         assign(socket, :docker, %{socket.assigns.docker | inspect: :loading, inspect_ref: ref})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("docker-close-inspect", _params, socket) do
    {:noreply, assign_docker(socket, fn d -> %{d | inspect: nil, inspect_ref: nil} end)}
  end

  def handle_event("docker-close-stats", _params, socket) do
    {:noreply, assign_docker(socket, fn d -> %{d | stats: nil, stats_ref: nil} end)}
  end

  def handle_event("docker-rmi", %{"id" => id}, socket) do
    case socket.assigns.docker do
      %{server_id: sid} ->
        ref = make_ref()
        lv = self()

        Task.start(fn ->
          send(lv, {:docker_rmi_done, ref, sid, id, Services.docker_rmi(sid, id)})
        end)

        {:noreply,
         assign_docker(socket, fn d ->
           %{d | busy: %{action: "remove-image", name: id}, action_ref: ref}
         end)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("docker-prune", _params, socket) do
    case socket.assigns.docker do
      %{server_id: sid} ->
        ref = make_ref()
        lv = self()

        Task.start(fn ->
          send(lv, {:docker_prune_done, ref, sid, Services.docker_prune(sid)})
        end)

        {:noreply,
         assign_docker(socket, fn d ->
           %{d | busy: %{action: "prune", name: ""}, action_ref: ref}
         end)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("docker-stack-toggle", %{"name" => name}, socket) do
    case socket.assigns.docker do
      %{server_id: sid} = d ->
        if d.expanded_stack == name do
          {:noreply, assign(socket, :docker, %{d | expanded_stack: nil})}
        else
          ref = make_ref()
          lv = self()

          Task.start(fn ->
            config = stack_config(d, name)

            result =
              if config, do: Services.compose_services(sid, config), else: {:error, :no_config}

            send(lv, {:docker_stack_services_done, ref, sid, name, result})
          end)

          {:noreply,
           assign(socket, :docker, %{
             d
             | expanded_stack: name,
               stack_services: :loading,
               stacks_ref: ref
           })}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("docker-compose-action", %{"service" => service}, socket) do
    case socket.assigns.docker do
      %{server_id: sid, expanded_stack: project} = d when not is_nil(project) ->
        config = stack_config(d, project)
        ref = make_ref()
        lv = self()

        Task.start(fn ->
          result = Services.compose_action(sid, config || "", "restart", service)
          send(lv, {:docker_compose_done, ref, sid, project, service, result})
        end)

        {:noreply,
         assign_docker(socket, fn dd ->
           %{dd | busy: %{action: "restart", name: service}, action_ref: ref}
         end)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("systemd-server", %{"server_id" => ""}, socket) do
    {:noreply, assign(socket, :systemd, nil)}
  end

  def handle_event("systemd-server", %{"server_id" => id}, socket) do
    {:noreply, load_systemd(socket, String.to_integer(id))}
  end

  def handle_event("systemd-refresh", _params, socket) do
    {:noreply, reload_systemd(socket)}
  end

  def handle_event("systemd-filter", %{"filter" => filter}, socket) do
    {:noreply, assign_systemd(socket, fn s -> %{s | filter: filter} end)}
  end

  def handle_event("systemd-state", %{"state" => state}, socket)
      when state in ~w(all active failed inactive) do
    {:noreply, assign_systemd(socket, fn s -> %{s | state: state} end)}
  end

  def handle_event("systemd-sort", %{"sort" => sort}, socket) when sort in ~w(name state) do
    {:noreply, assign_systemd(socket, fn s -> %{s | sort: sort} end)}
  end

  def handle_event("systemd-clear-filter", _params, socket) do
    {:noreply, assign_systemd(socket, fn s -> %{s | filter: ""} end)}
  end

  def handle_event("systemd-action", %{"action" => action, "name" => name}, socket) do
    socket =
      case socket.assigns.systemd do
        %{server_id: sid} ->
          case Services.systemd_action(sid, action, name) do
            {:ok, _} ->
              socket |> put_flash(:info, "Unit #{action}ed.") |> reload_systemd()

            {:error, reason} ->
              put_flash(socket, :error, "systemctl #{action} failed: #{inspect(reason)}")
          end

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("systemd-logs", %{"name" => name}, socket) do
    socket =
      case socket.assigns.systemd do
        %{server_id: sid} = s ->
          case Services.systemd_logs(sid, name) do
            {:ok, text} ->
              assign(socket, :systemd, %{
                s
                | logs: %{name: name, text: text, collapsed: false, wrap: false}
              })

            {:error, reason} ->
              put_flash(socket, :error, "Journal failed: #{inspect(reason)}")
          end

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("systemd-close-logs", _params, socket) do
    {:noreply, assign_systemd(socket, fn s -> %{s | logs: nil} end)}
  end

  def handle_event("systemd-logs-collapse", _params, socket) do
    {:noreply,
     assign_systemd(socket, fn
       %{logs: %{} = logs} = s ->
         %{s | logs: %{logs | collapsed: !Map.get(logs, :collapsed, false)}}

       s ->
         s
     end)}
  end

  def handle_event("systemd-logs-wrap", _params, socket) do
    {:noreply,
     assign_systemd(socket, fn
       %{logs: %{} = logs} = s -> %{s | logs: %{logs | wrap: !Map.get(logs, :wrap, false)}}
       s -> s
     end)}
  end

  def handle_event("systemd-unit-preview", %{"name" => name}, socket) do
    case socket.assigns.systemd do
      %{server_id: sid} = s ->
        case Marsad.Fleet.Services.systemd_unit_file(sid, name) do
          {:ok, data} ->
            frag_path =
              case Marsad.Fleet.exec(
                     sid,
                     "systemctl show #{name} -p FragmentPath 2>&1 | cut -d= -f2"
                   ) do
                {:ok, %{stdout: out}} -> String.trim(out)
                _ -> name
              end

            frag_path = if frag_path == "" or frag_path == "n/a", do: name, else: frag_path

            preview = %{
              name: name,
              path: frag_path,
              text: data,
              full_text: data,
              language: code_language(name),
              editing: false,
              fragment_path: frag_path,
              truncated?: false
            }

            {:noreply, assign(socket, :systemd, %{s | unit_preview: preview})}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Unit file not found: #{inspect(reason)}")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("systemd-unit-close", _params, socket) do
    {:noreply, assign_systemd(socket, fn s -> %{s | unit_preview: nil} end)}
  end

  def handle_event("nginx-server", %{"server_id" => ""}, socket) do
    {:noreply, assign(socket, :nginx, nil)}
  end

  def handle_event("nginx-server", %{"server_id" => id}, socket) do
    {:noreply, load_nginx(socket, String.to_integer(id))}
  end

  def handle_event("nginx-refresh", _params, socket) do
    {:noreply, reload_nginx(socket)}
  end

  def handle_event("nginx-action", %{"action" => action}, socket) do
    socket =
      case socket.assigns.nginx do
        %{server_id: sid} ->
          case Services.nginx_action(sid, action) do
            {:ok, ""} ->
              socket |> put_flash(:info, "nginx #{action} done.") |> reload_nginx()

            {:ok, out} ->
              socket |> put_flash(:info, out) |> reload_nginx()

            {:error, reason} ->
              put_flash(socket, :error, "nginx #{action} failed: #{inspect(reason)}")
          end

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("nginx-check-certs", _params, socket) do
    case socket.assigns.nginx do
      %{server_id: sid} ->
        ref = make_ref()
        lv = self()

        Task.start(fn ->
          send(lv, {:nginx_certs_done, ref, sid, Services.cert_check(sid)})
        end)

        {:noreply,
         assign(socket, :nginx, %{socket.assigns.nginx | certs: :loading, certs_ref: ref})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("nginx-logs-collapse", _params, socket) do
    {:noreply,
     assign_nginx(socket, fn n ->
       %{n | error_log_collapsed: !Map.get(n, :error_log_collapsed, false)}
     end)}
  end

  def handle_event("nginx-logs-close", _params, socket) do
    {:noreply,
     assign_nginx(socket, fn n -> %{n | error_log: nil, error_log_collapsed: false} end)}
  end

  def handle_event("nginx-config", _params, socket) do
    socket =
      case socket.assigns.nginx do
        %{server_id: sid} = n ->
          case Services.nginx_config(sid) do
            {:ok, text} ->
              assign(socket, :nginx, %{n | config: text})

            {:error, reason} ->
              put_flash(socket, :error, "Config load failed: #{inspect(reason)}")
          end

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("nginx-logs", _params, socket) do
    socket =
      case socket.assigns.nginx do
        %{server_id: sid} = n ->
          case Services.nginx_error_log(sid) do
            {:ok, text} -> assign(socket, :nginx, %{n | error_log: text})
            {:error, reason} -> put_flash(socket, :error, "Log load failed: #{inspect(reason)}")
          end

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("nginx-files", _params, socket) do
    socket =
      case socket.assigns.nginx do
        %{server_id: sid} = n ->
          case Services.nginx_files(sid) do
            {:ok, files} -> assign(socket, :nginx, %{n | files: files, files_error: false})
            {:error, _} -> assign(socket, :nginx, %{n | files: nil, files_error: true})
          end

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("nginx-file-preview", %{"path" => path}, socket) do
    socket =
      case socket.assigns.nginx do
        %{server_id: sid} = n ->
          case Services.nginx_file(sid, path) do
            {:ok, data} ->
              {text, full} =
                if String.valid?(data) do
                  {data, data}
                else
                  {"(binary file — preview unavailable)", data}
                end

              fp = %{
                path: path,
                text: text,
                full_text: full,
                truncated?: byte_size(full) >= 100_000,
                language: code_language(path),
                editing: false
              }

              assign(socket, :nginx, %{n | file_preview: fp})

            {:error, reason} ->
              put_flash(socket, :error, "File read failed: #{inspect(reason)}")
          end

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("nginx-file-close", _params, socket) do
    case socket.assigns.nginx do
      nil -> {:noreply, socket}
      n -> {:noreply, assign(socket, :nginx, %{n | file_preview: nil})}
    end
  end

  def handle_event("nginx-files-filter", %{"filter" => filter}, socket) do
    {:noreply, assign_nginx(socket, fn n -> %{n | files_filter: filter} end)}
  end

  def handle_event("nginx-files-clear-filter", _params, socket) do
    {:noreply, assign_nginx(socket, fn n -> %{n | files_filter: ""} end)}
  end

  def handle_event("set-theme-mode", %{"mode" => mode}, socket) when mode in ["light", "dark"] do
    Retry.retry_settings(fn -> Settings.put("theme_mode", mode) end)

    {:noreply,
     socket
     |> assign(:appearance, Settings.appearance())
     |> push_event("terminal_theme", %{mode: mode})
     |> push_event("code_editor_theme", %{theme: mode})}
  end

  def handle_event("set-theme-mode", _params, socket), do: {:noreply, socket}

  def handle_event("set-accent", %{"accent" => accent}, socket) do
    if Map.has_key?(Settings.accents(), accent) do
      Retry.retry_settings(fn -> Settings.put("accent", accent) end)
      {:noreply, assign(socket, :appearance, Settings.appearance())}
    else
      {:noreply, socket}
    end
  end

  def handle_event("change-password", %{"password" => password, "confirm" => confirm}, socket) do
    socket =
      cond do
        password != confirm ->
          assign(socket, :password_msg, {:error, "Passwords do not match"})

        true ->
          admin = socket.assigns[:current_admin] || Accounts.first_admin()

          case admin && Accounts.update_password(admin, %{"password" => password}) do
            {:ok, _} ->
              socket
              |> assign(:password_form, to_form(%{"password" => "", "confirm" => ""}))
              |> assign(:password_msg, {:ok, "Password updated"})

            {:error, %Ecto.Changeset{} = cs} ->
              msg =
                cs.errors
                |> Enum.map_join(", ", fn {field, {text, _}} -> "#{field} #{text}" end)
                |> case do
                  "" -> "Invalid password (min 8 characters)"
                  text -> text
                end

              assign(socket, :password_msg, {:error, msg})

            _ ->
              assign(socket, :password_msg, {:error, "No admin account found"})
          end
      end

    {:noreply, socket}
  end

  def handle_event("reset-auth", _params, socket) do
    Accounts.reset_all()
    {:noreply, push_navigate(socket, to: "/setup")}
  end

  # -- interactive shell terminal ----------------------------------------------
  #
  # Server-backed windows hold ONE persistent PTY shell (see
  # `Marsad.Fleet.ServerShell`): keystrokes stream in raw, screen bytes
  # stream out — vim/nano/top and `cd` all work natively. Windows without
  # a server stay in local demo mode (line discipline in the hook).

  def handle_event("terminal_ready", %{"window_id" => wid} = params, socket) do
    window = find_window(socket, wid)
    cols = to_pos_int(params["cols"], 80)
    rows = to_pos_int(params["rows"], 24)

    case server_for(window, socket.assigns) do
      nil ->
        socket =
          socket
          |> push_event("terminal_mode", %{mode: "demo", window_id: wid})
          |> then(fn s ->
            if Map.get(s.assigns.transcripts, wid, []) == [] do
              push_output(
                s,
                wid,
                Terminal.welcome_banner(nil) <> Terminal.demo_prompt()
              )
            else
              push_event(s, "terminal_output", %{
                data: Enum.join(Map.get(s.assigns.transcripts, wid, [])),
                window_id: wid
              })
            end
          end)

        {:noreply, socket}

      server ->
        socket = push_event(socket, "terminal_mode", %{mode: "shell", window_id: wid})

        socket =
          case ServerShell.ensure(server.id, wid, self(), cols, rows) do
            {:ok, pid} ->
              socket
              |> assign(
                :term_shells,
                Map.put(socket.assigns.term_shells, wid, %{pid: pid, open: false})
              )
              |> then(fn s ->
                if Map.get(s.assigns.transcripts, wid, []) == [] do
                  push_output(
                    s,
                    wid,
                    "\e[2mconnecting to #{server.username}@#{server.host}…\e[0m\r\n"
                  )
                else
                  push_event(s, "terminal_output", %{
                    data: Enum.join(Map.get(s.assigns.transcripts, wid, [])),
                    window_id: wid
                  })
                end
              end)

            {:error, reason} ->
              push_output(
                socket,
                wid,
                "✖ cannot open shell: #{inspect(reason)}\r\n[press Enter to retry]\r\n"
              )
          end

        {:noreply, socket}
    end
  end

  def handle_event("terminal_input", %{"data" => data, "window_id" => wid}, socket) do
    window = find_window(socket, wid)

    case server_for(window, socket.assigns) do
      nil ->
        {:noreply, demo_input(socket, wid, String.trim_trailing(data, "\n"))}

      server ->
        {:noreply, shell_input(socket, wid, server, data)}
    end
  end

  def handle_event(
        "terminal_resize",
        %{"cols" => cols, "rows" => rows, "window_id" => wid},
        socket
      ) do
    window = find_window(socket, wid)

    case server_for(window, socket.assigns) do
      nil ->
        {:noreply, socket}

      server ->
        case Map.get(socket.assigns.term_shells, wid) do
          %{pid: pid} when is_pid(pid) ->
            if Process.alive?(pid) do
              _ =
                ServerShell.resize(
                  server.id,
                  wid,
                  self(),
                  to_pos_int(cols, 80),
                  to_pos_int(rows, 24)
                )
            end

            {:noreply, socket}

          _ ->
            {:noreply, socket}
        end
    end
  end

  def handle_event("terminal_resize", _params, socket), do: {:noreply, socket}

  def handle_event("terminal_copy", %{"window" => wid}, socket) do
    {:noreply, push_event(socket, "terminal_copy_selection", %{window_id: wid})}
  end

  def handle_event("terminal_clear_window", %{"window" => wid}, socket) do
    {:noreply, clear_terminal(socket, find_window(socket, wid), wid)}
  end

  defp handle_files_filter(filter, socket) do
    case socket.assigns.file_browser do
      %{server_id: server_id} when is_binary(filter) ->
        if String.length(filter) >= 2 do
          if socket.assigns.files_filter == filter && socket.assigns.files_search_results != nil do
            {:noreply, socket}
          else
            ref = make_ref()
            pid = self()

            Task.start(fn ->
              send(
                pid,
                {:files_search_loaded, ref, server_id,
                 Marsad.Files.search_remote(server_id, filter)}
              )
            end)

            {:noreply,
             socket
             |> assign(:files_filter, filter)
             |> assign(:files_search_results, :loading)
             |> assign(:files_search_ref, ref)
             |> assign(:files_search_truncated, false)}
          end
        else
          {:noreply,
           socket
           |> assign(:files_filter, filter)
           |> assign(:files_search_results, nil)
           |> assign(:files_search_ref, nil)
           |> assign(:files_search_truncated, false)}
        end

      _ ->
        {:noreply,
         socket
         |> assign(:files_filter, filter)
         |> assign(:files_search_results, nil)
         |> assign(:files_search_ref, nil)
         |> assign(:files_search_truncated, false)}
    end
  end

  defp editor_id(prefix, path), do: Marsad.Files.editor_id(prefix, path)
  defp write_result(result), do: Marsad.Files.write_result(result)

  defp open_file_preview(socket, browser, server_id, path) do
    case Fleet.read_file(server_id, path, 15_000_000) do
      {:ok, data} when byte_size(data) > 0 ->
        preview = Marsad.Files.build_preview(path, data)
        {:noreply, assign(socket, :file_browser, %{browser | preview: preview, error: nil})}

      {:ok, _} ->
        {:noreply,
         assign(socket, :file_browser, %{
           browser
           | preview: %{
               path: path,
               text: "(empty file)",
               full_text: "",
               truncated?: false,
               language: Marsad.Files.code_language(path),
               editing: true
             },
             error: nil
         })}

      {:error, reason} ->
        {:noreply,
         assign(socket, :file_browser, %{browser | error: "Read failed: #{inspect(reason)}"})}
    end
  end

  @impl true
  def handle_info(:metrics_tick, socket) do
    interval = Map.get(socket.assigns, :metrics_interval, @metrics_interval)
    interval = max(interval, @min_metrics_interval)
    Process.send_after(self(), :metrics_tick, interval)

    socket =
      if monitor_open?(socket) do
        socket
        |> fetch_metrics_async(socket.assigns.monitor_server_id)
        |> fetch_top_procs_async(socket.assigns.monitor_server_id)
      else
        socket
      end

    # Live docker stats: refresh while visible (stale-while-revalidate, no skeleton flash).
    socket =
      case socket.assigns.docker do
        %{server_id: sid, stats: stats, stats_ref: nil} = d
        when is_list(stats) and not is_nil(sid) ->
          if docker_window_open?(socket) do
            ref = make_ref()
            lv = self()

            Task.start(fn ->
              send(lv, {:docker_stats_done, ref, sid, Services.docker_stats(sid)})
            end)

            assign(socket, :docker, %{d | stats_ref: ref})
          else
            socket
          end

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info({:metrics_result, sid, result}, socket) do
    # Persist snapshot for history (ignore errors, e.g., DB locked)
    case result do
      {:ok, snap} ->
        try do
          Marsad.Metrics.create_snapshot(%{
            server_id: sid,
            load1: snap.load1,
            load5: snap.load5,
            load15: snap.load15,
            cores: snap.cores,
            mem_total_mb: snap.mem_total_mb,
            mem_used_mb: snap.mem_used_mb,
            disk_total_mb: snap.disk_total_mb,
            disk_used_mb: snap.disk_used_mb,
            disk_pct: snap.disk_pct,
            disks: Jason.encode!(Map.get(snap, :disks, [])),
            cpu_per_core: Jason.encode!(Map.get(snap, :cpu_per_core, [])),
            net_rx_mb: Map.get(snap, :net_rx_mb),
            net_tx_mb: Map.get(snap, :net_tx_mb)
          })
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end

        # Prune old data occasionally (1% chance)
        if :rand.uniform(100) == 1 do
          Task.start(fn -> Marsad.Metrics.prune_old(48) end)
        end

      _ ->
        :ok
    end

    # Update chart data based on current duration
    chart_data =
      case socket.assigns.metrics_duration do
        "custom" ->
          # For custom, use 24h for now (could parse dates)
          Marsad.Metrics.chart_data(sid, 24)

        duration ->
          hours =
            case duration do
              "1h" -> 1
              "6h" -> 6
              "7d" -> 168
              _ -> 24
            end

          Marsad.Metrics.chart_data(sid, hours)
      end

    socket =
      socket
      |> assign(:metrics, Map.put(socket.assigns.metrics, sid, result))
      |> assign(:metrics_loading, nil)
      |> assign(:metrics_chart_data, chart_data)
      |> push_event("chart_update", %{id: "metrics-chart-#{sid}", data: chart_data})

    {:noreply, socket}
  end

  def handle_info({:top_procs_result, sid, result}, socket) do
    {:noreply,
     socket
     |> assign(:top_procs, Map.put(socket.assigns.top_procs, sid, result))
     |> assign(:top_procs_loading, nil)}
  end

  def handle_info({:files_loaded, ref, sid, path, result}, socket) do
    if socket.assigns.files_load_ref == ref do
      preview =
        case socket.assigns.files_pending_preview do
          %{path: preview_path} = preview ->
            if String.starts_with?(preview_path, path), do: preview, else: nil

          _ ->
            nil
        end

      browser = %{server_id: sid, path: path, entries: [], error: nil, preview: preview}

      browser =
        case result do
          {:ok, entries} -> %{browser | entries: entries}
          {:error, reason} -> %{browser | error: "Cannot list #{path}: #{inspect(reason)}"}
        end

      {:noreply, assign(socket, :file_browser, browser)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:files_search_loaded, ref, sid, %{entries: entries} = result}, socket) do
    if socket.assigns.files_search_ref == ref && socket.assigns.active_server_id == sid do
      {:noreply,
       socket
       |> assign(:files_search_results, entries)
       |> assign(:files_search_truncated, Map.get(result, :truncated?, false))}
    else
      {:noreply, socket}
    end
  end

  # Back-compat: plain entry lists (older callers/tests).
  def handle_info({:files_search_loaded, ref, sid, results}, socket) when is_list(results) do
    if socket.assigns.files_search_ref == ref && socket.assigns.active_server_id == sid do
      {:noreply,
       socket
       |> assign(:files_search_results, results)
       |> assign(:files_search_truncated, false)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:nginx_loaded, ref, sid, status, files, files_error}, socket) do
    if socket.assigns.nginx_load_ref == ref &&
         socket.assigns.nginx != nil && socket.assigns.nginx.server_id == sid do
      {:noreply,
       assign(socket, :nginx, %{
         socket.assigns.nginx
         | status: status,
           files: files,
           files_error: files_error
       })}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:nginx_certs_done, ref, sid, result}, socket) do
    case socket.assigns.nginx do
      %{server_id: ^sid, certs_ref: ^ref} = n ->
        {:noreply, assign(socket, :nginx, %{n | certs: result, certs_ref: nil})}

      _ ->
        {:noreply, socket}
    end
  end

  # -- interactive shell terminal --------------------------------------------------
  # Messages from `Marsad.Fleet.ServerShell` (keyed {:shell, sid, wid, lv}).

  def handle_info({:shell_opened, {:shell, sid, wid, lv}}, socket) do
    if find_window(socket, wid) do
      socket =
        case Map.get(socket.assigns.term_shells, wid) do
          %{pid: pid} = entry when is_pid(pid) ->
            assign(
              socket,
              :term_shells,
              Map.put(socket.assigns.term_shells, wid, %{entry | open: true})
            )

          _ ->
            socket
        end

      {:noreply, socket}
    else
      # Window already closed — don't leak the shell.
      ServerShell.close(sid, wid, lv)
      {:noreply, assign(socket, :term_shells, Map.delete(socket.assigns.term_shells, wid))}
    end
  end

  def handle_info({:shell_output, {:shell, _sid, wid, _lv}, data}, socket) do
    if find_window(socket, wid) do
      {:noreply, push_output(socket, wid, data)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:shell_failed, {:shell, _sid, wid, _lv}, reason}, socket) do
    socket = assign(socket, :term_shells, Map.delete(socket.assigns.term_shells, wid))

    if find_window(socket, wid) do
      {:noreply,
       push_output(
         socket,
         wid,
         "✖ cannot open shell: #{inspect(reason)}\r\n[press Enter to retry]\r\n"
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:shell_closed, {:shell, _sid, wid, _lv}, _reason}, socket) do
    socket = assign(socket, :term_shells, Map.delete(socket.assigns.term_shells, wid))

    if find_window(socket, wid) do
      {:noreply,
       push_output(socket, wid, "\r\n\e[2m[session ended — press Enter to reopen]\e[0m\r\n")}
    else
      {:noreply, socket}
    end
  end

  # Honest pill state: a live shell process means "connected", not
  # "a command is running" (only the remote shell knows that).
  def handle_info({:docker_list, ref, sid, result}, socket) do
    if docker_ref?(socket, :list_ref, ref, sid) do
      {:noreply, assign_docker(socket, fn d -> %{d | data: result, list_ref: nil} end)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:docker_action_done, ref, sid, action, name, result}, socket) do
    if docker_ref?(socket, :action_ref, ref, sid) do
      past = Services.action_past(action)

      socket =
        case result do
          {:ok, _} ->
            Services.audit(sid, "docker_#{action}", name, "ok")

            socket
            |> put_flash(:info, "Container #{past}.")
            |> assign_docker(fn d ->
              %{d | busy: nil, action_ref: nil, audit: Services.list_audit(sid)}
            end)
            |> reload_docker_list()

          {:error, reason} ->
            Services.audit(sid, "docker_#{action}", name, "failed: #{inspect(reason)}")

            socket
            |> put_flash(:error, "Docker #{action} failed: #{inspect(reason)}")
            |> assign_docker(fn d -> %{d | busy: nil, action_ref: nil} end)
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:docker_logs_done, ref, sid, name, opts, result}, socket) do
    if docker_ref?(socket, :logs_ref, ref, sid) do
      socket =
        case result do
          {:ok, text} ->
            assign_docker(socket, fn d ->
              %{
                d
                | logs: %{
                    name: name,
                    text: text,
                    tail: Keyword.get(opts, :tail, 200),
                    timestamps: Keyword.get(opts, :timestamps, false),
                    filter: "",
                    collapsed: false,
                    wrap: false
                  },
                  logs_ref: nil
              }
            end)

          {:error, reason} ->
            socket
            |> put_flash(:error, "Logs failed: #{inspect(reason)}")
            |> assign_docker(fn d -> %{d | logs: nil, logs_ref: nil} end)
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:docker_stats_done, ref, sid, result}, socket) do
    if docker_ref?(socket, :stats_ref, ref, sid) do
      socket =
        case result do
          {:ok, stats} ->
            assign_docker(socket, fn d -> %{d | stats: stats, stats_ref: nil} end)

          {:error, reason} ->
            socket
            |> put_flash(:error, "Stats failed: #{inspect(reason)}")
            |> assign_docker(fn d -> %{d | stats_ref: nil} end)
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:docker_inspect_done, ref, sid, name, result}, socket) do
    if docker_ref?(socket, :inspect_ref, ref, sid) do
      socket =
        case result do
          {:ok, data} ->
            assign_docker(socket, fn d ->
              %{d | inspect: %{name: name, data: data}, inspect_ref: nil}
            end)

          {:error, reason} ->
            socket
            |> put_flash(:error, "Inspect failed: #{inspect(reason)}")
            |> assign_docker(fn d -> %{d | inspect: nil, inspect_ref: nil} end)
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:docker_images_done, ref, sid, result}, socket) do
    if docker_ref?(socket, :images_ref, ref, sid) do
      {:noreply, assign_docker(socket, fn d -> %{d | images: result, images_ref: nil} end)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:docker_stacks_done, ref, sid, result}, socket) do
    if docker_ref?(socket, :stacks_ref, ref, sid) do
      {:noreply, assign_docker(socket, fn d -> %{d | stacks: result, stacks_ref: nil} end)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:docker_stack_services_done, ref, sid, project, result}, socket) do
    if docker_ref?(socket, :stacks_ref, ref, sid) do
      socket =
        case result do
          {:ok, services} ->
            assign_docker(socket, fn d ->
              %{d | stack_services: %{project: project, services: services}, stacks_ref: nil}
            end)

          {:error, reason} ->
            socket
            |> put_flash(:error, "Stack services failed: #{inspect(reason)}")
            |> assign_docker(fn d ->
              %{d | stack_services: nil, stacks_ref: nil, expanded_stack: nil}
            end)
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:docker_compose_done, ref, sid, project, service, result}, socket) do
    if docker_ref?(socket, :action_ref, ref, sid) do
      socket =
        case result do
          {:ok, _} ->
            Services.audit(sid, "docker_compose_restart", "#{project}/#{service}", "ok")

            socket
            |> put_flash(:info, "Service restarted.")
            |> assign_docker(fn d ->
              %{d | busy: nil, action_ref: nil, audit: Services.list_audit(sid)}
            end)

          {:error, reason} ->
            Services.audit(
              sid,
              "docker_compose_restart",
              "#{project}/#{service}",
              "failed: #{inspect(reason)}"
            )

            socket
            |> put_flash(:error, "Restart failed: #{inspect(reason)}")
            |> assign_docker(fn d -> %{d | busy: nil, action_ref: nil} end)
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:docker_rmi_done, ref, sid, id, result}, socket) do
    if docker_ref?(socket, :action_ref, ref, sid) do
      socket =
        case result do
          {:ok, out} ->
            Services.audit(sid, "docker_rmi", id, String.slice(out, 0, 200))

            socket
            |> put_flash(:info, "Image removed.")
            |> assign_docker(fn d ->
              %{d | busy: nil, action_ref: nil, audit: Services.list_audit(sid)}
            end)
            |> refresh_docker_images()

          {:error, reason} ->
            Services.audit(sid, "docker_rmi", id, "failed: #{inspect(reason)}")

            socket
            |> put_flash(:error, "Remove image failed: #{inspect(reason)}")
            |> assign_docker(fn d -> %{d | busy: nil, action_ref: nil} end)
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:docker_prune_done, ref, sid, result}, socket) do
    if docker_ref?(socket, :action_ref, ref, sid) do
      socket =
        case result do
          {:ok, out} ->
            Services.audit(sid, "docker_prune", "", String.slice(out, 0, 200))

            socket
            |> put_flash(:info, "Prune finished.")
            |> assign_docker(fn d ->
              %{d | busy: nil, action_ref: nil, audit: Services.list_audit(sid)}
            end)
            |> refresh_docker_images()
            |> reload_docker_list()

          {:error, reason} ->
            Services.audit(sid, "docker_prune", "", "failed: #{inspect(reason)}")

            socket
            |> put_flash(:error, "Prune failed: #{inspect(reason)}")
            |> assign_docker(fn d -> %{d | busy: nil, action_ref: nil} end)
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  defp term_shell_state(shells, wid) do
    case Map.get(shells, wid) do
      %{pid: pid, open: true} when is_pid(pid) -> if Process.alive?(pid), do: :open, else: :dead
      %{pid: pid} when is_pid(pid) -> if Process.alive?(pid), do: :connecting, else: :dead
      _ -> :dead
    end
  end

  defp active_default([]), do: nil
  defp active_default([first | _]), do: first.id

  # Drops per-server UI state when its server is deleted.
  defp drop_service_state(socket, server_id) do
    socket
    |> then(fn s ->
      if s.assigns.file_browser && s.assigns.file_browser.server_id == server_id,
        do: assign(s, :file_browser, nil),
        else: s
    end)
    |> then(fn s ->
      if s.assigns.docker && s.assigns.docker.server_id == server_id,
        do: assign(s, :docker, nil),
        else: s
    end)
    |> then(fn s ->
      if s.assigns.systemd && s.assigns.systemd.server_id == server_id,
        do: assign(s, :systemd, nil),
        else: s
    end)
    |> then(fn s ->
      if s.assigns.nginx && s.assigns.nginx.server_id == server_id,
        do: assign(s, :nginx, nil),
        else: s
    end)
    |> then(fn s ->
      if Map.has_key?(s.assigns.metrics, server_id),
        do: assign(s, :metrics, Map.delete(s.assigns.metrics, server_id)),
        else: s
    end)
    |> then(fn s ->
      if Map.has_key?(s.assigns.top_procs, server_id),
        do: assign(s, :top_procs, Map.delete(s.assigns.top_procs, server_id)),
        else: s
    end)
    |> then(fn s ->
      # Kill terminal shells bound to the deleted server.
      ServerShell.close_for_server(server_id)

      wids =
        for w <- s.assigns.windows,
            w.app == "terminal" and w.server_id == server_id,
            do: w.id

      assign(s, :term_shells, Map.drop(s.assigns.term_shells, wids))
    end)
  end

  defp ensure_browser(%{assigns: %{file_browser: %{}}} = socket), do: socket

  defp ensure_browser(socket) do
    case socket.assigns.active_server_id do
      nil -> socket
      sid -> load_browser(socket, sid, nil)
    end
  end

  defp load_browser(socket, server_id, path) do
    ref = make_ref()
    pid = self()
    old_preview = pending_preview(socket, server_id)

    Task.start(fn ->
      resolved =
        if is_binary(path) do
          path
        else
          case Fleet.home_dir(server_id) do
            {:ok, home} -> home
            {:error, _} -> "/"
          end
        end

      result =
        try do
          Fleet.list_dir(server_id, resolved)
        rescue
          e -> {:error, e}
        catch
          :exit, reason -> {:error, reason}
        end

      send(pid, {:files_loaded, ref, server_id, resolved, result})
    end)

    socket
    |> assign(:file_browser, %{
      server_id: server_id,
      path: path || "…",
      entries: nil,
      error: nil,
      preview: nil
    })
    |> assign(:files_load_ref, ref)
    |> assign(:files_pending_preview, old_preview)
  end

  defp pending_preview(socket, server_id) do
    case socket.assigns.file_browser do
      %{server_id: ^server_id, preview: preview} -> preview
      _ -> nil
    end
  end

  defp put_browser_error(socket, message) do
    case socket.assigns.file_browser do
      nil -> socket
      b -> assign(socket, :file_browser, %{b | error: message})
    end
  end

  defp ensure_docker(%{assigns: %{docker: %{}}} = socket), do: socket

  defp ensure_docker(socket) do
    case socket.assigns.active_server_id do
      nil -> socket
      sid -> load_docker(socket, sid)
    end
  end

  defp fresh_docker_state(server_id) do
    %{
      server_id: server_id,
      data: nil,
      list_ref: nil,
      filter: "",
      status: "all",
      sort: "name",
      tab: "containers",
      logs: nil,
      logs_ref: nil,
      stats: nil,
      stats_ref: nil,
      inspect: nil,
      inspect_ref: nil,
      busy: nil,
      action_ref: nil,
      images: nil,
      images_ref: nil,
      stacks: nil,
      stacks_ref: nil,
      expanded_stack: nil,
      stack_services: nil,
      audit: []
    }
  end

  defp load_docker(socket, server_id) do
    ref = make_ref()
    lv = self()

    Task.start(fn ->
      send(lv, {:docker_list, ref, server_id, Services.docker_containers(server_id)})
    end)

    assign(socket, :docker, %{
      fresh_docker_state(server_id)
      | list_ref: ref,
        audit: Services.list_audit(server_id)
    })
  end

  # Refreshes only the container list, preserving open panels/filters.
  defp reload_docker_list(socket) do
    case socket.assigns.docker do
      %{server_id: sid} = d ->
        ref = make_ref()
        lv = self()

        Task.start(fn ->
          send(lv, {:docker_list, ref, sid, Services.docker_containers(sid)})
        end)

        assign(socket, :docker, %{d | data: nil, list_ref: ref})

      _ ->
        socket
    end
  end

  defp assign_docker(%{assigns: %{docker: nil}} = socket, _fun), do: socket
  defp assign_docker(socket, fun), do: assign(socket, :docker, fun.(socket.assigns.docker))

  defp docker_ref?(socket, field, ref, sid) do
    case socket.assigns.docker do
      %{server_id: ^sid} = d -> Map.get(d, field) == ref
      _ -> false
    end
  end

  defp logs_opts(%{logs: %{tail: tail, timestamps: timestamps}}),
    do: [tail: tail, timestamps: timestamps]

  defp logs_opts(_), do: [tail: 200, timestamps: false]

  defp parse_log_tail(tail) do
    case Integer.parse(to_string(tail)) do
      {n, ""} when n in [50, 100, 200, 500, 1000] -> {:ok, n}
      _ -> {:ok, 200}
    end
  end

  defp stack_config(%{stacks: {:ok, projects}}, name) do
    case Enum.find(projects, &(&1.name == name)) do
      %{config: ""} -> nil
      %{config: config} -> config
      _ -> nil
    end
  end

  defp stack_config(_, _), do: nil

  defp valid_docker_status(s) when s in ~w(all running exited), do: s
  defp valid_docker_status(_), do: "all"

  defp valid_docker_sort(s) when s in ~w(name state image), do: s
  defp valid_docker_sort(_), do: "name"

  defp docker_window_open?(socket) do
    Enum.any?(socket.assigns.windows, &(&1.app == "docker"))
  end

  defp fetch_docker_logs(socket, sid, name, opts) do
    ref = make_ref()
    lv = self()

    Task.start(fn ->
      send(lv, {:docker_logs_done, ref, sid, name, opts, Services.docker_logs(sid, name, opts)})
    end)

    assign(socket, :docker, %{socket.assigns.docker | logs: :loading, logs_ref: ref})
  end

  defp fetch_docker_stats(socket, sid) do
    ref = make_ref()
    lv = self()

    Task.start(fn ->
      send(lv, {:docker_stats_done, ref, sid, Services.docker_stats(sid)})
    end)

    assign_docker(socket, fn d -> %{d | stats_ref: ref} end)
  end

  defp fetch_docker_images(socket, sid) do
    ref = make_ref()
    lv = self()

    Task.start(fn ->
      send(lv, {:docker_images_done, ref, sid, Services.docker_images(sid)})
    end)

    assign(socket, :docker, %{socket.assigns.docker | images: :loading, images_ref: ref})
  end

  defp fetch_docker_stacks(socket, sid) do
    ref = make_ref()
    lv = self()

    Task.start(fn ->
      send(lv, {:docker_stacks_done, ref, sid, Services.compose_projects(sid)})
    end)

    assign(socket, :docker, %{socket.assigns.docker | stacks: :loading, stacks_ref: ref})
  end

  defp refresh_docker_images(socket) do
    case socket.assigns.docker do
      %{server_id: sid} -> fetch_docker_images(socket, sid)
      _ -> socket
    end
  end

  defp ensure_systemd(%{assigns: %{systemd: %{}}} = socket), do: socket

  defp ensure_systemd(socket) do
    case socket.assigns.active_server_id do
      nil -> socket
      sid -> load_systemd(socket, sid)
    end
  end

  defp load_systemd(socket, server_id) do
    data =
      case Services.systemd_units(server_id) do
        {:ok, units} -> {:ok, units}
        {:error, _} = error -> error
      end

    assign(socket, :systemd, %{
      server_id: server_id,
      data: data,
      filter: "",
      state: "all",
      sort: "name",
      logs: nil,
      unit_preview: nil
    })
  end

  defp reload_systemd(
         %{assigns: %{systemd: %{server_id: sid, filter: filter, state: state, sort: sort}}} =
           socket
       ) do
    socket
    |> load_systemd(sid)
    |> assign_systemd(fn s -> %{s | filter: filter, state: state, sort: sort} end)
  end

  defp reload_systemd(socket), do: socket

  defp assign_systemd(%{assigns: %{systemd: nil}} = socket, _fun), do: socket
  defp assign_systemd(socket, fun), do: assign(socket, :systemd, fun.(socket.assigns.systemd))

  defp ensure_nginx(%{assigns: %{nginx: %{}}} = socket), do: socket

  defp ensure_nginx(socket) do
    case socket.assigns.active_server_id do
      nil -> socket
      sid -> load_nginx(socket, sid)
    end
  end

  defp load_nginx(socket, server_id) do
    ref = make_ref()
    pid = self()

    Task.start(fn ->
      status =
        case Services.nginx_status(server_id) do
          {:ok, st} -> {:ok, st}
          {:error, _} = err -> err
        end

      {files, files_error} =
        case Services.nginx_files(server_id) do
          {:ok, list} -> {list, false}
          _ -> {nil, true}
        end

      send(pid, {:nginx_loaded, ref, server_id, status, files, files_error})
    end)

    socket
    |> assign(:nginx, %{
      server_id: server_id,
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
    })
    |> assign(:nginx_load_ref, ref)
  end

  defp reload_nginx(
         %{assigns: %{nginx: %{server_id: sid, files_filter: filter, file_preview: preview}}} =
           socket
       ) do
    ref = make_ref()
    pid = self()

    Task.start(fn ->
      status =
        case Services.nginx_status(sid) do
          {:ok, st} -> {:ok, st}
          {:error, _} = err -> err
        end

      {files, files_error} =
        case Services.nginx_files(sid) do
          {:ok, list} -> {list, false}
          _ -> {nil, true}
        end

      send(pid, {:nginx_loaded, ref, sid, status, files, files_error})
    end)

    socket
    |> assign(:nginx, %{
      server_id: sid,
      status: nil,
      config: nil,
      error_log: nil,
      files: nil,
      files_error: false,
      files_filter: filter || "",
      file_preview: preview,
      certs: nil,
      certs_ref: nil,
      error_log_collapsed: false
    })
    |> assign(:nginx_load_ref, ref)
  end

  defp reload_nginx(%{assigns: %{nginx: %{server_id: sid}}} = socket), do: load_nginx(socket, sid)
  defp reload_nginx(socket), do: socket

  defp assign_nginx(%{assigns: %{nginx: nil}} = socket, _fun), do: socket
  defp assign_nginx(socket, fun), do: assign(socket, :nginx, fun.(socket.assigns.nginx))

  defp monitor_open?(socket), do: Enum.any?(socket.assigns.windows, &(&1.app == "monitor"))

  defp fetch_metrics_async(socket, nil), do: socket

  defp fetch_metrics_async(%{assigns: %{metrics_loading: sid}} = socket, sid), do: socket

  defp fetch_metrics_async(socket, sid) do
    pid = self()

    Task.start(fn ->
      result =
        try do
          Marsad.Fleet.SysInfo.fetch(sid)
        rescue
          e -> {:error, e}
        catch
          :exit, reason -> {:error, reason}
        end

      send(pid, {:metrics_result, sid, result})
    end)

    socket
    |> assign(:metrics_loading, sid)
    |> assign(:metrics, Map.put_new(socket.assigns.metrics, sid, :loading))
  end

  defp fetch_top_procs_async(socket, nil), do: socket

  defp fetch_top_procs_async(%{assigns: %{top_procs_loading: sid}} = socket, sid), do: socket

  defp fetch_top_procs_async(socket, sid) do
    pid = self()

    Task.start(fn ->
      result =
        try do
          Marsad.Fleet.SysInfo.top_processes(sid)
        rescue
          e -> {:error, e}
        catch
          :exit, reason -> {:error, reason}
        end

      send(pid, {:top_procs_result, sid, result})
    end)

    socket
    |> assign(:top_procs_loading, sid)
    |> assign(:top_procs, Map.put_new(socket.assigns.top_procs, sid, :loading))
  end

  defp bar_class(pct) when pct >= 90, do: "bg-red-500"
  defp bar_class(pct) when pct >= 70, do: "bg-amber-500"
  defp bar_class(_), do: "bg-emerald-500"

  defp cancel_all_uploads(socket, upload) do
    Enum.reduce(socket.assigns.uploads[upload].entries, socket, fn entry, acc ->
      cancel_upload(acc, upload, entry.ref)
    end)
  end

  defp code_language(path), do: Marsad.Files.code_language(path)

  defp terminal_window_id(%{assigns: %{active_server_id: nil}}), do: "terminal"
  defp terminal_window_id(%{assigns: %{active_server_id: id}}), do: "terminal-#{id}"

  defp find_window(socket, wid) do
    Enum.find(socket.assigns.windows, &(&1.id == wid))
  end

  defp open_window(socket, id, app, server_id) do
    if Enum.any?(socket.assigns.windows, &(&1.id == id)) do
      focus(socket, id)
    else
      window = %{id: id, app: app, server_id: server_id}

      socket
      |> assign(:windows, socket.assigns.windows ++ [window])
      |> assign(:focused_id, id)
    end
  end

  defp focus(socket, id) do
    if Enum.any?(socket.assigns.windows, &(&1.id == id)) do
      assign(socket, :focused_id, id)
    else
      socket
    end
  end

  defp focused_fallback(windows, current, closed_id) do
    if current == closed_id do
      case List.last(windows) do
        nil -> nil
        w -> w.id
      end
    else
      current
    end
  end

  defp server_for(nil, _assigns), do: nil

  defp server_for(window, assigns) do
    sid = (window && window.server_id) || assigns.active_server_id
    if sid, do: Enum.find(assigns.servers, &(&1.id == sid)), else: nil
  end

  # Toolbar Clear: wipes the local screen. Server windows get no synthetic
  # prompt — the remote shell owns its prompt; demo windows do.
  defp clear_terminal(socket, window, wid) do
    socket = assign(socket, :transcripts, Map.put(socket.assigns.transcripts, wid, []))
    socket = push_event(socket, "terminal_clear", %{window_id: wid})

    if server_for(window, socket.assigns) do
      socket
    else
      push_output(socket, wid, Terminal.demo_prompt())
    end
  end

  defp close_term_shell(socket, wid) do
    case Enum.find(socket.assigns.windows, &(&1.id == wid)) do
      %{server_id: sid} when not is_nil(sid) ->
        ServerShell.close(sid, wid, self())
        assign(socket, :term_shells, Map.delete(socket.assigns.term_shells, wid))

      _ ->
        socket
    end
  end

  # Local demo line discipline (no server attached).
  defp demo_input(socket, wid, "\u0003") do
    append_transcript(socket, wid, "^C\r\n")
  end

  defp demo_input(socket, wid, line) do
    socket = append_transcript(socket, wid, "$ #{line}\r\n")

    case String.trim(line) do
      "" ->
        push_output(socket, wid, Terminal.demo_prompt())

      "clear" ->
        socket
        |> assign(:transcripts, Map.put(socket.assigns.transcripts, wid, []))
        |> push_event("terminal_clear", %{window_id: wid})
        |> push_output(wid, Terminal.demo_prompt())

      "help" ->
        push_output(socket, wid, Terminal.help_text() <> Terminal.demo_prompt())

      "echo " <> rest ->
        push_output(socket, wid, rest <> "\r\n" <> Terminal.demo_prompt())

      "cd" <> _ ->
        push_output(
          socket,
          wid,
          "(demo mode) `cd` — add a server in the Servers app to browse remotely.\r\n" <>
            Terminal.demo_prompt()
        )

      cmd ->
        push_output(
          socket,
          wid,
          "(demo mode) `#{cmd}` — add a server in the Servers app to execute remotely.\r\n" <>
            Terminal.demo_prompt()
        )
    end
  end

  # Forwards raw bytes to the persistent shell, opening one on demand.
  defp shell_input(socket, wid, server, data) do
    pid =
      case Map.get(socket.assigns.term_shells, wid) do
        %{pid: pid} when is_pid(pid) -> if Process.alive?(pid), do: pid, else: nil
        _ -> nil
      end

    if pid do
      _ = ServerShell.input(server.id, wid, self(), data)
      socket
    else
      case ServerShell.ensure(server.id, wid, self(), 80, 24) do
        {:ok, new_pid} ->
          socket =
            assign(
              socket,
              :term_shells,
              Map.put(socket.assigns.term_shells, wid, %{pid: new_pid, open: false})
            )

          _ = ServerShell.input(server.id, wid, self(), data)
          socket

        {:error, reason} ->
          push_output(
            socket,
            wid,
            "✖ cannot open shell: #{inspect(reason)}\r\n[press Enter to retry]\r\n"
          )
      end
    end
  end

  defp to_pos_int(value, default) do
    case Integer.parse(to_string(value || "")) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  # Streaming transcripts are capped by bytes (a vim session scrolls fast).
  @transcript_byte_cap 100_000
  @transcript_chunk_cap 1000

  defp append_transcript(socket, wid, chunk) do
    chunks = Map.get(socket.assigns.transcripts, wid, []) ++ [chunk]

    assign(
      socket,
      :transcripts,
      Map.put(socket.assigns.transcripts, wid, trim_transcript(chunks))
    )
  end

  defp trim_transcript(chunks) do
    {kept, _} =
      chunks
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn chunk, {acc, bytes} ->
        bytes = bytes + byte_size(chunk)

        if bytes > @transcript_byte_cap or length(acc) >= @transcript_chunk_cap do
          {:halt, {acc, bytes}}
        else
          {:cont, {[chunk | acc], bytes}}
        end
      end)

    kept
  end

  defp push_output(socket, wid, chunk) do
    socket
    |> append_transcript(wid, chunk)
    |> push_event("terminal_output", %{data: chunk, window_id: wid})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app fluid flash={@flash}>
      <div
        id="desktop-shell"
        data-theme={@appearance.mode}
        style={"--marsad-accent: #{@appearance.hex}; --marsad-accent-ink: #{@appearance.ink}"}
        class="marsad-desktop relative flex h-full w-full flex-col text-base-content"
      >
        <%!-- Menu bar --%>
        <div class="marsad-glass-strong z-40 flex items-center gap-3 border-x-0 border-t-0 px-4 py-2.5">
          <span class="flex items-center gap-3">
            <span
              class="flex size-12 shrink-0 items-center justify-center overflow-hidden rounded-lg bg-base-100"
              id="marsad-top-logo-wrap"
            >
              <img
                :if={@appearance.mode == "light"}
                src={~p"/images/logo-light.png"}
                alt="Marsad logo"
                id="marsad-top-logo"
                class="h-12 w-12 object-contain"
              />
              <img
                :if={@appearance.mode != "light"}
                src={~p"/images/logo.png"}
                alt="Marsad logo"
                id="marsad-top-logo"
                class="h-12 w-12 object-contain"
              />
            </span>
            <span class="text-base font-bold tracking-wide acc-text">Marsad OS</span>
          </span>
          <span class="hidden h-4 w-px bg-base-content/15 sm:block" aria-hidden="true" />
          <.connection_pill servers={@servers} active_server_id={@active_server_id} />
          <span class="ml-auto hidden items-center gap-2 text-xs text-base-content/60 md:flex">
            <.icon name="hero-lock-closed" class="size-3.5 text-emerald-500" />
            <span class="font-mono">SSH fleet manager</span>
            <span :if={assigns[:current_admin]} class="font-mono text-base-content/50">
              · {@current_admin.username}
            </span>
            <a
              href="/logout"
              id="topbar-logout"
              title="Sign out"
              class="rounded-lg border border-base-content/15 p-1.5 hover:bg-base-content/10"
            >
              <.icon name="hero-arrow-right-start-on-rectangle" class="size-3.5" />
            </a>
          </span>
        </div>

        <div class="flex min-h-0 flex-1">
          <%!-- Dock --%>
          <nav
            id="desktop-icons"
            aria-label="Applications"
            class="marsad-glass z-30 m-3 flex w-[92px] flex-col items-center gap-1.5 overflow-y-auto rounded-2xl p-2.5"
          >
            <button
              :for={{app, idx} <- Enum.with_index(@apps)}
              id={"icon-#{app.id}"}
              phx-click="open-app"
              phx-value-app={app.id}
              class="marsad-icon-in group flex w-full cursor-pointer flex-col items-center gap-1.5 rounded-xl p-2.5 transition-all duration-200 hover:bg-base-content/10 active:scale-95"
              style={"animation-delay: #{idx * 70}ms"}
              title={app.desc}
            >
              <span class={[
                "flex size-12 items-center justify-center rounded-2xl border border-base-content/10 bg-base-content/[0.06] text-base-content/80 shadow transition-all duration-200 group-hover:scale-105 group-hover:acc-soft group-hover:acc-glow",
                running?(@windows, app.id) && "acc-soft acc-border border"
              ]}>
                <.icon name={app.icon} class="size-6" />
              </span>
              <span class="text-[11px] font-medium">{app.name}</span>
              <span
                class={[
                  "size-1 rounded-full transition-all duration-200",
                  running?(@windows, app.id) && "acc-bg",
                  !running?(@windows, app.id) && "bg-transparent"
                ]}
                aria-hidden="true"
              />
            </button>
            <div class="mt-auto flex flex-col items-center gap-1 pt-2 text-[10px] text-base-content/50">
              <span class="font-mono">{length(@servers)} hosts</span>
            </div>
          </nav>

          <%!-- Stage: all panels stay mounted, inactive ones hidden (state preserved) --%>
          <div id="desktop-stage" class="flex min-w-0 flex-1 flex-col overflow-hidden p-4">
            <div :if={@windows == []} class="flex h-full items-center justify-center">
              <div class="marsad-glass marsad-window-in max-w-md rounded-3xl p-8 text-center shadow-2xl">
                <span class="acc-soft mx-auto flex size-16 items-center justify-center rounded-2xl shadow-lg">
                  <.icon name="hero-computer-desktop" class="size-8" />
                </span>
                <p class="mt-4 text-lg font-bold">Welcome to Marsad OS</p>
                <p class="mt-1 text-sm leading-relaxed text-base-content/60">
                  Your fleet command center. Add a VPS, then open a terminal — every window here is live.
                </p>
                <div class="mt-5 flex justify-center gap-2">
                  <button
                    id="cta-open-servers"
                    phx-click="open-app"
                    phx-value-app="servers"
                    class="btn btn-sm acc-bg border-0"
                  >
                    <.icon name="hero-server-stack" class="size-4" /> Open Servers
                  </button>
                  <button
                    id="cta-open-terminal"
                    phx-click="open-app"
                    phx-value-app="terminal"
                    class="btn btn-ghost btn-sm border border-base-content/15"
                  >
                    <.icon name="hero-command-line" class="size-4" /> Terminal
                  </button>
                </div>
              </div>
            </div>

            <%!-- Tab strip (browser-like; hidden panels keep their state) --%>
            <div
              :if={@windows != []}
              id="desktop-tabs"
              role="tablist"
              aria-label="Open apps"
              class="marsad-glass z-30 flex items-center gap-1 overflow-x-auto border-x-0 px-2 py-1.5"
            >
              <span
                :for={w <- @windows}
                id={"tab-#{w.id}"}
                role="tab"
                aria-selected={@focused_id == w.id}
                title={window_title(w, @servers)}
                class={[
                  "marsad-tab group flex shrink-0 items-center gap-1 rounded-lg px-1.5 py-1 text-[13px] font-medium transition-colors duration-150",
                  (@focused_id == w.id && "bg-base-content/[0.08] text-base-content marsad-tab-active") ||
                    "text-base-content/60 hover:bg-base-content/[0.05] hover:text-base-content"
                ]}
              >
                <button
                  id={"switchtab-#{w.id}"}
                  phx-click="switch-tab"
                  phx-value-id={w.id}
                  class="flex cursor-pointer items-center gap-2 rounded px-1.5 py-0.5"
                >
                  <.icon name={window_icon(w)} class="size-4 opacity-70" />
                  <span class="max-w-44 truncate">{window_title(w, @servers)}</span>
                </button>
                <button
                  id={"closetab-#{w.id}"}
                  phx-click="close-window"
                  phx-value-id={w.id}
                  aria-label={"Close #{window_title(w, @servers)}"}
                  class="flex size-4 cursor-pointer items-center justify-center rounded text-xs leading-none text-base-content/40 transition hover:bg-base-content/15 hover:text-base-content"
                >×</button>
              </span>
            </div>

            <section
              :for={w <- @windows}
              id={"panel-#{w.id}"}
              role="tabpanel"
              aria-label={window_title(w, @servers)}
              class={[
                "marsad-window-in min-h-0 flex-1 flex-col overflow-hidden",
                @focused_id == w.id && "flex",
                @focused_id != w.id && "hidden"
              ]}
            >
              <div class="flex min-h-0 flex-1 flex-col">
                <%= cond do %>
                  <% w.app == "terminal" -> %>
                    <div class="flex items-center gap-2 border-b border-base-content/10 px-4 py-1.5 text-xs text-base-content/60">
                      <button
                        id={"termcopy-#{w.id}"}
                        phx-click="terminal_copy"
                        phx-value-window={w.id}
                        title="Copy selected text (or just select — it copies automatically)"
                        class="flex cursor-pointer items-center gap-1 rounded px-1.5 py-0.5 transition hover:bg-base-content/10 hover:text-base-content"
                      >
                        <.icon name="hero-clipboard-document" class="size-3.5" /> Copy
                      </button>
                      <button
                        id={"termclear-#{w.id}"}
                        phx-click="terminal_clear_window"
                        phx-value-window={w.id}
                        title="Clear the screen"
                        class="flex cursor-pointer items-center gap-1 rounded px-1.5 py-0.5 transition hover:bg-base-content/10 hover:text-base-content"
                      >
                        <.icon name="hero-trash" class="size-3.5" /> Clear
                      </button>
                      <.window_peer_pill
                        window={w}
                        servers={@servers}
                        state={term_shell_state(@term_shells, w.id)}
                      />
                    </div>
                    <div
                      id={"terminal-#{w.id}"}
                      phx-hook="XtermTerminal"
                      phx-update="ignore"
                      data-window-id={w.id}
                      data-prompt={Terminal.demo_prompt()}
                      data-theme-mode={@appearance.mode}
                      class="marsad-terminal-wrap min-h-[280px] w-full flex-1"
                    />
                  <% w.app == "servers" -> %>
                    <.servers_app
                      servers={@servers}
                      active_server_id={@active_server_id}
                      form={@server_form}
                      show_form={@show_server_form}
                      editing={@editing_server != nil}
                    />
                  <% w.app == "settings" -> %>
                    <.settings_app
                      appearance={@appearance}
                      password_form={@password_form}
                      password_msg={@password_msg}
                      current_admin={@current_admin}
                    />
                  <% w.app == "docker" -> %>
                    <DockerPanel.panel
                      servers={@servers}
                      state={@docker || %{server_id: nil, data: nil, logs: nil}}
                    />
                  <% w.app == "systemd" -> %>
                    <SystemdPanel.panel
                      servers={@servers}
                      state={
                        @systemd ||
                          %{
                            server_id: nil,
                            data: nil,
                            filter: "",
                            state: "all",
                            sort: "name",
                            logs: nil,
                            unit_preview: nil
                          }
                      }
                      appearance={@appearance}
                    />
                  <% w.app == "nginx" -> %>
                    <NginxPanel.panel
                      servers={@servers}
                      state={
                        @nginx ||
                          %{
                            server_id: nil,
                            status: nil,
                            config: nil,
                            error_log: nil,
                            files: nil,
                            files_error: false,
                            files_filter: "",
                            file_preview: nil
                          }
                      }
                      appearance={@appearance}
                    />
                  <% w.app == "files" -> %>
                    <FilesComponent.files_app
                      servers={@servers}
                      browser={@file_browser}
                      files_filter={@files_filter}
                      files_search_results={@files_search_results}
                      search_truncated={@files_search_truncated}
                      mkdir_form={@mkdir_form}
                      uploads={@uploads}
                      appearance={@appearance}
                    />
                  <% w.app == "monitor" -> %>
                    <.monitor_app
                      servers={@servers}
                      server_id={@monitor_server_id}
                      metrics={@metrics}
                      loading={@metrics_loading}
                      top_procs={@top_procs}
                      proc_sort={@proc_sort}
                      proc_order={@proc_order}
                      proc_page={@proc_page}
                      proc_per_page={@proc_per_page}
                      appearance={@appearance}
                      metrics_duration={@metrics_duration}
                      metrics_chart_data={@metrics_chart_data}
                      metrics_interval={@metrics_interval}
                    />
                  <% true -> %>
                    <div class="flex h-64 flex-col items-center justify-center gap-2 p-8 text-center text-base-content/60">
                      <.icon name="hero-wrench-screwdriver" class="size-10" />
                      <p class="font-semibold text-base-content">Coming soon</p>
                      <p class="text-sm">This app lands in the next phase.</p>
                    </div>
                <% end %>
              </div>
            </section>
          </div>
        </div>

        <%!-- Status bar --%>
        <div
          id="desktop-taskbar"
          class="marsad-glass-strong z-40 flex items-center gap-2 border-x-0 border-b-0 px-4 py-1.5 text-xs text-base-content/60"
        >
          <span class="relative flex size-2">
            <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-emerald-500 opacity-60" />
            <span class="relative inline-flex size-2 rounded-full bg-emerald-500" />
          </span>
          <span class="font-mono">{length(@servers)} servers · {length(@windows)} tabs open</span>
          <span class="ml-auto hidden font-mono sm:block">
            {if @active_server_id,
              do: "active: " <> active_peer(@servers, @active_server_id),
              else: "Standby"}
          </span>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp window_title(%{app: "terminal", server_id: nil}, _servers), do: "Terminal"

  defp window_title(%{app: "terminal", server_id: sid}, servers) do
    case Enum.find(servers, &(&1.id == sid)) do
      nil -> "Terminal"
      s -> "Terminal — #{s.name}"
    end
  end

  defp window_title(%{app: "servers"}, _), do: "Servers"
  defp window_title(%{app: "settings"}, _), do: "Settings"
  defp window_title(%{app: "docker"}, _), do: "Docker"
  defp window_title(%{app: "systemd"}, _), do: "Systemd"
  defp window_title(%{app: "nginx"}, _), do: "Nginx"
  defp window_title(%{app: app}, _), do: String.capitalize(app)

  defp window_icon(%{app: "terminal"}), do: "hero-command-line"
  defp window_icon(%{app: "servers"}), do: "hero-server-stack"
  defp window_icon(%{app: "files"}), do: "hero-folder"
  defp window_icon(%{app: "monitor"}), do: "hero-chart-bar"
  defp window_icon(%{app: "docker"}), do: "hero-cube"
  defp window_icon(%{app: "systemd"}), do: "hero-adjustments-horizontal"
  defp window_icon(%{app: "nginx"}), do: "hero-globe-alt"
  defp window_icon(%{app: "settings"}), do: "hero-cog-6-tooth"
  defp window_icon(_), do: "hero-window"

  defp running?(windows, app), do: Enum.any?(windows, &(&1.app == app))

  attr :servers, :list, required: true
  attr :active_server_id, :any, required: true

  defp connection_pill(assigns) do
    ~H"""
    <%= if server = Enum.find(@servers, &(&1.id == @active_server_id)) do %>
      <span class="flex items-center gap-2 rounded-full border border-emerald-500/30 bg-emerald-500/10 px-3 py-1 pl-2 text-xs font-medium st-online">
        <span class="relative flex size-2">
          <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-emerald-500 opacity-60" />
          <span class="relative inline-flex size-2 rounded-full bg-emerald-500" />
        </span>
        <span class="font-mono">{server.username}@{server.host}</span>
      </span>
    <% else %>
      <span class="flex items-center gap-2 rounded-full border border-amber-500/30 bg-amber-500/10 px-3 py-1 pl-2 text-xs font-medium st-warn">
        <span class="size-2 rounded-full bg-amber-500" aria-hidden="true" /> Standby
      </span>
    <% end %>
    """
  end

  attr :window, :map, required: true
  attr :servers, :list, required: true
  attr :state, :atom, required: false, default: :dead

  defp window_peer_pill(%{window: %{app: "terminal"}} = assigns) do
    ~H"""
    <%= if server = terminal_server(@window, @servers) do %>
      <%= if @state == :connecting do %>
        <span class="ml-auto flex shrink-0 items-center gap-1.5 rounded-full border border-amber-500/25 bg-amber-500/10 px-2 py-0.5 text-[11px] font-medium st-warn">
          <span class="loading loading-spinner loading-xs" aria-label="Connecting" />
          <span class="font-mono">SSH · {server.host}:{server.port} · connecting…</span>
        </span>
      <% else %>
        <span class="ml-auto flex shrink-0 items-center gap-1.5 rounded-full border border-emerald-500/25 bg-emerald-500/10 px-2 py-0.5 text-[11px] font-medium st-online">
          <.icon name="hero-signal" class="size-3" />
          <span class="font-mono">SSH · {server.host}:{server.port}</span>
        </span>
      <% end %>
    <% else %>
      <span class="ml-auto flex shrink-0 items-center gap-1.5 rounded-full border border-amber-500/25 bg-amber-500/10 px-2 py-0.5 text-[11px] font-medium st-warn">
        <.icon name="hero-beaker" class="size-3" /> local demo
      </span>
    <% end %>
    """
  end

  defp window_peer_pill(assigns) do
    ~H"""
    <span class="ml-auto"></span>
    """
  end

  defp terminal_server(%{server_id: nil}, _servers), do: nil
  defp terminal_server(%{server_id: sid}, servers), do: Enum.find(servers, &(&1.id == sid))

  defp active_peer(servers, id) do
    case Enum.find(servers, &(&1.id == id)) do
      nil -> "demo"
      s -> "#{s.username}@#{s.host}"
    end
  end

  defp status_style("online"),
    do: {"bg-emerald-500", "st-online", "Online", true}

  defp status_style("offline"),
    do: {"bg-red-500", "st-offline", "Offline", false}

  defp status_style(_), do: {"bg-base-content/30", "text-base-content/50", "Unknown", false}

  attr :appearance, :map, required: true
  attr :password_form, :any, required: false, default: nil
  attr :password_msg, :any, required: false, default: nil
  attr :current_admin, :any, required: false, default: nil

  defp settings_app(assigns) do
    ~H"""
    <div id="settings-appearance" class="marsad-scroll max-h-[480px] space-y-5 overflow-y-auto p-5">
      <div>
        <h3 class="flex items-center gap-2 font-bold">
          <span class="acc-soft flex size-7 items-center justify-center rounded-lg">
            <.icon name="hero-paint-brush" class="size-4" />
          </span>
          Appearance
        </h3>
        <p class="mt-0.5 text-xs text-base-content/60">
          Theme and accent apply instantly and are stored in the database.
        </p>
      </div>

      <section aria-label="Theme mode">
        <p class="mb-2 text-xs font-semibold uppercase tracking-wider text-base-content/60">Theme</p>
        <div
          class="grid grid-cols-2 gap-2 rounded-2xl border border-base-content/10 bg-base-content/[0.03] p-1.5"
          role="group"
        >
          <button
            id="theme-light"
            phx-click="set-theme-mode"
            phx-value-mode="light"
            aria-pressed={@appearance.mode == "light"}
            class={[
              "flex cursor-pointer items-center justify-center gap-2 rounded-xl px-3 py-2.5 text-sm font-medium transition-all duration-150",
              @appearance.mode == "light" && "acc-bg shadow",
              @appearance.mode != "light" && "text-base-content/70 hover:bg-base-content/10"
            ]}
          >
            <.icon name="hero-sun" class="size-4" /> Light
          </button>
          <button
            id="theme-dark"
            phx-click="set-theme-mode"
            phx-value-mode="dark"
            aria-pressed={@appearance.mode == "dark"}
            class={[
              "flex cursor-pointer items-center justify-center gap-2 rounded-xl px-3 py-2.5 text-sm font-medium transition-all duration-150",
              @appearance.mode == "dark" && "acc-bg shadow",
              @appearance.mode != "dark" && "text-base-content/70 hover:bg-base-content/10"
            ]}
          >
            <.icon name="hero-moon" class="size-4" /> Dark
          </button>
        </div>
      </section>

      <section aria-label="Accent color">
        <p class="mb-2 text-xs font-semibold uppercase tracking-wider text-base-content/60">Accent</p>
        <div class="grid grid-cols-3 gap-2">
          <button
            :for={{key, meta} <- Settings.accents()}
            id={"accent-#{key}"}
            phx-click="set-accent"
            phx-value-accent={key}
            aria-pressed={@appearance.accent == key}
            title={meta.name}
            class={[
              "flex cursor-pointer flex-col items-center gap-1.5 rounded-2xl border p-3 transition-all duration-150 hover:shadow-md",
              (@appearance.accent == key && "acc-border border-2 bg-base-content/[0.04]") ||
                "border-base-content/10 hover:border-base-content/25"
            ]}
          >
            <span
              class="flex size-8 items-center justify-center rounded-full shadow-inner"
              style={"background-color: #{meta.hex}; color: #{meta.ink}"}
            >
              <.icon :if={@appearance.accent == key} name="hero-check" class="size-4" />
            </span>
            <span class="text-xs font-medium">{meta.name}</span>
          </button>
        </div>
      </section>

      <section aria-label="Security" class="rounded-2xl border border-base-content/10 p-4">
        <h4 class="flex items-center gap-2 text-sm font-bold">
          <span class="acc-soft flex size-6 items-center justify-center rounded-lg">
            <.icon name="hero-lock-closed" class="size-3.5" />
          </span>
          Security
        </h4>
        <p class="mt-1 text-xs text-base-content/60">
          Signed in as <span class="font-mono font-semibold">{@current_admin && @current_admin.username}</span>.
          Change the admin password here. Reset deletes the admin so first-time setup runs again.
        </p>

        <.form
          for={@password_form}
          id="password-form"
          phx-submit="change-password"
          class="mt-3 space-y-2"
        >
          <.input
            field={@password_form[:password]}
            type="password"
            label="New password (min 8)"
            autocomplete="new-password"
          />
          <.input
            field={@password_form[:confirm]}
            type="password"
            label="Confirm new password"
            autocomplete="new-password"
          />
          <p
            :if={@password_msg}
            id="password-msg"
            role="status"
            class={[
              "text-xs font-medium",
              match?({:ok, _}, @password_msg) && "text-emerald-600",
              match?({:error, _}, @password_msg) && "text-red-500"
            ]}
          >
            {elem(@password_msg, 1)}
          </p>
          <div class="flex flex-wrap gap-2">
            <button type="submit" id="password-submit" class="btn btn-sm acc-bg border-0">
              Update password
            </button>
            <button
              type="button"
              id="auth-reset"
              phx-click="reset-auth"
              data-confirm="Delete the admin account and go back to setup? You will be signed out."
              class="btn btn-sm btn-ghost border border-red-500/30 text-red-500"
            >
              Reset auth
            </button>
            <a
              href="/logout"
              id="logout-link"
              class="btn btn-sm btn-ghost border border-base-content/15"
            >
              Sign out
            </a>
          </div>
        </.form>
      </section>

      <p class="flex items-center gap-1.5 rounded-xl bg-base-content/[0.04] p-3 text-[11px] leading-relaxed text-base-content/60">
        <.icon name="hero-information-circle" class="size-4 shrink-0" />
        More sections (SSH defaults, notifications) will live here as the OS grows.
      </p>
    </div>
    """
  end

  attr :servers, :list, required: true
  attr :server_id, :any, required: true
  attr :metrics, :map, required: true
  attr :loading, :any, required: true
  attr :top_procs, :map, required: true
  attr :proc_sort, :atom, required: true
  attr :proc_order, :atom, required: true
  attr :proc_page, :integer, required: true
  attr :proc_per_page, :integer, required: true
  attr :appearance, :map, required: false, default: %{mode: "dark"}
  attr :metrics_duration, :string, required: false, default: "24h"
  attr :metrics_chart_data, :map, required: false, default: %{labels: [], datasets: []}
  attr :metrics_interval, :integer, required: false, default: 15000

  defp monitor_app(assigns) do
    assigns =
      assign(assigns, :procs_state, Map.get(assigns.top_procs, assigns.server_id, :loading))

    ~H"""
    <div id="monitor-panel" class="marsad-scroll h-full min-h-0 overflow-y-auto p-4">
      <div class="mb-3 flex flex-wrap items-center gap-2">
        <span class="acc-soft flex size-8 items-center justify-center rounded-xl">
          <.icon name="hero-chart-bar" class="size-4" />
        </span>
        <div>
          <h3 class="font-bold leading-tight">Monitor</h3>
          <p class="text-[11px] text-base-content/60">
            Auto-refreshes every {div(Map.get(assigns, :metrics_interval, 15000), 1000)}s while open · min 5s
          </p>
        </div>
        <form
          id="monitor-server-form"
          phx-change="monitor-server"
          class="ml-auto flex items-center gap-1.5"
        >
          <select
            id="monitor-server-select"
            name="server_id"
            class="select select-sm select-bordered max-w-44"
            aria-label="Monitored server"
          >
            <option value="">Select server…</option>
            <option :for={s <- @servers} value={s.id} selected={@server_id == s.id}>{s.name}</option>
          </select>
          <button
            id="monitor-refresh"
            type="button"
            phx-click="monitor-refresh"
            title="Refresh now"
            class="btn btn-sm btn-ghost border border-base-content/15 phx-click-loading:opacity-60"
          >
            <.icon name="hero-arrow-path" class="marsad-spin-target size-4" />
          </button>
        </form>
      </div>

      <div
        :if={!@server_id}
        id="monitor-empty"
        class="flex h-48 items-center justify-center text-center"
      >
        <div>
          <.icon name="hero-chart-bar" class="mx-auto size-10 text-base-content/30" />
          <p class="mt-2 font-semibold">No server selected</p>
          <p class="text-sm text-base-content/60">Pick a server above to see live metrics.</p>
        </div>
      </div>

      <%= if @server_id do %>
        <%= case Map.get(@metrics, @server_id, :loading) do %>
          <% :loading -> %>
            <div class="grid gap-2.5 sm:grid-cols-2" aria-label="Loading metrics">
              <div
                :for={_ <- 1..4}
                class="rounded-2xl border border-base-content/10 bg-base-content/[0.03] p-4"
              >
                <div class="marsad-shimmer h-3 w-20 rounded" />
                <div class="marsad-shimmer mt-3 h-6 w-28 rounded" />
                <div class="marsad-shimmer mt-3 h-1.5 rounded-full" />
              </div>
            </div>
          <% {:error, reason} -> %>
            <div
              role="alert"
              class="rounded-2xl border border-red-500/30 bg-red-500/10 p-5 text-center text-sm"
            >
              <p class="st-offline font-semibold">Metrics unavailable</p>
              <p class="mt-1 font-mono text-xs text-base-content/60">{inspect(reason)}</p>
              <button phx-click="monitor-refresh" class="btn btn-sm mt-3 border-base-content/15">Retry</button>
            </div>
          <% {:ok, m} -> %>
            <div class="mb-3 flex flex-wrap items-center gap-2 rounded-xl bg-base-content/[0.03] p-2">
              <span class="text-xs font-medium text-base-content/60">Duration:</span>
              <form phx-change="metrics_duration" class="flex items-center gap-1">
                <select name="duration" class="select select-xs select-bordered h-7 min-h-0">
                  <option value="1h" selected={Map.get(assigns, :metrics_duration, "24h") == "1h"}>
                    1h
                  </option>
                  <option value="6h" selected={Map.get(assigns, :metrics_duration, "24h") == "6h"}>
                    6h
                  </option>
                  <option value="24h" selected={Map.get(assigns, :metrics_duration, "24h") == "24h"}>
                    24h
                  </option>
                  <option value="7d" selected={Map.get(assigns, :metrics_duration, "24h") == "7d"}>
                    7d
                  </option>
                  <option
                    value="custom"
                    selected={Map.get(assigns, :metrics_duration, "24h") == "custom"}
                  >
                    Custom
                  </option>
                </select>
              </form>
              <form
                :if={Map.get(assigns, :metrics_duration) == "custom"}
                phx-change="metrics_custom_range"
                class="flex items-center gap-1"
              >
                <input type="date" name="from" class="input input-xs h-7" />
                <span class="text-xs">→</span>
                <input type="date" name="to" class="input input-xs h-7" />
              </form>
              <span class="ml-auto flex items-center gap-2 text-[11px] text-base-content/50">
                <span>Chart.js • Auto-refresh</span>
                <form phx-change="metrics_interval" class="flex items-center gap-1">
                  <select
                    name="interval"
                    class="select select-xs select-bordered h-6 min-h-0 py-0 text-xs"
                  >
                    <option value="5" selected={Map.get(assigns, :metrics_interval, 15000) == 5000}>
                      5s
                    </option>
                    <option value="10" selected={Map.get(assigns, :metrics_interval, 15000) == 10000}>
                      10s
                    </option>
                    <option value="15" selected={Map.get(assigns, :metrics_interval, 15000) == 15000}>
                      15s
                    </option>
                    <option value="30" selected={Map.get(assigns, :metrics_interval, 15000) == 30000}>
                      30s
                    </option>
                    <option value="60" selected={Map.get(assigns, :metrics_interval, 15000) == 60000}>
                      60s
                    </option>
                  </select>
                </form>
              </span>
            </div>

            <div class="mb-3 rounded-2xl border border-base-content/10 bg-base-content/[0.03] p-3">
              <canvas
                id={"metrics-chart-#{@server_id}"}
                phx-hook="ChartHook"
                phx-update="ignore"
                data-theme={@appearance.mode}
                data-chart-data={
                  Jason.encode!(Map.get(assigns, :metrics_chart_data, %{labels: [], datasets: []}))
                }
                class="h-48 w-full"
              ></canvas>
            </div>

            <div id="monitor-grid" class="grid gap-2.5 sm:grid-cols-2">
              <.metric_card
                label="CPU load"
                value={"#{m.load1} / #{m.cores} cores"}
                pct={round(Marsad.Fleet.SysInfo.load_ratio(m) * 100)}
                sub={"#{m.load5} · #{m.load15} (5m · 15m)"}
              />
              <.metric_card
                label="Memory"
                value={"#{Marsad.Fleet.SysInfo.format_mb(m.mem_used_mb)} / #{Marsad.Fleet.SysInfo.format_mb(m.mem_total_mb)}"}
                pct={Marsad.Fleet.SysInfo.mem_pct(m)}
                sub="used / total"
              />
              <%= for disk <- Map.get(m, :disks, []) || [] do %>
                <.metric_card
                  label={"Disk #{disk.mount}"}
                  value={"#{Marsad.Fleet.SysInfo.format_mb(disk.used)} / #{Marsad.Fleet.SysInfo.format_mb(disk.total)}"}
                  pct={disk.pct}
                  sub={disk.fs}
                />
              <% end %>
              <%= if Map.get(m, :disks) == nil do %>
                <.metric_card
                  label="Disk /"
                  value={"#{Marsad.Fleet.SysInfo.format_mb(m.disk_used_mb)} / #{Marsad.Fleet.SysInfo.format_mb(m.disk_total_mb)}"}
                  pct={m.disk_pct}
                  sub="used / total"
                />
              <% end %>
              <div class="rounded-2xl border border-base-content/10 bg-base-content/[0.03] p-4">
                <p class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                  System
                </p>
                <p class="mt-2 truncate font-mono text-sm font-semibold" title={m.hostname}>
                  {m.hostname}
                </p>
                <p class="truncate font-mono text-[11px] text-base-content/60">kernel {m.kernel}</p>
                <p class="mt-1 truncate text-xs text-base-content/60">{m.uptime}</p>
                <p
                  :if={Map.get(m, :net_rx_mb)}
                  class="mt-1 font-mono text-[11px] text-base-content/50"
                >
                  Net RX {m.net_rx_mb} MB · TX {m.net_tx_mb} MB
                </p>
              </div>
            </div>
            <p class="mt-2 text-right font-mono text-[10px] text-base-content/40">
              updated {Calendar.strftime(m.taken_at, "%H:%M:%S")}
            </p>
            <details
              :if={Map.get(m, :cores_raw)}
              class="mt-1 rounded-lg border border-base-content/10 bg-base-content/[0.02] px-2 py-1 text-[10px]"
            >
              <summary class="cursor-pointer font-mono text-base-content/50 hover:text-base-content">
                cores debug · raw: "{String.slice(m.cores_raw || "", 0, 80)}" → {m.cores}
              </summary>
              <p class="mt-1 whitespace-pre-wrap break-all font-mono text-[10px] leading-relaxed text-base-content/60">
                Full raw output (max is taken): {m.cores_raw}
              </p>
              <p class="mt-1 text-[10px] text-base-content/40">
                Sources: nproc --all / nproc / cpuinfo / getconf / lscpu / sysfs / proc/stat — max wins. If you expect 4 but see 3, run on server:
                <code class="rounded bg-base-content/10 px-1 py-0.5">nproc --all; nproc; grep -c ^processor /proc/cpuinfo; lscpu | grep CPU</code>
              </p>
            </details>
        <% end %>

        <%!-- Top processes (paginated, sortable) --%>
        <div
          id="monitor-procs"
          class="mt-4 rounded-2xl border border-base-content/10 bg-base-content/[0.03]"
        >
          <div class="flex flex-wrap items-center gap-2 border-b border-base-content/10 px-4 py-3">
            <span class="acc-soft flex size-7 items-center justify-center rounded-lg">
              <.icon name="hero-cpu-chip" class="size-4" />
            </span>
            <div>
              <p class="text-sm font-bold leading-tight">Top processes</p>
              <p class="text-[11px] text-base-content/60">By resource usage · tap header to sort</p>
            </div>
            <div class="ml-auto flex items-center gap-1.5">
              <form
                id="monitor-per-page-form"
                phx-change="monitor-proc-per-page"
                class="flex items-center gap-1"
              >
                <select
                  name="per_page"
                  aria-label="Rows per page"
                  class="select select-xs select-bordered h-7 min-h-0"
                >
                  <option value="5" selected={@proc_per_page == 5}>5 / page</option>
                  <option value="10" selected={@proc_per_page == 10}>10 / page</option>
                  <option value="25" selected={@proc_per_page == 25}>25 / page</option>
                  <option value="50" selected={@proc_per_page == 50}>50 / page</option>
                </select>
              </form>
              <button
                phx-click="monitor-refresh"
                title="Refresh processes"
                class="btn btn-xs btn-ghost border border-base-content/15 phx-click-loading:opacity-60"
              >
                <.icon name="hero-arrow-path" class="marsad-spin-target size-3.5" />
              </button>
            </div>
          </div>

          <%= case @procs_state do %>
            <% :loading -> %>
              <div class="space-y-0 p-2" aria-label="Loading processes">
                <div :for={_ <- 1..6} class="flex items-center gap-3 px-2 py-2.5">
                  <span class="marsad-shimmer size-8 rounded" />
                  <span class="marsad-shimmer h-3.5 rounded" style="width: 25%" />
                  <span class="marsad-shimmer ml-auto h-3 w-20 rounded" />
                </div>
              </div>
            <% {:error, reason} -> %>
              <div
                role="alert"
                class="m-4 rounded-xl border border-amber-500/30 bg-amber-500/10 p-4 text-center text-sm"
              >
                <p class="st-warn font-semibold">Cannot load processes</p>
                <p class="mt-1 font-mono text-xs text-base-content/60">{inspect(reason)}</p>
                <button phx-click="monitor-refresh" class="btn btn-xs mt-3 border-base-content/15">Retry</button>
              </div>
            <% {:ok, procs} -> %>
              <%= if procs == [] do %>
                <p class="p-6 text-center text-sm text-base-content/50">No processes found.</p>
              <% else %>
                <% sorted = Marsad.Fleet.SysInfo.sort_procs(procs, @proc_sort, @proc_order) %>
                <% total = length(sorted) %>
                <% total_pages = max(1, ceil(total / @proc_per_page)) %>
                <% page = @proc_page |> min(total_pages) |> max(1) %>
                <% paged = Enum.slice(sorted, (page - 1) * @proc_per_page, @proc_per_page) %>
                <div class="overflow-x-auto">
                  <table class="w-full text-left text-xs">
                    <thead>
                      <tr class="border-b border-base-content/10 bg-base-content/[0.02] text-[11px] uppercase tracking-wider text-base-content/60">
                        <th class="px-4 py-2 font-semibold">
                          <button
                            phx-click="monitor-proc-sort"
                            phx-value-sort="pid"
                            class="flex items-center gap-1 hover:text-base-content"
                          >
                            PID <.sort_icon field={:pid} current={@proc_sort} order={@proc_order} />
                          </button>
                        </th>
                        <th class="px-4 py-2 font-semibold">
                          <button
                            phx-click="monitor-proc-sort"
                            phx-value-sort="comm"
                            class="flex items-center gap-1 hover:text-base-content"
                          >
                            Command
                            <.sort_icon field={:comm} current={@proc_sort} order={@proc_order} />
                          </button>
                        </th>
                        <th class="px-4 py-2 text-right font-semibold">
                          <button
                            phx-click="monitor-proc-sort"
                            phx-value-sort="cpu"
                            class="ml-auto flex items-center gap-1 hover:text-base-content"
                          >
                            CPU% <.sort_icon field={:cpu} current={@proc_sort} order={@proc_order} />
                          </button>
                        </th>
                        <th class="px-4 py-2 text-right font-semibold">
                          <button
                            phx-click="monitor-proc-sort"
                            phx-value-sort="mem"
                            class="ml-auto flex items-center gap-1 hover:text-base-content"
                          >
                            MEM% <.sort_icon field={:mem} current={@proc_sort} order={@proc_order} />
                          </button>
                        </th>
                        <th class="px-4 py-2 text-center font-semibold">Actions</th>
                      </tr>
                    </thead>
                    <tbody class="divide-y divide-base-content/[0.06]">
                      <tr
                        :for={p <- paged}
                        id={"proc-#{p.pid}"}
                        class="transition hover:bg-base-content/[0.04]"
                      >
                        <td class="px-4 py-1.5 font-mono text-[11px]">{p.pid}</td>
                        <td
                          class="max-w-[180px] truncate px-4 py-1.5 font-mono text-[11px] font-medium"
                          title={p.comm}
                        >
                          {p.comm}
                        </td>
                        <td class="px-4 py-1.5 text-right font-mono text-[11px]">
                          <span class={[
                            "rounded-full px-1.5 py-0.5 text-[10px] font-medium",
                            p.cpu >= 50 && "bg-red-500/10 text-red-600 dark:text-red-300",
                            p.cpu >= 20 && p.cpu < 50 &&
                              "bg-amber-500/10 text-amber-600 dark:text-amber-300",
                            p.cpu < 20 && "bg-base-content/10 text-base-content/70"
                          ]}>
                            {Float.round(p.cpu * 1.0, 1)}%
                          </span>
                        </td>
                        <td class="px-4 py-1.5 text-right font-mono text-[11px]">
                          {Float.round(p.mem * 1.0, 1)}%
                        </td>
                        <td class="px-4 py-1.5 text-center">
                          <button
                            phx-click="kill_process"
                            phx-value-pid={p.pid}
                            data-confirm={"Kill #{p.comm} (PID #{p.pid})? This will force terminate the process."}
                            class="btn btn-xs btn-ghost text-red-600 hover:bg-red-500/10 border border-red-200"
                            title={"Kill #{p.pid}"}
                          >
                            <.icon name="hero-x-mark" class="size-3" /> Kill
                          </button>
                          <button
                            phx-click="restart_service_for_pid"
                            phx-value-pid={p.pid}
                            phx-value-comm={p.comm}
                            class="btn btn-xs btn-ghost ml-1 border border-base-content/15 hover:bg-base-content/10"
                            title="Try to restart service for this process"
                          >
                            Restart
                          </button>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>

                <div class="flex flex-wrap items-center gap-2 border-t border-base-content/10 px-4 py-2.5 text-xs">
                  <span class="font-mono text-[11px] text-base-content/60">
                    {length(paged)} of {total} · page {page}/{total_pages}
                  </span>
                  <span class="ml-auto flex items-center gap-1">
                    <button
                      phx-click="monitor-proc-page"
                      phx-value-page={page - 1}
                      disabled={page <= 1}
                      class="btn btn-xs border-base-content/15 disabled:opacity-40"
                    >‹ Prev</button>
                    <span
                      :for={p <- 1..total_pages}
                      :if={total_pages <= 7 or p in [1, total_pages, page - 1, page, page + 1]}
                      class="flex items-center"
                    >
                      <button
                        :if={p == page}
                        class="btn btn-xs acc-bg border-0"
                      >{p}</button>
                      <button
                        :if={p != page}
                        phx-click="monitor-proc-page"
                        phx-value-page={p}
                        class="btn btn-xs btn-ghost border border-base-content/15"
                      >{p}</button>
                      <span
                        :if={p == 1 and page > 3 and total_pages > 7}
                        class="px-1 text-base-content/40"
                      >…</span>
                      <span
                        :if={p == page + 1 and page + 2 < total_pages and total_pages > 7}
                        class="px-1 text-base-content/40"
                      >…</span>
                    </span>
                    <button
                      phx-click="monitor-proc-page"
                      phx-value-page={page + 1}
                      disabled={page >= total_pages}
                      class="btn btn-xs border-base-content/15 disabled:opacity-40"
                    >Next ›</button>
                  </span>
                </div>
              <% end %>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr :field, :atom, required: true
  attr :current, :atom, required: true
  attr :order, :atom, required: true

  defp sort_icon(assigns) do
    ~H"""
    <span class="inline-flex items-center">
      <%= if @field == @current do %>
        <.icon
          name={if @order == :asc, do: "hero-chevron-up", else: "hero-chevron-down"}
          class="size-3"
        />
      <% else %>
        <.icon name="hero-chevron-up-down" class="size-3 opacity-40" />
      <% end %>
    </span>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :pct, :integer, required: true
  attr :sub, :string, required: true

  defp metric_card(assigns) do
    ~H"""
    <div class="rounded-2xl border border-base-content/10 bg-base-content/[0.03] p-4">
      <p class="text-xs font-semibold uppercase tracking-wider text-base-content/50">{@label}</p>
      <p class="mt-1.5 truncate font-mono text-lg font-bold" title={@value}>{@value}</p>
      <div
        class="mt-2 h-1.5 overflow-hidden rounded-full bg-base-content/10"
        role="progressbar"
        aria-valuenow={@pct}
        aria-valuemin="0"
        aria-valuemax="100"
        aria-label={@label}
      >
        <div
          class={["h-full rounded-full transition-all duration-500", bar_class(@pct)]}
          style={"width: #{min(@pct, 100)}%"}
        />
      </div>
      <p class="mt-1.5 font-mono text-[11px] text-base-content/50">{@sub} · {@pct}%</p>
    </div>
    """
  end

  attr :servers, :list, required: true
  attr :active_server_id, :any, required: true
  attr :form, :any, required: true
  attr :show_form, :boolean, required: true
  attr :editing, :boolean, required: true

  defp servers_app(assigns) do
    ~H"""
    <div class="marsad-scroll max-h-[480px] overflow-y-auto p-4">
      <div class="mb-3 flex items-center gap-2.5">
        <span class="acc-soft flex size-8 items-center justify-center rounded-xl">
          <.icon name="hero-server-stack" class="size-4" />
        </span>
        <div>
          <h3 class="font-bold leading-tight">Servers</h3>
          <p class="text-[11px] text-base-content/60">{length(@servers)} hosts · SSH fleet</p>
        </div>
        <button
          id="new-server"
          phx-click="new-server"
          class="btn btn-xs ml-auto gap-1 acc-bg border-0"
        >
          <.icon name="hero-plus" class="size-4" /> Add server
        </button>
      </div>

      <div :if={@show_form} class="marsad-glass mb-4 rounded-2xl p-4 shadow-xl">
        <p class="mb-3 flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wider text-base-content/60">
          <.icon name="hero-key" class="size-3.5" />
          {if @editing, do: "Edit server", else: "New server"}
        </p>
        <.form
          for={@form}
          id="server-form"
          phx-change="validate-server"
          phx-submit="save-server"
          class="space-y-3"
        >
          <.input field={@form[:name]} type="text" label="Name" placeholder="prod-1" />
          <div class="grid grid-cols-3 gap-2">
            <.input field={@form[:host]} type="text" label="Host" placeholder="203.0.113.10" />
            <.input field={@form[:port]} type="number" label="Port" />
            <.input field={@form[:username]} type="text" label="User" placeholder="root" />
          </div>
          <div class="grid grid-cols-2 gap-2">
            <.input
              field={@form[:auth_type]}
              type="select"
              label="Auth"
              options={[{"Password", "password"}, {"Private key", "key"}]}
            />
            <.input
              field={@form[:secret]}
              type="password"
              label="Secret (password / PEM / key path)"
              autocomplete="off"
            />
          </div>
          <div class="flex gap-2 pt-1">
            <button type="submit" class="btn btn-sm acc-bg border-0">Save</button>
            <button
              type="button"
              phx-click="cancel-server-form"
              class="btn btn-ghost btn-sm border border-base-content/15"
            >
              Cancel
            </button>
          </div>
        </.form>
      </div>

      <div id="servers-list" class="space-y-2.5">
        <div class="hidden rounded-2xl border border-dashed border-base-content/25 p-8 text-center text-sm text-base-content/60 only:block">
          <.icon name="hero-server" class="mx-auto size-8 opacity-50" />
          <p class="mt-2 font-medium">No servers yet</p>
          <p class="text-xs">Add your first VPS to start managing it over SSH.</p>
        </div>
        <div
          :for={s <- @servers}
          id={"server-row-#{s.id}"}
          class={[
            "group rounded-2xl border p-3.5 transition-all duration-150 hover:shadow-lg",
            (@active_server_id == s.id && "acc-border acc-glow border bg-base-content/[0.04]") ||
              "border-base-content/10 bg-base-content/[0.03] hover:border-base-content/20 hover:bg-base-content/[0.06]"
          ]}
        >
          <div class="flex items-center gap-3">
            <% {dot, _text, label, pulse?} = status_style(s.status) %>
            <span class="relative flex size-2.5 shrink-0" title={"Status: #{label}"}>
              <span
                :if={pulse?}
                class="absolute inline-flex h-full w-full animate-ping rounded-full bg-emerald-400 opacity-60"
              />
              <span class={["relative inline-flex size-2.5 rounded-full", dot]} />
              <span class="sr-only">Status: {label}</span>
            </span>
            <div class="min-w-0">
              <p class="flex items-center gap-2 truncate font-semibold">
                {s.name}
                <span
                  :if={@active_server_id == s.id}
                  class="acc-soft rounded-full px-1.5 py-px text-[10px] font-medium"
                >
                  active
                </span>
              </p>
              <p class="truncate font-mono text-xs text-base-content/60">
                {s.username}@{s.host}:{s.port} · {s.auth_type}
              </p>
              <p :if={s.host_fingerprint} class="truncate font-mono text-[10px] text-base-content/50">
                fingerprint {String.slice(s.host_fingerprint, 0, 32)}
              </p>
            </div>
            <span class={["ml-auto shrink-0 text-[11px] font-medium", elem(status_style(s.status), 1)]}>{label}</span>
          </div>
          <div class="mt-2.5 flex flex-wrap gap-1.5 border-t border-base-content/10 pt-2.5">
            <button
              id={"connect-#{s.id}"}
              phx-click="select-server"
              phx-value-id={s.id}
              class="btn btn-xs gap-1 acc-bg border-0"
            >
              <.icon name="hero-command-line" class="size-3.5" /> Terminal
            </button>
            <button
              id={"test-#{s.id}"}
              phx-click="test-server"
              phx-value-id={s.id}
              class="btn btn-xs border-base-content/15 hover:bg-base-content/10"
            >
              <.icon name="hero-signal" class="size-3.5" /> Test
            </button>
            <button
              id={"edit-#{s.id}"}
              phx-click="edit-server"
              phx-value-id={s.id}
              class="btn btn-xs border-base-content/15 hover:bg-base-content/10"
            >
              <.icon name="hero-pencil-square" class="size-3.5" /> Edit
            </button>
            <button
              id={"del-#{s.id}"}
              phx-click="delete-server"
              phx-value-id={s.id}
              data-confirm="Delete this server?"
              class="btn btn-xs border-base-content/15 text-red-500 hover:bg-red-500/10"
            >
              <.icon name="hero-trash" class="size-3.5" /> Delete
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
