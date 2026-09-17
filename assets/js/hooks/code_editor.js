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

    this._lastPath = this.el.dataset.path
    this._savedContent = this.editor.getValue()
    this._dirty = false
    if (!readOnly) {
      this.editor.on("change", () => this._notifyDirty())
    }

    this.handleEvent("code_editor_saved", ({id, content}) => {
      if (id !== this.el.id) return
      this._savedContent = content
      this.textarea.value = content
      // The server cleared editing; re-assert it if typing continued during save.
      this._dirty = false
      this._notifyDirty()
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

    // Focus if editable
    if (!readOnly) {
      setTimeout(() => this.editor.focus(), 100)
    }
  },

  _attachSaveButton() {
    const container = this.el.closest(".marsad-code-editor-wrap")?.parentElement
    if (container === this._saveContainer) return
    this._saveContainer?.removeEventListener("click", this._saveClickHandler)
    this._saveContainer = container
    if (!container) return

    // Delegate so buttons inserted by later LiveView patches work too.
    this._saveClickHandler = (event) => {
      const button = event.target.closest("button[data-save-path]")
      if (button && button.dataset.savePath === this.el.dataset.path) {
        event.preventDefault()
        this.triggerSave()
      }
    }
    this._saveContainer.addEventListener("click", this._saveClickHandler)
  },

  updated() {
    if (!this.editor) return
    const newContent = this.el.value
    const newReadOnly = this.el.dataset.readonly === "true"
    const newTheme = this.el.dataset.theme === "light" ? "eclipse" : "material"
    const newMode = this.el.dataset.language || "text/plain"

    // Ignored textarea content can be stale during unrelated LiveView patches.
    // Only an explicit reload or a different path may replace the document.
    if (this._lastPath !== this.el.dataset.path) {
      this._lastPath = this.el.dataset.path
      this._savedContent = newContent
      this.editor.setValue(newContent)
      this._dirty = false
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

  _notifyDirty() {
    const dirty = this.editor.getValue() !== this._savedContent
    if (dirty === this._dirty) return
    this._dirty = dirty
    this.pushEvent("file-editor-dirty", {
      path: this.el.dataset.path, editor_id: this.el.id, dirty
    })
  },

  destroyed() {
    this._saveContainer?.removeEventListener("click", this._saveClickHandler)
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
