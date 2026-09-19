defmodule Marsad.SSH do
  @moduledoc """
  Behaviour for remote command execution.

  The current implementation is `Marsad.SSH.SshAdapter` (direct OTP `:ssh`).
  A future agent-based transport can implement this same behaviour without
  changing LiveViews or the Fleet context.
  """

  @type connection :: term()
  @type exec_result ::
          {:ok, %{stdout: binary(), stderr: binary(), status: integer()}} | {:error, term()}

  @callback connect(map()) :: {:ok, connection()} | {:error, term()}
  @callback exec(connection(), binary(), timeout()) :: exec_result()
  @callback fingerprint(connection()) :: {:ok, binary()} | {:error, term()}
  @callback close(connection()) :: :ok

  @doc """
  Opens an interactive shell channel with a PTY (for terminals: vim, top…).
  Returns `{:ok, channel}` where channel is an `:ssh_connection` channel id.
  `cols`/`rows` size the remote PTY.
  """
  @callback open_shell(connection(), pos_integer(), pos_integer()) ::
              {:ok, term()} | {:error, term()}

  @doc "Sends raw keystrokes to an open shell channel."
  @callback shell_send(connection(), term(), iodata()) :: :ok | {:error, term()}

  @doc "Resizes the remote PTY."
  @callback shell_resize(connection(), term(), pos_integer(), pos_integer()) :: :ok

  @doc "Closes one shell channel (leaves the connection open)."
  @callback shell_close(connection(), term()) :: :ok

  @doc "Sends EOF on a shell channel (polite hangup, e.g. on `exit`)."
  @callback shell_eof(connection(), term()) :: :ok
end
