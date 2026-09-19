defmodule Marsad.Repo.RetryTest do
  use Marsad.DataCase, async: false

  alias Marsad.Repo.Retry

  test "retry_settings returns :ok on success" do
    assert Retry.retry_settings(fn -> {:ok, 1} end) == :ok
  end

  test "retry_settings exhausts attempts on persistent failure" do
    assert Retry.retry_settings(fn -> {:error, :boom} end, 2) == :error
    assert_raise RuntimeError, fn -> Retry.retry_settings(fn -> raise "nope" end, 1) end
  end

  test "retry_db passes through ok and changeset errors without retry" do
    assert Retry.retry_db(fn -> {:ok, 1} end) == {:ok, 1}

    cs = %Ecto.Changeset{data: %Marsad.Fleet.Server{}}
    assert Retry.retry_db(fn -> {:error, cs} end) == {:error, cs}
    assert Retry.retry_db(fn -> {:error, :invalid_pid} end) == {:error, :invalid_pid}
    assert Retry.retry_db(fn -> :weird end) == :weird
  end

  test "retry_db retries busy sqlite errors then gives up" do
    busy = %Exqlite.Error{message: "database is locked"}
    assert Retry.retry_db(fn -> {:error, busy} end, 2) == {:error, :busy}

    assert Retry.retry_db(
             fn -> raise %Exqlite.Error{message: "database is locked"} end,
             1
           ) == {:error, :busy}
  end

  test "retry_db does not swallow programming errors" do
    assert_raise RuntimeError, fn ->
      Retry.retry_db(fn -> raise %RuntimeError{message: "bug"} end, 1)
    end
  end

  test "busy_changeset returns empty server changeset" do
    assert %Ecto.Changeset{data: %Marsad.Fleet.Server{}} = Retry.busy_changeset()
  end
end
