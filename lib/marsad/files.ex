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

  # -- Smart remote search -------------------------------------------------
  #
  # Query language (all matching is case-insensitive):
  #
  #   word            must appear in the full path (AND semantics)
  #   "exact phrase"  literal substring (quotes)
  #   -word           must NOT appear
  #   ext:conf,json   file extension filter (or the `*.conf` shorthand)
  #   type:d          directories only (`type:f` files only = default, `type:a` both)
  #   size:>10M       size bounds (`>`, `<`, `>=`, `<=`, `=`; k/m/g suffixes)
  #   depth:3         limit recursion depth
  #   limit:50        result cap (default 200, max 500)
  #   all             also search heavy dirs (.git, node_modules, .cache…)
  #
  # `*` inside a term acts as a wildcard; results are ranked
  # (exact name > prefix > name-substring > path-only) and capped.

  @default_search_limit 200
  @max_search_limit 500
  @search_exec_timeout 15_000

  @prune_dirs ~w(.git node_modules .cache vendor .npm .cargo .rustup)

  @doc """
  Runs a smart recursive search under the remote home directory.

  Returns `%{entries: [...], truncated?: bool, query: map}`. Ranking and
  capping happen here so callers just render. Never raises — errors yield
  an empty result.
  """
  def search_remote(server_id, filter) do
    query = parse_query(filter)
    empty = %{entries: [], truncated?: false, query: query}

    if query.matchers? do
      with {:ok, home} <- Fleet.home_dir(server_id),
           {:ok, %{stdout: output}} <-
             Fleet.exec(server_id, search_command(home, query), @search_exec_timeout) do
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&parse_search_line/1)
        |> rank_results(query)
        |> cap_results(query.limit)
        |> then(fn {entries, truncated?} ->
          %{entries: entries, truncated?: truncated?, query: query}
        end)
      else
        _ -> empty
      end
    else
      empty
    end
  rescue
    _ -> %{entries: [], truncated?: false, query: parse_query(filter)}
  catch
    _, _ -> %{entries: [], truncated?: false, query: parse_query(filter)}
  end

  @doc "Same as `search_remote/2` but returns only the ranked entry list."
  def search_remote_files(server_id, filter) do
    search_remote(server_id, filter).entries
  end

  @doc """
  Parses a search string into a query map. Pure — unit tested.

  Always returns `matchers?: true/false`; when `false` the search is a
  no-op (avoids `find` calls that would list the whole home directory).
  """
  def parse_query(filter) do
    trimmed = String.trim(filter || "")
    tokens = tokenize(trimmed)

    query =
      Enum.reduce(tokens, fresh_query(), fn token, acc ->
        {negated?, core} =
          if String.starts_with?(token, "-") and byte_size(token) > 1 do
            {true, String.slice(token, 1..-1//1)}
          else
            {false, token}
          end

        cond do
          core == "" ->
            acc

          !negated? and core == "all" ->
            %{acc | prune?: false}

          !negated? and String.starts_with?(core, "*.") and byte_size(core) > 3 ->
            add_ext(acc, String.slice(core, 2..-1//1))

          !negated? and directive?(core) ->
            {key, value} = split_directive(core)
            apply_directive(acc, key, value, token)

          quoted?(core) ->
            text = slice_quoted(core)

            if negated?,
              do: %{acc | exclude: [text | acc.exclude]},
              else: %{acc | phrases: [text | acc.phrases]}

          negated? ->
            %{acc | exclude: [core | acc.exclude]}

          true ->
            %{acc | terms: [core | acc.terms]}
        end
      end)

    %{
      query
      | raw: trimmed,
        matchers?: query.terms != [] or query.phrases != [] or query.exts != []
    }
  end

  @doc """
  Returns the raw token surfaces of a filter string, in order
  (quotes/directives intact). Used to render removable filter chips.
  """
  def query_tokens(filter) do
    filter |> Kernel.||("") |> String.trim() |> tokenize()
  end

  @doc """
  Removes the first occurrence of `token` from a filter string and
  rejoins the rest. Pure — unit tested.
  """
  def remove_token(filter, token) do
    filter
    |> query_tokens()
    |> List.delete(token)
    |> Enum.join(" ")
  end

  @doc """
  Builds UI chip descriptors (`%{token:, class:}`) for a filter string.
  Color-codes by kind: red = exclude, amber = phrase, violet = directive.
  Pure — unit tested.
  """
  def filter_chips(filter) do
    filter
    |> query_tokens()
    |> Enum.map(fn token ->
      %{
        token: token,
        class:
          cond do
            String.starts_with?(token, "-") ->
              "border-red-500/30 bg-red-500/10 text-red-600 hover:bg-red-500/20 dark:text-red-300"

            String.starts_with?(token, "\"") ->
              "border-amber-500/30 bg-amber-500/10 text-amber-700 hover:bg-amber-500/20 dark:text-amber-300"

            String.contains?(token, ":") ->
              "border-violet-500/30 bg-violet-500/10 text-violet-700 hover:bg-violet-500/20 dark:text-violet-300"

            true ->
              "border-base-content/15 bg-base-content/[0.05] text-base-content/70 hover:bg-base-content/10"
          end
      }
    end)
  end

  @doc "Builds the safe `find` shell command for a parsed query. Pure — unit tested."
  def search_command(home, query) do
    root = Text.shell_quote(home)

    opts =
      ["-xdev"] ++
        if(query.maxdepth, do: ["-maxdepth #{query.maxdepth}"], else: [])

    prune =
      if query.prune? do
        paths =
          @prune_dirs
          |> Enum.map(&" -path #{Text.shell_quote("*/" <> &1)}")
          |> Enum.join(" -o")

        ["\\(#{paths} \\) -prune -o"]
      else
        []
      end

    type =
      case query.entry_type do
        :dir -> ["-type d"]
        :both -> ["\\( -type f -o -type d \\)"]
        _ -> ["-type f"]
      end

    preds =
      Enum.map(query.terms ++ query.phrases, &"-ipath #{find_pattern(&1)}") ++
        Enum.map(query.exclude, &"! -ipath #{find_pattern(&1)}") ++
        ext_predicates(query.exts) ++
        size_predicates(query.min_size, query.max_size)

    group = "\\( #{Enum.join(type ++ preds, " ")} \\)"

    parts =
      ["find #{root}"] ++ opts ++ prune ++ [group] ++ ["-printf '%y|%s|%T@|%p\\n' 2>/dev/null"]

    Enum.join(parts, " ") <> " | head -#{query.limit + 1}"
  end

  @doc "Ranks parsed entries best-first. Pure — unit tested."
  def rank_results(entries, query) do
    terms = Enum.map(query.terms ++ query.phrases, &String.downcase/1)
    raw = String.downcase(String.trim(query.raw))

    Enum.sort_by(entries, fn entry ->
      name = String.downcase(entry.name)
      path = String.downcase(entry.path)
      depth = path |> String.split("/", trim: true) |> length()

      score =
        cond do
          raw != "" and name == raw -> 0
          Enum.any?(terms, &String.starts_with?(name, &1)) -> 1
          Enum.any?(terms, &String.contains?(name, &1)) -> 2
          true -> 3
        end

      {score, depth, name, path}
    end)
  end

  @doc "Parses one `find -printf` line (new `y|s|t|p` or legacy `p|s|t` format)."
  def parse_search_line(line) do
    case parse_new_line(line) do
      nil ->
        case parse_legacy_line(line) do
          nil -> []
          entry -> [entry]
        end

      entry ->
        [entry]
    end
  end

  # -- query internals --------------------------------------------------------

  defp fresh_query do
    %{
      raw: "",
      terms: [],
      phrases: [],
      exclude: [],
      exts: [],
      entry_type: :file,
      min_size: nil,
      max_size: nil,
      maxdepth: nil,
      limit: @default_search_limit,
      prune?: true,
      matchers?: false
    }
  end

  # Splits on whitespace, keeping "quoted phrases" (optionally `-` negated)
  # as one token.
  defp tokenize(filter) do
    filter
    |> String.trim()
    |> then(fn s ->
      Regex.scan(~r/-?"[^"]*"|\S+/, s) |> Enum.map(&hd/1)
    end)
  end

  defp quoted?(token) do
    byte_size(token) >= 2 and String.starts_with?(token, "\"") and
      String.ends_with?(token, "\"")
  end

  defp slice_quoted(token), do: String.slice(token, 1..-2//1)

  defp directive?(core) do
    Regex.match?(~r/\A[a-z]+:.*\z/s, core)
  end

  defp split_directive(core) do
    [_, key, value] = Regex.run(~r/\A([a-z]+):(.*)\z/s, core)
    {key, value}
  end

  defp add_ext(query, ext) do
    ext = ext |> String.trim() |> String.trim_leading(".") |> String.downcase()

    if ext == "", do: query, else: %{query | exts: [ext | query.exts]}
  end

  defp apply_directive(query, "ext", value, _token) do
    value |> String.split(",", trim: true) |> Enum.reduce(query, &add_ext(&2, &1))
  end

  defp apply_directive(query, "type", value, _token) do
    case String.downcase(String.trim(value)) do
      v when v in ["d", "dir", "dirs", "directory", "folder", "folders"] ->
        %{query | entry_type: :dir}

      v when v in ["a", "all", "both"] ->
        %{query | entry_type: :both}

      _ ->
        %{query | entry_type: :file}
    end
  end

  defp apply_directive(query, "size", value, _token) do
    case parse_size_bound(String.trim(value)) do
      {:min, n} -> %{query | min_size: n}
      {:max, n} -> %{query | max_size: n}
      {:eq, n} -> %{query | min_size: n, max_size: n}
      # Unparseable bound — keep it as a literal term so nothing is lost.
      :error -> %{query | terms: ["size:#{value}" | query.terms]}
    end
  end

  defp apply_directive(query, "depth", value, _token) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> %{query | maxdepth: min(n, 32)}
      _ -> query
    end
  end

  defp apply_directive(query, "limit", value, _token) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> %{query | limit: min(n, @max_search_limit)}
      _ -> query
    end
  end

  defp apply_directive(query, _key, _value, token) do
    # Unknown `key:` — treat literally so nothing is silently dropped.
    %{query | terms: [token | query.terms]}
  end

  defp parse_size_bound(value) do
    with [_, op, num] <- Regex.run(~r/\A(>=|<=|>|<|=)?\s*(\d+(?:\.\d+)?\s*[kKmMgG]?)\s*\z/, value),
         n when not is_nil(n) <- parse_size_bytes(num) do
      case op do
        ">" -> {:min, n + 1}
        ">=" -> {:min, n}
        "<" -> {:max, n - 1}
        "<=" -> {:max, n}
        _ -> {:eq, n}
      end
    else
      _ -> :error
    end
  end

  defp parse_size_bytes(num) do
    case Regex.run(~r/\A(\d+(?:\.\d+)?)\s*([kKmMgG]?)\z/, String.trim(num)) do
      [_, digits, suffix] ->
        mult =
          case String.downcase(suffix) do
            "k" -> 1_024
            "m" -> 1_048_576
            "g" -> 1_073_741_824
            _ -> 1
          end

        case Float.parse(digits) do
          {f, ""} -> trunc(f * mult)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # find shell-pattern for a user token: escape glob chars except `*`
  # (kept as a wildcard), then match anywhere in the path.
  defp find_pattern(token) do
    escaped =
      token
      |> String.replace("\\", "\\\\")
      |> String.replace("?", "\\?")
      |> String.replace("[", "\\[")
      |> String.replace("]", "\\]")

    Text.shell_quote("*#{escaped}*")
  end

  defp ext_predicates([]), do: []

  defp ext_predicates(exts) do
    inner = exts |> Enum.map(&"-iname #{Text.shell_quote("*." <> &1)}") |> Enum.join(" -o")
    ["\\( #{inner} \\)"]
  end

  defp size_predicates(nil, nil), do: []

  defp size_predicates(min, max) do
    if(min, do: ["-size +#{min}c"], else: []) ++
      if max, do: ["-size -#{max}c"], else: []
  end

  defp cap_results(entries, limit) do
    if length(entries) > limit do
      {Enum.take(entries, limit), true}
    else
      {entries, false}
    end
  end

  defp parse_new_line(line) do
    case String.split(line, "|", parts: 4) do
      [y, size, mtime, path] when y in ["f", "d", "l"] ->
        with {n, _} <- Integer.parse(String.trim(size)),
             {f, _} <- Float.parse(String.trim(mtime)),
             true <- String.starts_with?(path, "/") do
          %{
            name: Path.basename(path),
            path: path,
            type: entry_type(y),
            size: n,
            mtime: trunc(f)
          }
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_legacy_line(line) do
    case String.split(line, "|", parts: 3) do
      [path, size, mtime] ->
        with true <- String.starts_with?(path, "/"),
             {n, _} <- Integer.parse(String.trim(size)),
             {f, _} <- Float.parse(String.trim(mtime)) do
          %{name: Path.basename(path), path: path, type: :file, size: n, mtime: trunc(f)}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp entry_type("d"), do: :dir
  defp entry_type("l"), do: :link
  defp entry_type(_), do: :file

  @max_text_preview 200_000

  def build_preview(path, data) do
    ext = String.downcase(Path.extname(path))
    size = byte_size(data)

    cond do
      # SVG is never inlined (XSS via <script>); served as base64 <img> like other images.
      ext == @svg_extension and size <= @max_svg_size ->
        %{
          path: path,
          kind: :image,
          data: Base.encode64(data),
          inline?: false,
          mime: "image/svg+xml",
          text: "(image preview)",
          full_text: nil,
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
          full_text: nil,
          truncated?: false,
          language: "image",
          editing: false
        }

      String.valid?(data) ->
        truncated? = byte_size(data) > @max_text_preview
        shown = if truncated?, do: binary_part(data, 0, @max_text_preview), else: data

        %{
          path: path,
          kind: :text,
          text: shown,
          full_text: shown,
          truncated?: truncated?,
          language: code_language(path),
          editing: not truncated?
        }

      true ->
        %{
          path: path,
          kind: :binary,
          text: "(binary file — preview unavailable)",
          full_text: nil,
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
        "elixir"

      ".exs" ->
        "elixir"

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
