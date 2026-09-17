defmodule Marsad.Repo do
  use Ecto.Repo,
    otp_app: :marsad,
    adapter: Ecto.Adapters.SQLite3,
    # WAL lets concurrent readers/writers coexist; a generous busy timeout
    # makes "database is locked" contention practically disappear.
    journal_mode: :wal,
    busy_timeout: 5_000
end
