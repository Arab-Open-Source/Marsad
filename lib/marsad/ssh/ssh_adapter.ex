defmodule Marsad.SSH.SshAdapter do
  @moduledoc """
  Direct-SSH transport built on OTP `:ssh` / `:ssh_connection`.

  Supports password auth and private-key auth (PEM content or a file path).
  Host keys are accepted on first use (TOFU) and the fingerprint is recorded
  so the UI can display it and future versions can enforce/verify it.
  """
  @behaviour Marsad.SSH

  require Logger

  @connect_timeout 10_000

  @impl true
  def connect(%{host: host, port: port, username: username} = params) do
    :ssh.start()

    opts =
      [
        user: to_charlist(username),
        user_interaction: false,
        silently_accept_hosts: true,
        connect_timeout: @connect_timeout
      ]
      |> with_auth(params)

    case :ssh.connect(to_charlist(host), port || 22, opts, @connect_timeout) do
      {:ok, conn} ->
        {:ok, conn}

      {:error, reason} ->
        Logger.warning("SSH connect failed to #{host}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def exec(conn, command, timeout \\ 30_000) when is_binary(command) do
    with {:ok, channel} <- :ssh_connection.session_channel(conn, timeout),
         :success <- :ssh_connection.exec(conn, channel, to_charlist(command), timeout) do
      collect(channel, conn, timeout, %{stdout: "", stderr: "", status: nil})
    else
      {:error, reason} -> {:error, reason}
      error -> {:error, error}
    end
  end

  @impl true
  def fingerprint(conn) do
    case :ssh.hostkey_fingerprint(conn) do
      fingerprint when is_list(fingerprint) -> {:ok, to_string(fingerprint)}
      other -> {:error, other}
    end
  rescue
    _ -> {:error, :unsupported}
  end

  @impl true
  def close(conn) do
    :ssh.close(conn)
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Runs `fun` with a fresh SFTP channel on `conn`.
  `fun` receives the channel pid; the channel is always closed afterwards.
  Returns `{:ok, fun_result}` or `{:error, reason}`.
  """
  @spec with_sftp(Marsad.SSH.connection(), (pid() -> term())) :: {:ok, term()} | {:error, term()}
  def with_sftp(conn, fun) when is_function(fun, 1) do
    case :ssh_sftp.start_channel(conn, []) do
      {:ok, channel} ->
        try do
          {:ok, fun.(channel)}
        rescue
          e -> {:error, e}
        catch
          :exit, reason -> {:error, reason}
          reason -> {:error, reason}
        after
          :ssh_sftp.stop_channel(channel)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Lists a directory: `{:ok, [%{name, type, size, mtime, perms}]}` (dots excluded)."
  @spec list_dir(pid(), binary()) :: {:ok, [map()]} | {:error, term()}
  def list_dir(channel, path) do
    with {:ok, names} <- :ssh_sftp.list_dir(channel, to_charlist(path)) do
      files =
        names
        |> Enum.map(&to_string/1)
        |> Enum.reject(&(&1 in [".", ".."]))

      entries =
        files
        |> Task.async_stream(
          &stat_entry(channel, path, &1),
          max_concurrency: 12,
          timeout: 8_000,
          ordered: false
        )
        |> Enum.flat_map(fn
          {:ok, entry} -> [entry]
          {:exit, _} -> []
        end)
        |> Enum.sort_by(fn e -> {e.type != :dir, String.downcase(e.name)} end)

      {:ok, entries}
    end
  end

  @doc "Reads up to `max_bytes` of a file (never pulls more than needed). Supports `:infinity` for full-file download; always returns raw binary (no `to_string` conversion) so binary files survive intact."
  @spec read_file(pid(), binary(), pos_integer() | :infinity) ::
          {:ok, binary()} | {:error, term()}
  def read_file(channel, path, max_bytes \\ 200_000)

  def read_file(channel, path, :infinity) do
    with {:ok, handle} <- :ssh_sftp.open(channel, to_charlist(path), [:read, :binary]) do
      result = read_all_chunks(channel, handle, <<>>)
      :ssh_sftp.close(channel, handle)
      result
    end
  end

  def read_file(channel, path, max_bytes) when is_integer(max_bytes) and max_bytes >= 0 do
    with {:ok, handle} <- :ssh_sftp.open(channel, to_charlist(path), [:read, :binary]) do
      result = read_limited_chunks(channel, handle, max_bytes, <<>>)
      :ssh_sftp.close(channel, handle)
      result
    end
  end

  defp read_limited_chunks(_channel, _handle, 0, acc), do: {:ok, acc}

  defp read_limited_chunks(channel, handle, remaining, acc) when remaining > 0 do
    chunk = min(65_536, remaining)

    case :ssh_sftp.read(channel, handle, chunk) do
      {:ok, data} ->
        bin = IO.iodata_to_binary(data)
        next_acc = <<acc::binary, bin::binary>>

        if byte_size(bin) < chunk do
          {:ok, next_acc}
        else
          read_limited_chunks(channel, handle, remaining - byte_size(bin), next_acc)
        end

      :eof ->
        {:ok, acc}

      {:error, _} = error ->
        error
    end
  end

  defp read_all_chunks(channel, handle, acc) do
    case :ssh_sftp.read(channel, handle, 65_536) do
      {:ok, data} ->
        bin = IO.iodata_to_binary(data)
        next_acc = <<acc::binary, bin::binary>>

        if byte_size(bin) < 65_536 do
          {:ok, next_acc}
        else
          read_all_chunks(channel, handle, next_acc)
        end

      :eof ->
        {:ok, acc}

      {:error, _} = error ->
        error
    end
  end

  @doc "Writes a whole binary to a remote path (creates/truncates). Chunked so large files (>32KB) don't exceed SSH packet limits and memory stays bounded."
  @spec write_file(pid(), binary(), binary()) :: :ok | {:error, term()}
  def write_file(channel, path, data) when is_binary(data) do
    case :ssh_sftp.open(channel, to_charlist(path), [:write, :binary, :creat, :trunc]) do
      {:ok, handle} ->
        result = write_chunks(channel, handle, data, 0)
        :ssh_sftp.close(channel, handle)
        result

      {:error, _} = error ->
        error
    end
  end

  defp write_chunks(_channel, _handle, data, offset) when offset >= byte_size(data), do: :ok

  defp write_chunks(channel, handle, data, offset) do
    chunk_size = 32_768
    remaining = byte_size(data) - offset
    len = min(chunk_size, remaining)
    chunk = binary_part(data, offset, len)

    case :ssh_sftp.write(channel, handle, chunk) do
      :ok -> write_chunks(channel, handle, data, offset + len)
      {:error, _} = error -> error
    end
  end

  @doc "Streams a local file (at `local_path`) to a remote path without loading it fully into memory. Used for `allow_upload` where the tmp file may be 100s of MB."
  @spec upload_file(pid(), binary(), binary()) :: :ok | {:error, term()}
  def upload_file(channel, remote_path, local_path) do
    case :ssh_sftp.open(channel, to_charlist(remote_path), [:write, :binary, :creat, :trunc]) do
      {:ok, handle} ->
        result =
          File.stream!(local_path, [], 65_536)
          |> Enum.reduce_while(:ok, fn chunk, :ok ->
            case :ssh_sftp.write(channel, handle, chunk) do
              :ok -> {:cont, :ok}
              {:error, _} = error -> {:halt, error}
            end
          end)

        :ssh_sftp.close(channel, handle)
        result

      {:error, _} = error ->
        error
    end
  end

  @doc "Creates a directory (including parents, mkdir -p style)."
  @spec make_dir(pid(), binary()) :: :ok | {:error, term()}
  def make_dir(channel, path) do
    parts = String.split(path, "/", trim: true)
    base = if String.starts_with?(path, "/"), do: "/", else: ""

    Enum.reduce_while(parts, base, fn part, acc ->
      dir = Path.join(acc, part)

      case :ssh_sftp.make_dir(channel, to_charlist(dir)) do
        :ok -> {:cont, dir}
        {:error, :file_already_exists} -> {:cont, dir}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  @doc "Deletes a file."
  @spec delete_file(pid(), binary()) :: :ok | {:error, term()}
  def delete_file(channel, path) do
    :ssh_sftp.delete(channel, to_charlist(path))
  end

  @doc "Deletes an empty directory."
  @spec delete_dir(pid(), binary()) :: :ok | {:error, term()}
  def delete_dir(channel, path) do
    :ssh_sftp.del_dir(channel, to_charlist(path))
  end

  @doc "Resolves the remote home directory."
  @spec home_dir(pid()) :: {:ok, binary()} | {:error, term()}
  def home_dir(channel) do
    case :ssh_sftp.real_path(channel, ~c".") do
      {:ok, path} -> {:ok, to_string(path)}
      {:error, _} = error -> error
    end
  end

  defp stat_entry(channel, dir, name) do
    full = Path.join(dir, name)

    case :ssh_sftp.read_file_info(channel, to_charlist(full)) do
      {:ok, info} ->
        %{
          name: name,
          type: entry_type(info),
          size: elem(info, 1),
          mtime: elem(info, 6),
          perms: format_perms(elem(info, 4))
        }

      {:error, _} ->
        %{name: name, type: :other, size: 0, mtime: 0, perms: "?"}
    end
  end

  # OTP file_info record: {:file_info, size, type, access, atime, mtime, ctime,
  #  mode, links, major, minor, inode, uid, gid}
  defp entry_type(
         {:file_info, _size, :directory, _a, _at, _mt, _ct, _mo, _l, _mj, _mi, _in, _u, _g}
       ),
       do: :dir

  defp entry_type(
         {:file_info, _size, :regular, _a, _at, _mt, _ct, _mo, _l, _mj, _mi, _in, _u, _g}
       ),
       do: :file

  defp entry_type(
         {:file_info, _size, :symlink, _a, _at, _mt, _ct, _mo, _l, _mj, _mi, _in, _u, _g}
       ),
       do: :link

  defp entry_type(_), do: :other

  defp format_perms(mode) when is_integer(mode) do
    import Bitwise
    r = fn bit, c -> if (mode &&& bit) != 0, do: c, else: "-" end
    r.(0o400, "r") <> r.(0o200, "w") <> r.(0o100, "x") <> r.(0o040, "r") <> r.(0o004, "r")
  end

  defp format_perms(_), do: "?????"

  defp with_auth(opts, %{auth_type: "password", secret: secret}) when is_binary(secret) do
    Keyword.put(opts, :password, to_charlist(secret))
  end

  defp with_auth(opts, %{auth_type: "key", secret: secret}) when is_binary(secret) do
    case key_file_for(secret) do
      {:ok, path, cleanup?} ->
        opts
        |> Keyword.put(:user_dir, String.to_charlist(Path.dirname(path)))
        |> Keyword.put(:identity, String.to_charlist(path))
        |> Keyword.put(:cleanup_key_file, cleanup?)
        |> Keyword.put(:save_accepted_host, false)

      :error ->
        opts
    end
  end

  defp with_auth(opts, _), do: opts

  # PEM content -> temp file (removed after connect by the caller session);
  # otherwise treat the secret as a path to an existing key file.
  defp key_file_for("-----BEGIN " <> _ = pem) do
    path = Path.join(System.tmp_dir!(), "marsad-key-#{:erlang.unique_integer([:positive])}")

    case File.write(path, pem, [:exclusive]) do
      :ok ->
        File.chmod(path, 0o600)
        {:ok, path, true}

      {:error, _} ->
        :error
    end
  end

  defp key_file_for(path) when is_binary(path) do
    if File.exists?(path), do: {:ok, path, false}, else: :error
  end

  defp collect(channel, conn, timeout, acc) do
    receive do
      {:ssh_cm, ^conn, {:data, ^channel, 0, data}} ->
        collect(channel, conn, timeout, Map.update!(acc, :stdout, &(&1 <> to_string(data))))

      {:ssh_cm, ^conn, {:data, ^channel, 1, data}} ->
        collect(channel, conn, timeout, Map.update!(acc, :stderr, &(&1 <> to_string(data))))

      {:ssh_cm, ^conn, {:eof, ^channel}} ->
        collect(channel, conn, timeout, acc)

      {:ssh_cm, ^conn, {:exit_status, ^channel, status}} ->
        collect(channel, conn, timeout, Map.put(acc, :status, status))

      {:ssh_cm, ^conn, {:closed, ^channel}} ->
        {:ok, %{stdout: acc.stdout, stderr: acc.stderr, status: acc.status || 0}}
    after
      timeout ->
        :ssh_connection.close(conn, channel)
        {:error, :timeout}
    end
  end
end
