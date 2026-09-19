defmodule Marsad.Helpers.TextTest do
  use ExUnit.Case, async: true

  alias Marsad.Helpers.Text

  test "shell_quote wraps and escapes" do
    assert Text.shell_quote("hello") == "'hello'"
    assert Text.shell_quote("a'b") == "'a'\\''b'"
    assert Text.shell_quote("") == "''"
  end

  test "format_size thresholds" do
    assert Text.format_size(0) == "0B"
    assert Text.format_size(512) == "512B"
    assert Text.format_size(1024) == "1.0K"
    assert Text.format_size(1_048_576) == "1.0M"
    assert Text.format_size(1_073_741_824) == "1.0G"
    assert Text.format_size(nil) == "—"
    assert Text.format_size("x") == "—"
  end

  test "format_mtime handles unix, tuple and garbage" do
    assert Text.format_mtime(0) == "—"
    assert Text.format_mtime(-5) == "—"
    assert Text.format_mtime(1_700_000_000) =~ ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/
    assert Text.format_mtime({{2026, 1, 2}, {3, 4, 5}}) == "2026-01-02 03:04"
    assert Text.format_mtime({{2026, 13, 40}, {25, 61, 0}}) == "—"
    assert Text.format_mtime(nil) == "—"
    assert Text.format_mtime("yesterday") == "—"
  end

  test "mime_type maps common extensions" do
    assert Text.mime_type("a.txt") == "text/plain"
    assert Text.mime_type("a.LOG") == "text/plain"
    assert Text.mime_type("a.json") == "application/json"
    assert Text.mime_type("a.yml") == "text/yaml"
    assert Text.mime_type("a.html") == "text/html"
    assert Text.mime_type("a.css") == "text/css"
    assert Text.mime_type("a.js") == "application/javascript"
    assert Text.mime_type("a.png") == "image/png"
    assert Text.mime_type("a.jpg") == "image/jpeg"
    assert Text.mime_type("a.svg") == "image/svg+xml"
    assert Text.mime_type("a.pdf") == "application/pdf"
    assert Text.mime_type("a.zip") == "application/zip"
    assert Text.mime_type("a.mp4") == "video/mp4"
    assert Text.mime_type("a.mp3") == "audio/mpeg"
    assert Text.mime_type("a.unknown-ext") == "application/octet-stream"
  end

  test "escape_filename replaces quotes" do
    assert Text.escape_filename(~s(a"b)) == "a_b"
    assert Text.escape_filename("plain") == "plain"
  end

  test "upload_error_to_string covers all branches" do
    assert Text.upload_error_to_string(:too_large) =~ "50MB"
    assert Text.upload_error_to_string(:too_many_files) =~ "max"
    assert Text.upload_error_to_string(:not_accepted) == "File type not accepted"
    assert Text.upload_error_to_string(:weird) == ":weird"
  end
end
