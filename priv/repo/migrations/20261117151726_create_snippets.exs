defmodule Marsad.Repo.Migrations.CreateSnippets do
  use Ecto.Migration

  def change do
    create table(:snippets) do
      add :name, :string, null: false
      add :description, :string, default: ""
      add :command, :string, null: false
      add :category, :string, default: "general"
      # JSON-encoded list of variable names, e.g. ["host", "path"].
      add :variables, :string, default: "[]"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:snippets, [:name])
  end
end
