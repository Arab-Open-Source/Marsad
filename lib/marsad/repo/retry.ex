defmodule Marsad.Repo.Retry do
  @moduledoc false

  alias Marsad.Fleet.Server

  def retry_settings(fun, attempts \\ 5)
  def retry_settings(_fun, 0), do: :error

  def retry_settings(fun, attempts) do
    case fun.() do
      {:ok, _} -> :ok
      _ -> retry_settings_after(fun, attempts)
    end
  rescue
    _ -> retry_settings_after(fun, attempts)
  catch
    _, _ -> retry_settings_after(fun, attempts)
  end

  defp retry_settings_after(fun, attempts) do
    Process.sleep(25 * (6 - attempts))
    retry_settings(fun, attempts - 1)
  end

  def retry_db(fun, attempts \\ 5)
  def retry_db(_fun, 0), do: {:error, :busy}

  def retry_db(fun, attempts) do
    case fun.() do
      {:ok, _} = ok ->
        ok

      {:error, %Ecto.Changeset{}} = err ->
        err

      {:error, reason} = err ->
        if busy_error?(reason), do: retry_db_after(fun, attempts), else: err

      other ->
        other
    end
  rescue
    e -> if busy_error?(e), do: retry_db_after(fun, attempts), else: {:error, e}
  catch
    _, reason -> if busy_error?(reason), do: retry_db_after(fun, attempts), else: {:error, reason}
  end

  defp retry_db_after(fun, attempts) do
    Process.sleep(25 * (6 - attempts))
    retry_db(fun, attempts - 1)
  end

  defp busy_error?(%Exqlite.Error{message: msg}) when is_binary(msg),
    do: String.contains?(msg, "busy") or String.contains?(msg, "locked")

  defp busy_error?(%{message: msg}) when is_binary(msg),
    do: String.contains?(msg, "busy") or String.contains?(msg, "locked")

  defp busy_error?(msg) when is_binary(msg),
    do: String.contains?(msg, "busy") or String.contains?(msg, "locked")

  defp busy_error?(other), do: String.contains?(inspect(other), "busy")

  # Helper for Fleet.Server changeset fallback
  def busy_changeset do
    %Ecto.Changeset{data: %Server{}}
  end
end
