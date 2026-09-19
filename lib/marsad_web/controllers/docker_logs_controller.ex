defmodule MarsadWeb.DockerLogsController do
  use MarsadWeb, :controller

  alias Marsad.Fleet
  alias Marsad.Fleet.Services

  @doc """
  Downloads a container's logs as `<name>.log`.

  `GET /docker/logs/download?server_id=1&name=web&timestamps=true`

  Newest bytes win (capped server-side); binary-safe, never converts.
  """
  def download(conn, %{"server_id" => sid, "name" => name} = params) do
    with {server_id, ""} <- Integer.parse(to_string(sid)),
         :ok <- Services.validate_name(name),
         server when not is_nil(server) <- Fleet.get_server(server_id) do
      timestamps = Map.get(params, "timestamps") in ["true", "1"]

      case Services.docker_logs_download(server_id, name, timestamps: timestamps) do
        {:ok, data} ->
          filename = "#{name}.log"

          conn
          |> put_resp_content_type("text/plain")
          |> put_resp_header(
            "content-disposition",
            ~s[attachment; filename="#{escape_filename(filename)}"]
          )
          |> send_resp(200, data)

        {:error, reason} ->
          conn
          |> put_status(:not_found)
          |> text("Log download failed: #{inspect(reason)}")
      end
    else
      _ ->
        conn
        |> put_status(:bad_request)
        |> text("Missing or invalid server_id/name")
    end
  end

  def download(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> text("Missing server_id/name")
  end

  defp escape_filename(name) do
    name |> Path.basename() |> String.replace("\"", "_") |> String.replace(["\r", "\n"], "_")
  end
end
