// Global connectivity monitor: toggles #global-offline-overlay only on real
// outages — browser offline, or a LiveView socket that stays dead.
//
// Two past false-positive causes are handled explicitly:
//  1. The overlay is hidden via inline `display:none` (NOT the `hidden`
//     attribute), because Tailwind's `.flex` overrides `[hidden]`.
//  2. Socket state is only considered when LiveViews exist on the page
//     (controller pages like /login have none, so `isConnected() === false`
//     there is normal). Showing requires consecutive dead checks.
export const ConnectionStatus = {
  mounted() {
    const overlay = document.getElementById("global-offline-overlay");
    const detail = document.getElementById("global-offline-detail");
    if (!overlay) return;

    // Consecutive dead-socket observations before showing (each tick is 5s).
    const DEAD_TICKS_TO_SHOW = 3;
    let deadTicks = 0;
    let everConnected = false;

    const setVisible = (visible, reason) => {
      overlay.style.display = visible ? "flex" : "none";
      document.body.classList.toggle("is-offline", visible);
      if (detail && reason) detail.textContent = reason;
    };

    const hasLiveViews = () =>
      document.querySelector("[data-phx-session],[data-phx-root],[data-phx-main]") !== null;

    const socketDead = () =>
      hasLiveViews() && (!window.liveSocket || !window.liveSocket.isConnected());

    const refresh = (reason) => {
      if (!navigator.onLine) {
        deadTicks = DEAD_TICKS_TO_SHOW;
        setVisible(true, reason || "Browser reports no internet (navigator.onLine == false).");
      } else if (socketDead()) {
        deadTicks += 1;
        if (everConnected && deadTicks >= DEAD_TICKS_TO_SHOW) {
          setVisible(true, reason || "Lost connection to the Marsad server. Retrying…");
        }
      } else {
        deadTicks = 0;
        setVisible(false);
      }
    };

    window.addEventListener("online", () => refresh());
    window.addEventListener("offline", () =>
      refresh("Browser reports no internet (offline event).")
    );
    window.addEventListener("phx:page-loading-start", () => {
      // navigating while offline -> show immediately
      if (!navigator.onLine) refresh();
    });

    // LiveView socket lifecycle (fired by phoenix_live_view on the window).
    window.addEventListener("phx:connected", () => {
      everConnected = true;
      deadTicks = 0;
      setVisible(false);
    });
    window.addEventListener("phx:join", () => {
      everConnected = true;
      deadTicks = 0;
      setVisible(false);
    });
    window.addEventListener("phx:disconnected", () =>
      setTimeout(() => refresh(), 5000)
    );

    // Periodic re-check (covers "limited internet": online but socket dead).
    // Never shows on socket state alone before the first successful connect.
    this._timer = setInterval(() => {
      if (!navigator.onLine) refresh();
      else if (socketDead()) refresh();
      else {
        deadTicks = 0;
        setVisible(false);
      }
    }, 5000);

    // Initial state: hidden. First check only after load settles.
    setVisible(false);
    setTimeout(() => refresh(), 8000);
  },

  destroyed() {
    if (this._timer) clearInterval(this._timer);
  },
};
