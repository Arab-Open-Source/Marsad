defmodule Marsad.SnippetsTest do
  use Marsad.DataCase, async: false

  alias Marsad.Snippets
  alias Marsad.Snippets.Snippet

  test "variables_in finds unique placeholders in order" do
    assert Snippets.variables_in("echo {{host}} && df -h {{path}} && echo {{host}}") ==
             ["host", "path"]

    assert Snippets.variables_in("no variables") == []
    assert Snippets.variables_in(nil) == []
  end

  test "render substitutes values and leaves unknown placeholders" do
    command = "ssh {{user}}@{{host}} 'df -h {{path}}; echo {{missing}}'"

    assert Snippets.render(command, %{"user" => "root", "host" => "web1", "path" => "/"}) ==
             "ssh root@web1 'df -h /; echo {{missing}}'"
  end

  test "CRUD stores variables as JSON and auto-detects them from the command" do
    attrs = %{
      "name" => "Disk check #{System.unique_integer([:positive])}",
      "description" => "usage",
      "command" => "df -h {{path}}",
      "category" => "storage"
    }

    assert {:ok, snippet} = Snippets.create_snippet(attrs)
    assert snippet.variables == ~s(["path"])
    assert Snippet.variable_list(snippet) == ["path"]

    assert {:ok, updated} =
             Snippets.update_snippet(snippet, %{"command" => "du -sh {{path}} {{other}}"})

    assert Jason.decode!(updated.variables) == ["path", "other"]

    assert {:error, changeset} = Snippets.create_snippet(%{"name" => "", "command" => ""})
    assert changeset.errors != []

    assert {:ok, _} = Snippets.delete_snippet(updated)
  end
end
