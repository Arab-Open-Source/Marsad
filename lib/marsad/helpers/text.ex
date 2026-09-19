defmodule Marsad.Helpers.Text do
  @moduledoc false

  @doc "Shell-quotes a value with single quotes, escaping embedded `'`."

  def shell_quote(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  def format_size(bytes) when is_integer(bytes) and bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)}G"

  def format_size(bytes) when is_integer(bytes) and bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)}M"

  def format_size(bytes) when is_integer(bytes) and bytes >= 1024,
    do: "#{Float.round(bytes / 1024, 1)}K"

  def format_size(bytes) when is_integer(bytes), do: "#{bytes}B"
  def format_size(_), do: "—"

  def format_mtime(mtime) when is_integer(mtime) and mtime > 0 do
    case DateTime.from_unix(mtime) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
      _ -> "—"
    end
  end

  def format_mtime({{y, mo, d}, {h, mi, _s}}) do
    case NaiveDateTime.new(y, mo, d, h, mi, 0) do
      {:ok, ndt} -> Calendar.strftime(ndt, "%Y-%m-%d %H:%M")
      _ -> "—"
    end
  end

  def format_mtime(_), do: "—"

  def mime_type(path) when is_binary(path) do
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

  def escape_filename(name) when is_binary(name) do
    String.replace(name, "\"", "_")
  end

  def upload_error_to_string(:too_large), do: "Too large (max 50MB per file)"

  def upload_error_to_string(:too_many_files),
    do: "Too many files (max 3 files / 20 folder entries)"

  def upload_error_to_string(:not_accepted), do: "File type not accepted"
  def upload_error_to_string(other), do: inspect(other)
end
