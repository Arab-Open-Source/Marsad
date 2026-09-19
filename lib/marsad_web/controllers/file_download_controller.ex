defmodule MarsadWeb.FileDownloadController do
  use MarsadWeb, :controller

  alias Marsad.Fleet

  # Hard caps so one download cannot OOM the BEAM (exec buffers stdout).
  @max_file_bytes 100_000_000
  @max_dir_bytes 50_000_000

  @doc """
  Downloads a remote file (or directory as tar.gz).

  `GET /files/download?server_id=1&path=/var/log/syslog`

  Auth is enforced by the `:require_admin` pipeline. Sizes are pre-checked
  (`stat`/`du`) and rejected with 413 before buffering.
  Binary-safe: never converts to string.
  """
  def download(conn, %{"server_id" => sid, "path" => path}) do
    with {server_id, ""} <- Integer.parse(to_string(sid)),
         path when is_binary(path) and path != "" <- String.trim(path),
         server when not is_nil(server) <- Fleet.get_server(server_id) do
      normalized = Fleet.remote_join("/", path)

      # If path is a directory, stream it as tar.gz via `tar` over SSH.
      case Fleet.list_dir(server_id, normalized) do
        {:ok, _entries} ->
          download_dir(conn, server_id, normalized)

        {:error, _} ->
          download_file(conn, server_id, normalized)
      end
    else
      _ ->
        conn
        |> put_status(:bad_request)
        |> text("Missing or invalid server_id/path")
    end
  end

  def download(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> text("Missing server_id/path")
  end

  defp download_dir(conn, server_id, normalized) do
    parent = Fleet.remote_parent(normalized)
    base = Path.basename(normalized)

    with {:ok, size} <- remote_size(server_id, "du -sb #{shell_quote(normalized)} | cut -f1"),
         true <- size <= @max_dir_bytes do
      # `tar -czf -` streams the archive to stdout; exec collects it.
      cmd =
        "tar -czf - -C #{shell_quote(parent)} #{shell_quote(base)} 2>/dev/null"

      case Fleet.exec(server_id, cmd, 60_000) do
        {:ok, %{stdout: data}} when is_binary(data) and byte_size(data) > 0 ->
          filename = base <> ".tar.gz"

          conn
          |> put_resp_content_type("application/gzip")
          |> put_resp_header(
            "content-disposition",
            ~s[attachment; filename="#{escape_filename(filename)}"]
          )
          |> send_resp(200, data)

        {:ok, %{stdout: ""}} ->
          conn
          |> put_status(:not_found)
          |> text("Directory is empty or cannot be archived")

        {:error, reason} ->
          conn
          |> put_status(:not_found)
          |> text("Directory download failed: #{inspect(reason)}")

        _ ->
          conn
          |> put_status(:not_found)
          |> text("Directory download failed")
      end
    else
      false ->
        conn
        |> put_status(:request_entity_too_large)
        |> text("Directory too large (max #{div(@max_dir_bytes, 1_000_000)}MB)")

      _ ->
        conn
        |> put_status(:not_found)
        |> text("Directory download failed")
    end
  end

  defp download_file(conn, server_id, normalized) do
    with {:ok, size} <-
           remote_size(server_id, "stat -c %s #{shell_quote(normalized)} 2>/dev/null"),
         true <- size <= @max_file_bytes,
         {:ok, data} <- Fleet.read_file(server_id, normalized, @max_file_bytes) do
      filename = Path.basename(normalized)
      content_type = mime_type(normalized)

      conn
      |> put_resp_content_type(content_type)
      |> put_resp_header(
        "content-disposition",
        ~s[attachment; filename="#{escape_filename(filename)}"]
      )
      |> send_resp(200, data)
    else
      false ->
        conn
        |> put_status(:request_entity_too_large)
        |> text("File too large (max #{div(@max_file_bytes, 1_000_000)}MB)")

      {:error, reason} ->
        conn
        |> put_status(:not_found)
        |> text("Download failed: #{inspect(reason)}")

      _ ->
        conn
        |> put_status(:not_found)
        |> text("Download failed")
    end
  end

  defp remote_size(server_id, cmd) do
    case Fleet.exec(server_id, cmd, 10_000) do
      {:ok, %{stdout: out}} ->
        case Integer.parse(String.trim(out)) do
          {n, _} when n >= 0 -> {:ok, n}
          _ -> {:error, :unknown_size}
        end

      {:error, _} = error ->
        error
    end
  end

  defp mime_type(path) do
    case String.downcase(Path.extname(path)) do
      ".txt" -> "text/plain"
      ".log" -> "text/plain"
      ".conf" -> "text/plain"
      ".json" -> "application/json"
      ".yaml" -> "text/yaml"
      ".yml" -> "text/yaml"
      ".html" -> "text/html"
      ".css" -> "text/css"
      ".js" -> "application/javascript"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".svg" -> "image/svg+xml"
      ".pdf" -> "application/pdf"
      ".zip" -> "application/zip"
      ".tar" -> "application/x-tar"
      ".gz" -> "application/gzip"
      ".mp4" -> "video/mp4"
      ".mp3" -> "audio/mpeg"
      _ -> "application/octet-stream"
    end
  end

  defp escape_filename(name) do
    name |> Path.basename() |> String.replace("\"", "_") |> String.replace(["\r", "\n"], "_")
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
