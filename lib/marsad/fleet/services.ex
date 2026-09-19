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

  @doc "Starts/stops/restarts one container."
  @spec docker_action(pos_integer(), binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def docker_action(server_id, action, name)
      when action in ["start", "stop", "restart"] do
    with :ok <- validate_name(name),
         {:ok, %{stdout: out, stderr: err}} <- Fleet.exec(server_id, "docker #{action} #{name}") do
      if docker_unavailable?(out <> err),
        do: {:error, :docker_unavailable},
        else: {:ok, String.trim(out <> err)}
    end
  end

  @doc "Tails container logs (stdout + stderr merged)."
  @spec docker_logs(pos_integer(), binary()) :: {:ok, binary()} | {:error, term()}
  def docker_logs(server_id, name) do
    with :ok <- validate_name(name),
         {:ok, %{stdout: out, stderr: err}} <-
           Fleet.exec(server_id, "docker logs --tail 200 #{name} 2>&1") do
      {:ok, out <> err}
    end
  end

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
