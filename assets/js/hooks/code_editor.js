import CodeMirror from "codemirror"

// Modes
import "codemirror/mode/nginx/nginx"
import "codemirror/mode/shell/shell"
import "codemirror/mode/yaml/yaml"
import "codemirror/mode/markdown/markdown"
import "codemirror/mode/javascript/javascript"
import "codemirror/mode/css/css"
import "codemirror/mode/xml/xml"
import "codemirror/mode/htmlmixed/htmlmixed"
import "codemirror/mode/python/python"
import "codemirror/mode/ruby/ruby"
import "codemirror/mode/clike/clike"
import "codemirror/mode/properties/properties"
import "codemirror/mode/toml/toml"
import "codemirror/mode/sql/sql"
import "codemirror/mode/dockerfile/dockerfile"
import "codemirror/mode/go/go"
import "codemirror/mode/php/php"
import "codemirror/mode/rust/rust"
import "codemirror/mode/erlang/erlang"
import "codemirror/mode/groovy/groovy"
import "codemirror/mode/crystal/crystal"

// Addons
import "codemirror/addon/selection/active-line"
import "codemirror/addon/edit/closebrackets"
import "codemirror/addon/edit/matchbrackets"

export const CodeEditor = {
  mounted() {
    this.textarea = this.el
    const language = this.el.dataset.language || "text/plain"
    const theme = this.el.dataset.theme === "light" ? "eclipse" : "material"
    const readOnly = this.el.dataset.readonly === "true"

    this.editor = CodeMirror.fromTextArea(this.textarea, {
      lineNumbers: true,
      mode: language,
      theme: theme,
      readOnly: readOnly,
      lineWrapping: true,
      tabSize: 2,
      indentUnit: 2,
      styleActiveLine: !readOnly,
      autoCloseBrackets: !readOnly,
      matchBrackets: true,
      viewportMargin: Infinity,
      extraKeys: {
        "Ctrl-S": () => this.triggerSave(),
        "Cmd-S": () => this.triggerSave(),
      },
    })

    // Refresh after mount (needed when inside hidden tab)
    setTimeout(() => this.editor.refresh(), 50)

    // Handle save from LiveView (when user clicks Save button outside)
    this._saveHandler = ({ id }) => {
      if (!id || this.el.id === id || this.el.dataset.path === id) {
        this.triggerSave()
      }
    }
    this.handleEvent("code_editor_request_save", this._saveHandler)

    // Handle theme change from LiveView
    this._themeHandler = ({ theme, id }) => {
      if (!id || this.el.id === id) {
        this.editor.setOption("theme", theme === "light" ? "eclipse" : "material")
      }
    }
    this.handleEvent("code_editor_theme", this._themeHandler)

    // Handle external content update (e.g., when file is reloaded)
    this._updateHandler = ({ id, content, language: lang }) => {
      if (this.el.id === id || this.el.dataset.path === id) {
        if (content !== this.editor.getValue()) {
          this.editor.setValue(content)
        }
        if (lang && lang !== this.editor.getOption("mode")) {
          this.editor.setOption("mode", lang)
        }
      }
    }
    this.handleEvent("code_editor_update", this._updateHandler)

    // Also handle resize
    this._resizeObserver = new ResizeObserver(() => {
      try {
        this.editor.refresh()
      } catch (_e) {}
    })
    this._resizeObserver.observe(this.el.parentElement || this.el)

    if (window.IntersectionObserver) {
      this._io = new IntersectionObserver(
        (entries) => {
          for (const entry of entries) {
            if (entry.isIntersecting) this.editor.refresh()
          }
        },
        { threshold: 0.1 }
      )
      this._io.observe(this.el.parentElement || this.el)
    }

    // Direct Save button handling (simplified UX — no Edit/Cancel toggle)
    this._attachSaveButton()
    // Also handle any save button added later (LiveView re-render)
    this._saveObserver = new MutationObserver(() => this._attachSaveButton())
    this._saveObserver.observe(document.body, { childList: true, subtree: true })

    // Focus if editable
    if (!readOnly) {
      setTimeout(() => this.editor.focus(), 100)
    }
  },

  _attachSaveButton() {
    const path = this.el.dataset.path
    if (!path) return
    // Find save buttons for this path (files, nginx, systemd)
    const selectors = [
      `button[data-save-path="${CSS.escape(path)}"]`,
      `#save-files-${CSS.escape(path.replaceAll("/", "-"))}`,
      `#save-nginx-${CSS.escape(path.replaceAll("/", "-"))}`,
      `#save-systemd-${CSS.escape(path.replaceAll("/", "-"))}`,
    ]
    // Also try generic save buttons inside the same preview container
    const container = this.el.closest(".border-t")?.parentElement || this.el.closest(".marsad-code-editor-wrap")?.parentElement || document
    const buttons = container.querySelectorAll ? container.querySelectorAll("button[data-save-path]") : []
    for (const btn of buttons) {
      if (btn.dataset.savePath === path && !btn._codeEditorBound) {
        btn._codeEditorBound = true
        btn.addEventListener("click", (e) => {
          e.preventDefault()
          this.triggerSave()
        })
      }
    }
    // Fallback: also check document for any button with matching data-save-path
    for (const sel of selectors) {
      try {
        const btn = document.querySelector(sel)
        if (btn && !btn._codeEditorBound) {
          btn._codeEditorBound = true
          btn.addEventListener("click", (e) => {
            e.preventDefault()
            this.triggerSave()
          })
        }
      } catch (_e) {}
    }
  },

  updated() {
    if (!this.editor) return
    const newContent = this.el.value
    const newReadOnly = this.el.dataset.readonly === "true"
    const newTheme = this.el.dataset.theme === "light" ? "eclipse" : "material"
    const newMode = this.el.dataset.language || "text/plain"

    // Only update if changed and not dirty (user hasn't edited)
    // We check if editor is dirty by comparing current value with textarea's value
    // If LiveView changed the textarea's value (new file), we should update
    if (newContent !== this.editor.getValue()) {
      // If the editor is not focused or content is from server (new file), update
      // We use a simple heuristic: if the newContent is different and the editor's content
      // is not the same as the previous textarea value, update.
      // For now, just update if the path changed
      const newPath = this.el.dataset.path
      if (this._lastPath !== newPath || document.activeElement !== this.editor.getInputField()) {
        this.editor.setValue(newContent)
        this._lastPath = newPath
      }
    } else {
      this._lastPath = this.el.dataset.path
    }

    if (this.editor.getOption("readOnly") !== newReadOnly) {
      this.editor.setOption("readOnly", newReadOnly)
      this.editor.setOption("styleActiveLine", !newReadOnly)
      this.editor.setOption("autoCloseBrackets", !newReadOnly)
    }
    if (this.editor.getOption("theme") !== newTheme) {
      this.editor.setOption("theme", newTheme)
    }
    if (this.editor.getOption("mode") !== newMode) {
      this.editor.setOption("mode", newMode)
    }
    setTimeout(() => this.editor.refresh(), 20)
    // Re-attach save button if DOM changed
    this._attachSaveButton()
  },

  destroyed() {
    if (this._resizeObserver) this._resizeObserver.disconnect()
    if (this._io) this._io.disconnect()
    if (this._saveObserver) this._saveObserver.disconnect()
    if (this.editor) {
      try {
        this.editor.toTextArea()
      } catch (_e) {}
    }
  },

  triggerSave() {
    const content = this.editor.getValue()
    const path = this.el.dataset.path
    const id = this.el.id
    this.pushEvent("save_file_content", { path: path, content: content, editor_id: id })
  },
}
