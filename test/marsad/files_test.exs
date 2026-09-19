defmodule Marsad.FilesTest do
  use Marsad.DataCase, async: false

  alias Marsad.Files

  test "filtered_entries matches case-insensitively, blank returns all" do
    entries = [%{name: "App.conf"}, %{name: "readme.md"}, %{name: "data.LOG"}]

    assert Files.filtered_entries(entries, "") == entries
    assert Files.filtered_entries(entries, nil) == entries
    assert Files.filtered_entries(entries, "  app ") == [%{name: "App.conf"}]
    assert Files.filtered_entries(entries, "LOG") == [%{name: "data.LOG"}]
    assert Files.filtered_entries(entries, "zzz") == []
  end

  test "editor_id is stable and URL-safe" do
    id = Files.editor_id("files", "/root/a b.conf")
    assert String.starts_with?(id, "code-files-")
    refute id =~ " "
    assert id == Files.editor_id("files", "/root/a b.conf")
  end

  test "write_result normalizes ok shapes" do
    assert Files.write_result({:ok, "anything"}) == :ok
    assert Files.write_result(:ok) == :ok
    assert Files.write_result({:error, :boom}) == {:error, :boom}
  end

  test "build_preview handles images without raw binaries in socket" do
    png = :crypto.strong_rand_bytes(100)

    preview = Files.build_preview("/x/photo.png", png)
    assert preview.kind == :image
    assert preview.inline? == false
    assert preview.mime == "image/png"
    assert preview.full_text == nil
    assert {:ok, ^png} = Base.decode64(preview.data)

    svg = "<svg xmlns='http://www.w3.org/2000/svg'></svg>"
    svg_preview = Files.build_preview("/x/pic.svg", svg)
    assert svg_preview.kind == :image
    assert svg_preview.inline? == false
    assert svg_preview.mime == "image/svg+xml"
    assert svg_preview.full_text == nil
  end

  test "build_preview truncates long text and disables editing" do
    big = String.duplicate("a", 250_000)
    preview = Files.build_preview("/x/big.log", big)
    assert preview.kind == :text
    assert preview.truncated? == true
    assert preview.editing == false
    assert byte_size(preview.text) == 200_000

    small = "echo hi"
    small_preview = Files.build_preview("/x/run.sh", small)
    assert small_preview.kind == :text
    assert small_preview.truncated? == false
    assert small_preview.editing == true
    assert small_preview.language == "shell"
  end

  test "build_preview marks binaries without storing raw data" do
    bin = <<0, 159, 146, 150>>
    refute String.valid?(bin)
    preview = Files.build_preview("/x/a.bin", bin)
    assert preview.kind == :binary
    assert preview.full_text == nil
    assert preview.editing == false
  end

  test "code_language maps extensions" do
    assert Files.code_language("/x/a.ex") == "elixir"
    assert Files.code_language("/x/a.exs") == "elixir"
    assert Files.code_language("/x/a.py") == "python"
    assert Files.code_language("/x/a.json") == "javascript"
    assert Files.code_language("/x/Dockerfile") == "text/plain"
    assert Files.code_language("/etc/nginx/nginx.conf") == "nginx"
    assert Files.code_language("/x/unknown.zzz") == "text/plain"
    assert Files.code_language(nil) == "text/plain"
    assert Files.code_language(123) == "text/plain"
  end

  test "search_remote_files returns [] when server is unreachable" do
    {:ok, server} =
      Marsad.Fleet.create_server(%{
        name: "unreachable-#{System.unique_integer([:positive])}",
        host: "127.0.0.1",
        port: 1,
        username: "root",
        auth_type: "password",
        secret: "x"
      })

    assert Files.search_remote_files(server.id, "conf") == []
    assert Files.search_remote_files(-999_999, "conf") == []
  end
end
