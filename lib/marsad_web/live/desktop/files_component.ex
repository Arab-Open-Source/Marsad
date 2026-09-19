defmodule MarsadWeb.Desktop.FilesComponent do
  use MarsadWeb, :html

  alias Marsad.Fleet
  alias Marsad.Helpers.Text

  attr :servers, :list, required: true
  attr :browser, :any, required: true
  attr :files_filter, :string, required: true
  attr :files_search_results, :any, required: true
  attr :search_truncated, :boolean, required: false, default: false
  attr :mkdir_form, :any, required: true
  attr :uploads, :any, required: true
  attr :appearance, :map, required: true

  @search_help "Smart search — words must all match (AND) · \"exact phrase\" · -exclude · ext:conf,json (or *.conf) · type:dirs/files · size:>10M size:<1G · depth:3 · limit:50 · all (include .git/node_modules)"

  def files_app(assigns) do
    browser_entries =
      case assigns.browser do
        %{entries: entries} -> entries || []
        _ -> []
      end

    local_entries = Marsad.Files.filtered_entries(browser_entries, assigns.files_filter)

    display_entries =
      case assigns.files_search_results do
        results when is_list(results) ->
          Enum.uniq_by(local_entries ++ results, fn entry ->
            Map.get(entry, :path) || Fleet.remote_join(assigns.browser.path, entry.name)
          end)

        _ ->
          local_entries
      end

    assigns =
      assigns
      |> assign(:display_entries, display_entries)
      |> assign(:search_help, @search_help)
      |> assign(:filter_tokens, Marsad.Files.query_tokens(assigns.files_filter))
      |> assign(:filter_chips, Marsad.Files.filter_chips(assigns.files_filter))

    ~H"""
    <div id="files-browser" class="flex h-full min-h-0 flex-col lg:flex-row">
      <!-- File list panel -->
      <div class="flex min-h-0 flex-1 flex-col lg:max-w-[420px] lg:border-r lg:border-base-content/10">
        <!-- Header: server + breadcrumb + actions -->
        <div class="shrink-0 border-b border-base-content/10 px-4 py-3">
          <div class="flex items-center gap-2 mb-2">
            <span class="acc-soft flex size-7 items-center justify-center rounded-lg">
              <.icon name="hero-folder" class="size-4" />
            </span>
            <form id="files-server-form" phx-change="files-server" class="flex-1">
              <select
                id="files-server-select"
                name="server_id"
                class="select select-sm select-bordered w-full max-w-56"
                aria-label="Browse server"
              >
                <option value="">Select server…</option>
                <option
                  :for={s <- @servers}
                  value={s.id}
                  selected={@browser && @browser.server_id == s.id}
                >
                  {s.name}
                </option>
              </select>
            </form>
            <div :if={@browser} class="flex items-center gap-0.5">
              <button
                id="files-up"
                phx-click="files-up"
                title="Parent directory"
                class="btn btn-xs btn-ghost border border-base-content/15 phx-click-loading:opacity-60"
              >
                <.icon name="hero-arrow-up" class="marsad-spin-target size-3.5" />
              </button>
              <button
                id="files-refresh"
                phx-click="files-refresh"
                title="Refresh"
                class="btn btn-xs btn-ghost border border-base-content/15 phx-click-loading:opacity-60"
              >
                <.icon name="hero-arrow-path" class="marsad-spin-target size-3.5" />
              </button>
            </div>
          </div>
          <div
            :if={!@browser}
            id="files-empty"
            class="flex flex-1 items-center justify-center p-6 text-center"
          >
            <.icon name="hero-folder-open" class="mx-auto size-10 text-base-content/30" />
            <p class="mt-2 font-semibold">No server selected</p>
            <p class="text-sm text-base-content/60">
              Pick a server above to browse its files over SFTP.
            </p>
          </div>
        </div>

        <!-- File list -->
        <div :if={@browser} class="flex min-h-0 flex-1 flex-col">
          <p
            :if={@browser.error}
            id="files-error"
            role="alert"
            class="mx-4 mt-2 rounded-xl border border-red-500/30 bg-red-500/10 px-3 py-2 text-xs text-red-700 dark:text-red-300"
          >
            {@browser.error}
          </p>

          <!-- Skeleton -->
          <div
            :if={@browser.entries == nil}
            id="files-skeleton"
            class="min-h-0 flex-1 space-y-0 overflow-hidden p-2"
            aria-label="Loading files"
          >
            <div :for={_ <- 1..8} class="flex items-center gap-3 px-2 py-2">
              <span class="marsad-shimmer size-4 shrink-0 rounded" />
              <span class="marsad-shimmer h-3.5 rounded" style="width: 32%" />
              <span class="marsad-shimmer ml-auto h-3 w-12 rounded" />
            </div>
          </div>

          <!-- Entries -->
          <div :if={@browser.entries != nil} id="files-list" class="min-h-0 flex-1 overflow-y-auto">
            <div class="border-b border-base-content/10 bg-base-content/[0.02] px-4 pb-2.5 pt-3">
              <form id="files-filter-form" phx-change="files-filter" role="search">
                <label
                  class="group flex items-center gap-2.5 rounded-2xl border border-base-content/15 bg-base-100 py-2 pl-2 pr-2.5 shadow-sm transition-all duration-150 focus-within:border-[color:var(--marsad-accent)] focus-within:shadow-md focus-within:ring-2 focus-within:ring-[color:var(--marsad-accent)]/25 hover:border-base-content/25"
                  title={@search_help}
                >
                  <span class="acc-soft flex size-8 shrink-0 items-center justify-center rounded-xl transition-transform duration-150 group-focus-within:scale-105">
                    <.icon name="hero-magnifying-glass" class="size-4" />
                  </span>
                  <input
                    id="files-filter"
                    type="search"
                    name="filter"
                    value={@files_filter}
                    placeholder="Smart search… ext:conf size:>1M &quot;exact&quot; -skip"
                    phx-debounce="600"
                    autocomplete="off"
                    spellcheck="false"
                    class="min-w-0 grow bg-transparent text-sm outline-none placeholder:text-base-content/35"
                    aria-label="Search files and folders"
                  />
                  <span
                    :if={@files_search_results == :loading}
                    class="loading loading-spinner loading-xs shrink-0"
                  />
                  <button
                    :if={@files_filter != ""}
                    type="button"
                    phx-click="files-clear-filter"
                    class="flex shrink-0 items-center gap-1 rounded-full bg-base-content/10 px-2 py-1 text-[11px] font-medium text-base-content/60 transition hover:bg-base-content/20 hover:text-base-content"
                    title="Clear search"
                    aria-label="Clear search"
                  >
                    <.icon name="hero-x-mark" class="size-3" /> Clear
                  </button>
                </label>
              </form>
              <%!-- Active filter chips (click × to drop one token) --%>
              <div
                :if={@filter_tokens != []}
                class="mt-2 flex flex-wrap items-center gap-1.5"
                role="group"
                aria-label="Active search filters"
              >
                <%= for chip <- @filter_chips do %>
                  <button
                    type="button"
                    phx-click="files-drop-token"
                    phx-value-token={chip.token}
                    title={"Remove #{chip.token} from the search"}
                    class={[
                      "group/chip flex max-w-44 cursor-pointer items-center gap-1 rounded-full border px-2 py-0.5 font-mono text-[11px] transition hover:shadow-sm",
                      chip.class
                    ]}
                  >
                    <span class="truncate">{chip.token}</span>
                    <.icon
                      name="hero-x-mark"
                      class="size-3 shrink-0 opacity-50 transition group-hover/chip:opacity-100"
                    />
                  </button>
                <% end %>
              </div>
              <%!-- Result meta: count, scope, truncation --%>
              <div class="mt-1.5 flex min-h-4 flex-wrap items-center gap-x-2 gap-y-1 text-[11px] text-base-content/50">
                <span :if={@files_search_results == :loading} class="flex items-center gap-1.5">
                  <span class="marsad-shimmer h-2.5 w-24 rounded-full" /> Searching the server…
                </span>
                <span :if={is_list(@files_search_results)} class="font-medium text-base-content/70">
                  {length(@display_entries)} {if length(@display_entries) == 1,
                    do: "result",
                    else: "results"}
                </span>
                <span
                  :if={is_list(@files_search_results) and @search_truncated}
                  title="More than the shown results matched — refine the query (ext:, size:, -word) or raise limit:N"
                  class="rounded-full bg-amber-500/15 px-2 py-px font-semibold text-amber-700 dark:text-amber-300"
                >
                  showing first {length(@display_entries)} — truncated
                </span>
                <span :if={is_list(@files_search_results)} class="ml-auto hidden sm:inline">
                  recursive · .git & node_modules skipped
                </span>
              </div>
            </div>
            <!-- Column headers -->
            <div class="sticky top-0 z-10 flex items-center gap-3 border-b border-base-content/10 bg-base-100 px-4 py-1.5 text-[10px] font-medium uppercase tracking-wider text-base-content/40">
              <span class="flex-1">Name</span>
              <span class="hidden w-16 text-right sm:block">Size</span>
              <span class="hidden w-24 text-right md:block">Modified</span>
              <span class="w-8"></span>
            </div>
            <div
              :for={e <- @display_entries}
              id={"file-#{e.name}"}
              class="group flex items-center gap-3 border-b border-base-content/[0.06] px-4 py-2 text-sm transition hover:bg-base-content/[0.05]"
              data-context-menu={
                Jason.encode!(%{
                  name: e.name,
                  type: to_string(e.type),
                  path: Fleet.remote_join(@browser.path, e.name)
                })
              }
            >
              <%= if e.type == :dir do %>
                <button
                  phx-click="files-open"
                  phx-value-name={e.name}
                  phx-value-type="dir"
                  class="flex min-w-0 flex-1 cursor-pointer items-center gap-2.5 text-left"
                >
                  <.icon name="hero-folder" class="size-4 shrink-0 acc-text" />
                  <span class="min-w-0 flex-1">
                    <span class="block truncate font-medium">{e.name}</span>
                    <span
                      :if={Map.has_key?(e, :path)}
                      class="block truncate font-mono text-[10px] text-base-content/40"
                      title={e.path}
                    >
                      {e.path}
                    </span>
                  </span>
                </button>
              <% else %>
                <button
                  phx-click={if Map.has_key?(e, :path), do: "files-open-path", else: "files-open"}
                  phx-value-name={e.name}
                  phx-value-type="file"
                  phx-value-path={Map.get(e, :path)}
                  class="flex min-w-0 flex-1 cursor-pointer items-center gap-2.5 text-left"
                >
                  <.icon name="hero-document" class="size-4 shrink-0 text-base-content/40" />
                  <span class="min-w-0 flex-1">
                    <span class="block truncate">{e.name}</span>
                    <span
                      :if={Map.has_key?(e, :path)}
                      class="block truncate font-mono text-[10px] text-base-content/40"
                      title={e.path}
                    >
                      {e.path}
                    </span>
                  </span>
                </button>
              <% end %>
              <span class="hidden w-16 shrink-0 text-right font-mono text-[11px] text-base-content/50 sm:block">
                {if e.type == :file, do: Text.format_size(e.size), else: "—"}
              </span>
              <span class="hidden w-24 shrink-0 text-right font-mono text-[11px] text-base-content/40 md:block">
                {Text.format_mtime(e.mtime)}
              </span>
              <a
                href={
                  ~p"/files/download?server_id=#{@browser.server_id}&path=#{Map.get(e, :path) || Fleet.remote_join(@browser.path, e.name)}"
                }
                download={if e.type == :dir, do: e.name <> ".tar.gz", else: e.name}
                title={
                  if e.type == :dir, do: "Download #{e.name} as tar.gz", else: "Download #{e.name}"
                }
                class="shrink-0 rounded p-1 text-base-content/40 opacity-60 transition hover:bg-sky-500/10 hover:text-sky-600 focus:opacity-100"
              >
                <.icon name="hero-arrow-down-tray" class="size-3.5" />
              </a>
              <button
                phx-click="files-delete"
                phx-value-name={e.name}
                phx-value-type={to_string(e.type)}
                data-confirm={"Delete #{e.name}?"}
                title={"Delete #{e.name}"}
                class="shrink-0 rounded p-1 text-base-content/40 opacity-60 transition hover:bg-red-500/10 hover:text-red-500 focus:opacity-100"
              >
                <.icon name="hero-trash" class="size-3.5" />
              </button>
            </div>
            <p
              :if={@browser.entries == [] and !@browser.error}
              class="p-6 text-center text-sm text-base-content/50"
            >
              Empty directory.
            </p>
            <p
              :if={
                @files_search_results != :loading and @browser.entries != [] and
                  @display_entries == []
              }
              class="p-6 text-center text-sm text-base-content/50"
            >
              No matching files.
            </p>
          </div>

          <!-- Actions bar -->
          <div class="flex shrink-0 flex-col gap-2 border-t border-base-content/10 px-4 py-2.5">
            <div class="flex items-center gap-2">
              <.form
                for={@mkdir_form}
                id="mkdir-form"
                phx-submit="files-mkdir"
                class="flex items-center gap-1.5"
              >
                <.input
                  field={@mkdir_form[:dirname]}
                  type="text"
                  placeholder="New folder…"
                  aria-label="New folder name"
                  class="input-xs"
                />
                <button type="submit" class="btn btn-xs border-base-content/15">Create</button>
              </.form>
              <.form
                for={%{}}
                id="upload-form"
                phx-change="validate-upload"
                phx-submit="files-upload"
                class="ml-auto flex items-center gap-2"
              >
                <label class="inline-flex cursor-pointer items-center gap-1.5 rounded-lg border border-base-content/15 px-2.5 py-1 text-xs text-base-content/60 hover:bg-base-content/10 hover:text-base-content transition-colors">
                  <.icon name="hero-arrow-up-tray" class="size-3.5" /> Files
                  <.live_file_input upload={@uploads.remote_files} class="hidden" />
                </label>
                <label class="inline-flex cursor-pointer items-center gap-1.5 rounded-lg border border-base-content/15 px-2.5 py-1 text-xs text-base-content/60 hover:bg-base-content/10 hover:text-base-content transition-colors">
                  <.icon name="hero-folder-plus" class="size-3.5" /> Folder
                  <.live_file_input upload={@uploads.remote_folder} webkitdirectory class="hidden" />
                </label>
                <button
                  :if={@uploads.remote_files.entries != [] or @uploads.remote_folder.entries != []}
                  type="submit"
                  class="btn btn-xs acc-bg border-0 gap-1"
                >
                  <.icon name="hero-arrow-up-tray" class="size-3" />
                  Upload {length(@uploads.remote_files.entries) +
                    length(@uploads.remote_folder.entries)} file(s)
                </button>
              </.form>
            </div>
            <!-- Upload entries: progress, errors, and cancel -->
            <div
              :for={entry <- @uploads.remote_files.entries}
              class="flex items-center gap-2 rounded-lg bg-base-content/[0.03] px-2 py-1 text-[11px]"
            >
              <span class="truncate font-mono">{entry.client_name} — {entry.progress}%</span>
              <progress value={entry.progress} max="100" class="h-1 w-24 flex-1"></progress>
              <button
                type="button"
                phx-click="cancel-upload"
                phx-value-ref={entry.ref}
                class="rounded p-0.5 text-base-content/40 hover:text-red-500"
                title="Cancel"
              >
                <.icon name="hero-x-mark" class="size-3" />
              </button>
              <span
                :for={err <- upload_errors(@uploads.remote_files, entry)}
                class="text-red-500"
              >
                {Text.upload_error_to_string(err)}
              </span>
            </div>
            <div
              :for={entry <- @uploads.remote_folder.entries}
              class="flex items-center gap-2 rounded-lg bg-base-content/[0.03] px-2 py-1 text-[11px]"
            >
              <span class="truncate font-mono">{entry.client_relative_path || entry.client_name} — {entry.progress}%</span>
              <progress value={entry.progress} max="100" class="h-1 w-24 flex-1"></progress>
              <button
                type="button"
                phx-click="cancel-upload"
                phx-value-ref={entry.ref}
                class="rounded p-0.5 text-base-content/40 hover:text-red-500"
                title="Cancel"
              >
                <.icon name="hero-x-mark" class="size-3" />
              </button>
              <span
                :for={err <- upload_errors(@uploads.remote_folder, entry)}
                class="text-red-500"
              >
                {Text.upload_error_to_string(err)}
              </span>
            </div>
            <p :if={@uploads.remote_files.errors != []} class="text-[11px] text-red-500">
              <span :for={err <- @uploads.remote_files.errors}>{Text.upload_error_to_string(err)}</span>
            </p>
            <p :if={@uploads.remote_folder.errors != []} class="text-[11px] text-red-500">
              <span :for={err <- @uploads.remote_folder.errors}>{Text.upload_error_to_string(err)}</span>
            </p>
          </div>
        </div>
      </div>

      <!-- Preview panel -->
      <div
        :if={@browser && @browser.preview}
        class="flex min-h-0 flex-1 flex-col border-t border-base-content/10 lg:border-t-0"
        id="files-preview-panel"
      >
        <div class="flex shrink-0 items-center gap-2 bg-base-content/[0.04] border-b border-base-content/10 px-4 py-2 font-mono text-xs">
          <%= case @browser.preview.kind do %>
            <% :image -> %>
              <.icon name="hero-photo" class="size-3.5 text-base-content/50" />
            <% :text -> %>
              <.icon name="hero-document-text" class="size-3.5 text-base-content/50" />
            <% :binary -> %>
              <.icon name="hero-document" class="size-3.5 text-base-content/50" />
          <% end %>
          <span class="truncate font-medium text-base-content/80">{@browser.preview.path}</span>
          <span
            :if={
              @browser.preview.language not in [nil, "text/plain"] and @browser.preview.kind == :text
            }
            class="shrink-0 rounded bg-base-content/10 px-1.5 py-0.5 text-[10px] uppercase tracking-wider"
          >{@browser.preview.language}</span>
          <span
            :if={@browser.preview.kind == :image}
            class="shrink-0 rounded bg-sky-500/10 px-1.5 py-0.5 text-sky-500"
          >image</span>
          <span
            :if={@browser.preview.truncated? and @browser.preview.kind == :text}
            class="shrink-0 rounded bg-amber-500/10 px-1.5 py-0.5 text-amber-700 dark:text-amber-300"
          >truncated</span>
          <span class="ml-auto flex shrink-0 items-center gap-1">
            <span
              :if={@browser.preview.kind == :text}
              class="hidden text-[10px] text-base-content/40 sm:inline"
            >Ctrl+S</span>
            <a
              href={~p"/files/download?server_id=#{@browser.server_id}&path=#{@browser.preview.path}"}
              download={Path.basename(@browser.preview.path)}
              title="Download"
              class="btn btn-xs btn-ghost border border-base-content/15 gap-1"
            >
              <.icon name="hero-arrow-down-tray" class="size-3.5" /> Download
            </a>
            <button
              :if={@browser.preview.kind == :text and @browser.preview.editing}
              data-save-path={@browser.preview.path}
              id="files-preview-save"
              class="btn btn-xs acc-bg border-0 gap-1"
              title="Save (Ctrl+S)"
            >
              <.icon name="hero-check" class="size-3.5" /> Save
            </button>
            <button
              id="files-preview-close"
              phx-click="files-close-preview"
              class="rounded p-0.5 hover:bg-base-content/10"
              aria-label="Close preview"
            >
              <.icon name="hero-x-mark" class="size-3.5" />
            </button>
          </span>
        </div>
        <!-- Preview content -->
        <%= case @browser.preview.kind do %>
          <% :image -> %>
            <div
              class="flex min-h-0 flex-1 items-center justify-center overflow-auto bg-base-content/[0.02] p-4"
              id="files-image-preview"
            >
              <img
                src={"data:#{@browser.preview.mime};base64,#{@browser.preview.data}"}
                alt={@browser.preview.path}
                class="max-h-full max-w-full rounded-lg border border-base-content/10 object-contain shadow-lg"
                loading="lazy"
              />
            </div>
          <% :text -> %>
            <div class="marsad-code-editor-wrap min-h-0 flex-1" id="files-code-preview">
              <textarea
                id={"code-files-" <> Base.url_encode64(@browser.preview.path, padding: false)}
                phx-hook="CodeEditor"
                phx-update="ignore"
                data-path={@browser.preview.path}
                data-language={@browser.preview.language || "text/plain"}
                data-theme={@appearance.mode}
                data-readonly="false"
                class="hidden"
              ><%= @browser.preview.full_text || @browser.preview.text %></textarea>
            </div>
          <% :binary -> %>
            <div
              class="flex min-h-0 flex-1 items-center justify-center p-8 text-center text-sm text-base-content/50"
              id="files-binary-preview"
            >
              <div>
                <.icon name="hero-document" class="mx-auto size-10 text-base-content/30" />
                <p class="mt-2">Binary file preview unavailable</p>
                <p class="mt-1 text-xs text-base-content/40">
                  Download or use terminal to inspect this file
                </p>
              </div>
            </div>
        <% end %>
      </div>
    </div>
    """
  end
end
