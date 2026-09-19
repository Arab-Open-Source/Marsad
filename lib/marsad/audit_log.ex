defmodule Marsad.AuditLog do
  use Ecto.Schema
  import Ecto.Changeset

  schema "audit_logs" do
    belongs_to :server, Marsad.Fleet.Server
    field :action, :string
    field :container, :string
    field :details, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:server_id, :action, :container, :details])
    |> validate_required([:server_id, :action])
    |> validate_length(:action, max: 64)
    |> validate_length(:container, max: 255)
    |> foreign_key_constraint(:server_id)
  end
end
