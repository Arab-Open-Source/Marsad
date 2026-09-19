import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";

/**
 * XtermTerminal hook — LiveView <-> xterm.js bridge.
 *
 * Server -> client: push_event("terminal_output", %{data: binary})
 * Client -> server: pushEvent("terminal_input", %{data: binary}) raw,
 *   plus pushEvent("terminal_resize", %{cols, rows}) on fit.
 *
 * Two disciplines, chosen by the server via push_event("terminal_mode"):
 *  - "shell": raw passthrough to a persistent remote PTY — the server owns
 *    echo, history and job control, so vim/nano/top all work.
 *  - "demo": local line buffer (typing, arrows, backspace) for windows
 *    without a server; each submitted line is answered locally.
 *
 * Selection improvements (v2):
 *  - xterm.css is now bundled via app.css (vendor/xterm.css) so selection
 *    overlay and viewport are correctly positioned.
 *  - Right-click is smart: copy when there is a selection, otherwise paste.
 *  - Select-to-copy keeps the highlight visible (PuTTY-style) without clearing.
 *  - Double/triple-click word/line selection works via xterm defaults.
 *  - Hidden tabs re-fit when they become visible (ResizeObserver + updated).
 *  - Copy button preserves selection for re-copy / visual feedback.
 */
const TERMINAL_THEMES = {
  dark: {
    background: "#020617",
    foreground: "#F1F5F9",
    cursor: "#38BDF8",
    cursorAccent: "#020617",
    selectionBackground: "rgba(56, 189, 248, 0.42)",
    selectionInactiveBackground: "rgba(56, 189, 248, 0.22)",
    black: "#1E293B",
    red: "#FF5757",
    green: "#22C55E",
    yellow: "#FACC15",
    blue: "#38BDF8",
    magenta: "#C084FC",
    cyan: "#22D3EE",
    white: "#F1F5F9",
    brightBlack: "#475569",
    brightRed: "#FF7B72",
    brightGreen: "#4ADE80",
    brightYellow: "#FDE047",
    brightBlue: "#7DD3FC",
    brightMagenta: "#E9D5FF",
    brightCyan: "#67E8F9",
    brightWhite: "#FFFFFF",
  },
  light: {
    background: "#FFFFFF",
    foreground: "#0F172A",
    cursor: "#0284C7",
    cursorAccent: "#FFFFFF",
    selectionBackground: "rgba(2, 132, 199, 0.28)",
    selectionInactiveBackground: "rgba(2, 132, 199, 0.16)",
    black: "#0F172A",
    red: "#DC2626",
    green: "#059669",
    yellow: "#CA8A04",
    blue: "#2563EB",
    magenta: "#9333EA",
    cyan: "#0891B2",
    white: "#F8FAFC",
    brightBlack: "#64748B",
    brightRed: "#EF4444",
    brightGreen: "#10B981",
    brightYellow: "#EAB308",
    brightBlue: "#3B82F6",
    brightMagenta: "#A855F7",
    brightCyan: "#06B6D4",
    brightWhite: "#1E293B",
  },
};
export const XtermTerminal = {
  mounted() {
    this.lineBuffer = "";
    this.history = [];
    this.historyIndex = -1;
    this.prompt = this.el.dataset.prompt || "$ ";
    this.windowId = this.el.dataset.windowId;
    // Shell mode: raw passthrough to a persistent remote PTY (vim/top work).
    // Demo mode keeps the local line discipline below.
    this.shellMode = false;

    this.term = new Terminal({
      cursorBlink: true,
      cursorStyle: "bar",
      cursorWidth: 2,
      fontFamily: "'JetBrains Mono', 'Cascadia Code', ui-monospace, Menlo, Consolas, monospace",
      fontSize: 14.5,
      lineHeight: 1.45,
      letterSpacing: 0.2,
      fontWeight: 400,
      fontWeightBold: 700,
      allowBold: true,
      drawBoldTextInBrightColors: true,
      minimumContrastRatio: 4.5,
      theme: TERMINAL_THEMES[this.el.dataset.themeMode] || TERMINAL_THEMES.dark,
      scrollback: 8000,
      allowTransparency: true,
      convertEol: false,
      scrollOnUserInput: true,
      rightClickSelectsWord: true,
      wordSeparator: " ()[]{}'\"`",
      macOptionIsMeta: false,
      altClickMovesCursor: false,
    });

    this.fit = new FitAddon();
    this.term.loadAddon(this.fit);
    this.term.open(this.el);
    // Initial fit may fail if the tab is initially hidden; retry shortly.
    this.scheduleFit();
    this.pushEvent("terminal_resize", { cols: this.term.cols, rows: this.term.rows, window_id: this.windowId });

    this._outputHandler = ({ data, window_id }) => {
      if (window_id && window_id !== this.windowId) return;
      // Normalize lone \n so xterm renders correctly.
      this.term.write(String(data).replace(/\n(?!\r)/g, "\r\n"));
      // Keep viewport at bottom unless user has scrolled up and has selection.
      if (!this.term.hasSelection()) {
        this.term.scrollToBottom();
      }
    };
    this.handleEvent("terminal_output", this._outputHandler);
    this.handleEvent("terminal_clear", ({ window_id }) => {
      if (window_id && window_id !== this.windowId) return;
      this.term.clear();
    });
    // Explicit copy request (toolbar button): copies the current selection.
    this.handleEvent("terminal_copy_selection", ({ window_id }) => {
      if (window_id && window_id !== this.windowId) return;
      this.copySelection();
    });
    // Live appearance switch (all terminals follow the OS theme).
    this.handleEvent("terminal_theme", ({ mode }) => {
      if (TERMINAL_THEMES[mode]) this.term.options.theme = TERMINAL_THEMES[mode];
    });
    // Server-declared line discipline: "shell" = raw PTY passthrough,
    // "demo" = local line editing (no server attached).
    this.handleEvent("terminal_mode", ({ mode, window_id }) => {
      if (window_id && window_id !== this.windowId) return;
      this.shellMode = mode === "shell";
      if (this.shellMode) {
        // Abandon any half-typed local line; the remote owns the screen now.
        this.lineBuffer = "";
        this.historyIndex = -1;
      }
    });

    this.term.onData((data) => {
      if (this.shellMode) {
        // Raw passthrough: the remote PTY owns echo, line editing, history.
        this.pushEvent("terminal_input", { data, window_id: this.windowId });
      } else {
        this.handleInput(data);
      }
    });

    // Selection-aware keys: with an active selection, Ctrl+C / Ctrl+Shift+C
    // copy instead of cancelling the line; Shift+Insert pastes.
    // NOTE: e.code (physical key) is used instead of e.key so shortcuts keep
    // working on non-Latin keyboard layouts (e.g. Arabic).
    this.term.attachCustomKeyEventHandler((e) => {
      if (e.type !== "keydown") return true;
      const keyC = e.code === "KeyC";
      const keyA = e.code === "KeyA";
      const keyV = e.code === "KeyV";
      const ctrlC = (e.ctrlKey || e.metaKey) && keyC && !e.shiftKey && !e.altKey;
      const ctrlShiftC = (e.ctrlKey || e.metaKey) && keyC && e.shiftKey;
      const ctrlA = (e.ctrlKey || e.metaKey) && keyA && !e.shiftKey && !e.altKey;
      const ctrlV = (e.ctrlKey || e.metaKey) && keyV && !e.shiftKey && !e.altKey;

      if (this.shellMode) {
        // In shell mode the remote owns every key: only clipboard shortcuts
        // are intercepted. Ctrl+C without a selection goes through as SIGINT.
        if (ctrlShiftC || (ctrlC && this.term.hasSelection())) {
          this.copySelection();
          return false;
        }
        if (ctrlV) {
          this.pasteFromClipboard();
          return false;
        }
        if (e.shiftKey && e.key === "Insert") {
          this.pasteFromClipboard();
          return false;
        }
        if ((e.ctrlKey || e.metaKey) && keyV && e.shiftKey) {
          this.pasteFromClipboard();
          return false;
        }
        return true;
      }

      if (ctrlShiftC || (ctrlC && this.term.hasSelection())) {
        this.copySelection();
        return false;
      }
      if (ctrlC) {
        // Cancel the line explicitly: on non-Latin layouts xterm would
        // otherwise insert the localized character into the buffer.
        this.handleInput("\u0003");
        return false;
      }
      if (ctrlA) {
        this.term.selectAll();
        // Copy the full buffer selection to clipboard for convenience.
        window.setTimeout(() => this.copySelectionQuiet(), 10);
        return false;
      }
      if (ctrlV) {
        this.pasteFromClipboard();
        return false;
      }
      if (e.shiftKey && e.key === "Insert") {
        this.pasteFromClipboard();
        return false;
      }
      // Ctrl+Shift+V pastes as well (common Linux shortcut)
      if ((e.ctrlKey || e.metaKey) && keyV && e.shiftKey) {
        this.pasteFromClipboard();
        return false;
      }
      return true;
    });

    // Smart right-click: copy if selection exists, otherwise paste.
    // This matches VS Code / GNOME Terminal UX and avoids losing selections.
    this._onContextMenu = (e) => {
      e.preventDefault();
      if (this.term.hasSelection()) {
        this.copySelection();
      } else {
        this.pasteFromClipboard();
      }
    };
    this.el.addEventListener("contextmenu", this._onContextMenu);

    // Select-to-copy (PuTTY-style): releasing the mouse with an active
    // selection copies it immediately, no shortcut needed. Keep highlight.
    this._onMouseUp = () => {
      window.setTimeout(() => {
        if (this.term && this.term.hasSelection()) this.copySelectionQuiet();
      }, 30);
    };
    this.el.addEventListener("mouseup", this._onMouseUp);

    // Double-click handled natively by xterm (word select). Ensure triple-click
    // line select also copies quietly for convenience.
    this._onDblClick = () => {
      window.setTimeout(() => {
        if (this.term && this.term.hasSelection()) this.copySelectionQuiet();
      }, 30);
    };
    this.el.addEventListener("dblclick", this._onDblClick);

    this._resizeObserver = new ResizeObserver(() => {
      this.scheduleFit();
    });
    this._resizeObserver.observe(this.el);

    // Also observe the panel parent — tab switches toggle hidden/visible.
    this._panelEl = this.el.closest('[role="tabpanel"]') || this.el.parentElement;
    if (this._panelEl) {
      this._panelObserver = new ResizeObserver(() => this.scheduleFit());
      this._panelObserver.observe(this._panelEl);
    }

    // IntersectionObserver ensures we refit exactly when the terminal becomes visible
    // after being in a hidden tab (display:none -> flex).
    if (window.IntersectionObserver) {
      this._io = new IntersectionObserver(
        (entries) => {
          for (const entry of entries) {
            if (entry.isIntersecting) this.scheduleFit();
          }
        },
        { threshold: 0.1 }
      );
      this._io.observe(this.el);
    }

    // Ask the server for the welcome banner + transcript replay.
    // Cols/rows let the server size the remote PTY up front.
    this.pushEvent("terminal_ready", {
      window_id: this.windowId,
      cols: this.term.cols,
      rows: this.term.rows,
    });

    // Debug/testing handle (selection state, dims). Harmless in production.
    window.__marsadTerms = window.__marsadTerms || {};
    window.__marsadTerms[this.windowId] = this.term;
  },

  updated() {
    // LiveView may re-render the wrapper (e.g. tab switch). Re-fit shortly after.
    this.scheduleFit();
  },

  scheduleFit() {
    if (this._fitTimer) window.clearTimeout(this._fitTimer);
    this._fitTimer = window.setTimeout(() => {
      try {
        // Only fit when actually visible (offsetParent != null)
        if (this.el.offsetParent === null && this.el.offsetWidth === 0) return;
        this.fit.fit();
        this.pushEvent("terminal_resize", { cols: this.term.cols, rows: this.term.rows, window_id: this.windowId });
      } catch (_e) {
        // ignore fit errors while hidden/minimized
      }
    }, 30);
  },

  destroyed() {
    if (this._fitTimer) window.clearTimeout(this._fitTimer);
    if (this._resizeObserver) this._resizeObserver.disconnect();
    if (this._panelObserver) this._panelObserver.disconnect();
    if (this._io) this._io.disconnect();
    if (this._onContextMenu) this.el.removeEventListener("contextmenu", this._onContextMenu);
    if (this._onMouseUp) this.el.removeEventListener("mouseup", this._onMouseUp);
    if (this._onDblClick) this.el.removeEventListener("dblclick", this._onDblClick);
    if (window.__marsadTerms) delete window.__marsadTerms[this.windowId];
    if (this.term) this.term.dispose();
  },

  copySelection() {
    const text = this.term.getSelection();
    if (!text) {
      this.flashCopyButton(false, "Select text first");
      return;
    }
    const done = (ok) => {
      if (ok) {
        this.flashCopyButton(true);
        this.hideFallbackBox();
        // Keep selection visible so user can verify / re-copy.
        // Clear only on next user interaction, not immediately.
      } else {
        // Bulletproof escape hatch: a real textarea the user copies from
        // with their own OS shortcut (always works, no permissions needed).
        this.showFallbackBox(text);
        this.flashCopyButton(false, "Press Ctrl+C");
      }
      this.term.focus();
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(
        () => done(true),
        () => done(this.legacyCopy(text))
      );
    } else {
      done(this.legacyCopy(text));
    }
  },

  legacyCopy(text) {
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    let ok = false;
    try {
      ok = document.execCommand("copy");
    } catch (_e) {
      ok = false;
    }
    document.body.removeChild(ta);
    return ok;
  },

  // Visible, selectable fallback: clipboard API + execCommand both failed
  // (e.g. permissions, insecure context). Native copy from here always works.
  showFallbackBox(text) {
    this.hideFallbackBox();
    const box = document.createElement("div");
    box.setAttribute("data-marsad-fallback", "1");
    box.style.cssText =
      "position:absolute;right:12px;bottom:12px;z-index:60;max-width:min(420px,90%);" +
      "background:#0f172a;color:#e2e8f0;border:1px solid rgba(148,163,184,.35);" +
      "border-radius:12px;padding:10px 12px;box-shadow:0 12px 32px rgba(0,0,0,.5);" +
      "font:12px/1.5 ui-monospace,monospace;";
    const label = document.createElement("div");
    label.textContent = "Clipboard blocked — press Ctrl+C (then Esc to dismiss):";
    label.style.cssText = "opacity:.7;margin-bottom:6px;font-family:inherit;";
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.rows = Math.min(8, text.split("\n").length + 1);
    ta.style.cssText =
      "width:100%;box-sizing:border-box;background:#020617;color:#e2e8f0;" +
      "border:1px solid rgba(148,163,184,.3);border-radius:8px;padding:6px 8px;font:inherit;";
    ta.addEventListener("keydown", (e) => {
      if (e.key === "Escape") this.hideFallbackBox();
      e.stopPropagation();
    });
    box.appendChild(label);
    box.appendChild(ta);
    const host = this.el.parentElement || this.el;
    if (!host.style.position || host.style.position === "static") host.style.position = "relative";
    host.appendChild(box);
    this._fallbackBox = box;
    ta.focus();
    ta.select();
  },

  hideFallbackBox() {
    if (this._fallbackBox && this._fallbackBox.isConnected) {
      this._fallbackBox.remove();
    }
    this._fallbackBox = null;
  },

  // Brief visible feedback on the toolbar Copy button (✓ / ✗).
  flashCopyButton(ok, altText) {
    const btn = document.getElementById(`termcopy-${this.windowId}`);
    if (!btn) return;
    if (!btn.dataset.orig) btn.dataset.orig = btn.innerHTML;
    btn.innerHTML = ok ? "✓ Copied" : `✗ ${altText || "Copy failed"}`;
    window.clearTimeout(this._copyT);
    this._copyT = window.setTimeout(() => {
      const b = document.getElementById(`termcopy-${this.windowId}`);
      if (b && b.dataset.orig) b.innerHTML = b.dataset.orig;
    }, 1400);
  },

  // Silent variant for select-to-copy: keeps the highlight visible.
  copySelectionQuiet() {
    const text = this.term.getSelection();
    if (!text) return;
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).catch(() => this.legacyCopy(text));
    } else {
      this.legacyCopy(text);
    }
  },

  pasteFromClipboard() {
    if (navigator.clipboard && navigator.clipboard.readText) {
      navigator.clipboard
        .readText()
        .then((t) => {
          if (this.shellMode) {
            // Raw paste: newlines become carriage returns for the remote.
            this.pushEvent("terminal_input", {
              data: String(t || "").replace(/\r\n?/g, "\r"),
              window_id: this.windowId,
            });
          } else {
            this.injectPaste(t || "");
          }
        })
        .catch(() => {});
    }
    this.term.focus();
  },

  // Feeds pasted text through the same line discipline as typing:
  // printable chars accumulate, newlines submit the line.
  injectPaste(text) {
    for (const ch of String(text).replace(/\r\n?/g, "\n")) {
      if (ch === "\n") {
        this.handleInput("\r");
      } else if (ch >= " " && ch !== "\u007F") {
        this.lineBuffer += ch;
        this.term.write(ch);
      }
    }
  },

  handleInput(data) {
    // Enter -> submit the buffered line to the server
    if (data === "\r") {
      const line = this.lineBuffer;
      this.term.write("\r\n");
      if (line.trim() !== "") {
        this.history.unshift(line);
        this.historyIndex = -1;
      }
      this.lineBuffer = "";
      this.pushEvent("terminal_input", { data: line + "\n", window_id: this.windowId });
      return;
    }

    // Ctrl+C -> cancel current line
    if (data === "\u0003") {
      this.term.write("^C\r\n" + this.prompt);
      this.lineBuffer = "";
      this.historyIndex = -1;
      this.pushEvent("terminal_input", { data: "\u0003", window_id: this.windowId });
      return;
    }

    // Ctrl+L -> clear screen locally
    if (data === "\u000C") {
      this.term.clear();
      this.term.write(this.prompt + this.lineBuffer);
      return;
    }

    // Backspace
    if (data === "\u007F") {
      if (this.lineBuffer.length > 0) {
        this.lineBuffer = this.lineBuffer.slice(0, -1);
        this.term.write("\b \b");
      }
      return;
    }

    // History: up / down arrows
    if (data === "\u001b[A") {
      if (this.historyIndex < this.history.length - 1) {
        this.historyIndex += 1;
        this.replaceLine(this.history[this.historyIndex]);
      }
      return;
    }
    if (data === "\u001b[B") {
      if (this.historyIndex > 0) {
        this.historyIndex -= 1;
        this.replaceLine(this.history[this.historyIndex]);
      } else if (this.historyIndex === 0) {
        this.historyIndex = -1;
        this.replaceLine("");
      }
      return;
    }

    // Printable input
    if (data >= " " && !data.startsWith("\u001b")) {
      this.lineBuffer += data;
      this.term.write(data);
    }
  },

  replaceLine(next) {
    // Erase current buffer from the terminal, then write the history entry.
    for (let i = 0; i < this.lineBuffer.length; i++) this.term.write("\b \b");
    this.lineBuffer = next;
    this.term.write(next);
  },
};
