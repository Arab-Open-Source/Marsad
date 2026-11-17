defmodule Marsad.Snippets do
  @moduledoc """
  Saved commands / runbooks with `{{variable}}` placeholders.

  Variables are stored as a JSON list of names and substituted at run time.
  All functions are pure except the CRUD calls, which never raise on bad input.
  """

  import Ecto.Query, warn: false

  alias Marsad.Repo
  alias Marsad.Snippets.Snippet

  def list_snippets do
    Snippet |> order_by([s], asc: s.category, asc: s.name) |> Repo.all()
  end

  def get_snippet!(id), do: Repo.get!(Snippet, id)

  def change_snippet(%Snippet{} = snippet, attrs \\ %{}), do: Snippet.changeset(snippet, attrs)

  def create_snippet(attrs) do
    %Snippet{}
    |> Snippet.changeset(prepare_attrs(attrs))
    |> Repo.insert()
  end

  def update_snippet(%Snippet{} = snippet, attrs) do
    snippet
    |> Snippet.changeset(prepare_attrs(attrs))
    |> Repo.update()
  end

  def delete_snippet(%Snippet{} = snippet), do: Repo.delete(snippet)

  @doc "Finds `{{name}}` placeholders in a command, in order of appearance."
  def variables_in(command) when is_binary(command) do
    Regex.scan(~r/\{\{([a-zA-Z0-9_.-]+)\}\}/, command)
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.uniq()
  end

  def variables_in(_), do: []

  @doc """
  Substitutes `{{name}}` placeholders with `values` (string or atom keys).

  Placeholders without a value are left intact so a missing variable is
  visible instead of silently producing an empty argument.
  """
  def render(command, values) when is_binary(command) and is_map(values) do
    normalized = for {k, v} <- values, into: %{}, do: {to_string(k), to_string(v || "")}

    Regex.replace(~r/\{\{([a-zA-Z0-9_.-]+)\}\}/, command, fn whole, name ->
      Map.get(normalized, name, whole)
    end)
  end

  def render(command, _values), do: command

  # Accept the variables textarea as either a JSON list or comma-separated
  # names, and auto-fill it from the command when left blank.
  defp prepare_attrs(attrs) when is_map(attrs) do
    attrs = for {k, v} <- attrs, into: %{}, do: {to_string(k), v}
    command = Map.get(attrs, "command", "")

    variables =
      case Map.get(attrs, "variables") do
        nil -> variables_in(command)
        "" -> variables_in(command)
        raw when is_binary(raw) -> normalize_variables(raw, command)
        other -> other
      end

    Map.put(attrs, "variables", Jason.encode!(variables))
  end

  defp prepare_attrs(attrs), do: attrs

  defp normalize_variables(raw, command) do
    case Jason.decode(raw) do
      {:ok, list} when is_list(list) ->
        Enum.map(list, &to_string/1)

      _ ->
        raw
        |> String.split(~r/[\s,]+/, trim: true)
        |> then(fn list -> if list == [], do: variables_in(command), else: list end)
    end
  end
end
