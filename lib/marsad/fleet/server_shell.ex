defmodule Marsad.Fleet.ServerShell do
  @moduledoc """
  One persistent interactive shell (PTY) per terminal window.

  Unlike `ServerSession` (one exec channel per command, no TTY), this holds
  a single `shell` channel with a pseudo-terminal, so fullscreen programs
  (`vim`, `nano`, `top`, …), job control, `cd` and shell history all work
  natively. Raw keystrokes stream in, screen bytes stream out.

  Registered as `{:shell, server_id, window_id}` in `Marsad.Fleet.Registry`,
  supervised by `Marsad.Fleet.DynamicSupervisor` with `restart: :temporary`
  (a fresh `ensure/5` recovers from crashes). Holds its own SSH connection
  so a stuck shell never affects command execution. Monitors the owning
  LiveView and exits when it goes away.

  The SSH primitives go through a configurable transport
  (`:marsad, :shell_transport`, default `Marsad.SSH.SshAdapter`) so tests
  can drive the whole state machine with a fake.
  """

  use GenServer

  alias Marsad.Fleet.CredentialVault
  alias Marsad.Fleet.Server

  @max_pending 8_192

  # -- identity ---------------------------------------------------------------

  def key(server_id, window_id, lv_pid), do: {:shell, server_id, window_id, lv_pid}

  def via(server_id, window_id, lv_pid),
    do: {:via, Registry, {Marsad.Fleet.Registry, key(server_id, window_id, lv_pid)}}

  def child_spec(args) do
    %{
      id: {__MODULE__, args.server_id, args.window_id},
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary
    }
  end

  # -- public API (all keyed, never raise) ---------------------------------------

  @doc "Returns the live shell, starting (and connecting) one if needed."
  def ensure(server_id, window_id, lv_pid, cols, rows) do
    case Registry.lookup(Marsad.Fleet.Registry, key(server_id, window_id, lv_pid)) do
      [{pid, _}] when is_pid(pid) ->
        if Process.alive?(pid),
          do: {:ok, pid},
          else: start_shell(server_id, window_id, lv_pid, cols, rows)

      [] ->
        start_shell(server_id, window_id, lv_pid, cols, rows)
    end
  end

  @doc "Streams raw keystrokes to the shell (buffered while connecting)."
  def input(server_id, window_id, lv_pid, data) do
    with {:ok, pid} <- alive_shell(server_id, window_id, lv_pid) do
      GenServer.call(pid, {:input, IO.iodata_to_binary(data)})
    end
  rescue
    _ -> {:error, :gone}
  catch
    :exit, _ -> {:error, :gone}
  end

  @doc "Resizes the remote PTY."
  def resize(server_id, window_id, lv_pid, cols, rows) do
    with {:ok, pid} <- alive_shell(server_id, window_id, lv_pid) do
      GenServer.call(pid, {:resize, cols, rows})
    end
  rescue
    _ -> {:error, :gone}
  catch
    :exit, _ -> {:error, :gone}
  end

  @doc "Closes the shell (idempotent)."
  def close(server_id, window_id, lv_pid) do
    case Registry.lookup(Marsad.Fleet.Registry, key(server_id, window_id, lv_pid)) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(Marsad.Fleet.DynamicSupervisor, pid)
        :ok

      [] ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "Closes every shell belonging to a server (used when the server is deleted)."
  def close_for_server(server_id) do
    spec = [{{{:shell, :"$1", :_, :_}, :"$2", :_}, [{:==, :"$1", server_id}], [:"$2"]}]

    for pid <- Registry.select(Marsad.Fleet.Registry, spec) do
      DynamicSupervisor.terminate_child(Marsad.Fleet.DynamicSupervisor, pid)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp alive_shell(server_id, window_id, lv_pid) do
    case Registry.lookup(Marsad.Fleet.Registry, key(server_id, window_id, lv_pid)) do
      [{pid, _}] -> if Process.alive?(pid), do: {:ok, pid}, else: {:error, :gone}
      [] -> {:error, :gone}
    end
  end

  defp start_shell(server_id, window_id, lv_pid, cols, rows) do
    args = %{server_id: server_id, window_id: window_id, lv_pid: lv_pid, cols: cols, rows: rows}

    case DynamicSupervisor.start_child(Marsad.Fleet.DynamicSupervisor, {__MODULE__, args}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- GenServer -------------------------------------------------------------------

  def start_link(%{server_id: _, window_id: _, lv_pid: _} = args) do
    GenServer.start_link(
      __MODULE__,
      args,
      name: via(args.server_id, args.window_id, args.lv_pid)
    )
  end

  @impl true
  def init(%{server_id: sid, window_id: wid, lv_pid: lv_pid} = args) do
    case Marsad.Repo.get(Server, sid) do
      nil ->
        {:stop, :server_not_found}

      server ->
        mon = Process.monitor(lv_pid)

        {:ok,
         %{
           server: server,
           window_id: wid,
           lv_pid: lv_pid,
           lv_mon: mon,
           conn: nil,
           channel: nil,
           phase: :connecting,
           pending: "",
           cols: max(args[:cols] || 80, 1),
           rows: max(args[:rows] || 24, 1)
         }, {:continue, :connect}}
    end
  end

  @impl true
  def handle_continue(:connect, %{server: server} = state) do
    transport = transport()

    with {:ok, secret} <- open_secret(server),
         {:ok, conn} <-
           transport.connect(%{
             host: server.host,
             port: server.port,
             username: server.username,
             auth_type: server.auth_type,
             secret: secret
           }),
         {:ok, channel} <- transport.open_shell(conn, state.cols, state.rows) do
      notify(state, {:shell_opened, key(server.id, state.window_id, state.lv_pid)})
      state = %{state | conn: conn, channel: channel, phase: :open}
      {:noreply, flush_pending(state)}
    else
      :error -> fail(state, :cannot_decrypt_secret)
      {:error, reason} -> fail(state, reason)
    end
  end

  @impl true
  def handle_call({:input, data}, _from, %{phase: :open} = state) do
    case transport().shell_send(state.conn, state.channel, data) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, close_down(state, reason)}
    end
  end

  def handle_call({:input, data}, _from, %{phase: :connecting} = state) do
    pending = String.slice(state.pending <> data, -@max_pending..-1//1)
    {:reply, :ok, %{state | pending: pending}}
  end

  def handle_call({:resize, cols, rows}, _from, state) do
    state = %{state | cols: max(cols, 1), rows: max(rows, 1)}

    if state.phase == :open do
      transport().shell_resize(state.conn, state.channel, state.cols, state.rows)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(
        {:ssh_cm, conn, {:data, channel, _type, data}},
        %{conn: conn, channel: channel} = state
      ) do
    notify(
      state,
      {:shell_output, key(state.server.id, state.window_id, state.lv_pid),
       IO.iodata_to_binary(data)}
    )

    {:noreply, state}
  end

  def handle_info({:ssh_cm, conn, {:eof, channel}}, %{conn: conn, channel: channel} = state) do
    # Remote says no more output; the :closed message follows shortly.
    {:noreply, state}
  end

  def handle_info({:ssh_cm, conn, {closed, channel}}, %{conn: conn, channel: channel} = state)
      when closed in [:closed, :exit_signal] do
    notify(state, {:shell_closed, key(state.server.id, state.window_id, state.lv_pid), closed})
    {:stop, :normal, state}
  end

  def handle_info({:ssh_cm, _conn, _msg}, state) do
    # Stray messages for other channels — ignore.
    {:noreply, state}
  end

  def handle_info({:DOWN, mon, :process, pid, _reason}, %{lv_mon: mon, lv_pid: pid} = state) do
    {:stop, :normal, state}
  end

  def handle_info(:stop_now, state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{conn: nil}), do: :ok

  def terminate(_reason, %{conn: conn, channel: nil}) do
    transport().close(conn)
    :ok
  end

  def terminate(_reason, %{conn: conn, channel: channel}) do
    transport().shell_close(conn, channel)
    transport().close(conn)
    :ok
  end

  # -- internals ---------------------------------------------------------------------

  defp transport, do: Application.get_env(:marsad, :shell_transport, Marsad.SSH.SshAdapter)

  defp open_secret(%Server{secret_encrypted: nil}), do: {:ok, nil}
  defp open_secret(%Server{secret_encrypted: sealed}), do: CredentialVault.open(sealed)

  defp notify(%{lv_pid: pid}, msg) when is_pid(pid) do
    send(pid, msg)
    :ok
  end

  defp fail(state, reason) do
    notify(state, {:shell_failed, key(state.server.id, state.window_id, state.lv_pid), reason})
    {:stop, :normal, state}
  end

  defp flush_pending(%{pending: ""} = state), do: state

  defp flush_pending(state) do
    case transport().shell_send(state.conn, state.channel, state.pending) do
      :ok -> %{state | pending: ""}
      {:error, reason} -> close_down(%{state | pending: ""}, reason)
    end
  end

  defp close_down(state, reason) do
    notify(state, {:shell_closed, key(state.server.id, state.window_id, state.lv_pid), reason})
    # Stop asynchronously so the reply still goes out.
    send(self(), :stop_now)
    state
  end
end
