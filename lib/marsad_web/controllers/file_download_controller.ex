defmodule MarsadWeb.FileDownloadController do
  use MarsadWeb, :controller

  alias Marsad.Fleet

  @doc """
  Streams a remote file to the browser.

  `GET /files/download?server_id=1&path=/var/log/syslog`

  Uses `Fleet.read_file/3` with `:infinity` so any size/type is supported.
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
          parent = Fleet.remote_parent(normalized)
          base = Path.basename(normalized)
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

        {:error, _} ->
          # Not a directory — treat as file
          case Fleet.read_file(server_id, normalized, :infinity) do
            {:ok, data} ->
              filename = Path.basename(normalized)
              content_type = mime_type(normalized)

              conn
              |> put_resp_content_type(content_type)
              |> put_resp_header(
                "content-disposition",
                ~s[attachment; filename="#{escape_filename(filename)}"]
              )
              |> send_resp(200, data)

            {:error, reason} ->
              conn
              |> put_status(:not_found)
              |> text("Download failed: #{inspect(reason)}")
          end
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
    String.replace(name, "\"", "_")
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
