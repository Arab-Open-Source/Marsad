defmodule Marsad.AuditLog do
  use Ecto.Schema
  import Ecto.Changeset

  schema "audit_logs" do
    field :server_id, :integer
    field :action, :string
    field :container, :string
    field :details, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:server_id, :action, :container, :details])
    |> validate_required([:server_id, :action])
  end
end
