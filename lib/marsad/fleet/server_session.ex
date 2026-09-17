defmodule Marsad.Fleet.ServerSession do
  @moduledoc """
  One GenServer per managed server, holding its SSH connection.

  Registered in `Marsad.Fleet.Registry`, supervised by
  `Marsad.Fleet.DynamicSupervisor`. Started lazily on first use via
  `Marsad.Fleet.ensure_session/1`, receiving the `%Server{}` struct so the
  session never needs Repo access itself (and stale credentials die with it —
  `Fleet` stops the session whenever a server is updated or deleted).
  """
  use GenServer

  require Logger

  alias Marsad.Fleet
  alias Marsad.SSH.SshAdapter

  @exec_timeout 30_000
  @sftp_timeout 45_000

  def start_link(%Fleet.Server{id: id} = server) do
    GenServer.start_link(__MODULE__, server, name: via(id))
  end

  def via(server_id), do: {:via, Registry, {Marsad.Fleet.Registry, server_id}}

  @doc "Runs a command on the server, connecting first if needed."
  def exec(server_id, command, timeout \\ @exec_timeout) do
    GenServer.call(via(server_id), {:exec, command, timeout}, timeout + 15_000)
  end

  @doc "Runs `fun` with an SFTP channel, connecting first if needed."
  def sftp(server_id, fun) when is_function(fun, 1) do
    GenServer.call(via(server_id), {:sftp, fun}, @sftp_timeout + 10_000)
  end

  @doc "Current connection state without touching the network."
  def status(server_id) do
    case Registry.lookup(Marsad.Fleet.Registry, server_id) do
      [{pid, _}] -> GenServer.call(pid, :status)
      [] -> %{connected?: false}
    end
  end

  @impl true
  def init(%Fleet.Server{} = server) do
    {:ok, %{server: server, conn: nil, fingerprint: nil, failures: 0}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{connected?: state.conn != nil, fingerprint: state.fingerprint}, state}
  end

  def handle_call({:exec, command, timeout}, _from, %{conn: nil} = state) do
    case connect(state) do
      {:ok, %{conn: conn} = connected} ->
        case SshAdapter.exec(conn, command, timeout) do
          {:ok, result} ->
            {:reply, {:ok, result}, connected}

          {:error, _reason} = error ->
            SshAdapter.close(conn)
            {:reply, error, %{connected | conn: nil, failures: connected.failures + 1}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | failures: state.failures + 1}}
    end
  end

  def handle_call({:exec, command, timeout}, _from, %{conn: conn} = state) do
    case SshAdapter.exec(conn, command, timeout) do
      {:ok, result} ->
        {:reply, {:ok, result}, state}

      {:error, _reason} = error ->
        # Connection may have dropped — close it so the next call reconnects.
        SshAdapter.close(conn)
        {:reply, error, %{state | conn: nil, failures: state.failures + 1}}
    end
  end

  def handle_call({:sftp, fun}, _from, %{conn: nil} = state) do
    case connect(state) do
      {:ok, %{conn: conn} = connected} ->
        {:reply, SshAdapter.with_sftp(conn, fun), connected}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | failures: state.failures + 1}}
    end
  end

  def handle_call({:sftp, fun}, _from, %{conn: conn} = state) do
    case SshAdapter.with_sftp(conn, fun) do
      {:ok, _} = ok ->
        {:reply, ok, state}

      {:error, _} = error ->
        SshAdapter.close(conn)
        {:reply, error, %{state | conn: nil, failures: state.failures + 1}}
    end
  end

  defp connect(%{server: server} = state) do
    with {:ok, secret} <- Fleet.open_secret(server),
         {:ok, conn} <-
           SshAdapter.connect(%{
             host: server.host,
             port: server.port,
             username: server.username,
             auth_type: server.auth_type,
             secret: secret
           }) do
      fingerprint =
        case SshAdapter.fingerprint(conn) do
          {:ok, fp} -> fp
          _ -> nil
        end

      # Best-effort telemetry: a failed status write must never break the
      # connection itself (e.g. Repo unreachable from this process).
      try do
        Fleet.mark_seen(server, fingerprint)
      rescue
        e -> Logger.warning("ServerSession mark_seen failed: #{inspect(e)}")
      catch
        _, reason -> Logger.warning("ServerSession mark_seen failed: #{inspect(reason)}")
      end

      {:ok, %{state | conn: conn, fingerprint: fingerprint, failures: 0}}
    else
      :error -> {:error, :cannot_decrypt_secret}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def handle_info({:ssh_cm, _conn, _msg}, state) do
    # Late channel close / data messages arriving after timeout - ignore
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{conn: nil}), do: :ok
  def terminate(_reason, %{conn: conn}), do: SshAdapter.close(conn)
end
