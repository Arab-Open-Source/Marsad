defmodule MarsadWeb.LiveAuthDirectTest do
  use Marsad.DataCase, async: false

  alias MarsadWeb.LiveAuth

  defp socket do
    %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
  end

  test "ensure sends fresh installs to setup, guests to login" do
    assert {:halt, %{redirected: {:redirect, %{to: "/setup"}}}} =
             LiveAuth.on_mount(:ensure, %{}, %{}, socket())

    {:ok, admin} =
      Marsad.Accounts.register_admin(%{
        "username" => "first-#{System.unique_integer([:positive])}",
        "password" => "password1234"
      })

    assert {:halt, %{redirected: {:redirect, %{to: "/login"}}}} =
             LiveAuth.on_mount(:ensure, %{}, %{}, socket())

    assert {:halt, _} = LiveAuth.on_mount(:ensure, %{}, %{"admin_id" => -1}, socket())

    assert {:cont, sock} = LiveAuth.on_mount(:ensure, %{}, %{"admin_id" => admin.id}, socket())
    assert sock.assigns.current_admin.id == admin.id
  end

  test "guest continues strangers and halts members" do
    assert {:cont, _} = LiveAuth.on_mount(:guest, %{}, %{}, socket())
    assert {:cont, _} = LiveAuth.on_mount(:guest, %{}, %{"admin_id" => -1}, socket())

    {:ok, admin} =
      Marsad.Accounts.register_admin(%{
        "username" => "guest-#{System.unique_integer([:positive])}",
        "password" => "password1234"
      })

    assert {:halt, _} = LiveAuth.on_mount(:guest, %{}, %{"admin_id" => admin.id}, socket())
  end
end

defmodule Marsad.SSH.SshAdapterExtraTest do
  use ExUnit.Case, async: true

  alias Marsad.SSH.SshAdapter

  test "upload_file fails cleanly for missing local file" do
    assert {:error, _} =
             SshAdapter.upload_file(
               :no_channel,
               "/remote/x",
               "/no/such/file-#{System.unique_integer()}"
             )
  end

  test "make_dir handles root without channel and errors nested" do
    assert :ok = SshAdapter.make_dir(:no_channel, "/")
    assert {:error, _} = SshAdapter.make_dir(:no_channel, "/tmp/a/b")
  end
end
