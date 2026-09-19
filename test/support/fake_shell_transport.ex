defmodule Marsad.SSH.FakeShellTransport do
  @moduledoc """
  In-memory fake of `Marsad.SSH` shell transport for tests.

  Script replies up-front with `enqueue/1`; each `shell_send/3` pops one
  reply and delivers it to the shell process as a real
  `{:ssh_cm, conn, {:data, channel, 0, reply}}` message. Special replies:

    * `:closed` — delivers `{:ssh_cm, conn, {:closed, channel}}`
    * `{:eof}` — delivers `{:ssh_cm, conn, {:eof, channel}}`

  With an empty queue, sends are recorded but produce no message
  (simulates a hung remote). Inspect what the client sent with `sent/0`.
  Call `reset/0` in test setup (one shell per test).
  """
  @behaviour Marsad.SSH

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(
      fn ->
        %{
          replies: :queue.new(),
          sent: [],
          sessions: %{},
          fail_open: nil,
          open_gate: false,
          open_waiters: []
        }
      end,
      name: __MODULE__
    )
  end

  def reset do
    Agent.update(__MODULE__, fn _ ->
      %{
        replies: :queue.new(),
        sent: [],
        sessions: %{},
        fail_open: nil,
        open_gate: false,
        open_waiters: []
      }
    end)
  end

  @doc "Makes the next `open_shell/3` fail once with `reason`."
  def fail_open_once(reason) do
    Agent.update(__MODULE__, fn s -> %{s | fail_open: reason} end)
  end

  @doc "Blocks `open_shell/3` until `release_open/0` (for testing the connecting state)."
  def gate_open do
    Agent.update(__MODULE__, fn s -> %{s | open_gate: true} end)
  end

  def release_open do
    waiters =
      Agent.get_and_update(__MODULE__, fn s ->
        {s.open_waiters, %{s | open_gate: false, open_waiters: []}}
      end)

    for pid <- waiters, do: send(pid, :release_shell_open)
    :ok
  end

  def enqueue(reply) do
    Agent.update(__MODULE__, fn s -> %{s | replies: :queue.in(reply, s.replies)} end)
  end

  def sent do
    Agent.get(__MODULE__, &Enum.reverse(&1.sent))
  end

  @impl true
  def connect(_params) do
    {:ok, {:fake_conn, self()}}
  end

  @impl true
  def exec(_conn, _command, _timeout), do: {:error, :unsupported}

  @impl true
  def fingerprint(_conn), do: {:error, :unsupported}

  @impl true
  def close(_conn), do: :ok

  @impl true
  def open_shell(conn, cols, rows) do
    # NOTE: capture the caller BEFORE Agent.update — self() inside the fun
    # would be the agent process itself.
    owner = self()
    channel = {:fake_channel, System.unique_integer([:positive])}

    decision =
      Agent.get_and_update(__MODULE__, fn
        %{fail_open: reason} = s when not is_nil(reason) ->
          {{:error, reason}, %{s | fail_open: nil, sent: [{:open_shell_failed} | s.sent]}}

        %{open_gate: true} = s ->
          {:wait, %{s | open_waiters: [owner | s.open_waiters]}}

        s ->
          sessions =
            Map.put(s.sessions, channel, %{conn: conn, owner: owner, cols: cols, rows: rows})

          {{:ok, channel}, %{s | sessions: sessions, sent: [{:open_shell, cols, rows} | s.sent]}}
      end)

    case decision do
      {:ok, _} = ok ->
        ok

      {:error, _} = error ->
        error

      :wait ->
        receive do
          :release_shell_open -> :ok
        after
          5000 -> :ok
        end

        Agent.get_and_update(__MODULE__, fn s ->
          sessions =
            Map.put(s.sessions, channel, %{conn: conn, owner: owner, cols: cols, rows: rows})

          {{:ok, channel}, %{s | sessions: sessions, sent: [{:open_shell, cols, rows} | s.sent]}}
        end)
    end
  end

  @impl true
  def shell_send(conn, channel, data) do
    bin = IO.iodata_to_binary(data)

    popped =
      Agent.get_and_update(__MODULE__, fn s ->
        owner =
          case Map.get(s.sessions, channel) do
            %{owner: owner} -> owner
            nil -> nil
          end

        case :queue.out(s.replies) do
          {{:value, reply}, rest} ->
            {{reply, owner}, %{s | replies: rest, sent: [{:send, bin} | s.sent]}}

          {:empty, _} ->
            {:no_reply, %{s | sent: [{:send, bin} | s.sent]}}
        end
      end)

    case popped do
      {reply, owner} when is_pid(owner) -> deliver(owner, conn, channel, reply)
      _ -> :ok
    end

    :ok
  end

  @impl true
  def shell_resize(_conn, _channel, cols, rows) do
    Agent.update(__MODULE__, fn s -> %{s | sent: [{:resize, cols, rows} | s.sent]} end)
    :ok
  end

  @impl true
  def shell_close(_conn, channel) do
    Agent.update(__MODULE__, fn s ->
      %{s | sessions: Map.delete(s.sessions, channel), sent: [:close | s.sent]}
    end)

    :ok
  end

  @impl true
  def shell_eof(_conn, _channel), do: :ok

  defp deliver(owner, conn, channel, :closed) do
    send(owner, {:ssh_cm, conn, {:closed, channel}})
  end

  defp deliver(owner, conn, channel, {:eof}) do
    send(owner, {:ssh_cm, conn, {:eof, channel}})
  end

  defp deliver(owner, conn, channel, reply) when is_binary(reply) do
    send(owner, {:ssh_cm, conn, {:data, channel, 0, reply}})
  end
end
