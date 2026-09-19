defmodule MarsadWeb.OfflineLive do
  @moduledoc """
  Limited / no-internet page.

  Public (no auth) on purpose: when the browser is offline or the
  LiveView socket drops, the user can still open `/offline` (or see the
  global offline overlay) with diagnostics + retry.
  """
  use MarsadWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Offline")
     |> assign(:checked_at, DateTime.utc_now())}
  end

  @impl true
  def handle_event("recheck", _params, socket) do
    {:noreply,
     socket
     |> assign(:checked_at, DateTime.utc_now())
     |> push_event("connection-recheck", %{at: DateTime.to_iso8601(DateTime.utc_now())})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div
        id="offline-page"
        phx-hook="ConnectionStatus"
        class="mx-auto w-full max-w-lg py-14 text-center"
      >
        <span class="mx-auto flex size-16 items-center justify-center rounded-2xl bg-warning/15 text-warning">
          <.icon name="hero-wifi" class="size-8" />
        </span>
        <p class="mt-2 inline-flex items-center gap-2 text-xs font-semibold uppercase tracking-wider text-warning">
          <span id="offline-status-dot" class="size-2 rounded-full bg-warning status-live"></span>
          <span id="offline-status-text">Limited or no connection</span>
        </p>
        <h1 class="mt-2 text-2xl font-bold">You're offline</h1>
        <p class="mx-auto mt-2 max-w-md text-sm leading-relaxed text-base-content/60">
          Marsad needs a live connection to this server for SSH, metrics and file browsing.
          Check your network or the server, then try again. Your data on managed servers is safe.
        </p>

        <div class="card bg-base-100 border border-base-content/10 mt-6 text-left shadow-xl">
          <div class="card-body gap-2 text-sm">
            <div class="flex items-center justify-between gap-2">
              <span class="text-base-content/60">Browser online?</span>
              <code id="offline-navigator" class="font-mono text-xs">checking…</code>
            </div>
            <div class="flex items-center justify-between gap-2">
              <span class="text-base-content/60">LiveView socket</span>
              <code id="offline-socket" class="font-mono text-xs">checking…</code>
            </div>
            <div class="flex items-center justify-between gap-2">
              <span class="text-base-content/60">Last check</span>
              <code class="font-mono text-xs">{Calendar.strftime(@checked_at, "%H:%M:%S")} UTC</code>
            </div>
          </div>
        </div>

        <div class="mt-5 flex justify-center gap-2">
          <button id="offline-retry" phx-click="recheck" class="btn btn-primary gap-2">
            <.icon name="hero-arrow-path" class="size-4" /> Try again
          </button>
          <.link navigate={~p"/"} class="btn btn-ghost border border-base-content/15">
            Back to Marsad
          </.link>
        </div>

        <p class="mt-4 text-xs text-base-content/50">
          Tip: this banner also appears automatically as a full-screen overlay whenever the connection drops.
        </p>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ConnectionStatusCheck">
        export default {
          mounted() {
            const nav = document.getElementById("offline-navigator");
            const sock = document.getElementById("offline-socket");
            if (nav) nav.textContent = navigator.onLine ? "yes (online)" : "no (offline)";
            if (sock) sock.textContent = window.liveSocket && window.liveSocket.isConnected() ? "connected" : "disconnected";
            this.handleEvent("connection-recheck", () => {
              if (nav) nav.textContent = navigator.onLine ? "yes (online)" : "no (offline)";
              if (sock) sock.textContent = window.liveSocket && window.liveSocket.isConnected() ? "connected" : "disconnected";
            });
          }
        }
      </script>
    </Layouts.app>
    """
  end
end
