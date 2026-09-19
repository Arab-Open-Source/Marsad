defmodule Marsad.Fleet.SysInfoExtraTest do
  use ExUnit.Case, async: true

  alias Marsad.Fleet.SysInfo

  @load "0.50 0.30 0.20 1/100 1234"
  @cores "4\n4\n4\n"
  @mem "              total        used        free\nMem:           8000        2000        6000\nSwap:             0           0           0"
  @disk "Filesystem 1M-blocks Used Available Use% Mounted on\n/dev/sda1  20000  5000  15000  25% /"
  @misc "up 2 days\nhost-1\n6.8.0\n"

  test "batched_command contains all markers" do
    cmd = SysInfo.batched_command()

    for marker <- ~w(LOAD CORES MEM DFALL DF NET MISC) do
      assert cmd =~ "__MARSAD_#{marker}__"
    end
  end

  test "parse_batched splits sections" do
    out = """
    __MARSAD_LOAD__
    #{@load}
    __MARSAD_CORES__
    #{@cores}
    __MARSAD_MEM__
    #{@mem}
    __MARSAD_DFALL__
    #{@disk}
    __MARSAD_DF__
    #{@disk}
    __MARSAD_NET__
    Inter-|   Receive | Transmit
    __MARSAD_MISC__
    #{@misc}
    __MARSAD_END__
    """

    assert {:ok, sections} = SysInfo.parse_batched(out)
    assert sections.load =~ "0.50"
    assert sections.cores =~ "4"
    assert {:error, :unparseable_batch} = SysInfo.parse_batched("no markers here")
  end

  test "parse/5 round-trips the batched sections" do
    out = """
    __MARSAD_LOAD__
    #{@load}
    __MARSAD_CORES__
    #{@cores}
    __MARSAD_MEM__
    #{@mem}
    __MARSAD_DFALL__
    #{@disk}
    __MARSAD_DF__
    #{@disk}
    __MARSAD_NET__
    x
    __MARSAD_MISC__
    #{@misc}
    __MARSAD_END__
    """

    {:ok, sections} = SysInfo.parse_batched(out)

    assert {:ok, parsed} =
             SysInfo.parse(
               sections.load,
               sections.cores,
               sections.mem,
               sections.disk,
               sections.misc
             )

    assert parsed.cores == 4
    assert parsed.hostname == "host-1"
  end

  test "parse rejects garbage" do
    assert {:error, :unparseable} = SysInfo.parse("bad", "bad", "bad", "bad", "bad")
  end

  test "parse_ps skips headers and bad rows" do
    out = "PID COMMAND %CPU %MEM\n  1 init 0.0 0.1\nbad row\n  42 nginx 12.5 1.2\n"
    assert [%{pid: 1, comm: "init"}, %{pid: 42, comm: "nginx"}] = SysInfo.parse_ps(out)
  end

  test "sort_procs orders by field" do
    procs = [%{pid: 2, comm: "b", cpu: 5.0, mem: 1.0}, %{pid: 1, comm: "a", cpu: 1.0, mem: 9.0}]
    assert [%{pid: 1} | _] = SysInfo.sort_procs(procs, :cpu, :asc)
    assert [%{pid: 2} | _] = SysInfo.sort_procs(procs, :cpu, :desc)
    assert [%{comm: "a"} | _] = SysInfo.sort_procs(procs, :comm, :asc)
  end

  test "parse_disks only keeps real mounts" do
    out =
      "Filesystem 1M-blocks Used Available Use% Mounted on\n/dev/sda1 20000 5000 15000 25% /\ntmpfs 100 0 100 0% /run\n"

    assert [%{mount: "/", pct: 25}] = SysInfo.parse_disks(out)
  end

  test "parse_net sums interfaces" do
    out =
      "Inter-| Receive | Transmit\n face |bytes ...\n  eth0: 1048576 0 0 0 0 0 0 0 2097152 0 0 0 0 0 0 0\n"

    assert %{rx_mb: rx, tx_mb: tx} = SysInfo.parse_net(out)
    assert rx == 1.0 and tx == 2.0
    assert %{rx_mb: rx0, tx_mb: tx0} = SysInfo.parse_net("")
    assert rx0 == 0.0 and tx0 == 0.0
  end

  test "load_ratio, mem_pct and format_mb" do
    assert SysInfo.load_ratio(%{load1: 2.0, cores: 4}) == 0.5
    assert SysInfo.mem_pct(%{mem_total_mb: 0}) == 0
    assert SysInfo.mem_pct(%{mem_total_mb: 100, mem_used_mb: 25}) == 25
    assert SysInfo.format_mb(512) == "512 MiB"
    assert SysInfo.format_mb(2048) == "2.0 GiB"
  end
end
