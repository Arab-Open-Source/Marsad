defmodule Marsad.Fleet.Services do
  @moduledoc """
  Service management over SSH: Docker containers, systemd units, nginx.

  Remote names interpolated into shell commands are strictly validated
  (`valid_name?/1`) to prevent injection. All parsing is pure and unit-tested.
  """

  alias Marsad.Fleet

  @type container :: %{
          id: binary(),
          name: binary(),
          image: binary(),
          state: binary(),
          status: binary(),
          ports: binary()
        }
  @type unit :: %{
          unit: binary(),
          load: binary(),
          active: binary(),
          sub: binary(),
          description: binary()
        }

  # -- Docker ---------------------------------------------------------------

  @doc "Lists all containers (`docker ps -a`)."
  @spec docker_containers(pos_integer()) :: {:ok, [container()]} | {:error, term()}
  def docker_containers(server_id) do
    case Fleet.exec(server_id, "docker ps -a --format '{{json .}}'") do
      {:ok, %{stdout: out, stderr: err}} ->
        if docker_unavailable?(out <> err),
          do: {:error, :docker_unavailable},
          else: {:ok, parse_docker_ps(out)}

      {:error, _} = error ->
        error
    end
  end

  @docker_actions ~w(start stop restart remove)

  @doc "Container actions (`start`/`stop`/`restart`/`rm -f`). Unknown actions are rejected, never crash."
  @spec docker_action(pos_integer(), binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def docker_action(server_id, action, name) when action in @docker_actions do
    cmd = if action == "remove", do: "docker rm -f #{name}", else: "docker #{action} #{name}"

    with :ok <- validate_name(name),
         {:ok, %{stdout: out, stderr: err}} <- Fleet.exec(server_id, cmd) do
      if docker_unavailable?(out <> err),
        do: {:error, :docker_unavailable},
        else: {:ok, String.trim(out <> err)}
    end
  end

  def docker_action(_server_id, _action, _name), do: {:error, :invalid_action}

  @doc "English past tense for container actions (for flash messages)."
  @spec action_past(binary()) :: binary()
  def action_past("start"), do: "started"
  def action_past("stop"), do: "stopped"
  def action_past("restart"), do: "restarted"
  def action_past("remove"), do: "removed"
  def action_past(action), do: "#{action}ed"

  @doc "Supported container actions."
  def docker_actions, do: @docker_actions

  @log_tails [50, 100, 200, 500, 1000]

  @doc """
  Tails container logs (stdout + stderr merged), capped at 200KB.

  Options: `tail:` (one of 50/100/200/500/1000, default 200),
  `timestamps:` (prepend `-t` RFC3339 stamps, default false).
  """
  @spec docker_logs(pos_integer(), binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def docker_logs(server_id, name, opts \\ []) do
    tail = Keyword.get(opts, :tail, 200)
    tail = if tail in @log_tails, do: tail, else: 200

    flags =
      if Keyword.get(opts, :timestamps, false), do: "--tail #{tail} -t", else: "--tail #{tail}"

    with :ok <- validate_name(name),
         {:ok, %{stdout: out, stderr: err}} <-
           Fleet.exec(server_id, "docker logs #{flags} #{name} 2>&1 | head -c 200000") do
      {:ok, out <> err}
    end
  end

  @doc "Log tail sizes offered by the UI."
  def log_tails, do: @log_tails

  @max_log_download 5_000_000

  @doc """
  Full log download (newest bytes win): streams `docker logs` through
  `tail -c` so the transfer never exceeds #{div(@max_log_download, 1_000_000)}MB
  no matter how chatty the container is. Binary-safe.
  """
  @spec docker_logs_download(pos_integer(), binary(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def docker_logs_download(server_id, name, opts \\ []) do
    ts = if Keyword.get(opts, :timestamps, false), do: "-t ", else: ""

    with :ok <- validate_name(name),
         {:ok, %{stdout: out, stderr: err}} <-
           Fleet.exec(server_id, "docker logs #{ts}#{name} 2>&1 | tail -c #{@max_log_download}") do
      {:ok, out <> err}
    end
  end

  @doc "Byte cap applied to log downloads."
  def max_log_download, do: @max_log_download

  @doc "Live stats (`docker stats --no-stream`)."
  @spec docker_stats(pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def docker_stats(server_id) do
    case Fleet.exec(server_id, "docker stats --no-stream --format '{{json .}}' 2>&1") do
      {:ok, %{stdout: out, stderr: err}} ->
        if docker_unavailable?(out <> err),
          do: {:error, :docker_unavailable},
          else: {:ok, parse_docker_stats(out)}

      {:error, _} = error ->
        error
    end
  end

  @doc "Inspects a container (`docker inspect`)."
  @spec docker_inspect(pos_integer(), binary()) :: {:ok, map()} | {:error, term()}
  def docker_inspect(server_id, name) do
    with :ok <- validate_name(name),
         {:ok, %{stdout: out, stderr: err}} <-
           Fleet.exec(server_id, "docker inspect #{name} 2>&1") do
      if docker_unavailable?(out <> err) do
        {:error, :docker_unavailable}
      else
        case Jason.decode(String.trim(out)) do
          {:ok, [first | _]} -> {:ok, first}
          {:ok, map} when is_map(map) -> {:ok, map}
          _ -> {:error, {:inspect_failed, String.trim(out <> err)}}
        end
      end
    end
  end

  @doc "Parses `docker ps --format '{{json .}}'` output (one object per line)."
  @spec parse_docker_ps(binary()) :: [container()]
  def parse_docker_ps(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, m} ->
          [
            %{
              id: String.slice(to_string(m["ID"] || ""), 0, 12),
              name: to_string(m["Names"] || ""),
              image: to_string(m["Image"] || ""),
              state: to_string(m["State"] || ""),
              status: to_string(m["Status"] || ""),
              ports: to_string(m["Ports"] || "")
            }
          ]

        _ ->
          []
      end
    end)
  end

  @doc "Parses `docker stats --no-stream --format '{{json .}}'` output."
  @spec parse_docker_stats(binary()) :: [map()]
  def parse_docker_stats(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, m} ->
          [
            %{
              name: to_string(m["Name"] || m["Names"] || ""),
              id: String.slice(to_string(m["ID"] || m["Container"] || ""), 0, 12),
              cpu: to_string(m["CPUPerc"] || ""),
              mem: to_string(m["MemPerc"] || ""),
              mem_usage: to_string(m["MemUsage"] || ""),
              net_io: to_string(m["NetIO"] || ""),
              block_io: to_string(m["BlockIO"] || ""),
              pids: to_string(m["PIDs"] || "")
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp docker_unavailable?(text) do
    String.contains?(text, "Cannot connect to the Docker daemon") or
      String.contains?(text, "command not found") or String.contains?(text, "docker: not found")
  end

  # -- Docker images ------------------------------------------------------------

  @type image :: %{
          repository: binary(),
          tag: binary(),
          id: binary(),
          size: binary(),
          created: binary()
        }

  @doc "Lists local images (`docker images`)."
  @spec docker_images(pos_integer()) :: {:ok, [image()]} | {:error, term()}
  def docker_images(server_id) do
    case Fleet.exec(server_id, "docker images --format '{{json .}}' 2>&1") do
      {:ok, %{stdout: out, stderr: err}} ->
        if docker_unavailable?(out <> err),
          do: {:error, :docker_unavailable},
          else: {:ok, parse_docker_images(out)}

      {:error, _} = error ->
        error
    end
  end

  @doc "Parses `docker images --format '{{json .}}'` output (one object per line)."
  @spec parse_docker_images(binary()) :: [image()]
  def parse_docker_images(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, m} ->
          [
            %{
              repository: to_string(m["Repository"] || ""),
              tag: to_string(m["Tag"] || ""),
              id: String.slice(to_string(m["ID"] || ""), 0, 12),
              size: to_string(m["Size"] || ""),
              created: to_string(m["CreatedSince"] || m["CreatedAt"] || "")
            }
          ]

        _ ->
          []
      end
    end)
  end

  @doc "Removes one image (`docker rmi`)."
  @spec docker_rmi(pos_integer(), binary()) :: {:ok, binary()} | {:error, term()}
  def docker_rmi(server_id, image_id) do
    with :ok <- validate_name(image_id),
         {:ok, %{stdout: out, stderr: err}} <-
           Fleet.exec(server_id, "docker rmi #{image_id} 2>&1") do
      if docker_unavailable?(out <> err),
        do: {:error, :docker_unavailable},
        else: {:ok, String.trim(out <> err)}
    end
  end

  @doc "Prunes unused images and stopped containers (`-f`, non-interactive)."
  @spec docker_prune(pos_integer()) :: {:ok, binary()} | {:error, term()}
  def docker_prune(server_id) do
    case Fleet.exec(server_id, "docker image prune -f 2>&1; docker container prune -f 2>&1") do
      {:ok, %{stdout: out, stderr: err}} ->
        if docker_unavailable?(out <> err),
          do: {:error, :docker_unavailable},
          else: {:ok, String.trim(out <> err)}

      {:error, _} = error ->
        error
    end
  end

  # -- Docker Compose -------------------------------------------------------------

  @type project :: %{name: binary(), status: binary(), config: binary()}
  @type service :: %{
          name: binary(),
          service: binary(),
          state: binary(),
          status: binary(),
          ports: binary()
        }

  @doc "Lists compose projects (`docker compose ls`)."
  @spec compose_projects(pos_integer()) :: {:ok, [project()]} | {:error, term()}
  def compose_projects(server_id) do
    case Fleet.exec(server_id, "docker compose ls --format '{{json .}}' 2>&1") do
      {:ok, %{stdout: out, stderr: err}} ->
        cond do
          compose_unavailable?(out <> err) -> {:error, :compose_unavailable}
          true -> {:ok, parse_compose_json(out, &compose_project/1)}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc "Lists services of one compose project (by its config file)."
  @spec compose_services(pos_integer(), binary()) :: {:ok, [service()]} | {:error, term()}
  def compose_services(server_id, config_file) do
    quoted = Marsad.Helpers.Text.shell_quote(config_file)

    case Fleet.exec(server_id, "docker compose -f #{quoted} ps --format '{{json .}}' 2>&1") do
      {:ok, %{stdout: out, stderr: err}} ->
        cond do
          compose_unavailable?(out <> err) -> {:error, :compose_unavailable}
          true -> {:ok, parse_compose_json(out, &compose_service/1)}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc "Restarts/stops/starts one compose service."
  @spec compose_action(pos_integer(), binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def compose_action(server_id, config_file, action, service)
      when action in ["start", "stop", "restart"] do
    quoted = Marsad.Helpers.Text.shell_quote(config_file)

    with :ok <- validate_name(service),
         {:ok, %{stdout: out, stderr: err, status: status}} <-
           Fleet.exec(server_id, "docker compose -f #{quoted} #{action} #{service} 2>&1") do
      cond do
        compose_unavailable?(out <> err) -> {:error, :compose_unavailable}
        status == 0 -> {:ok, String.trim(out <> err)}
        true -> {:error, {:action_failed, String.trim(out <> err)}}
      end
    end
  end

  def compose_action(_server_id, _config, _action, _service), do: {:error, :invalid_action}

  defp compose_project(m) do
    %{
      name: to_string(m["Name"] || ""),
      status: to_string(m["Status"] || ""),
      config: m["ConfigFiles"] |> to_string() |> String.split(",", trim: true) |> List.first("")
    }
  end

  defp compose_service(m) do
    %{
      name: to_string(m["Name"] || ""),
      service: to_string(m["Service"] || ""),
      state: to_string(m["State"] || ""),
      status: to_string(m["Status"] || ""),
      ports: to_string(m["Publishers"] || m["Ports"] || "")
    }
  end

  @doc "Parses compose JSON output (array or newline-delimited objects)."
  @spec parse_compose_json(binary(), (map() -> map())) :: [map()]
  def parse_compose_json(out, fun) do
    trimmed = String.trim(out)

    objects =
      case Jason.decode(trimmed) do
        {:ok, list} when is_list(list) -> list
        {:ok, map} when is_map(map) -> [map]
        _ -> trimmed |> String.split("\n", trim: true) |> Enum.flat_map(&decode_line/1)
      end

    objects
    |> Enum.filter(&is_map/1)
    |> Enum.map(fun)
    |> Enum.reject(&(&1.name == "" and &1[:service] in [nil, ""]))
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, m} when is_map(m) -> [m]
      _ -> []
    end
  end

  defp compose_unavailable?(text) do
    String.contains?(text, "not a docker command") or
      String.contains?(text, "unknown shorthand flag") or
      String.contains?(text, "Cannot connect to the Docker daemon") or
      String.contains?(text, "docker: not found")
  end

  # -- Audit trail ------------------------------------------------------------------

  @doc "Recent audit entries for a server (newest first). Never raises."
  @spec list_audit(pos_integer(), pos_integer()) :: [map()]
  def list_audit(server_id, limit \\ 20) do
    import Ecto.Query, warn: false

    Marsad.AuditLog
    |> where([a], a.server_id == ^server_id)
    |> order_by([a], desc: a.inserted_at)
    |> limit(^limit)
    |> Marsad.Repo.all()
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @doc "Logs an audit entry (best-effort, never fails the caller)."
  @spec audit(pos_integer(), binary(), binary(), binary()) :: :ok
  def audit(server_id, action, container, details \\ "") do
    %Marsad.AuditLog{}
    |> Marsad.AuditLog.changeset(%{
      server_id: server_id,
      action: action,
      container: container,
      details: details
    })
    |> Marsad.Repo.insert()
    |> case do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        require Logger
        Logger.warning("audit insert failed: #{inspect(changeset.errors)}")
        :ok
    end
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError, Exqlite.Error] ->
      require Logger
      Logger.warning("audit insert failed: #{inspect(e)}")
      :ok
  end

  # -- systemd ----------------------------------------------------------------

  @doc "Lists all service units."
  @spec systemd_units(pos_integer()) :: {:ok, [unit()]} | {:error, term()}
  def systemd_units(server_id) do
    case Fleet.exec(server_id, "systemctl list-units --type=service --all --no-legend --no-pager") do
      {:ok, %{stdout: out, status: 0}} -> {:ok, parse_systemctl(out)}
      {:ok, %{stderr: err}} -> {:error, {:systemctl_failed, String.trim(err)}}
      {:error, _} = error -> error
    end
  end

  @doc "Starts/stops/restarts one unit."
  @spec systemd_action(pos_integer(), binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def systemd_action(server_id, action, unit) when action in ["start", "stop", "restart"] do
    with :ok <- validate_name(unit),
         {:ok, %{stdout: out, stderr: err, status: status}} <-
           Fleet.exec(server_id, "systemctl #{action} #{unit}") do
      if status == 0,
        do: {:ok, String.trim(out <> err)},
        else: {:error, {:action_failed, String.trim(out <> err)}}
    end
  end

  @doc "Kills a process by PID (validated, requires numeric PID)."
  @spec kill_process(pos_integer(), binary() | integer()) :: {:ok, binary()} | {:error, term()}
  def kill_process(server_id, pid) when is_integer(pid) do
    kill_process(server_id, to_string(pid))
  end

  def kill_process(server_id, pid) when is_binary(pid) do
    with {int_pid, ""} <- Integer.parse(String.trim(pid)),
         true <- int_pid > 0 and int_pid < 4_194_304,
         {:ok, %{stdout: out, stderr: err, status: 0}} <-
           Fleet.exec(server_id, "kill -9 #{int_pid} 2>&1") do
      {:ok, String.trim(out <> err)}
    else
      {:ok, %{stdout: out, stderr: err}} -> {:error, {:kill_failed, String.trim(out <> err)}}
      {:error, _} = err -> err
      _ -> {:error, :invalid_pid}
    end
  end

  @doc "Tails a unit's journal."
  @spec systemd_logs(pos_integer(), binary()) :: {:ok, binary()} | {:error, term()}
  def systemd_logs(server_id, unit) do
    with :ok <- validate_name(unit),
         {:ok, %{stdout: out, stderr: err}} <-
           Fleet.exec(server_id, "journalctl -u #{unit} -n 200 --no-pager 2>&1") do
      {:ok, out <> err}
    end
  end

  @doc "Fetches a unit's definition file via `systemctl cat`."
  @spec systemd_unit_file(pos_integer(), binary()) :: {:ok, binary()} | {:error, term()}
  def systemd_unit_file(server_id, unit) do
    with :ok <- validate_name(unit),
         {:ok, %{stdout: out, stderr: err}} <- Fleet.exec(server_id, "systemctl cat #{unit} 2>&1") do
      combined = String.trim(out <> err)

      if combined == "" or String.contains?(combined, "No files found") do
        case Fleet.exec(server_id, "systemctl show #{unit} -p FragmentPath 2>&1 | cut -d= -f2") do
          {:ok, %{stdout: frag}} ->
            path = String.trim(frag)

            if path != "" and path != "n/a" and not String.contains?(path, "not-found") do
              case Fleet.read_file(server_id, String.trim(path), 100_000) do
                {:ok, data} -> {:ok, data}
                {:error, _} -> {:error, {:not_found, combined}}
              end
            else
              {:error, {:not_found, combined}}
            end

          _ ->
            {:error, {:not_found, combined}}
        end
      else
        {:ok, combined}
      end
    end
  end

  @doc "Parses `systemctl list-units` legend-less output."
  @spec parse_systemctl(binary()) :: [unit()]
  def parse_systemctl(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, ~r/\s+/, parts: 5, trim: true) do
        [unit, load, active, sub, desc] ->
          [%{unit: unit, load: load, active: active, sub: sub, description: String.trim(desc)}]

        [unit, load, active, sub] ->
          [%{unit: unit, load: load, active: active, sub: sub, description: ""}]

        _ ->
          []
      end
    end)
  end

  # -- nginx ------------------------------------------------------------------

  @doc "nginx health: service state + config test."
  @spec nginx_status(pos_integer()) :: {:ok, map()} | {:error, term()}
  def nginx_status(server_id) do
    with {:ok, %{stdout: active}} <-
           Fleet.exec(server_id, "systemctl is-active nginx 2>&1 || echo unknown"),
         {:ok, %{stdout: out, stderr: err}} <- Fleet.exec(server_id, "nginx -t 2>&1") do
      combined = (out <> err) |> String.trim()

      combined =
        if combined == "",
          do:
            "nginx: not found — is nginx installed? Try: sudo apt update && sudo apt install -y nginx",
          else: combined

      active_trim = String.trim(active)

      active_norm =
        cond do
          active_trim in ["active", "inactive", "failed", "activating", "deactivating"] ->
            active_trim

          String.contains?(String.downcase(combined), "not found") ->
            "not-installed"

          active_trim == "unknown" ->
            "unknown"

          true ->
            active_trim
        end

      {:ok,
       %{
         active: active_norm,
         test_ok?: String.contains?(combined, "test is successful"),
         test_output: combined
       }}
    end
  end

  @doc "Reloads/restarts nginx, or re-runs the config test."
  @spec nginx_action(pos_integer(), binary()) :: {:ok, binary()} | {:error, term()}
  def nginx_action(server_id, "test") do
    case Fleet.exec(server_id, "nginx -t 2>&1") do
      {:ok, %{stdout: out, stderr: err}} -> {:ok, String.trim(out <> err)}
      {:error, _} = error -> error
    end
  end

  def nginx_action(server_id, action) when action in ["reload", "restart"] do
    case Fleet.exec(server_id, "systemctl #{action} nginx") do
      {:ok, %{stdout: out, stderr: err, status: 0}} -> {:ok, String.trim(out <> err)}
      {:ok, %{stdout: out, stderr: err}} -> {:error, {:action_failed, String.trim(out <> err)}}
      {:error, _} = error -> error
    end
  end

  @doc "Dumps the effective nginx config (capped)."
  @spec nginx_config(pos_integer()) :: {:ok, binary()} | {:error, term()}
  def nginx_config(server_id) do
    case Fleet.exec(server_id, "nginx -T 2>/dev/null | head -c 100000") do
      {:ok, %{stdout: out}} when byte_size(out) > 0 -> {:ok, out}
      {:ok, _} -> {:error, :empty_config}
      {:error, _} = error -> error
    end
  end

  @doc "Tails the nginx error log."
  @spec nginx_error_log(pos_integer()) :: {:ok, binary()} | {:error, term()}
  def nginx_error_log(server_id) do
    case Fleet.exec(server_id, "tail -n 100 /var/log/nginx/error.log 2>&1") do
      {:ok, %{stdout: out, stderr: err}} -> {:ok, out <> err}
      {:error, _} = error -> error
    end
  end

  @nginx_root "/etc/nginx"

  @doc "Lists nginx config files (path + size), confined under /etc/nginx."
  @spec nginx_files(pos_integer()) ::
          {:ok, [%{path: binary(), size: non_neg_integer()}]} | {:error, term()}
  def nginx_files(server_id) do
    case Fleet.exec(
           server_id,
           "find #{@nginx_root} -maxdepth 3 -type f -printf '%p|%s\\n' 2>/dev/null | sort | head -100"
         ) do
      {:ok, %{stdout: out}} -> {:ok, parse_nginx_files(out)}
      {:error, _} = error -> error
    end
  end

  @doc "Reads one nginx file (capped). The path must stay under /etc/nginx."
  @spec nginx_file(pos_integer(), binary()) :: {:ok, binary()} | {:error, term()}
  def nginx_file(server_id, path) do
    with {:ok, safe} <- nginx_file_path(path),
         {:ok, data} <- Fleet.read_file(server_id, safe, 100_000) do
      {:ok, data}
    end
  end

  @doc "Confines a requested path under /etc/nginx. Pure — unit tested."
  @spec nginx_file_path(binary()) :: {:ok, binary()} | {:error, :outside_nginx_root}
  def nginx_file_path(path) when is_binary(path) do
    clean = Fleet.remote_join("/", path)

    if clean == @nginx_root or String.starts_with?(clean, @nginx_root <> "/") do
      {:ok, clean}
    else
      {:error, :outside_nginx_root}
    end
  end

  def nginx_file_path(_), do: {:error, :outside_nginx_root}

  @doc "Parses `find -printf '%p|%s'` lines."
  @spec parse_nginx_files(binary()) :: [%{path: binary(), size: non_neg_integer()}]
  def parse_nginx_files(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "|") do
        [path, size] ->
          case Integer.parse(String.trim(size)) do
            {n, ""} when n >= 0 -> [%{path: String.trim(path), size: n}]
            _ -> []
          end

        _ ->
          []
      end
    end)
  end

  # -- Shared -----------------------------------------------------------------

  @doc "Strict allow-list for remote names interpolated into shell commands."
  @spec validate_name(binary()) :: :ok | {:error, :invalid_name}
  def validate_name(name) when is_binary(name) do
    if name != "" and Regex.match?(~r/\A[\w@:.+=,~-]+\z/, name),
      do: :ok,
      else: {:error, :invalid_name}
  end

  def validate_name(_), do: {:error, :invalid_name}
end
