defmodule Marsad.Fleet.ServicesNginxCertsTest do
  use Marsad.DataCase, async: false

  alias Marsad.Fleet.Services
  alias MarsadWeb.FileSessionStub

  @dump """
  # global comment
  events {}
  http {
    server {
      listen 80;
      server_name example.com www.example.com;
    }
    server {
      listen 443 ssl;
      listen [::]:443 ssl;
      server_name shop.example.com;
      ssl_certificate /etc/letsencrypt/live/x/fullchain.pem;
      location / {
        proxy_pass http://127.0.0.1:3000;
      }
    }
    server {
      listen 8443 ssl;
      server_name "*.cdn.example.com" _;
    }
    server {
      # no ssl here
      listen 8080;
      server_name internal.local;
    }
  }
  """

  test "parse_nginx_vhosts extracts only HTTPS vhosts" do
    assert [
             %{domains: ["shop.example.com"], port: 443},
             %{domains: ["*.cdn.example.com"], port: 8443}
           ] = Services.parse_nginx_vhosts(@dump)
  end

  test "parse_nginx_vhosts tolerates garbage and nesting" do
    assert Services.parse_nginx_vhosts("") == []
    assert Services.parse_nginx_vhosts(nil) == []
    assert Services.parse_nginx_vhosts("server { listen 80; ") == []
    # Unclosed blocks and non-ssl servers yield nothing checkable.
    assert Services.parse_nginx_vhosts("events {}\n") == []

    assert Services.parse_nginx_vhosts(
             "server {\nlisten 80;\nserver_name plain.example.com;\n}\n"
           ) == []
  end

  test "vhost_targets dedupes and rewrites wildcards" do
    vhosts = [
      %{domains: ["a.com", "*.x.com", "a.com"], port: 443},
      %{domains: ["b.com"], port: 8443}
    ]

    assert [{"a.com", 443, false}, {"www.x.com", 443, true}, {"b.com", 8443, false}] =
             Services.vhost_targets(vhosts)
  end

  test "cert_check_command is a guarded loop with quoted domains" do
    cmd = Services.cert_check_command([{"a.com", 443, false}, {"evil'; reboot #", 443, false}])
    assert cmd =~ "__MARSAD_NO_OPENSSL__"
    assert cmd =~ "chk 'a.com' 443"
    # Injection stays inside single quotes.
    assert cmd =~ "chk 'evil'\\''; reboot #' 443"

    for chunk <- String.split(cmd) do
      refute String.starts_with?(chunk, ";")
    end
  end

  test "parse_cert_date handles openssl format strictly" do
    assert {:ok, %DateTime{year: 2026, month: 11, day: 3, hour: 12}} =
             Services.parse_cert_date("Nov  3 12:00:00 2026 GMT")

    assert {:ok, %DateTime{month: 1, day: 15}} =
             Services.parse_cert_date("Jan 15 00:00:00 2027 GMT")

    assert :error = Services.parse_cert_date("Feb 30 00:00:00 2026 GMT")
    assert :error = Services.parse_cert_date("Foo  3 12:00:00 2026 GMT")
    assert :error = Services.parse_cert_date("garbage")
    assert :error = Services.parse_cert_date("")
    assert :error = Services.parse_cert_date(nil)
  end

  test "thresholds classify expiry" do
    assert Services.cert_thresholds() == %{warning: 30, critical: 14}

    soon = openssl_date(DateTime.add(DateTime.utc_now(), 5 * 86_400, :second))
    later = openssl_date(DateTime.add(DateTime.utc_now(), 40 * 86_400, :second))
    past = openssl_date(DateTime.add(DateTime.utc_now(), -2 * 86_400, :second))

    out = "a.com|443|#{soon}\nb.com|443|#{later}\nc.com|443|#{past}\nd.com|443|\n"

    assert [
             %{domain: "a.com", status: :critical},
             %{domain: "b.com", status: :ok},
             %{domain: "c.com", status: :critical, note: "expired"},
             %{domain: "d.com", status: :unknown}
           ] =
             Services.parse_cert_results(out, [
               {"a.com", 443, false},
               {"b.com", 443, false},
               {"c.com", 443, false},
               {"d.com", 443, false}
             ])

    assert Services.parse_cert_results("__MARSAD_NO_OPENSSL__\n", [{"a.com", 443, false}]) == []

    assert %{total: 4, critical: 2, warning: 0, unknown: 1} =
             Services.cert_summary(
               Services.parse_cert_results(out, [
                 {"a.com", 443, false},
                 {"b.com", 443, false},
                 {"c.com", 443, false},
                 {"d.com", 443, false}
               ])
             )
  end

  test "cert_check runs dump then loop via stub" do
    {:ok, server} =
      Marsad.Fleet.create_server(%{
        name: "certs-#{System.unique_integer([:positive])}",
        host: "127.0.0.1",
        port: 22,
        username: "root",
        auth_type: "password",
        secret: "x"
      })

    kill_registry(server.id)
    stub = start_stub(server.id)
    on_exit(fn -> if Process.alive?(stub), do: GenServer.stop(stub, :normal, 1000) end)

    future = openssl_date(DateTime.add(DateTime.utc_now(), 90 * 86_400, :second))

    FileSessionStub.enqueue(stub, {:ok, %{stdout: @dump, stderr: "", status: 0}})

    FileSessionStub.enqueue(
      stub,
      {:ok, %{stdout: "shop.example.com|443|#{future}\n", stderr: "", status: 0}}
    )

    assert {:ok, checks} = Services.cert_check(server.id)
    assert [%{domain: "shop.example.com", status: :ok}, %{domain: "www.cdn.example.com"}] = checks
  end

  test "cert_check returns empty when no HTTPS vhosts" do
    {:ok, server} =
      Marsad.Fleet.create_server(%{
        name: "nocerts-#{System.unique_integer([:positive])}",
        host: "127.0.0.1",
        port: 22,
        username: "root",
        auth_type: "password",
        secret: "x"
      })

    kill_registry(server.id)
    stub = start_stub(server.id)
    on_exit(fn -> if Process.alive?(stub), do: GenServer.stop(stub, :normal, 1000) end)

    FileSessionStub.enqueue(
      stub,
      {:ok, %{stdout: "server { listen 80; }\n", stderr: "", status: 0}}
    )

    assert {:ok, []} = Services.cert_check(server.id)
  end

  defp openssl_date(dt) do
    months = ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

    "#{Enum.at(months, dt.month - 1)} #{dt.day} #{pad(dt.hour)}:#{pad(dt.minute)}:#{pad(dt.second)} #{dt.year} GMT"
  end

  defp pad(n), do: String.pad_leading(to_string(n), 2, "0")

  defp kill_registry(server_id) do
    case Registry.lookup(Marsad.Fleet.Registry, server_id) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(Marsad.Fleet.DynamicSupervisor, pid)

        try do
          if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1000)
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end

    wait_free(server_id)
  end

  defp start_stub(server_id, attempts \\ 5) do
    kill_registry(server_id)
    wait_free(server_id)

    case FileSessionStub.start_link(server_id: server_id, owner: self()) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, _}} when attempts > 1 ->
        Process.sleep(50)
        start_stub(server_id, attempts - 1)

      {:error, reason} ->
        flunk("could not start file session stub: #{inspect(reason)}")
    end
  end

  defp wait_free(id, deadline \\ System.monotonic_time(:millisecond) + 2000) do
    case Registry.lookup(Marsad.Fleet.Registry, id) do
      [] ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          :ok
        else
          Process.sleep(20)
          wait_free(id, deadline)
        end
    end
  end
end
