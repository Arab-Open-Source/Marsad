defmodule Marsad.SSH.SshAdapterTest do
  use ExUnit.Case, async: false

  alias Marsad.SSH.SshAdapter

  test "close is always :ok, even for garbage" do
    assert SshAdapter.close(nil) == :ok
    assert SshAdapter.close(:not_a_conn) == :ok
  end

  test "fingerprint returns error without crashing" do
    assert {:error, _} = SshAdapter.fingerprint(nil)
    assert {:error, _} = SshAdapter.fingerprint(:not_a_conn)
  end

  test "with_sftp returns error for bad connection" do
    assert {:error, _} = SshAdapter.with_sftp(:not_a_conn, fn _ -> :ok end)
  end

  test "connect fails fast for closed port and cleans temp key files" do
    before = Path.wildcard(Path.join(System.tmp_dir!(), "marsad-key-*"))

    assert {:error, _} =
             SshAdapter.connect(%{
               host: "127.0.0.1",
               port: 1,
               username: "root",
               auth_type: "key",
               secret:
                 "-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY-----"
             })

    after_files = Path.wildcard(Path.join(System.tmp_dir!(), "marsad-key-*"))
    assert length(after_files) <= length(before)
  end

  test "exec returns error for bad connection without hanging" do
    assert {:error, _} = SshAdapter.exec(:not_a_conn, "echo hi", 500)
  end

  test "list_dir/read/write/delete report errors for bad channels" do
    chan = :not_a_channel
    assert {:error, _} = SshAdapter.list_dir(chan, "/tmp")
    assert {:error, _} = SshAdapter.read_file(chan, "/tmp/x", 10)
    assert {:error, _} = SshAdapter.read_file(chan, "/tmp/x", :infinity)
    assert {:error, _} = SshAdapter.write_file(chan, "/tmp/x", "data")
    assert {:error, _} = SshAdapter.delete_file(chan, "/tmp/x")
    assert {:error, _} = SshAdapter.delete_dir(chan, "/tmp/x")
    assert {:error, _} = SshAdapter.home_dir(chan)
    assert {:error, _} = SshAdapter.make_dir(chan, "/tmp/a/b")
  end

  test "shell primitives fail safely on bad connections" do
    assert {:error, _} = SshAdapter.open_shell(:not_a_conn, 80, 24)
    assert {:error, _} = SshAdapter.shell_send(:not_a_conn, :no_channel, "x")
    assert :ok = SshAdapter.shell_resize(:not_a_conn, :no_channel, 80, 24)
    assert :ok = SshAdapter.shell_close(:not_a_conn, :no_channel)
    assert :ok = SshAdapter.shell_eof(:not_a_conn, :no_channel)
  end
end
