defmodule Marsad.Files do
  @moduledoc """
  File browser domain — pure helpers and SFTP operations used by the desktop.
  Keeps `DesktopLive` thin and testable.
  """

  alias Marsad.Fleet
  alias Marsad.Helpers.Text

  @image_extensions ~w[.png .jpg .jpeg .gif .webp .bmp .svg .ico .tiff .avif]
  @svg_extension ".svg"
  @max_image_size 15_000_000
  @max_svg_size 1_000_000

  def filtered_entries(entries, filter) do
    filter = String.downcase(String.trim(filter || ""))

    Enum.filter(entries, fn entry ->
      filter == "" or String.contains?(String.downcase(entry.name), filter)
    end)
  end

  def editor_id(prefix, path), do: "code-#{prefix}-" <> Base.url_encode64(path, padding: false)

  def write_result({:ok, _}), do: :ok
  def write_result(:ok), do: :ok
  def write_result({:error, _} = error), do: error

  def search_remote_files(server_id, filter) do
    with {:ok, home} <- Fleet.home_dir(server_id) do
      pattern = Text.shell_quote("*#{filter}*")
      root = Text.shell_quote(home)

      command =
        "find #{root} -xdev -type f -iname #{pattern} -printf '%p|%s|%T@\\n' 2>/dev/null | head -200"

      try do
        case Fleet.exec(server_id, command, 10_000) do
          {:ok, %{stdout: output}} ->
            output |> String.split("\n", trim: true) |> Enum.flat_map(&parse_search_entry/1)

          _ ->
            []
        end
      rescue
        _ -> []
      catch
        _, _ -> []
      end
    else
      _ -> []
    end
  end

  defp parse_search_entry(line) do
    case String.split(line, "|", parts: 3) do
      [path, size, mtime] ->
        [
          %{
            name: Path.basename(path),
            path: path,
            type: :file,
            size: parse_integer(size),
            mtime: trunc(parse_float(mtime))
          }
        ]

      _ ->
        []
    end
  end

  defp parse_integer(value) do
    case Integer.parse(String.trim(value)) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_float(value) do
    value = String.trim(value)

    case Float.parse(value) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  def build_preview(path, data) do
    ext = String.downcase(Path.extname(path))
    size = byte_size(data)

    cond do
      ext == @svg_extension and size <= @max_svg_size ->
        %{
          path: path,
          kind: :image,
          data: data,
          inline?: true,
          text: "(image preview)",
          full_text: data,
          truncated?: false,
          language: "image",
          editing: false
        }

      ext in @image_extensions and ext != @svg_extension and size <= @max_image_size ->
        %{
          path: path,
          kind: :image,
          data: Base.encode64(data),
          inline?: false,
          mime: image_mime(ext),
          text: "(image preview)",
          full_text: data,
          truncated?: false,
          language: "image",
          editing: false
        }

      String.valid?(data) ->
        %{
          path: path,
          kind: :text,
          text: data,
          full_text: data,
          truncated?: byte_size(data) >= 200_000,
          language: code_language(path),
          editing: true
        }

      true ->
        %{
          path: path,
          kind: :binary,
          text: "(binary file — preview unavailable)",
          full_text: data,
          truncated?: false,
          language: "text/plain",
          editing: false
        }
    end
  end

  defp image_mime(ext) do
    case ext do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".bmp" -> "image/bmp"
      ".svg" -> "image/svg+xml"
      ".ico" -> "image/x-icon"
      ".tiff" -> "image/tiff"
      ".avif" -> "image/avif"
      _ -> "image/png"
    end
  end

  def code_language(path) when is_binary(path) do
    case String.downcase(Path.extname(path)) do
      ".sh" ->
        "shell"

      ".bash" ->
        "shell"

      ".zsh" ->
        "shell"

      ".service" ->
        "properties"

      ".timer" ->
        "properties"

      ".socket" ->
        "properties"

      ".mount" ->
        "properties"

      ".target" ->
        "properties"

      ".conf" ->
        "nginx"

      ".config" ->
        "nginx"

      ".yml" ->
        "yaml"

      ".yaml" ->
        "yaml"

      ".json" ->
        "javascript"

      ".js" ->
        "javascript"

      ".ts" ->
        "javascript"

      ".jsx" ->
        "javascript"

      ".tsx" ->
        "javascript"

      ".css" ->
        "css"

      ".scss" ->
        "css"

      ".less" ->
        "css"

      ".html" ->
        "htmlmixed"

      ".htm" ->
        "htmlmixed"

      ".xml" ->
        "xml"

      ".md" ->
        "markdown"

      ".markdown" ->
        "markdown"

      ".py" ->
        "python"

      ".rb" ->
        "ruby"

      ".go" ->
        "go"

      ".php" ->
        "php"

      ".rs" ->
        "rust"

      ".ex" ->
        "erlang"

      ".exs" ->
        "erlang"

      ".toml" ->
        "toml"

      ".ini" ->
        "properties"

      ".env" ->
        "properties"

      ".dockerfile" ->
        "dockerfile"

      ".sql" ->
        "sql"

      ".gradle" ->
        "groovy"

      ".kt" ->
        "text/x-kotlin"

      ".kts" ->
        "text/x-kotlin"

      ".java" ->
        "text/x-java"

      ".cs" ->
        "text/x-csharp"

      ".cr" ->
        "crystal"

      ".crystal" ->
        "crystal"

      _ ->
        cond do
          String.contains?(path, "nginx") -> "nginx"
          String.ends_with?(path, ".service") -> "properties"
          true -> "text/plain"
        end
    end
  end

  def code_language(_), do: "text/plain"
end
