defmodule Marsad.Snippets.Snippet do
  @moduledoc "A saved command/runbook with `{{variables}}` placeholders."

  use Ecto.Schema
  import Ecto.Changeset

  schema "snippets" do
    field :name, :string
    field :description, :string
    field :command, :string
    field :category, :string
    # JSON-encoded list of variable names, e.g. ["host", "path"].
    field :variables, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(snippet, attrs) do
    snippet
    |> cast(attrs, [:name, :description, :command, :category, :variables])
    |> validate_required([:name, :command])
    |> validate_length(:name, max: 80)
    |> validate_length(:command, max: 8_000)
    |> unique_constraint(:name)
  end

  @doc "Decodes the stored JSON variable list (never raises)."
  def variable_list(%__MODULE__{variables: value}) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end

  def variable_list(_), do: []
end
