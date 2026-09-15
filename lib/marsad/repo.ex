defmodule Marsad.Repo do
  use Ecto.Repo,
    otp_app: :marsad,
    adapter: Ecto.Adapters.SQLite3
end
