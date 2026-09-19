defmodule Marsad.FilesSearchTest do
  use Marsad.DataCase, async: false

  alias Marsad.Files
  alias Marsad.Fleet
  alias MarsadWeb.FileSessionStub

  # -- parse_query ---------------------------------------------------------

  test "plain words become AND terms" do
    q = Files.parse_query("nginx conf")
    assert q.matchers?
    assert Enum.sort(q.terms) == ["conf", "nginx"]
    assert q.entry_type == :file
    assert q.prune?
    assert q.limit == 200
  end

  test "quoted phrases and excludes" do
    q = Files.parse_query(~s("exact phrase" foo -bar -"no go"))
    assert q.phrases == ["exact phrase"]
    assert q.terms == ["foo"]
    assert Enum.sort(q.exclude) == ["bar", "no go"]
    assert q.matchers?
  end

  test "ext directive and wildcard shorthand" do
    q = Files.parse_query("ext:conf,JSON .ignored *.log")
    assert Enum.sort(q.exts) == ["conf", "json", "log"]
    assert q.matchers?
  end

  test "type directive variants" do
    assert Files.parse_query("x type:d").entry_type == :dir
    assert Files.parse_query("x type:dir").entry_type == :dir
    assert Files.parse_query("x type:a").entry_type == :both
    assert Files.parse_query("x type:f").entry_type == :file
    assert Files.parse_query("x type:bogus").entry_type == :file
    assert Files.parse_query("plain").entry_type == :file
  end

  test "size bounds with suffixes" do
    assert Files.parse_query("x size:>10M").min_size == 10 * 1_048_576 + 1
    assert Files.parse_query("x size:<1k").max_size == 1_024 - 1
    assert Files.parse_query("x size:>=2G").min_size == 2 * 1_073_741_824
    assert Files.parse_query("x size:100").min_size == 100
    assert Files.parse_query("x size:100").max_size == 100
    bad = Files.parse_query("x size:banana")
    assert bad.min_size == nil and bad.max_size == nil
    assert "size:banana" in bad.terms
  end

  test "depth and limit with clamps" do
    assert Files.parse_query("x depth:3").maxdepth == 3
    assert Files.parse_query("x depth:999").maxdepth == 32
    assert Files.parse_query("x depth:xx").maxdepth == nil
    assert Files.parse_query("x limit:50").limit == 50
    assert Files.parse_query("x limit:9999").limit == 500
    assert Files.parse_query("x limit:0").limit == 200
  end

  test "all disables pruning; unknown keys stay literal" do
    assert Files.parse_query("x all").prune? == false
    q = Files.parse_query("color:red x")
    assert "color:red" in q.terms
  end

  test "empty or directive-only queries have no matchers" do
    refute Files.parse_query("").matchers?
    refute Files.parse_query("   ").matchers?
    refute Files.parse_query("limit:10 depth:2").matchers?
    refute Files.parse_query(nil).matchers?
  end

  test "query_tokens surfaces and remove_token rejoins" do
    assert Files.query_tokens(~s(conf ext:log -cache "a b")) == [
             "conf",
             "ext:log",
             "-cache",
             "\"a b\""
           ]

    assert Files.query_tokens("") == []
    assert Files.remove_token("conf ext:log -cache", "ext:log") == "conf -cache"
    assert Files.remove_token("conf", "conf") == ""
    assert Files.remove_token("a a b", "a") == "a b"
    assert Files.remove_token("conf", "missing") == "conf"
  end

  # -- search_command ------------------------------------------------------

  test "command structure for a plain term" do
    cmd = Files.search_command("/root", Files.parse_query("conf"))
    assert cmd =~ "find '/root' -xdev"
    assert cmd =~ "-type f"
    assert cmd =~ "-ipath '*conf*'"
    assert cmd =~ "-prune -o"
    assert cmd =~ "-printf '%y|%s|%T@|%p\\n'"
    assert cmd =~ "| head -201"
    refute cmd =~ "-maxdepth"
  end

  test "command honors type/size/depth/limit/all" do
    q = Files.parse_query("conf type:d size:>1k depth:3 limit:10 all")
    cmd = Files.search_command("/r oot", q)
    assert cmd =~ "find '/r oot'"
    assert cmd =~ "-type d"
    assert cmd =~ "-maxdepth 3"
    assert cmd =~ "-size +1025c"
    assert cmd =~ "| head -11"
    refute cmd =~ "-prune"
  end

  test "command groups multiple exts and excludes globs safely" do
    q = Files.parse_query("a ext:log,conf -cache")
    cmd = Files.search_command("/root", q)
    assert cmd =~ "-iname '*.conf'"
    assert cmd =~ "-iname '*.log'"
    assert cmd =~ "! -ipath '*cache*'"
  end

  test "user quotes cannot break out of the shell quoting" do
    q = Files.parse_query("a'b")
    cmd = Files.search_command("/root", q)
    # User input stays inside single quotes with embedded quotes escaped.
    assert cmd =~ "'*a'\\''b*'"
  end

  test "injection metacharacters stay quoted" do
    cmd = Files.search_command("/root", Files.parse_query("x; rm -rf /"))
    # `;` only ever appears inside single-quoted patterns, never as a separator.
    for chunk <- String.split(cmd, " ") do
      refute String.starts_with?(chunk, ";")
    end

    assert cmd =~ "-ipath '*x;*'"
  end

  test "glob metacharacters are escaped except star" do
    cmd = Files.search_command("/root", Files.parse_query("file[1]?.txt"))
    assert cmd =~ "-ipath '*file\\[1\\]\\?.txt*'"
  end

  # -- parse_search_line ---------------------------------------------------

  test "parses new 4-part lines with types" do
    assert [
             %{name: "a.conf", path: "/x/a.conf", type: :file, size: 9, mtime: 1_700_000_000}
           ] = Files.parse_search_line("f|9|1700000000.12|/x/a.conf")

    assert [%{type: :dir}] = Files.parse_search_line("d|0|1700000000|/x/sub")
    assert [%{type: :link}] = Files.parse_search_line("l|0|1700000000|/x/ln")
  end

  test "paths containing pipes survive in the new format" do
    assert [%{path: "/x/we|ird.log", size: 3}] =
             Files.parse_search_line("f|3|1700000000|/x/we|ird.log")
  end

  test "legacy 3-part lines still parse; garbage is dropped" do
    assert [%{name: "n.conf", type: :file}] =
             Files.parse_search_line("/var/n.conf|9|1700000000.1")

    assert Files.parse_search_line("garbage") == []
    assert Files.parse_search_line("f|xx|yy|/x") == []
    assert Files.parse_search_line("") == []
  end

  # -- rank_results --------------------------------------------------------

  defp entry(name, path),
    do: %{name: name, path: path, type: :file, size: 1, mtime: 0}

  test "exact beats prefix beats substring beats path-only" do
    entries = [
      entry("other.conf", "/deep/down/other.conf"),
      entry("my.conf.backup", "/my.conf.backup"),
      entry("conf", "/conf"),
      entry("config", "/config")
    ]

    q = Files.parse_query("conf")

    assert Enum.map(Files.rank_results(entries, q), & &1.name) == [
             "conf",
             "config",
             "my.conf.backup",
             "other.conf"
           ]
  end

  test "shallower paths win ties" do
    entries = [entry("a.log", "/x/y/a.log"), entry("a.log", "/a.log")]
    q = Files.parse_query("a.log")
    assert [%{path: "/a.log"} | _] = Files.rank_results(entries, q)
  end

  # -- search_remote via stub ----------------------------------------------

  setup do
    {:ok, server} =
      Fleet.create_server(%{
        name: "search-#{System.unique_integer([:positive])}",
        host: "127.0.0.1",
        port: 22,
        username: "root",
        auth_type: "password",
        secret: "x"
      })

    stub = start_stub(server.id, 5)
    on_exit(fn -> if Process.alive?(stub), do: GenServer.stop(stub, :normal, 1000) end)
    %{server: server, stub: stub}
  end

  defp start_stub(server_id, attempts) do
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

  test "ranked entries and truncation flag", %{stub: stub, server: server} do
    FileSessionStub.enqueue(stub, {:ok, {:ok, "/root"}})

    FileSessionStub.enqueue(
      stub,
      {:ok,
       %{
         stdout: """
         f|1|1700000000|/root/deep/zap.conf
         f|1|1700000000|/root/zap.conf
         f|1|1700000000|/root/other.txt
         """
       }}
    )

    assert %{entries: entries, truncated?: true} =
             Files.search_remote(server.id, "zap limit:2")

    assert Enum.map(entries, & &1.name) == ["zap.conf", "zap.conf"]
    assert hd(entries).path == "/root/zap.conf"
  end

  test "no truncation when under the limit", %{stub: stub, server: server} do
    FileSessionStub.enqueue(stub, {:ok, {:ok, "/root"}})
    FileSessionStub.enqueue(stub, {:ok, %{stdout: "f|1|1700000000|/root/a.conf\n"}})

    assert %{entries: [_], truncated?: false} = Files.search_remote(server.id, "a.conf")
  end

  test "matcher-less queries never touch SSH", %{stub: _stub, server: _server} do
    assert %{entries: [], truncated?: false} = Files.search_remote(123_456, "limit:5")
    refute_received {:file_session_request, _, _, _}
  end

  test "search_remote_files stays a plain ranked list", %{stub: stub, server: server} do
    FileSessionStub.enqueue(stub, {:ok, {:ok, "/root"}})
    FileSessionStub.enqueue(stub, {:ok, %{stdout: "f|2|1700000000|/root/b.conf\n"}})
    assert [%{name: "b.conf"}] = Files.search_remote_files(server.id, "b.conf")
  end

  test "unreachable servers still yield empty results", %{server: _server} do
    assert Files.search_remote(-999_999, "conf").entries == []
  end
end
