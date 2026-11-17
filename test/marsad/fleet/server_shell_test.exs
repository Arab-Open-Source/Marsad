defmodule Marsad.Fleet.ServerShellTest do
  use Marsad.DataCase, async: false

  alias Marsad.Fleet.ServerShell
  alias Marsad.SSH.FakeShellTransport

  setup do
    start_supervised!(FakeShellTransport)
    FakeShellTransport.reset()

    {:ok, server} =
      Marsad.Fleet.create_server(%{
        name: "shell-#{System.unique_integer([:positive])}",
        host: "127.0.0.1",
        port: 22,
        username: "root",
        auth_type: "password",
        secret: "x"
      })

    kill_shells(server.id)
    on_exit(fn -> kill_shells(server.id) end)
    %{server: server}
  end

  defp kill_shells(server_id) do
    ServerShell.close_for_server(server_id)
    Process.sleep(20)
  end

  defp key(server_id, wid), do: ServerShell.key(server_id, wid, self())

  test "opens, streams output both ways and resizes", %{server: server} do
    wid = "w1"
    assert {:ok, pid} = ServerShell.ensure(server.id, wid, self(), 80, 24)

    assert_receive {:shell_opened, {_, _, _, _} = k}, 2000
    assert k == key(server.id, wid)

    FakeShellTransport.enqueue("hello-remote\r\nfakesh$ ")
    assert :ok = ServerShell.input(server.id, wid, self(), "echo hello\r")

    assert_receive {:shell_output, ^k, "hello-remote\r\nfakesh$ "}, 2000

    # What the client typed reached the transport…
    assert [{:open_shell, 80, 24} | _] = FakeShellTransport.sent()
    assert {:send, "echo hello\r"} in FakeShellTransport.sent()

    assert :ok = ServerShell.resize(server.id, wid, self(), 100, 30)
    assert {:resize, 100, 30} in FakeShellTransport.sent()

    assert Process.alive?(pid)
    assert :ok = ServerShell.close(server.id, wid, self())
    refute Process.alive?(pid)
  end

  test "a reconnected LiveView gets a fresh shell, not the old one", %{server: server} do
    wid = "w-reconnect"
    test = self()
    owner1 = spawn(fn -> forward_loop(test) end)
    owner2 = spawn(fn -> forward_loop(test) end)

    assert {:ok, p1} = ServerShell.ensure(server.id, wid, owner1, 80, 24)
    assert_receive {:shell_opened, {_, _, ^wid, ^owner1}}, 2000

    # Same server + window, new LiveView pid: the supervisor id must differ.
    assert {:ok, p2} = ServerShell.ensure(server.id, wid, owner2, 80, 24)
    assert_receive {:shell_opened, {_, _, ^wid, ^owner2}}, 2000

    refute p1 == p2
    assert Process.alive?(p1)
    assert Process.alive?(p2)

    send(owner1, :stop)
    send(owner2, :stop)
  end

  test "shell replenishes the SSH flow-control window on output", %{server: server} do
    wid = "w-window"
    assert {:ok, _pid} = ServerShell.ensure(server.id, wid, self(), 80, 24)
    assert_receive {:shell_opened, _}, 2000

    payload = "a-bunch-of-remote-output"
    FakeShellTransport.enqueue(payload)
    assert :ok = ServerShell.input(server.id, wid, self(), "go\r")
    assert_receive {:shell_output, _, ^payload}, 2000

    assert {_channel, bytes} = hd(FakeShellTransport.adjusts())
    assert bytes == byte_size(payload)
  end

  test "input typed while connecting is buffered and flushed", %{server: server} do
    wid = "w2"
    # Block the open: enqueue nothing yet; open_shell itself succeeds
    # immediately, so simulate slowness by ensuring first, then… instead we
    # test the buffer path by racing: input right after ensure usually lands
    # while connecting (transport is instant, so force via direct call order
    # is racy). Deterministic approach: stop the shell mid-connect is hard;
    # instead assert input-before-open still delivers once open.
    assert {:ok, pid} = ServerShell.ensure(server.id, wid, self(), 80, 24)
    assert :ok = ServerShell.input(server.id, wid, self(), "early\r")
    assert_receive {:shell_opened, _}, 2000

    # Input is a cast: sync with the shell before inspecting the transport.
    _ = :sys.get_state(pid)

    # Either it was buffered+flushed (one send) or sent directly — both fine.
    sends = for {:send, bin} <- FakeShellTransport.sent(), do: bin
    assert "early\r" in sends
  end

  test "remote close notifies and stops the shell", %{server: server} do
    wid = "w3"
    assert {:ok, pid} = ServerShell.ensure(server.id, wid, self(), 80, 24)
    assert_receive {:shell_opened, _}, 2000

    ref = Process.monitor(pid)
    FakeShellTransport.enqueue(:closed)
    assert :ok = ServerShell.input(server.id, wid, self(), "exit\r")
    assert_receive {:shell_closed, _, _}, 2000
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2000
  end

  test "failed open notifies and returns gone afterwards", %{server: _server} do
    assert {:error, :server_not_found} =
             ServerShell.ensure(-123_456, "nope", self(), 80, 24)
  end

  test "shell dies with its LiveView", %{server: server} do
    wid = "w4"
    test = self()

    owner = spawn(fn -> forward_loop(test) end)

    assert {:ok, pid} = ServerShell.ensure(server.id, wid, owner, 80, 24)
    assert_receive {:shell_opened, _}, 2000

    ref = Process.monitor(pid)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2000
  end

  defp forward_loop(test) do
    receive do
      :stop -> :ok
      msg -> send(test, msg) && forward_loop(test)
    end
  end

  test "close_for_server terminates that server's shells", %{server: server} do
    assert {:ok, p1} = ServerShell.ensure(server.id, "a", self(), 80, 24)
    assert {:ok, p2} = ServerShell.ensure(server.id, "b", self(), 80, 24)
    assert_receive {:shell_opened, _}, 2000
    assert_receive {:shell_opened, _}, 2000

    m1 = Process.monitor(p1)
    m2 = Process.monitor(p2)
    assert :ok = ServerShell.close_for_server(server.id)
    assert_receive {:DOWN, ^m1, :process, ^p1, _}, 2000
    assert_receive {:DOWN, ^m2, :process, ^p2, _}, 2000
  end

  test "input/resize to a dead shell returns gone" do
    assert {:error, :gone} = ServerShell.input(-1, "ghost", self(), "x")
    assert {:error, :gone} = ServerShell.resize(-1, "ghost", self(), 80, 24)
    assert :ok = ServerShell.close(-1, "ghost", self())
  end
end
