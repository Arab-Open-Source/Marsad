defmodule Marsad.Fleet do
  @moduledoc """
  Fleet context — CRUD for managed servers plus remote execution.

  Secrets are sealed with `Marsad.Fleet.CredentialVault` before storage and
  only opened inside `ServerSession` at connect time.
  """
  import Ecto.Query, warn: false

  alias Marsad.Fleet.{CredentialVault, Server, ServerSession}
  alias Marsad.Repo

  # -- Servers ------------------------------------------------------------

  def list_servers do
    Server |> order_by([s], desc: s.updated_at) |> Repo.all()
  end

  def get_server(id), do: Repo.get(Server, id)

  def get_server!(id), do: Repo.get!(Server, id)

  def change_server(%Server{} = server, attrs \\ %{}) do
    Server.changeset(server, attrs)
  end

  def create_server(attrs) do
    %Server{}
    |> Server.changeset(seal_secret(attrs))
    |> Repo.insert()
  end

  def update_server(%Server{} = server, attrs) do
    case server |> Server.changeset(seal_secret(attrs)) |> Repo.update() do
      {:ok, updated} = ok ->
        stop_session(updated.id)
        ok

      {:error, _} = error ->
        error
    end
  end

  def delete_server(%Server{} = server) do
    case Repo.delete(server) do
      {:ok, deleted} = ok ->
        stop_session(deleted.id)
        ok

      {:error, _} = error ->
        error
    end
  end

  @doc "Decrypts the stored secret for a server."
  def open_secret(%Server{secret_encrypted: nil}), do: {:ok, nil}
  def open_secret(%Server{secret_encrypted: sealed}), do: CredentialVault.open(sealed)

  @doc "Records a successful contact (and host fingerprint when known)."
  def mark_seen(%Server{} = server, fingerprint) do
    server
    |> Server.changeset(%{
      status: "online",
      last_seen_at: DateTime.utc_now() |> DateTime.truncate(:second),
      host_fingerprint: fingerprint || server.host_fingerprint
    })
    |> Repo.update()
  end

  def mark_offline(%Server{} = server) do
    server |> Server.changeset(%{status: "offline"}) |> Repo.update()
  end

  # -- Remote execution ---------------------------------------------------

  @doc "Ensures a session process exists for the server."
  def ensure_session(server_id) do
    case Registry.lookup(Marsad.Fleet.Registry, server_id) do
      [{_pid, _}] ->
        :ok

      [] ->
        case get_server(server_id) do
          nil ->
            {:error, :server_not_found}

          server ->
            case DynamicSupervisor.start_child(
                   Marsad.Fleet.DynamicSupervisor,
                   {ServerSession, server}
                 ) do
              {:ok, _} -> :ok
              {:error, {:already_started, _}} -> :ok
              {:error, reason} -> {:error, reason}
            end
        end
    end
  end

  # Stops the live session so the next command reconnects with fresh
  # credentials. Never fails the caller.
  defp stop_session(server_id) do
    case Registry.lookup(Marsad.Fleet.Registry, server_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Marsad.Fleet.DynamicSupervisor, pid)
      [] -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :failed}
  catch
    _, _ -> {:error, :failed}
  end

  @doc "Runs a command on the server (connects lazily on first use)."
  def exec(server_id, command, timeout \\ 30_000) do
    with :ok <- ensure_session(server_id) do
      ServerSession.exec(server_id, command, timeout)
    end
  end

  @doc "Runs a lightweight reachability probe (`echo marsad-ok`)."
  def test_connection(server_id) do
    case exec(server_id, "echo marsad-ok") do
      {:ok, %{stdout: out}} ->
        if String.contains?(out, "marsad-ok"), do: :ok, else: {:error, :unexpected_response}

      {:error, _} = error ->
        error
    end
  end

  # -- SFTP file operations (each opens + closes its own channel) ----------

  @doc "Lists a remote directory."
  def list_dir(server_id, path) do
    with :ok <- ensure_session(server_id),
         {:ok, result} <- ServerSession.sftp(server_id, &Marsad.SSH.SshAdapter.list_dir(&1, path)) do
      result
    end
  end

  @doc "Reads up to `max_bytes` of a remote file."
  def read_file(server_id, path, max_bytes \\ 200_000) do
    with :ok <- ensure_session(server_id),
         {:ok, result} <-
           ServerSession.sftp(server_id, &Marsad.SSH.SshAdapter.read_file(&1, path, max_bytes)) do
      result
    end
  end

  @doc "Writes data to a remote path."
  def write_file(server_id, path, data) do
    with :ok <- ensure_session(server_id),
         {:ok, result} <-
           ServerSession.sftp(server_id, &Marsad.SSH.SshAdapter.write_file(&1, path, data)) do
      result
    end
  end

  @doc "Creates a remote directory (parents included)."
  def make_dir(server_id, path) do
    with :ok <- ensure_session(server_id),
         {:ok, result} <- ServerSession.sftp(server_id, &Marsad.SSH.SshAdapter.make_dir(&1, path)) do
      result
    end
  end

  @doc "Deletes a remote file (`dir?` deletes an empty directory)."
  def delete_path(server_id, path, dir? \\ false) do
    fun =
      if dir?,
        do: &Marsad.SSH.SshAdapter.delete_dir(&1, path),
        else: &Marsad.SSH.SshAdapter.delete_file(&1, path)

    with :ok <- ensure_session(server_id),
         {:ok, result} <- ServerSession.sftp(server_id, fun) do
      result
    end
  end

  @doc "Resolves the remote home directory."
  def home_dir(server_id) do
    with :ok <- ensure_session(server_id),
         {:ok, result} <- ServerSession.sftp(server_id, &Marsad.SSH.SshAdapter.home_dir(&1)) do
      result
    end
  end

  # -- Remote POSIX path helpers (pure, lexical — no network) ---------------

  @doc """
  Joins a remote path segment onto a base and normalizes `.` / `..`.
  Never escapes `/`. `remote_join("/a/b", "../c") == "/a/c"`.
  """
  @spec remote_join(binary(), binary()) :: binary()
  def remote_join(base, name) when is_binary(base) and is_binary(name) do
    raw = if String.starts_with?(name, "/"), do: name, else: base <> "/" <> name

    parts =
      raw
      |> String.split("/", trim: true)
      |> Enum.reduce([], fn
        ".", acc -> acc
        "..", [_ | rest] -> rest
        "..", [] -> []
        part, acc -> [part | acc]
      end)
      |> Enum.reverse()

    "/" <> Enum.join(parts, "/")
  end

  @doc "Parent directory (`remote_parent(\"/\") == \"/\"`)."
  @spec remote_parent(binary()) :: binary()
  def remote_parent("/"), do: "/"

  def remote_parent(path) do
    case String.split(path, "/", trim: true) do
      [] -> "/"
      [_] -> "/"
      parts -> "/" <> Enum.join(Enum.drop(parts, -1), "/")
    end
  end

  @doc "Breadcrumb segments as `[{name, full_path}]`."
  @spec remote_segments(binary()) :: [{binary(), binary()}]
  def remote_segments(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.scan("/", fn part, acc -> remote_join(acc, part) end)
    |> Enum.zip(String.split(path, "/", trim: true))
    |> Enum.map(fn {full, name} -> {name, full} end)
  end

  # -- Private ------------------------------------------------------------

  # Accepts a plaintext `:secret`/string `"secret"` virtual param and seals it
  # into `"secret_encrypted"`. Keys are normalized to strings first because
  # Ecto refuses mixed-key params. An absent/empty secret keeps the old one.
  defp seal_secret(attrs) when is_map(attrs) do
    attrs = for {k, v} <- attrs, into: %{}, do: {to_string(k), v}

    case Map.pop(attrs, "secret") do
      {nil, rest} ->
        rest

      {"", rest} ->
        rest

      {plaintext, rest} when is_binary(plaintext) ->
        Map.put(rest, "secret_encrypted", CredentialVault.seal(plaintext))
    end
  end
end
