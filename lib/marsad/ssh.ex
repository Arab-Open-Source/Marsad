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
end
