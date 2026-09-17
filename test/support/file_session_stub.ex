defmodule MarsadWeb.FileSessionStub do
  @moduledoc """
  Test double for `Marsad.Fleet.ServerSession`.

  Registers under the same Registry name so `Fleet.ensure_session/1` finds it
  instead of starting a real SSH session. Calls are answered from a FIFO queue
  seeded by the test; unexpected calls are forwarded to the test process so
  missing replies fail loudly instead of hanging.
  """
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Marsad.Fleet.ServerSession.via(opts[:server_id]))
  end

  @doc "Queues `reply` as the answer to the next `Fleet` call."
  def enqueue(pid, reply), do: GenServer.call(pid, {:enqueue, reply})

  @impl true
  def init(opts), do: {:ok, %{owner: opts[:owner], replies: :queue.new(), pending: nil}}

  @impl true
  def handle_call({:enqueue, reply}, _from, %{pending: from} = state) when from != nil do
    GenServer.reply(from, reply)
    {:reply, :ok, %{state | pending: nil}}
  end

  def handle_call({:enqueue, reply}, _from, state) do
    {:reply, :ok, %{state | replies: :queue.in(reply, state.replies)}}
  end

  def handle_call(request, from, state) do
    case :queue.out(state.replies) do
      {{:value, reply}, rest} ->
        {:reply, reply, %{state | replies: rest}}

      {:empty, _} ->
        # Let the test observe and answer blocked requests if it wants to.
        send(state.owner, {:file_session_request, self(), from, request})
        {:noreply, %{state | pending: from}}
    end
  end
end
