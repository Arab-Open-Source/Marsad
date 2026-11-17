defmodule Marsad.Helpers.Text do
  @moduledoc false

  @utf8_replacement <<0xEF, 0xBF, 0xBD>>

  defguardp cont?(byte) when byte >= 0x80 and byte <= 0xBF

  @doc """
  Returns a valid UTF-8 version of `bin`, replacing malformed bytes with U+FFFD.

  PTY output is raw bytes: binary files, legacy locales or a truncated
  multibyte sequence can all produce invalid UTF-8. LiveView event payloads
  are encoded with `encode!/1` by the channel serializer (Jason in prod),
  which raises on such strings and crashes the whole LiveView — the browser
  then reconnects/remounts, which looks like a page reload. Control/escape
  sequences and all valid text pass through untouched.

  Runs in a single linear pass: a recursive `:unicode.characters_to_binary`
  fallback copies the remaining binary on every bad byte (seconds for a
  binary file dumped into the terminal).
  """
  def utf8_safe(bin) when is_binary(bin) do
    case :unicode.characters_to_binary(bin, :utf8, :utf8) do
      result when is_binary(result) -> result
      _ -> sanitize_utf8(bin, []) |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  # Fast path above handles all-valid input without allocating a list.
  # Here we keep an iolist (reversed) so malformed bytes cost O(1) each.
  defp sanitize_utf8(<<>>, acc), do: acc

  defp sanitize_utf8(<<byte, rest::binary>>, acc) when byte < 0x80,
    do: sanitize_utf8(rest, [byte | acc])

  defp sanitize_utf8(<<b1, b2, rest::binary>>, acc)
       when b1 in 0xC2..0xDF and cont?(b2),
       do: sanitize_utf8(rest, [<<b1, b2>> | acc])

  defp sanitize_utf8(<<b1, b2, b3, rest::binary>>, acc)
       when b1 in 0xE0..0xEF and cont?(b2) and cont?(b3) and
              (b1 != 0xE0 or b2 >= 0xA0) and (b1 != 0xED or b2 <= 0x9F),
       do: sanitize_utf8(rest, [<<b1, b2, b3>> | acc])

  defp sanitize_utf8(<<b1, b2, b3, b4, rest::binary>>, acc)
       when b1 in 0xF0..0xF4 and cont?(b2) and cont?(b3) and cont?(b4) and
              (b1 != 0xF0 or b2 >= 0x90) and (b1 != 0xF4 or b2 <= 0x8F),
       do: sanitize_utf8(rest, [<<b1, b2, b3, b4>> | acc])

  defp sanitize_utf8(<<_bad, rest::binary>>, acc),
    do: sanitize_utf8(rest, [@utf8_replacement | acc])

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
