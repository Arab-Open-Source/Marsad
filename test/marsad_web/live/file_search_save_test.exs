defmodule MarsadWeb.FileSearchSaveTest do
  use MarsadWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Marsad.Fleet
  alias MarsadWeb.FileSessionStub

  @filter "conf"
  @path "/root/app.conf"
  @editor_id "code-files-" <> Base.url_encode64(@path, padding: false)

  setup do
    {:ok, server} =
      Fleet.create_server(%{
        name: "files-target-#{System.unique_integer([:positive])}",
        host: "127.0.0.1",
        port: 22,
        username: "root",
        auth_type: "password",
        secret: "x"
      })

    stub = start_supervised!({FileSessionStub, server_id: server.id, owner: self()})

    %{server: server, stub: stub}
  end

  defp enqueue(stub, replies), do: Enum.each(replies, &FileSessionStub.enqueue(stub, &1))

  # SFTP-backed Fleet functions unwrap once more than `exec`, so queue replies
  # in the same shape `ServerSession.sftp/2` would return: {:ok, fun_result}.
  defp sftp(value), do: {:ok, {:ok, value}}

  defp wait_until(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("condition not met in time")
      true -> Process.sleep(50) && do_wait(fun, deadline)
    end
  end

  test "search keeps local matches while remote results load, and saving clears the edit bar", %{
    conn: conn,
    stub: stub
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    # Initial directory listing (home_dir + list_dir consumed by the load task).
    enqueue(stub, [
      sftp("/root"),
      sftp([
        %{name: "etc", type: :dir, size: 0, mtime: 0},
        %{name: "app.conf", type: :file, size: 6, mtime: 0},
        %{name: "app2.log", type: :file, size: 3, mtime: 0}
      ])
    ])

    view |> element("#icon-files") |> render_click()
    wait_until(fn -> has_element?(view, "#file-app\\.conf") end)

    # Typing the same filter twice must spawn exactly one remote search task.
    # Replies are queued up-front: the search Task runs concurrently with the
    # test process, so a late enqueue would race with the task's first call.
    enqueue(stub, [
      sftp("/root"),
      {:ok, %{stdout: "/var/network.conf|9|1700000000.123456\n"}}
    ])

    view |> render_change("files-filter", %{"filter" => @filter})
    view |> render_change("files-filter", %{"filter" => @filter})

    # Local matches stay visible while the remote search is loading.
    assert has_element?(view, "#file-app\\.conf")
    refute has_element?(view, "#file-app2\\.log")

    wait_until(fn -> has_element?(view, "#file-network\\.conf") end)
    # The local match disappears from the merged list only if the fix regresses.
    assert has_element?(view, "#file-app\\.conf")

    # Open the local file preview (read_file reply queued first).
    enqueue(stub, [sftp("one\n")])
    view |> element("#file-app\\.conf button[phx-click=files-open]") |> render_click()
    wait_until(fn -> has_element?(view, "##{@editor_id}") end)
    assert has_element?(view, "#files-preview-save")

    # Editor reports a clean state -> bar hides; dirty again -> bar returns.
    view
    |> render_click("file-editor-dirty", %{
      "path" => @path,
      "editor_id" => @editor_id,
      "dirty" => false
    })

    refute has_element?(view, "#files-preview-save")

    view
    |> render_click("file-editor-dirty", %{
      "path" => @path,
      "editor_id" => @editor_id,
      "dirty" => true
    })

    assert has_element?(view, "#files-preview-save")

    # Saving once clears the editing bar and pushes the saved content back.
    enqueue(stub, [sftp(:ok)])

    view
    |> render_click("save_file_content", %{
      "path" => @path,
      "content" => "one-two",
      "editor_id" => @editor_id
    })

    refute has_element?(view, "#files-preview-save")
    assert render(view) =~ "File saved"

    # Flash is dismissible like any other flash message.
    view |> render_click("lv:clear-flash", %{"key" => "info"})
    refute has_element?(view, "#flash-info")

    # A second save works the same way (no one-shot state left behind).
    enqueue(stub, [sftp(:ok)])

    view
    |> render_click("save_file_content", %{
      "path" => @path,
      "content" => "one-two-three",
      "editor_id" => @editor_id
    })

    refute has_element?(view, "#files-preview-save")
    assert render(view) =~ "File saved"
  end
end
