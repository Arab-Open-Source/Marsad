defmodule Marsad.Fleet.SysInfoTest do
  use ExUnit.Case, async: true

  alias Marsad.Fleet.SysInfo

  @load "0.42 0.31 0.25 2/412 9812\n"
  @cores "8\n"
  @mem """
  total        used        free      shared  buff/cache   available
  Mem:            7956        2143        1021         123        4791        5420
  Swap:           2047           0        2047
  """
  @disk """
  Filesystem     1M-blocks  Used Available Use% Mounted on
  /dev/sda1          48612 18234     30378  38% /
  """
  @misc "up 12 days, 3 hours, 5 minutes\nhost-01\n6.8.0-41-generic\n"

  test "parse/5 extracts a full snapshot" do
    assert {:ok, m} = SysInfo.parse(@load, @cores, @mem, @disk, @misc)
    assert m.load1 == 0.42
    assert m.cores == 8
    assert m.mem_total_mb == 7956
    assert m.mem_used_mb == 2143
    assert m.disk_total_mb == 48612
    assert m.disk_pct == 38
    assert m.hostname == "host-01"
    assert m.kernel == "6.8.0-41-generic"
    assert m.uptime =~ "up 12 days"
  end

  test "parse/5 rejects garbage load but tolerates unknown cores" do
    assert {:error, :unparseable} = SysInfo.parse("nope", "8", "nope", "nope", "nope")
    # nproc missing entirely → safe fallback, never a stray PID as core count
    assert {:ok, %{cores: 1}} = SysInfo.parse(@load, "oops\n", @mem, @disk, @misc)
    assert {:ok, %{cores: 4}} = SysInfo.parse(@load, "4\n", @mem, @disk, @misc)
  end

  test "helpers" do
    assert SysInfo.mem_pct(%{mem_total_mb: 0, mem_used_mb: 0}) == 0
    assert SysInfo.mem_pct(%{mem_total_mb: 1000, mem_used_mb: 250}) == 25
    assert SysInfo.load_ratio(%{load1: 4.0, cores: 8}) == 0.5
    assert SysInfo.format_mb(512) == "512 MiB"
    assert SysInfo.format_mb(2048) == "2.0 GiB"
  end
end
