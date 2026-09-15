defmodule Marsad.Fleet.SysInfo do
  @moduledoc """
  Server health snapshots collected over SSH with standard Linux tools.

  All parsing is pure (and unit-tested); `fetch/1` composes the remote calls.
  """

  alias Marsad.Fleet

  @type snapshot :: %{
          load1: float(),
          load5: float(),
          load15: float(),
          cores: pos_integer(),
          cores_raw: binary() | nil,
          mem_total_mb: non_neg_integer(),
          mem_used_mb: non_neg_integer(),
          disk_total_mb: non_neg_integer(),
          disk_used_mb: non_neg_integer(),
          disk_pct: 0..100,
          disks: [map()] | nil,
          net_rx_mb: float() | nil,
          net_tx_mb: float() | nil,
          uptime: binary(),
          hostname: binary(),
          kernel: binary(),
          taken_at: DateTime.t()
        }

  @doc "Fetches one snapshot. Returns `{:ok, snapshot}` or `{:error, reason}`."
  @spec fetch(pos_integer()) :: {:ok, snapshot()} | {:error, term()}
  def fetch(server_id) do
    with {:ok, %{stdout: load}} <- Fleet.exec(server_id, "cat /proc/loadavg"),
         {:ok, %{stdout: cores}} <-
           Fleet.exec(
             server_id,
             # Run ALL sources in one shell and let parse_cores pick the max.
             # Covers cgroup-limited nproc (3) vs real cpuinfo/lscpu/sysfs (4).
             "nproc --all 2>/dev/null; nproc 2>/dev/null; grep -c '^processor' /proc/cpuinfo 2>/dev/null; grep -c processor /proc/cpuinfo 2>/dev/null; getconf _NPROCESSORS_ONLN 2>/dev/null; getconf _NPROCESSORS_CONF 2>/dev/null; lscpu 2>/dev/null | awk '/^CPU\\(s\\):/ {print $2}'; lscpu -p 2>/dev/null | grep -v '^#' | wc -l 2>/dev/null; ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | wc -l; cat /proc/stat 2>/dev/null | grep -c \"^cpu[0-9]\"; echo 1"
           ),
         {:ok, %{stdout: mem}} <- Fleet.exec(server_id, "free -m"),
         {:ok, %{stdout: disk_all}} <- Fleet.exec(server_id, "df -m 2>/dev/null | head -20"),
         {:ok, %{stdout: disk}} <- Fleet.exec(server_id, "df -m /"),
         {:ok, %{stdout: net}} <-
           Fleet.exec(server_id, "cat /proc/net/dev 2>/dev/null || echo ''"),
         {:ok, %{stdout: misc}} <- Fleet.exec(server_id, "uptime -p; hostname; uname -r"),
         {:ok, parsed} <- parse(load, cores, mem, disk, misc) do
      disks = parse_disks(disk_all)
      net_stats = parse_net(net)

      {:ok,
       parsed
       |> Map.put(:taken_at, DateTime.utc_now())
       |> Map.put(:cores_raw, String.trim(cores))
       |> Map.put(:disks, disks)
       |> Map.put(:net_rx_mb, net_stats.rx_mb)
       |> Map.put(:net_tx_mb, net_stats.tx_mb)}
    end
  end

  @doc "Parses the five command outputs. Pure — safe to unit test."
  @spec parse(binary(), binary(), binary(), binary(), binary()) ::
          {:ok, map()} | {:error, :unparseable}
  def parse(load_out, cores_out, mem_out, disk_out, misc_out) do
    with [l1, l5, l15] <- parse_load(load_out),
         cores <- parse_cores(cores_out),
         [mt, mu] <- parse_mem(mem_out),
         [dt, du, pct] <- parse_disk(disk_out),
         [uptime, hostname, kernel] <- parse_misc(misc_out) do
      {:ok,
       %{
         load1: l1,
         load5: l5,
         load15: l15,
         cores: cores,
         cores_raw: String.trim(cores_out),
         mem_total_mb: mt,
         mem_used_mb: mu,
         disk_total_mb: dt,
         disk_used_mb: du,
         disk_pct: pct,
         uptime: uptime,
         hostname: hostname,
         kernel: kernel
       }}
    else
      _ -> {:error, :unparseable}
    end
  end

  defp parse_load(out) do
    case String.split(out) do
      [l1, l5, l15 | _] ->
        with {f1, ""} <- Float.parse(l1),
             {f5, ""} <- Float.parse(l5),
             {f15, ""} <- Float.parse(l15) do
          [f1, f5, f15]
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  # Cores come from their own command; unknown → 1 (never a stray PID).
  # Robust: extracts all integers from the output and picks the largest
  # plausible value, so "4\n", " 4 \n", "4\n4\n" and "nproc: missing\n4" all → 4.
  # Uses max to prefer --all (installed) over affinity-limited nproc.
  # Cap at 8192 to filter stray PIDs while allowing large servers.
  defp parse_cores(out) do
    nums =
      out
      |> String.split(~r/[^0-9]+/, trim: true)
      |> Enum.flat_map(fn s ->
        case Integer.parse(s) do
          {n, ""} when n >= 1 and n <= 8192 -> [n]
          _ -> []
        end
      end)

    case nums do
      [] -> 1
      list -> Enum.max(list)
    end
  end

  defp parse_mem(out) do
    row = out |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "Mem:"))

    case row && String.split(row) do
      ["Mem:", total, used | _] ->
        with {t, ""} <- Integer.parse(total),
             {u, ""} <- Integer.parse(used) do
          [t, u]
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_disk(out) do
    row = out |> String.split("\n", trim: true) |> Enum.at(1)

    case row && String.split(row) do
      [_fs, total, used, _avail, pct | _] ->
        with {t, ""} <- Integer.parse(total),
             {u, ""} <- Integer.parse(used),
             {p, "%"} <- pct |> String.trim() |> Integer.parse() do
          [t, u, min(max(p, 0), 100)]
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_misc(out) do
    case String.split(out, "\n", trim: true) do
      [uptime, hostname, kernel | _] ->
        [String.trim(uptime), String.trim(hostname), String.trim(kernel)]

      [uptime, hostname] ->
        [String.trim(uptime), String.trim(hostname), ""]

      _ ->
        :error
    end
  end

  @type proc :: %{pid: pos_integer(), comm: binary(), cpu: float(), mem: float()}

  @doc "Fetches top processes (ps without --sort for busybox compat). Returns up to `limit` entries."
  @spec top_processes(pos_integer(), pos_integer()) :: {:ok, [proc()]} | {:error, term()}
  def top_processes(server_id, limit \\ 80) do
    cmd =
      "ps -eo pid,comm,pcpu,pmem --no-headers 2>/dev/null || ps -eo pid,comm,pcpu,pmem 2>/dev/null | tail -n +2 | head -n 200"

    case Fleet.exec(server_id, cmd) do
      {:ok, %{stdout: out}} -> {:ok, out |> parse_ps() |> Enum.take(limit)}
      {:error, _} = err -> err
    end
  end

  @doc "Parses `ps -eo pid,comm,pcpu,pmem` output. Pure — skips header, tolerant to busybox."
  @spec parse_ps(binary()) :: [proc()]
  def parse_ps(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reject(&Regex.match?(~r/^\s*PID/i, &1))
    |> Enum.flat_map(fn line ->
      case String.split(String.trim(line), ~r/\s+/, parts: 4, trim: true) do
        [pid_s, comm, cpu_s, mem_s] ->
          with {pid, ""} <- Integer.parse(pid_s),
               {cpu, ""} <- parse_float(cpu_s),
               {mem, ""} <- parse_float(mem_s) do
            [%{pid: pid, comm: comm, cpu: cpu, mem: mem}]
          else
            _ -> []
          end

        _ ->
          []
      end
    end)
  end

  defp parse_float(s) do
    case Float.parse(s) do
      {f, ""} ->
        {f, ""}

      _ ->
        case Integer.parse(s) do
          {i, ""} -> {i * 1.0, ""}
          _ -> :error
        end
    end
  end

  @doc "Sorts a proc list by field and order. Pure."
  @spec sort_procs([proc()], atom(), :asc | :desc) :: [proc()]
  def sort_procs(procs, field, order)
      when field in [:cpu, :mem, :pid, :comm] and order in [:asc, :desc] do
    sorted = Enum.sort_by(procs, &Map.get(&1, field))

    case order do
      :asc -> sorted
      :desc -> Enum.reverse(sorted)
    end
  end

  @doc "Parses `df -m` for all mounts (skip tmpfs). Returns list of %{fs, total, used, pct, mount}."
  @spec parse_disks(binary()) :: [
          %{fs: binary(), total: integer(), used: integer(), pct: integer(), mount: binary()}
        ]
  def parse_disks(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.flat_map(fn line ->
      case String.split(line) do
        [fs, total, used, _avail, pct, mount | _] ->
          with {t, ""} <- Integer.parse(total),
               {u, ""} <- Integer.parse(used),
               {p, "%"} <- pct |> String.trim() |> Integer.parse() do
            if String.starts_with?(fs, "/dev/") or mount in ["/", "/home", "/data"] do
              [%{fs: fs, total: t, used: u, pct: min(max(p, 0), 100), mount: mount}]
            else
              []
            end
          else
            _ -> []
          end

        _ ->
          []
      end
    end)
  end

  @doc "Parses `cat /proc/net/dev` for RX/TX MB."
  @spec parse_net(binary()) :: %{rx_mb: float(), tx_mb: float()}
  def parse_net(out) do
    lines = String.split(out, "\n", trim: true) |> Enum.drop(2)

    {rx, tx} =
      Enum.reduce(lines, {0, 0}, fn line, {acc_rx, acc_tx} ->
        case String.split(String.trim(line), ~r/\s+/) do
          [_iface, rx_bytes, _, _, _, _, _, _, _, tx_bytes | _] ->
            with {r, ""} <- Integer.parse(rx_bytes),
                 {t, ""} <- Integer.parse(tx_bytes) do
              {acc_rx + r, acc_tx + t}
            else
              _ -> {acc_rx, acc_tx}
            end

          _ ->
            {acc_rx, acc_tx}
        end
      end)

    %{rx_mb: Float.round(rx / 1_048_576, 1), tx_mb: Float.round(tx / 1_048_576, 1)}
  end

  @doc "0.0–1.0+ load relative to core count (for bars)."
  @spec load_ratio(snapshot()) :: float()
  def load_ratio(%{load1: l1, cores: cores}), do: l1 / max(cores, 1)

  @doc "0–100 memory usage percent."
  @spec mem_pct(snapshot()) :: 0..100
  def mem_pct(%{mem_total_mb: 0}), do: 0
  def mem_pct(%{mem_total_mb: t, mem_used_mb: u}), do: round(u / t * 100)

  @doc "Human MiB/GiB formatting."
  @spec format_mb(non_neg_integer()) :: binary()
  def format_mb(mb) when mb >= 1024, do: "#{Float.round(mb / 1024, 1)} GiB"
  def format_mb(mb), do: "#{mb} MiB"
end
