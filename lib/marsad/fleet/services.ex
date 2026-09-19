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

  @systemd_types ~w(service timer socket)
  @systemd_actions ~w(start stop restart reload enable disable mask unmask reset-failed)
  @systemd_log_tails [50, 100, 200, 500, 1000]
  @systemd_log_priorities ~w(emerg alert crit err warning notice info debug)

  @doc "Unit types offered by the UI."
  def systemd_unit_types, do: @systemd_types

  @doc "Supported unit actions (unknown actions are rejected, never crash)."
  def systemd_actions, do: @systemd_actions

  @doc "Journal tail sizes offered by the UI."
  def systemd_log_tails, do: @systemd_log_tails

  @doc "Journal priority levels offered by the UI."
  def systemd_log_priorities, do: @systemd_log_priorities

  @doc "Lists units of one type (default `service`). Unknown types are rejected."
  @spec systemd_units(pos_integer()) :: {:ok, [unit()]} | {:error, term()}
  def systemd_units(server_id), do: systemd_units(server_id, "service")

  @spec systemd_units(pos_integer(), binary()) :: {:ok, [unit()]} | {:error, term()}
  def systemd_units(server_id, type) when type in @systemd_types do
    case Fleet.exec(
           server_id,
           "systemctl list-units --type=#{type} --all --no-legend --no-pager"
         ) do
      {:ok, %{stdout: out, status: 0}} -> {:ok, parse_systemctl(out)}
      {:ok, %{stderr: err}} -> {:error, {:systemctl_failed, String.trim(err)}}
      {:error, _} = error -> error
    end
  end

  def systemd_units(_server_id, _type), do: {:error, :invalid_type}

  @doc "Runs one unit action (`start`/`stop`/`restart`/`reload`/`enable`/...). Unknown actions are rejected, never crash."
  @spec systemd_action(pos_integer(), binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def systemd_action(server_id, action, unit) when action in @systemd_actions do
    with :ok <- validate_name(unit),
         {:ok, %{stdout: out, stderr: err, status: status}} <-
           Fleet.exec(server_id, "systemctl #{action} #{unit}") do
      if status == 0,
        do: {:ok, String.trim(out <> err)},
        else: {:error, {:action_failed, String.trim(out <> err)}}
    end
  end

  def systemd_action(_server_id, _action, _unit), do: {:error, :invalid_action}

  @doc "English past tense for unit actions (for flash messages)."
  @spec systemd_action_past(binary()) :: binary()
  def systemd_action_past("start"), do: "started"
  def systemd_action_past("stop"), do: "stopped"
  def systemd_action_past("restart"), do: "restarted"
  def systemd_action_past("reload"), do: "reloaded"
  def systemd_action_past("enable"), do: "enabled"
  def systemd_action_past("disable"), do: "disabled"
  def systemd_action_past("mask"), do: "masked"
  def systemd_action_past("unmask"), do: "unmasked"
  def systemd_action_past("reset-failed"), do: "reset"
  def systemd_action_past(action), do: "#{action}ed"

  @doc "Reloads the systemd manager configuration."
  @spec systemd_daemon_reload(pos_integer()) :: {:ok, binary()} | {:error, term()}
  def systemd_daemon_reload(server_id) do
    case Fleet.exec(server_id, "systemctl daemon-reload 2>&1") do
      {:ok, %{stdout: out, stderr: err, status: 0}} -> {:ok, String.trim(out <> err)}
      {:ok, %{stdout: out, stderr: err}} -> {:error, {:reload_failed, String.trim(out <> err)}}
      {:error, _} = error -> error
    end
  end

  @doc "Resets all failed units (`systemctl reset-failed` without arguments)."
  @spec systemd_reset_failed(pos_integer()) :: {:ok, binary()} | {:error, term()}
  def systemd_reset_failed(server_id) do
    case Fleet.exec(server_id, "systemctl reset-failed 2>&1") do
      {:ok, %{stdout: out, stderr: err, status: 0}} ->
        {:ok, String.trim(out <> err)}

      {:ok, %{stdout: out, stderr: err}} ->
        {:error, {:reset_failed_failed, String.trim(out <> err)}}

      {:error, _} = error ->
        error
    end
  end

  @doc "Resolves a unit's fragment path via `systemctl show` (validated, never interpolates raw input)."
  @spec systemd_fragment_path(pos_integer(), binary()) :: {:ok, binary()} | {:error, term()}
  def systemd_fragment_path(server_id, unit) do
    with :ok <- validate_name(unit),
         {:ok, %{stdout: out}} <-
           Fleet.exec(server_id, "systemctl show #{unit} -p FragmentPath 2>&1 | cut -d= -f2") do
      path =
        out |> String.trim() |> String.split("\n", trim: true) |> List.first("") |> String.trim()

      if path == "" or path == "n/a" or String.contains?(path, "not-found") do
        {:error, :not_found}
      else
        {:ok, path}
      end
    end
  end

  @doc "Fetches live `systemctl show` properties for one unit."
  @spec systemd_status(pos_integer(), binary()) :: {:ok, map()} | {:error, term()}
  def systemd_status(server_id, unit) do
    with :ok <- validate_name(unit),
         {:ok, %{stdout: out}} <-
           Fleet.exec(
             server_id,
             "systemctl show #{unit} -p Id,LoadState,ActiveState,SubState,UnitFileState,MainPID,MemoryCurrent,CPUUsageNSec,ActiveEnterTimestamp,ExecMainStatus,NRestarts 2>&1"
           ) do
      {:ok, parse_systemctl_show(out)}
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

  @doc """
  Tails a unit's journal (stdout + stderr merged), capped at 200KB.

  Options: `tail:` (one of 50/100/200/500/1000, default 200),
  `priority:` (one of emerg/alert/crit/err/warning/notice/info/debug, default nil).
  Forged values fall back to defaults instead of crashing.
  """
  @spec systemd_logs(pos_integer(), binary()) :: {:ok, binary()} | {:error, term()}
  def systemd_logs(server_id, unit), do: systemd_logs(server_id, unit, [])

  @spec systemd_logs(pos_integer(), binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def systemd_logs(server_id, unit, opts) do
    tail = Keyword.get(opts, :tail, 200)
    tail = if tail in @systemd_log_tails, do: tail, else: 200

    priority = Keyword.get(opts, :priority)
    priority = if priority in @systemd_log_priorities, do: priority, else: nil

    prio_flag = if priority, do: " -p #{priority}", else: ""

    with :ok <- validate_name(unit),
         {:ok, %{stdout: out, stderr: err}} <-
           Fleet.exec(
             server_id,
             "journalctl -u #{unit}#{prio_flag} -n #{tail} --no-pager 2>&1 | head -c 200000"
           ) do
      {:ok, out <> err}
    end
  end

  @doc """
  Full journal download (newest bytes win): streams `journalctl` through
  `tail -c` so the transfer never exceeds #{div(@max_log_download, 1_000_000)}MB.
  Binary-safe. Respects `priority:` when given.
  """
  @spec systemd_logs_download(pos_integer(), binary(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def systemd_logs_download(server_id, unit, opts \\ []) do
    priority = Keyword.get(opts, :priority)
    priority = if priority in @systemd_log_priorities, do: priority, else: nil
    prio_flag = if priority, do: " -p #{priority}", else: ""

    with :ok <- validate_name(unit),
         {:ok, %{stdout: out, stderr: err}} <-
           Fleet.exec(
             server_id,
             "journalctl -u #{unit}#{prio_flag} --no-pager 2>&1 | tail -c #{@max_log_download}"
           ) do
      {:ok, out <> err}
    end
  end

  @systemd_root "/etc/systemd/system"

  @doc "Confines a systemd unit path under #{@systemd_root}. Pure — unit tested."
  @spec systemd_unit_path(binary()) :: {:ok, binary()} | {:error, term()}
  def systemd_unit_path(name) when is_binary(name) do
    with :ok <- validate_name(name),
         true <- String.contains?(name, ".") do
      clean = Fleet.remote_join(@systemd_root, name)

      if clean == @systemd_root or String.starts_with?(clean, @systemd_root <> "/") do
        {:ok, clean}
      else
        {:error, :outside_systemd_root}
      end
    else
      {:error, :invalid_name} = err -> err
      false -> {:error, :invalid_name}
    end
  end

  def systemd_unit_path(_), do: {:error, :invalid_name}

  @doc "Creates a new unit file under #{@systemd_root} and reloads the daemon. The name must be a valid unit name (e.g. `myapp.service`)."
  @spec systemd_create_unit(pos_integer(), binary(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def systemd_create_unit(server_id, name, content) when is_binary(content) do
    with {:ok, path} <- systemd_unit_path(name),
         :ok <- validate_unit_content(content),
         :ok <- write_result(Fleet.write_file(server_id, path, content)),
         {:ok, _} <- systemd_daemon_reload(server_id) do
      {:ok, path}
    end
  end

  def systemd_create_unit(_server_id, _name, _content), do: {:error, :invalid_content}

  defp validate_unit_content(content) do
    cond do
      not is_binary(content) -> {:error, :invalid_content}
      byte_size(content) == 0 -> {:error, :empty_content}
      byte_size(content) > 200_000 -> {:error, :too_large}
      true -> :ok
    end
  end

  defp write_result(:ok), do: :ok
  defp write_result({:ok, _} = ok), do: ok |> elem(0) |> then(fn _ -> :ok end)
  defp write_result({:error, _} = err), do: err
  defp write_result(other), do: {:error, other}

  @doc """
  Fetches a unit's definition file via `systemctl cat` plus its fragment
  path in one call, so callers never run a second (unvalidated) SSH lookup.
  Returns `%{text:, path:}`.
  """
  @spec systemd_unit_file(pos_integer(), binary()) ::
          {:ok, %{text: binary(), path: binary()}} | {:error, term()}
  def systemd_unit_file(server_id, unit) do
    with :ok <- validate_name(unit),
         {:ok, %{stdout: out, stderr: err}} <- Fleet.exec(server_id, "systemctl cat #{unit} 2>&1") do
      combined = String.trim(out <> err)

      if combined == "" or String.contains?(combined, "No files found") do
        case systemd_fragment_path(server_id, unit) do
          {:ok, path} ->
            case Fleet.read_file(server_id, path, 100_000) do
              {:ok, data} -> {:ok, %{text: data, path: path}}
              {:error, _} -> {:error, {:not_found, combined}}
            end

          {:error, _} ->
            {:error, {:not_found, combined}}
        end
      else
        path =
          case systemd_fragment_path(server_id, unit) do
            {:ok, p} -> p
            {:error, _} -> unit
          end

        {:ok, %{text: combined, path: path}}
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

  @doc "Parses `systemctl show` `Key=Value` output into a string map."
  @spec parse_systemctl_show(binary()) :: %{optional(binary()) => binary()}
  def parse_systemctl_show(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [key, value] when key != "" -> Map.put(acc, String.trim(key), String.trim(value))
        _ -> acc
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

  # -- SSL certificates ---------------------------------------------------------------

  @cert_warn_days 30
  @cert_critical_days 14

  @type cert_check :: %{
          domain: binary(),
          port: pos_integer(),
          wildcard?: boolean(),
          expires_at: DateTime.t() | nil,
          days_left: integer() | nil,
          status: :ok | :warning | :critical | :unknown,
          note: binary()
        }

  @doc """
  Checks TLS certificate expiry for every HTTPS vhost (2 SSH calls:
  config dump, then one `openssl` loop). Never raises.
  """
  @spec cert_check(pos_integer()) :: {:ok, [cert_check()]} | {:error, term()}
  def cert_check(server_id) do
    with {:ok, dump} <- nginx_config(server_id),
         [_ | _] = vhosts <- parse_nginx_vhosts(dump),
         [_ | _] = targets <- vhost_targets(vhosts),
         {:ok, %{stdout: out}} <- Fleet.exec(server_id, cert_check_command(targets)) do
      {:ok, parse_cert_results(out, targets)}
    else
      [] -> {:ok, []}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :check_failed}
  catch
    _, _ -> {:error, :check_failed}
  end

  @doc "Warning/critical day thresholds for certificate expiry."
  def cert_thresholds, do: %{warning: @cert_warn_days, critical: @cert_critical_days}

  @doc """
  Extracts HTTPS vhosts (`%{domains: [...], port: n}`) from an `nginx -T`
  dump. Pure — unit tested.
  """
  @spec parse_nginx_vhosts(binary()) :: [%{domains: [binary()], port: pos_integer()}]
  def parse_nginx_vhosts(dump) when is_binary(dump) do
    dump
    |> String.split("\n")
    |> Enum.reduce({[], []}, &vhost_line/2)
    |> then(fn {done, stack} -> Enum.reverse(done) ++ flush_stack(stack) end)
    |> Enum.filter(&(&1.domains != []))
    |> Enum.map(fn v -> %{domains: Enum.uniq(v.domains), port: v.port} end)
  end

  def parse_nginx_vhosts(_), do: []

  # Stack frames: {:server, vhost} | :other. Depth is implicit in the stack.
  defp vhost_line(line, {done, stack}) do
    code = line |> String.split("#", parts: 2) |> hd() |> String.trim()

    cond do
      code == "" ->
        {done, stack}

      # `server {` opens a vhost frame (only at http level, but tracking
      # depth via the stack makes nesting safe anywhere).
      Regex.match?(~r/\Aserver\s*\{\s*\z/, code) ->
        {done, [{:server, %{domains: [], port: 80, ssl?: false}} | stack]}

      String.ends_with?(code, "{") ->
        {done, [:other | stack]}

      code == "}" ->
        case stack do
          [{:server, v} | rest] -> {maybe_ssl_vhost(done, v), rest}
          [_ | rest] -> {done, rest}
          [] -> {done, []}
        end

      true ->
        {done, vhost_directive(stack, code)}
    end
  end

  defp flush_stack(stack) do
    stack
    |> Enum.flat_map(fn
      {:server, v} -> [v]
      _ -> []
    end)
  end

  defp maybe_ssl_vhost(done, %{ssl?: true} = v), do: [Map.delete(v, :ssl?) | done]
  defp maybe_ssl_vhost(done, _), do: done

  # Directives inside nested blocks (location/if) must not leak into the vhost.
  defp vhost_directive([:other | _] = stack, _code), do: stack

  defp vhost_directive([{:server, v} | rest], code) do
    [{:server, apply_server_directive(v, code)} | rest]
  end

  defp vhost_directive(stack, _code), do: stack

  defp apply_server_directive(v, code) do
    cond do
      String.starts_with?(code, "server_name ") ->
        names =
          code
          |> String.trim_trailing(";")
          |> String.split(~r/\s+/, trim: true)
          |> Enum.drop(1)
          |> Enum.map(&unquote_name/1)
          |> Enum.reject(&(&1 in ["", "_"]))

        %{v | domains: v.domains ++ names}

      String.starts_with?(code, "listen ") ->
        %{v | port: listen_port(code, v.port), ssl?: v.ssl? or listen_ssl?(code)}

      String.starts_with?(code, "ssl_certificate ") ->
        %{v | ssl?: true}

      true ->
        v
    end
  end

  defp unquote_name(name) do
    if String.length(name) >= 2 and String.starts_with?(name, ["\"", "'"]) and
         String.ends_with?(name, ["\"", "'"]) do
      String.slice(name, 1..-2//1)
    else
      name
    end
  end

  defp listen_port(code, default) do
    # Last `host:port` or bare port wins (`listen [::]:8443 ssl`).
    ports =
      Regex.scan(~r/(\d+)(?=\s|;|$)/, code)
      |> Enum.map(fn [_, p] -> String.to_integer(p) end)
      |> Enum.reject(&(&1 > 65_535))

    List.last(ports) || default
  end

  defp listen_ssl?(code), do: Regex.match?(~r/(^|\s)ssl(\s|;|$)/, code)

  @doc "Flattens vhosts to unique `{check_domain, port, wildcard?}` targets. Pure."
  @spec vhost_targets([map()]) :: [{binary(), pos_integer(), boolean()}]
  def vhost_targets(vhosts) do
    vhosts
    |> Enum.flat_map(fn v ->
      Enum.map(v.domains, fn d ->
        if String.starts_with?(d, "*.") do
          {"www." <> String.slice(d, 2..-1//1), v.port, true}
        else
          {d, v.port, false}
        end
      end)
    end)
    |> Enum.uniq()
  end

  @doc "Builds the single remote `openssl` loop for the targets. Pure — unit tested."
  @spec cert_check_command([{binary(), pos_integer(), boolean()}]) :: binary()
  def cert_check_command(targets) do
    checks =
      targets
      |> Enum.map(fn {domain, port, _wild} ->
        "chk #{Marsad.Helpers.Text.shell_quote(domain)} #{port}"
      end)
      |> Enum.join("\n")

    """
    command -v openssl >/dev/null 2>&1 || { echo "__MARSAD_NO_OPENSSL__"; exit 0; }
    if command -v timeout >/dev/null 2>&1; then TO="timeout 10"; else TO=""; fi
    chk() { d="$1"; p="$2"; e=$(echo | $TO openssl s_client -connect "127.0.0.1:$p" -servername "$d" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null); echo "$d|$p|${e#notAfter=}"; }
    #{checks}
    """
  end

  @doc "Parses loop output lines into checks (with thresholds applied). Pure."
  @spec parse_cert_results(binary(), [{binary(), pos_integer(), boolean()}]) :: [cert_check()]
  def parse_cert_results(out, targets) do
    if String.contains?(out, "__MARSAD_NO_OPENSSL__") do
      []
    else
      by_key =
        out
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&parse_cert_line/1)
        |> Map.new(fn {domain, port, date} -> {{domain, port}, date} end)

      Enum.map(targets, fn {domain, port, wild} ->
        build_cert_check(domain, port, wild, Map.get(by_key, {domain, port}))
      end)
    end
  end

  defp parse_cert_line(line) do
    case String.split(line, "|", parts: 3) do
      [domain, port_s, date] ->
        with {port, ""} <- Integer.parse(String.trim(port_s)),
             true <- domain != "" do
          [{String.trim(domain), port, String.trim(date)}]
        else
          _ -> []
        end

      _ ->
        []
    end
  end

  defp build_cert_check(domain, port, wild, date_str) do
    base = %{domain: domain, port: port, wildcard?: wild, expires_at: nil, days_left: nil}

    case parse_cert_date(date_str || "") do
      {:ok, expires} ->
        days = DateTime.diff(expires, DateTime.utc_now(), :second) |> div(86_400)
        {status, note} = cert_status(days)

        Map.merge(base, %{expires_at: expires, days_left: days, status: status, note: note})

      :error ->
        Map.merge(base, %{status: :unknown, note: "check failed"})
    end
  end

  defp cert_status(days) when days < 0, do: {:critical, "expired"}
  defp cert_status(days) when days <= @cert_critical_days, do: {:critical, "expires in #{days}d"}
  defp cert_status(days) when days <= @cert_warn_days, do: {:warning, "expires in #{days}d"}
  defp cert_status(days), do: {:ok, "expires in #{days}d"}

  @months %{
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
  }

  @doc "Parses `openssl x509 -enddate` output (`Nov  3 12:00:00 2026 GMT`). Pure."
  @spec parse_cert_date(binary()) :: {:ok, DateTime.t()} | :error
  def parse_cert_date(date) when is_binary(date) do
    case Regex.run(~r/\A(\w{3})\s+(\d{1,2}) (\d{2}):(\d{2}):(\d{2}) (\d{4})/, String.trim(date)) do
      [_, mon, day, hh, mm, ss, year] ->
        with month when not is_nil(month) <- Map.get(@months, mon),
             {:ok, d} <- Date.new(String.to_integer(year), month, String.to_integer(day)),
             {:ok, t} <-
               Time.new(String.to_integer(hh), String.to_integer(mm), String.to_integer(ss)),
             {:ok, dt} <- DateTime.new(d, t, "Etc/UTC") do
          {:ok, dt}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def parse_cert_date(_), do: :error

  # -- Certificate renewal --------------------------------------------------------------

  @type renew_result :: %{renewed?: boolean(), reloaded?: boolean(), output: binary()}

  @doc """
  Renews one domain's certificate via certbot, then reloads nginx.

  Steps: locate the certbot lineage covering `domain`, run
  `certbot renew --cert-name <lineage>` (never `--force`; a not-due cert
  is reported honestly, not faked), and on success run
  `nginx -t && systemctl reload nginx` so the new cert is served.

  `on_step` receives `:locate | :renew | :reload` as the work progresses
  (used for live progress UI). Never raises.
  """
  @spec cert_renew(pos_integer(), binary(), (atom() -> any())) ::
          {:ok, renew_result()} | {:error, term()}
  def cert_renew(server_id, domain, on_step \\ fn _step -> :ok end) do
    with {:ok, lineages} <- certbot_lineages(server_id, on_step),
         {:ok, lineage} <- find_lineage(lineages, domain),
         {:ok, result} <- run_renew(server_id, lineage, on_step) do
      {:ok, result}
    end
  rescue
    _ -> {:error, :renew_failed}
  catch
    _, _ -> {:error, :renew_failed}
  end

  defp certbot_lineages(server_id, on_step) do
    on_step.(:locate)

    case Fleet.exec(server_id, "certbot certificates 2>&1") do
      {:ok, %{stdout: out, stderr: err}} ->
        combined = out <> err

        cond do
          String.contains?(combined, "command not found") or
              String.contains?(combined, "certbot: not found") ->
            {:error, :certbot_missing}

          true ->
            {:ok, parse_certbot_certificates(combined)}
        end

      {:error, _} = error ->
        error
    end
  end

  defp find_lineage(lineages, domain) do
    want = String.downcase(String.trim(domain))

    case Enum.find(lineages, fn l -> Enum.any?(l.domains, &(String.downcase(&1) == want)) end) do
      %{name: name} ->
        case validate_name(name) do
          :ok -> {:ok, name}
          _ -> {:error, :invalid_lineage}
        end

      nil ->
        {:error, :no_lineage}
    end
  end

  defp run_renew(server_id, lineage, on_step) do
    on_step.(:renew)
    quoted = Marsad.Helpers.Text.shell_quote(lineage)

    with {:ok, %{stdout: out, stderr: err, status: status}} <-
           Fleet.exec(server_id, "certbot renew --cert-name #{quoted} 2>&1") do
      output = truncate_output(out <> err)

      cond do
        status not in [0, nil] ->
          {:error, {:renew_failed, output}}

        String.contains?(String.downcase(output), "not due for renewal") ->
          {:ok, %{renewed?: false, reloaded?: false, output: output}}

        String.contains?(String.downcase(output), "keeping the existing") ->
          {:ok, %{renewed?: false, reloaded?: false, output: output}}

        String.contains?(String.downcase(output), "congratulations") or
            String.contains?(String.downcase(output), "success") ->
          reload_after_renew(server_id, output, on_step)

        true ->
          # Unrecognized but clean exit — treat as renewed; the UI re-check
          # verifies ground truth afterwards.
          reload_after_renew(server_id, output, on_step)
      end
    end
  end

  defp reload_after_renew(server_id, output, on_step) do
    on_step.(:reload)

    case Fleet.exec(
           server_id,
           "nginx -t 2>&1 && sudo systemctl reload nginx 2>&1 || systemctl reload nginx 2>&1"
         ) do
      {:ok, %{stdout: out, stderr: err, status: status}} when status in [0, nil] ->
        {:ok,
         %{renewed?: true, reloaded?: true, output: output <> "\n" <> String.trim(out <> err)}}

      {:ok, %{stdout: out, stderr: err}} ->
        {:ok,
         %{
           renewed?: true,
           reloaded?: false,
           output: output <> "\nRELOAD FAILED:\n" <> String.trim(out <> err)
         }}

      {:error, reason} ->
        {:ok,
         %{
           renewed?: true,
           reloaded?: false,
           output: output <> "\nRELOAD FAILED: #{inspect(reason)}"
         }}
    end
  end

  defp truncate_output(text, max \\ 10_000) do
    if byte_size(text) > max, do: binary_part(text, 0, max) <> "\n…[truncated]", else: text
  end

  @doc """
  Parses `certbot certificates` into `[%{name:, domains: [...]}]`. Pure.
  """
  @spec parse_certbot_certificates(binary()) :: [%{name: binary(), domains: [binary()]}]
  def parse_certbot_certificates(out) when is_binary(out) do
    out
    |> String.split("\n")
    |> Enum.reduce({[], nil}, fn line, {done, current} ->
      cond do
        # A new block starts: flush any previous (complete or not).
        (m = Regex.run(~r/^\s*Certificate Name:\s*(.+?)\s*$/, line)) != nil ->
          [_, name] = m
          flushed = if is_nil(current), do: done, else: done ++ [current]
          {flushed, %{name: String.trim(name), domains: []}}

        (m = Regex.run(~r/^\s*Domains:\s*(.+?)\s*$/, line)) != nil and not is_nil(current) ->
          [_, domains] = m
          {done, %{current | domains: String.split(domains, ~r/\s+/, trim: true)}}

        # Dash separators / blanks end a block.
        Regex.match?(~r/^\s*(-\s+)+-\s*$/, line) or String.trim(line) == "" ->
          if is_nil(current), do: {done, nil}, else: {done ++ [current], nil}

        true ->
          {done, current}
      end
    end)
    |> then(fn {done, current} -> if is_nil(current), do: done, else: done ++ [current] end)
    |> Enum.filter(&(&1.name != "" and &1.domains != []))
  end

  def parse_certbot_certificates(_), do: []

  @doc "Summarizes checks for header pills. Pure."
  @spec cert_summary([cert_check()]) :: %{
          total: integer(),
          critical: integer(),
          warning: integer(),
          unknown: integer()
        }
  def cert_summary(certs) do
    %{
      total: length(certs),
      critical: Enum.count(certs, &(&1.status == :critical)),
      warning: Enum.count(certs, &(&1.status == :warning)),
      unknown: Enum.count(certs, &(&1.status == :unknown))
    }
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
