# تحسينات التصميم وتجربة المستخدم لـ Marsad

> وثيقة شاملة لتحسين تصميم وتجربة المستخدم في نظام إدارة الخوادم Marsad

## 📋 جدول المحتويات

- [تحسينات التصميم المرئي](#-تحسينات-التصميم-المرئي)
- [تحسينات تجربة المستخدم](#-تحسينات-تجربة-المستخدم)
- [تحسينات الأداء والتفاعلية](#-تحسينات-الأداء-والتفاعلية)
- [ميزات جديدة مقترحة](#-ميزات-جديدة-مقترحة)
- [تحسينات الأمان وUX](#-تحسينات-الأمان-وux)
- [تحسينات الوصولية](#-تحسينات-الوصولية)
- [خطة التنفيذ](#-خطة-التنفيذ)

---

## 🎨 تحسينات التصميم المرئي

### 1. نظام الألوان والتباين المحسّن

#### المشكلة الحالية
- بعض النصوص قد تفتقر للتباين الكافي في الوضع الداكن
- حاجة لمستويات أوضح من التدرج اللوني

#### الحل المقترح
إضافة متغيرات CSS محسّنة في `assets/css/app.css`:

```css
@theme {
  /* ألوان محسّنة للوضع الداكن */
  --color-surface-elevated: oklch(0.18 0.02 264);
  --color-border-subtle: oklch(0.25 0.04 264);
  
  /* تباين أفضل للنصوص */
  --text-primary: oklch(0.95 0.02 264);
  --text-secondary: oklch(0.70 0.04 264);
  --text-muted: oklch(0.50 0.04 264);
  
  /* حالات تفاعلية محسّنة */
  --interactive-hover: oklch(0.30 0.06 264);
  --interactive-active: oklch(0.35 0.08 264);
}
```

#### الفوائد
- ✅ تباين يتوافق مع WCAG 2.1 AA (4.5:1 للنصوص العادية)
- ✅ تجربة بصرية أكثر راحة في الإضاءة المنخفضة
- ✅ تمييز أفضل بين مستويات المعلومات

---

### 2. تحسين الأيقونات والمؤشرات البصرية

#### التحسينات المقترحة

##### أ) مؤشرات حالة الخادم
```elixir
# في lib/marsad_web/live/desktop_live.ex
defp server_status_indicator(server) do
  {icon, color, label} = case server.status do
    :online -> {"hero-check-circle", "text-green-500", "Online"}
    :offline -> {"hero-x-circle", "text-red-500", "Offline"}
    :connecting -> {"hero-arrow-path", "text-yellow-500 animate-spin", "Connecting"}
    :error -> {"hero-exclamation-triangle", "text-orange-500", "Error"}
  end
  
  assigns = %{icon: icon, color: color, label: label}
  
  ~H"""
  <div class="flex items-center gap-2">
    <.icon name={@icon} class={"w-4 h-4 #{@color}"} />
    <span class="text-sm">{@label}</span>
  </div>
  """
end
```

##### ب) Badge System للحاويات
```heex
<%!-- في nginx_panel.ex أو docker_panel.ex --%>
<span class={[
  "inline-flex items-center gap-1 px-2 py-1 rounded-full text-xs font-medium",
  case @status do
    "running" -> "bg-green-500/10 text-green-500"
    "stopped" -> "bg-gray-500/10 text-gray-400"
    "restarting" -> "bg-yellow-500/10 text-yellow-500"
    "paused" -> "bg-blue-500/10 text-blue-500"
    _ -> "bg-gray-500/10 text-gray-400"
  end
]}>
  <span class="w-2 h-2 rounded-full bg-current"></span>
  <%= String.capitalize(@status) %>
</span>
```

---

### 3. نظام الطباعة (Typography) المحسّن

#### إضافة مقياس طباعي متناسق

```css
/* في assets/css/app.css */

/* نظام الطباعة الأساسي */
.text-heading-xl {
  font-size: clamp(20px, 2vw, 24px);
  font-weight: 700;
  letter-spacing: -0.02em;
  line-height: 1.2;
}

.text-heading-lg {
  font-size: clamp(18px, 1.8vw, 20px);
  font-weight: 600;
  letter-spacing: -0.01em;
  line-height: 1.3;
}

.text-heading-md {
  font-size: clamp(16px, 1.5vw, 18px);
  font-weight: 600;
  letter-spacing: -0.01em;
  line-height: 1.4;
}

.text-body {
  font-size: clamp(14px, 1.2vw, 16px);
  font-weight: 400;
  line-height: 1.5;
}

.text-body-sm {
  font-size: clamp(12px, 1vw, 14px);
  font-weight: 400;
  line-height: 1.5;
}

.text-caption {
  font-size: clamp(11px, 0.9vw, 12px);
  font-weight: 400;
  line-height: 1.4;
  color: var(--text-muted);
}

/* طباعة monospace للأكواد */
.text-mono {
  font-family: 'JetBrains Mono', 'Fira Code', monospace;
  font-size: 0.9em;
  letter-spacing: -0.02em;
}
```

---

## 🚀 تحسينات تجربة المستخدم

### 1. نظام Toast Notifications

#### المشكلة
حالياً يتم استخدام `flash` فقط، وهو قد لا يكون واضحاً كفاية للعمليات الطويلة.

#### الحل
إضافة نظام إشعارات toast تفاعلي.

##### أ) إضافة Toast Component
ملف جديد: `lib/marsad_web/components/toast.ex`

```elixir
defmodule MarsadWeb.Components.Toast do
  use Phoenix.Component
  
  attr :id, :string, required: true
  attr :type, :atom, default: :info, values: [:success, :error, :warning, :info]
  attr :message, :string, required: true
  attr :duration, :integer, default: 3000
  attr :closable, :boolean, default: true
  
  def toast(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="Toast"
      data-duration={@duration}
      class={[
        "fixed bottom-4 right-4 z-[9999] max-w-md",
        "animate-slide-up-fade-in",
        "pointer-events-auto"
      ]}
    >
      <div class={[
        "flex items-start gap-3 p-4 rounded-lg shadow-lg",
        "backdrop-blur-sm border",
        case @type do
          :success -> "bg-green-500/10 border-green-500/20 text-green-500"
          :error -> "bg-red-500/10 border-red-500/20 text-red-500"
          :warning -> "bg-yellow-500/10 border-yellow-500/20 text-yellow-500"
          :info -> "bg-blue-500/10 border-blue-500/20 text-blue-500"
        end
      ]}>
        <.icon name={toast_icon(@type)} class="w-5 h-5 flex-shrink-0 mt-0.5" />
        <div class="flex-1 min-w-0">
          <p class="text-sm font-medium"><%= @message %></p>
        </div>
        <button
          :if={@closable}
          phx-click={JS.remove_class("animate-slide-up-fade-in", to: "##{@id}")
                     |> JS.add_class("animate-slide-down-fade-out", to: "##{@id}")
                     |> JS.hide(to: "##{@id}", time: 200)}
          class="flex-shrink-0 hover:opacity-70 transition-opacity"
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      </div>
    </div>
    """
  end
  
  defp toast_icon(:success), do: "hero-check-circle"
  defp toast_icon(:error), do: "hero-x-circle"
  defp toast_icon(:warning), do: "hero-exclamation-triangle"
  defp toast_icon(:info), do: "hero-information-circle"
end
```

##### ب) JavaScript Hook
إضافة في `assets/js/app.js`:

```javascript
// Toast Hook
Hooks.Toast = {
  mounted() {
    const duration = parseInt(this.el.dataset.duration);
    
    setTimeout(() => {
      this.el.classList.remove('animate-slide-up-fade-in');
      this.el.classList.add('animate-slide-down-fade-out');
      setTimeout(() => {
        this.el.remove();
      }, 200);
    }, duration);
  }
};
```

##### ج) استخدام Toast في LiveView
```elixir
def handle_event("docker_start", %{"id" => id}, socket) do
  case Services.docker_start(socket.assigns.session, id) do
    {:ok, _} ->
      {:noreply,
        socket
        |> push_event("show-toast", %{
          id: "toast-#{:erlang.unique_integer([:positive])}",
          type: "success",
          message: "Container #{id} started successfully",
          duration: 3000
        })}
    
    {:error, reason} ->
      {:noreply,
        socket
        |> push_event("show-toast", %{
          id: "toast-#{:erlang.unique_integer([:positive])}",
          type: "error",
          message: "Failed to start container: #{reason}",
          duration: 5000
        })}
  end
end
```

---

### 2. Command Palette (⌘K / Ctrl+K)

لوحة أوامر سريعة للوصول الفوري لكل الوظائف.

#### التنفيذ

##### أ) Component
ملف جديد: `lib/marsad_web/components/command_palette.ex`

```elixir
defmodule MarsadWeb.Components.CommandPalette do
  use Phoenix.Component
  alias Phoenix.LiveView.JS
  
  attr :id, :string, default: "command-palette"
  attr :servers, :list, required: true
  
  def command_palette(assigns) do
    ~H"""
    <div
      id={@id}
      class="hidden fixed inset-0 z-[10000] bg-black/50 backdrop-blur-sm"
      phx-click-away={JS.add_class("hidden", to: "##{@id}")}
    >
      <div class="flex items-start justify-center pt-[20vh] px-4">
        <div class="bg-gray-900 border border-gray-700 rounded-xl shadow-2xl w-full max-w-2xl">
          <%!-- Search Input --%>
          <div class="p-4 border-b border-gray-700">
            <div class="flex items-center gap-3">
              <.icon name="hero-magnifying-glass" class="w-5 h-5 text-gray-400" />
              <input
                type="text"
                placeholder="Search commands or servers..."
                class="flex-1 bg-transparent border-0 focus:ring-0 text-white placeholder-gray-400"
                phx-hook="CommandPaletteInput"
                autofocus
              />
              <kbd class="px-2 py-1 text-xs bg-gray-800 rounded border border-gray-700">ESC</kbd>
            </div>
          </div>
          
          <%!-- Commands List --%>
          <div class="max-h-96 overflow-y-auto p-2">
            <%!-- Quick Actions --%>
            <div class="mb-4">
              <div class="px-3 py-1 text-xs font-semibold text-gray-400 uppercase">Quick Actions</div>
              <button
                phx-click="open_terminal"
                class="w-full flex items-center gap-3 px-3 py-2 rounded hover:bg-gray-800 transition-colors text-left"
              >
                <.icon name="hero-command-line" class="w-5 h-5 text-blue-400" />
                <span>Open Terminal</span>
                <kbd class="ml-auto px-2 py-1 text-xs bg-gray-800 rounded">Alt+1</kbd>
              </button>
              <button
                phx-click="open_files"
                class="w-full flex items-center gap-3 px-3 py-2 rounded hover:bg-gray-800 transition-colors text-left"
              >
                <.icon name="hero-folder" class="w-5 h-5 text-green-400" />
                <span>Open Files</span>
                <kbd class="ml-auto px-2 py-1 text-xs bg-gray-800 rounded">Alt+2</kbd>
              </button>
              <button
                phx-click="open_docker"
                class="w-full flex items-center gap-3 px-3 py-2 rounded hover:bg-gray-800 transition-colors text-left"
              >
                <.icon name="hero-cube" class="w-5 h-5 text-purple-400" />
                <span>Open Docker</span>
                <kbd class="ml-auto px-2 py-1 text-xs bg-gray-800 rounded">Alt+3</kbd>
              </button>
            </div>
            
            <%!-- Servers --%>
            <div :if={@servers != []}>
              <div class="px-3 py-1 text-xs font-semibold text-gray-400 uppercase">Servers</div>
              <div :for={server <- @servers} class="mb-1">
                <button
                  phx-click="switch_server"
                  phx-value-id={server.id}
                  class="w-full flex items-center gap-3 px-3 py-2 rounded hover:bg-gray-800 transition-colors text-left"
                >
                  <.icon name="hero-server" class="w-5 h-5 text-cyan-400" />
                  <div class="flex-1 min-w-0">
                    <div class="font-medium"><%= server.name %></div>
                    <div class="text-xs text-gray-400"><%= server.host %></div>
                  </div>
                  <div class={[
                    "w-2 h-2 rounded-full",
                    if server.online, do: "bg-green-500", else: "bg-gray-500"
                  ]}></div>
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
```

##### ب) JavaScript Integration
```javascript
// في assets/js/app.js
window.addEventListener('keydown', (e) => {
  // Command Palette: Ctrl+K or Cmd+K
  if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
    e.preventDefault();
    const palette = document.getElementById('command-palette');
    palette.classList.toggle('hidden');
    if (!palette.classList.contains('hidden')) {
      palette.querySelector('input')?.focus();
    }
  }
  
  // Close on ESC
  if (e.key === 'Escape') {
    document.getElementById('command-palette')?.classList.add('hidden');
  }
});

// Hook للبحث
Hooks.CommandPaletteInput = {
  mounted() {
    this.handleInput = debounce((e) => {
      this.pushEvent('search_commands', {query: e.target.value});
    }, 200);
    
    this.el.addEventListener('input', this.handleInput);
  },
  destroyed() {
    this.el.removeEventListener('input', this.handleInput);
  }
};
```

---

### 3. Breadcrumbs Navigation في File Explorer

#### التنفيذ
في `lib/marsad_web/desktop/file_browser_panel.ex`:

```heex
<%!-- إضافة في بداية panel_content --%>
<div class="flex items-center gap-2 text-sm mb-4 px-4 py-2 bg-gray-800/50 rounded">
  <.icon name="hero-home" class="w-4 h-4 text-gray-400" />
  <button 
    phx-click="navigate_to_path" 
    phx-value-path="/"
    class="hover:text-accent transition-colors"
  >
    root
  </button>
  
  <%= for {segment, index} <- Enum.with_index(path_segments(@current_path)) do %>
    <.icon name="hero-chevron-right" class="w-4 h-4 text-gray-600" />
    <button 
      phx-click="navigate_to_path" 
      phx-value-path={build_path_up_to(index, path_segments(@current_path))}
      class={[
        "hover:text-accent transition-colors",
        if(index == length(path_segments(@current_path)) - 1, do: "font-semibold text-accent")
      ]}
    >
      <%= segment %>
    </button>
  <% end %>
</div>

<%!-- Helper functions في module --%>
defp path_segments(path) do
  path
  |> String.split("/", trim: true)
end

defp build_path_up_to(index, segments) do
  segments
  |> Enum.take(index + 1)
  |> Enum.join("/")
  |> then(&"/#{&1}")
end
```

---

### 4. Loading States المحسّنة

#### Skeleton Loaders
```heex
<%!-- Component للـ skeleton loader --%>
<div :if={@loading} class="animate-pulse space-y-3">
  <div :for={_ <- 1..5} class="flex items-center gap-3">
    <div class="w-10 h-10 bg-gray-700 rounded"></div>
    <div class="flex-1 space-y-2">
      <div class="h-4 bg-gray-700 rounded w-3/4"></div>
      <div class="h-3 bg-gray-700 rounded w-1/2"></div>
    </div>
  </div>
</div>
```

#### Inline Loading Indicators
```heex
<button
  phx-click="docker_start"
  phx-value-id={container.id}
  disabled={@starting_container == container.id}
  class="btn btn-sm"
>
  <.icon
    :if={@starting_container == container.id}
    name="hero-arrow-path"
    class="w-4 h-4 animate-spin"
  />
  <.icon
    :if={@starting_container != container.id}
    name="hero-play"
    class="w-4 h-4"
  />
  Start
</button>
```

---

### 5. Empty States المحسّنة

```heex
<%!-- Empty state component قابل لإعادة الاستخدام --%>
<div :if={@items == []} class="flex flex-col items-center justify-center py-16 px-4 text-center">
  <div class="w-20 h-20 rounded-full bg-gray-800 flex items-center justify-center mb-4">
    <.icon name={@icon} class="w-10 h-10 text-gray-600" />
  </div>
  <h3 class="text-lg font-semibold mb-2"><%= @title %></h3>
  <p class="text-sm text-gray-400 max-w-md mb-6"><%= @description %></p>
  <button :if={@action} phx-click={@action.event} class="btn btn-primary">
    <.icon :if={@action.icon} name={@action.icon} class="w-4 h-4 mr-2" />
    <%= @action.label %>
  </button>
</div>

<%!-- مثال الاستخدام --%>
<.empty_state
  :if={@containers == []}
  icon="hero-cube"
  title="No Containers Found"
  description="Get started by pulling a Docker image or creating a new container. Containers will appear here once they're created."
  action=%{
    label: "Pull Image",
    icon: "hero-arrow-down-tray",
    event: "show_pull_image_dialog"
  }
/>
```

---

## ⚡ تحسينات الأداء والتفاعلية

### 1. Optimistic Updates

#### المشكلة
العمليات مثل إيقاف/تشغيل الحاويات تستغرق وقتاً، والمستخدم لا يرى تغييراً فورياً.

#### الحل
```elixir
def handle_event("docker_stop", %{"id" => id}, socket) do
  # 1. تحديث UI فوراً (optimistic)
  containers = update_container_status(socket.assigns.containers, id, :stopping)
  socket = assign(socket, containers: containers, stopping_container: id)
  
  # 2. تنفيذ العملية في الخلفية
  Task.start(fn ->
    case Services.docker_stop(socket.assigns.session, id) do
      {:ok, _} ->
        send(self(), {:container_stopped, id, :success})
      {:error, reason} ->
        send(self(), {:container_stopped, id, {:error, reason}})
    end
  end)
  
  {:noreply, socket}
end

def handle_info({:container_stopped, id, :success}, socket) do
  containers = update_container_status(socket.assigns.containers, id, :stopped)
  
  {:noreply,
    socket
    |> assign(containers: containers, stopping_container: nil)
    |> push_event("show-toast", %{
      type: "success",
      message: "Container stopped successfully"
    })}
end

def handle_info({:container_stopped, id, {:error, reason}}, socket) do
  # إرجاع الحالة السابقة
  containers = update_container_status(socket.assigns.containers, id, :running)
  
  {:noreply,
    socket
    |> assign(containers: containers, stopping_container: nil)
    |> push_event("show-toast", %{
      type: "error",
      message: "Failed to stop container: #{reason}"
    })}
end

defp update_container_status(containers, id, new_status) do
  Enum.map(containers, fn container ->
    if container.id == id do
      %{container | status: new_status}
    else
      container
    end
  end)
end
```

---

### 2. Debounced Search

```javascript
// Debounce helper
function debounce(func, wait) {
  let timeout;
  return function executedFunction(...args) {
    const later = () => {
      clearTimeout(timeout);
      func(...args);
    };
    clearTimeout(timeout);
    timeout = setTimeout(later, wait);
  };
}

// Hook للبحث
Hooks.SearchInput = {
  mounted() {
    this.handleInput = debounce((e) => {
      this.pushEvent('search', {query: e.target.value});
    }, 300);
    
    this.el.addEventListener('input', this.handleInput);
  },
  destroyed() {
    this.el.removeEventListener('input', this.handleInput);
  }
};
```

```heex
<%!-- في file browser --%>
<input
  type="text"
  placeholder="Search files..."
  phx-hook="SearchInput"
  class="input"
/>
```

---

### 3. Virtual Scrolling للقوائم الطويلة

عند عرض عدد كبير من الملفات أو الحاويات:

```javascript
Hooks.VirtualScroll = {
  mounted() {
    this.page = 1;
    this.loading = false;
    
    this.el.addEventListener('scroll', () => {
      if (this.loading) return;
      
      const { scrollTop, scrollHeight, clientHeight } = this.el;
      
      // Load more when 80% scrolled
      if (scrollTop + clientHeight >= scrollHeight * 0.8) {
        this.loading = true;
        this.page++;
        this.pushEvent('load_more', {page: this.page}, () => {
          this.loading = false;
        });
      }
    });
  }
};
```

---

## 🎯 ميزات جديدة مقترحة

### 1. Favorites/Bookmarks System

#### Schema
ملف جديد: `lib/marsad/accounts/favorite_server.ex`

```elixir
defmodule Marsad.Accounts.FavoriteServer do
  use Ecto.Schema
  import Ecto.Changeset
  
  schema "favorite_servers" do
    belongs_to :admin, Marsad.Accounts.Admin
    belongs_to :server, Marsad.Fleet.Server
    field :position, :integer
    field :notes, :string
    
    timestamps()
  end
  
  def changeset(favorite, attrs) do
    favorite
    |> cast(attrs, [:admin_id, :server_id, :position, :notes])
    |> validate_required([:admin_id, :server_id])
    |> unique_constraint([:admin_id, :server_id])
  end
end
```

#### Migration
```elixir
defmodule Marsad.Repo.Migrations.CreateFavoriteServers do
  use Ecto.Migration
  
  def change do
    create table(:favorite_servers) do
      add :admin_id, references(:admins, on_delete: :delete_all), null: false
      add :server_id, references(:servers, on_delete: :delete_all), null: false
      add :position, :integer, default: 0
      add :notes, :text
      
      timestamps()
    end
    
    create unique_index(:favorite_servers, [:admin_id, :server_id])
    create index(:favorite_servers, [:admin_id])
  end
end
```

#### UI
```heex
<%!-- في server list --%>
<button
  phx-click="toggle_favorite"
  phx-value-id={server.id}
  class="p-1 hover:bg-gray-700 rounded transition-colors"
  title={if server.is_favorite, do: "Remove from favorites", else: "Add to favorites"}
>
  <.icon
    name={if server.is_favorite, do: "hero-star-solid", else: "hero-star"}
    class={[
      "w-5 h-5",
      if server.is_favorite, do: "text-yellow-500", else: "text-gray-400"
    ]}
  />
</button>
```

---

### 2. Quick Actions Panel

زر عائم للوصول السريع للوظائف الشائعة.

```heex
<%!-- في desktop_live.html.heex --%>
<div class="fixed bottom-24 right-6 z-50">
  <%!-- Backdrop للقائمة --%>
  <div
    :if={@show_quick_actions}
    class="fixed inset-0 bg-black/20"
    phx-click="toggle_quick_actions"
  >
  </div>
  
  <%!-- القائمة --%>
  <div
    :if={@show_quick_actions}
    class="absolute bottom-16 right-0 bg-gray-800 border border-gray-700 rounded-lg shadow-xl p-2 min-w-[200px] animate-scale-in"
  >
    <button
      :for={action <- quick_actions()}
      phx-click={action.event}
      class="w-full flex items-center gap-3 px-3 py-2 rounded hover:bg-gray-700 transition-colors text-left"
    >
      <.icon name={action.icon} class="w-5 h-5 text-gray-400" />
      <span class="text-sm"><%= action.label %></span>
      <kbd :if={action.shortcut} class="ml-auto px-1.5 py-0.5 text-xs bg-gray-900 rounded border border-gray-700">
        <%= action.shortcut %>
      </kbd>
    </button>
  </div>
  
  <%!-- الزر الرئيسي --%>
  <button
    phx-click="toggle_quick_actions"
    class={[
      "w-14 h-14 rounded-full shadow-lg flex items-center justify-center",
      "transition-all duration-200",
      if @show_quick_actions do
        "bg-gray-700 rotate-45"
      else
        "bg-accent hover:bg-accent/90"
      end
    ]}
  >
    <.icon name="hero-bolt" class="w-6 h-6 text-white" />
  </button>
</div>

<%!-- Helper function --%>
defp quick_actions do
  [
    %{label: "New Terminal", icon: "hero-command-line", event: "open_terminal", shortcut: "Alt+1"},
    %{label: "File Browser", icon: "hero-folder", event: "open_files", shortcut: "Alt+2"},
    %{label: "Docker", icon: "hero-cube", event: "open_docker", shortcut: "Alt+3"},
    %{label: "Metrics", icon: "hero-chart-bar", event: "open_metrics", shortcut: "Alt+4"},
    %{label: "Settings", icon: "hero-cog-6-tooth", event: "open_settings", shortcut: nil}
  ]
end
```

---

### 3. Terminal Themes

إضافة سمات مختلفة للـ terminal.

```javascript
// في assets/js/terminal.js
const TERMINAL_THEMES = {
  default: {
    background: '#1a1b26',
    foreground: '#c0caf5',
    cursor: '#c0caf5',
    black: '#15161e',
    red: '#f7768e',
    green: '#9ece6a',
    yellow: '#e0af68',
    blue: '#7aa2f7',
    magenta: '#bb9af7',
    cyan: '#7dcfff',
    white: '#a9b1d6'
  },
  dracula: {
    background: '#282a36',
    foreground: '#f8f8f2',
    cursor: '#f8f8f2',
    black: '#21222c',
    red: '#ff5555',
    green: '#50fa7b',
    yellow: '#f1fa8c',
    blue: '#bd93f9',
    magenta: '#ff79c6',
    cyan: '#8be9fd',
    white: '#f8f8f2'
  },
  solarized: {
    background: '#002b36',
    foreground: '#839496',
    cursor: '#839496',
    black: '#073642',
    red: '#dc322f',
    green: '#859900',
    yellow: '#b58900',
    blue: '#268bd2',
    magenta: '#d33682',
    cyan: '#2aa198',
    white: '#eee8d5'
  }
};

function applyTerminalTheme(terminal, themeName) {
  const theme = TERMINAL_THEMES[themeName] || TERMINAL_THEMES.default;
  terminal.options.theme = theme;
}
```

---

### 4. Enhanced Metrics Dashboard

#### مقارنة تاريخية
```elixir
defmodule Marsad.Metrics do
  def get_metrics_comparison(server_id, period \\ :hour) do
    now = DateTime.utc_now()
    
    {start_current, end_current, start_previous, end_previous} = 
      case period do
        :hour ->
          {
            DateTime.add(now, -1, :hour),
            now,
            DateTime.add(now, -2, :hour),
            DateTime.add(now, -1, :hour)
          }
        :day ->
          {
            DateTime.add(now, -1, :day),
            now,
            DateTime.add(now, -2, :day),
            DateTime.add(now, -1, :day)
          }
        :week ->
          {
            DateTime.add(now, -7, :day),
            now,
            DateTime.add(now, -14, :day),
            DateTime.add(now, -7, :day)
          }
      end
    
    current_metrics = get_average_metrics(server_id, start_current, end_current)
    previous_metrics = get_average_metrics(server_id, start_previous, end_previous)
    
    %{
      cpu: %{
        current: current_metrics.cpu,
        previous: previous_metrics.cpu,
        change: calculate_change(current_metrics.cpu, previous_metrics.cpu)
      },
      memory: %{
        current: current_metrics.memory,
        previous: previous_metrics.memory,
        change: calculate_change(current_metrics.memory, previous_metrics.memory)
      },
      disk: %{
        current: current_metrics.disk,
        previous: previous_metrics.disk,
        change: calculate_change(current_metrics.disk, previous_metrics.disk)
      }
    }
  end
  
  defp calculate_change(current, previous) when previous == 0, do: 0.0
  defp calculate_change(current, previous) do
    ((current - previous) / previous * 100)
    |> Float.round(1)
  end
end
```

#### UI للمقارنة
```heex
<div class="grid grid-cols-3 gap-4 mb-6">
  <div :for={{metric, data} <- @metrics_comparison} class="bg-gray-800 rounded-lg p-4">
    <div class="flex items-center justify-between mb-2">
      <span class="text-sm text-gray-400 uppercase"><%= metric %></span>
      <span class={[
        "text-sm font-medium px-2 py-0.5 rounded",
        cond do
          data.change > 10 -> "bg-red-500/10 text-red-500"
          data.change > 0 -> "bg-yellow-500/10 text-yellow-500"
          true -> "bg-green-500/10 text-green-500"
        end
      ]}>
        <%= if data.change > 0, do: "+", else: "" %><%= data.change %>%
      </span>
    </div>
    <div class="text-2xl font-bold mb-1">
      <%= format_metric_value(metric, data.current) %>
    </div>
    <div class="text-xs text-gray-500">
      Previous: <%= format_metric_value(metric, data.previous) %>
    </div>
  </div>
</div>
```

---

## 🔐 تحسينات الأمان وUX

### 1. تأكيدات العمليات الخطرة

#### Modal Component محسّن
```heex
<div
  :if={@show_delete_confirmation}
  class="fixed inset-0 z-[9999] flex items-center justify-center bg-black/50 backdrop-blur-sm"
  phx-click-away="cancel_delete"
>
  <div class="bg-gray-900 border border-red-500/20 rounded-xl shadow-2xl max-w-md w-full mx-4 animate-scale-in">
    <%!-- Header --%>
    <div class="p-6 border-b border-gray-800">
      <div class="flex items-start gap-4">
        <div class="w-12 h-12 rounded-full bg-red-500/10 flex items-center justify-center flex-shrink-0">
          <.icon name="hero-exclamation-triangle" class="w-6 h-6 text-red-500" />
        </div>
        <div class="flex-1">
          <h3 class="text-lg font-semibold mb-1">Delete Server?</h3>
          <p class="text-sm text-gray-400">This action cannot be undone.</p>
        </div>
      </div>
    </div>
    
    <%!-- Body --%>
    <div class="p-6 space-y-4">
      <div class="bg-gray-800/50 rounded-lg p-4 space-y-2">
        <div class="flex justify-between text-sm">
          <span class="text-gray-400">Server:</span>
          <span class="font-medium"><%= @server_to_delete.name %></span>
        </div>
        <div class="flex justify-between text-sm">
          <span class="text-gray-400">Host:</span>
          <span class="font-mono text-xs"><%= @server_to_delete.host %></span>
        </div>
      </div>
      
      <div>
        <label class="block text-sm font-medium mb-2">
          Type <span class="font-bold text-red-500">"<%= @server_to_delete.name %>"</span> to confirm:
        </label>
        <input
          type="text"
          phx-hook="ConfirmInput"
          data-expected={@server_to_delete.name}
          placeholder="Enter server name"
          class="input w-full"
          autocomplete="off"
        />
      </div>
    </div>
    
    <%!-- Footer --%>
    <div class="p-6 border-t border-gray-800 flex gap-3">
      <button
        phx-click="cancel_delete"
        class="flex-1 btn btn-secondary"
      >
        Cancel
      </button>
      <button
        id="confirm-delete-btn"
        phx-click="confirm_delete"
        disabled
        class="flex-1 btn bg-red-500 hover:bg-red-600 disabled:opacity-50 disabled:cursor-not-allowed"
      >
        Delete Server
      </button>
    </div>
  </div>
</div>
```

#### JavaScript Hook للتأكيد
```javascript
Hooks.ConfirmInput = {
  mounted() {
    const expected = this.el.dataset.expected;
    const confirmBtn = document.getElementById('confirm-delete-btn');
    
    this.el.addEventListener('input', (e) => {
      if (e.target.value === expected) {
        confirmBtn.disabled = false;
        confirmBtn.classList.add('animate-pulse');
      } else {
        confirmBtn.disabled = true;
        confirmBtn.classList.remove('animate-pulse');
      }
    });
    
    // Focus input
    setTimeout(() => this.el.focus(), 100);
  }
};
```

---

### 2. Session Timeout Warning

```javascript
// في assets/js/app.js
class SessionManager {
  constructor(warningTime = 25 * 60 * 1000, timeoutTime = 30 * 60 * 1000) {
    this.warningTime = warningTime;
    this.timeoutTime = timeoutTime;
    this.warningTimer = null;
    this.timeoutTimer = null;
    
    this.startTimers();
    this.setupActivityListeners();
  }
  
  startTimers() {
    this.clearTimers();
    
    // Warning after 25 minutes
    this.warningTimer = setTimeout(() => {
      this.showWarning();
    }, this.warningTime);
    
    // Logout after 30 minutes
    this.timeoutTimer = setTimeout(() => {
      this.logout();
    }, this.timeoutTime);
  }
  
  clearTimers() {
    if (this.warningTimer) clearTimeout(this.warningTimer);
    if (this.timeoutTimer) clearTimeout(this.timeoutTimer);
  }
  
  resetTimers() {
    this.startTimers();
    this.hideWarning();
  }
  
  setupActivityListeners() {
    ['mousedown', 'keydown', 'scroll', 'touchstart'].forEach(event => {
      document.addEventListener(event, () => this.resetTimers(), {passive: true});
    });
  }
  
  showWarning() {
    // Push event to LiveView
    window.liveSocket.getSocket()?.channels[0]?.push('session_warning', {
      remaining: Math.floor((this.timeoutTime - this.warningTime) / 1000)
    });
  }
  
  hideWarning() {
    window.liveSocket.getSocket()?.channels[0]?.push('session_warning_dismissed', {});
  }
  
  logout() {
    window.location.href = '/logout?reason=timeout';
  }
}

// Initialize
const sessionManager = new SessionManager();
```

---

## 📱 تحسينات الوصولية (Accessibility)

### 1. Keyboard Navigation محسّن

```javascript
// Global keyboard shortcuts
const shortcuts = {
  'Alt+1': () => openApp('terminal'),
  'Alt+2': () => openApp('files'),
  'Alt+3': () => openApp('docker'),
  'Alt+4': () => openApp('metrics'),
  'Alt+5': () => openApp('systemd'),
  'Alt+6': () => openApp('nginx'),
  'Alt+S': () => openApp('settings'),
  'Alt+Q': () => closeActiveWindow(),
  'Alt+W': () => toggleWindowMaximize(),
  'Ctrl+K': () => toggleCommandPalette(),
  'Escape': () => closeAllModals()
};

window.addEventListener('keydown', (e) => {
  const key = [
    e.ctrlKey && 'Ctrl',
    e.altKey && 'Alt',
    e.shiftKey && 'Shift',
    e.key
  ].filter(Boolean).join('+');
  
  if (shortcuts[key]) {
    e.preventDefault();
    shortcuts[key]();
  }
});
```

#### Help Modal للاختصارات
```heex
<div id="shortcuts-modal" class="modal hidden">
  <div class="modal-content max-w-2xl">
    <h2 class="text-xl font-bold mb-6">Keyboard Shortcuts</h2>
    
    <div class="space-y-6">
      <div>
        <h3 class="text-sm font-semibold text-gray-400 uppercase mb-3">Applications</h3>
        <div class="grid grid-cols-2 gap-3">
          <div :for={{label, key} <- app_shortcuts()} class="flex justify-between items-center p-2 bg-gray-800 rounded">
            <span class="text-sm"><%= label %></span>
            <kbd class="kbd"><%= key %></kbd>
          </div>
        </div>
      </div>
      
      <div>
        <h3 class="text-sm font-semibold text-gray-400 uppercase mb-3">Navigation</h3>
        <div class="grid grid-cols-2 gap-3">
          <div :for={{label, key} <- navigation_shortcuts()} class="flex justify-between items-center p-2 bg-gray-800 rounded">
            <span class="text-sm"><%= label %></span>
            <kbd class="kbd"><%= key %></kbd>
          </div>
        </div>
      </div>
    </div>
    
    <div class="mt-6 pt-4 border-t border-gray-800 text-center">
      <p class="text-sm text-gray-400">
        Press <kbd class="kbd">?</kbd> anytime to show this help
      </p>
    </div>
  </div>
</div>

<style>
.kbd {
  @apply px-2 py-1 text-xs font-mono bg-gray-900 border border-gray-700 rounded;
}
</style>
```

---

### 2. ARIA Labels محسّنة

```heex
<%!-- في docker_panel.ex --%>
<button
  phx-click="docker_start"
  phx-value-id={container.id}
  aria-label={"Start container #{container.name || container.id}"}
  aria-describedby={"container-#{container.id}-status"}
  class="btn btn-sm"
>
  <.icon name="hero-play" class="w-4 h-4" />
  <span class="sr-only">Start</span>
</button>

<div id={"container-#{container.id}-status"} class="sr-only">
  Container <%= container.name || container.id %> is currently <%= container.status %>
</div>

<%!-- Screen reader only class --%>
<style>
.sr-only {
  position: absolute;
  width: 1px;
  height: 1px;
  padding: 0;
  margin: -1px;
  overflow: hidden;
  clip: rect(0, 0, 0, 0);
  white-space: nowrap;
  border-width: 0;
}
</style>
```

---

### 3. Focus Indicators واضحة

```css
/* في assets/css/app.css */

/* Focus ring للعناصر التفاعلية */
button:focus-visible,
a:focus-visible,
input:focus-visible,
select:focus-visible,
textarea:focus-visible {
  outline: 2px solid theme('colors.accent');
  outline-offset: 2px;
  border-radius: 0.375rem;
}

/* Custom focus للـ windows */
.desktop-window:focus-within {
  box-shadow: 0 0 0 2px theme('colors.accent / 0.5');
}

/* Skip to content link */
.skip-to-content {
  position: absolute;
  top: -40px;
  left: 0;
  background: theme('colors.accent');
  color: white;
  padding: 8px 16px;
  text-decoration: none;
  z-index: 10000;
}

.skip-to-content:focus {
  top: 0;
}
```

---

## 🎨 نظام تصميم موحّد

### استخدام design tokens

```css
/* ملف: assets/design-tokens.css */

:root {
  /* Colors - Primitives */
  --color-gray-950: oklch(0.10 0.02 264);
  --color-gray-900: oklch(0.15 0.02 264);
  --color-gray-800: oklch(0.20 0.02 264);
  --color-gray-700: oklch(0.30 0.03 264);
  --color-gray-600: oklch(0.40 0.03 264);
  --color-gray-500: oklch(0.50 0.04 264);
  --color-gray-400: oklch(0.60 0.04 264);
  --color-gray-300: oklch(0.70 0.03 264);
  --color-gray-200: oklch(0.80 0.02 264);
  --color-gray-100: oklch(0.90 0.02 264);
  --color-gray-50: oklch(0.95 0.01 264);
  
  /* Accent colors */
  --color-ocean-500: oklch(0.55 0.22 230);
  --color-emerald-500: oklch(0.60 0.20 150);
  --color-amber-500: oklch(0.75 0.18 85);
  --color-rose-500: oklch(0.60 0.22 15);
  --color-violet-500: oklch(0.55 0.22 290);
  --color-royal-500: oklch(0.50 0.24 260);
  
  /* Semantic tokens */
  --color-background: var(--color-gray-950);
  --color-surface: var(--color-gray-900);
  --color-surface-elevated: var(--color-gray-800);
  
  --color-text-primary: var(--color-gray-50);
  --color-text-secondary: var(--color-gray-400);
  --color-text-muted: var(--color-gray-600);
  
  --color-border: var(--color-gray-800);
  --color-border-subtle: var(--color-gray-900);
  
  --color-accent: var(--color-ocean-500);
  --color-success: var(--color-emerald-500);
  --color-warning: var(--color-amber-500);
  --color-error: var(--color-rose-500);
  
  /* Spacing scale */
  --space-1: 0.25rem;
  --space-2: 0.5rem;
  --space-3: 0.75rem;
  --space-4: 1rem;
  --space-6: 1.5rem;
  --space-8: 2rem;
  --space-12: 3rem;
  --space-16: 4rem;
  
  /* Typography */
  --font-sans: 'Inter', system-ui, -apple-system, sans-serif;
  --font-mono: 'JetBrains Mono', 'Fira Code', monospace;
  
  /* Shadows */
  --shadow-sm: 0 1px 2px 0 rgb(0 0 0 / 0.3);
  --shadow-md: 0 4px 6px -1px rgb(0 0 0 / 0.4);
  --shadow-lg: 0 10px 15px -3px rgb(0 0 0 / 0.5);
  --shadow-xl: 0 20px 25px -5px rgb(0 0 0 / 0.6);
  
  /* Transitions */
  --transition-fast: 150ms ease-in-out;
  --transition-base: 200ms ease-in-out;
  --transition-slow: 300ms ease-in-out;
}

/* استخدام الـ tokens */
.desktop-window {
  background: var(--color-surface);
  border: 1px solid var(--color-border);
  box-shadow: var(--shadow-lg);
  transition: box-shadow var(--transition-base);
}

.btn {
  padding: var(--space-2) var(--space-4);
  border-radius: var(--space-2);
  font-family: var(--font-sans);
  transition: all var(--transition-fast);
}
```

---

## 📅 خطة التنفيذ

### المرحلة 1: Quick Wins (أسبوع 1)
- [x] إضافة Toast Notifications
- [x] تحسين Loading States
- [x] Empty States محسّنة
- [x] تحسين نظام الألوان والتباين
- [x] Badge System للحالات

### المرحلة 2: UX Enhancements (أسبوع 2)
- [ ] Command Palette (⌘K)
- [ ] Breadcrumbs Navigation
- [ ] Optimistic Updates
- [ ] Debounced Search
- [ ] Quick Actions Panel

### المرحلة 3: New Features (أسبوع 3-4)
- [ ] Favorites System
- [ ] Terminal Themes
- [ ] Enhanced Metrics Dashboard
- [ ] Session Timeout Warning
- [ ] Keyboard Shortcuts System

### المرحلة 4: Accessibility & Polish (أسبوع 5)
- [ ] ARIA Labels شاملة
- [ ] Keyboard Navigation كامل
- [ ] Focus Indicators محسّنة
- [ ] Help Modal للاختصارات
- [ ] توثيق كامل للوصولية

### المرحلة 5: Mobile & Responsive (أسبوع 6)
- [ ] تحسينات الشاشات الصغيرة
- [ ] Touch gestures
- [ ] Mobile-specific UI adaptations
- [ ] PWA capabilities

---

## 🔍 الخطوات التالية

### للبدء فوراً:
1. اختر مرحلة من خطة التنفيذ
2. راجع الكود المقترح لكل ميزة
3. اختبر على بيئة التطوير
4. اجمع feedback من المستخدمين

### للتخصيص:
- عدّل design tokens حسب هوية علامتك التجارية
- اضبط الاختصارات حسب تفضيلات المستخدمين
- خصص Terminal themes حسب الحاجة

### للمساهمة:
- كل التحسينات المقترحة قابلة للتطبيق تدريجياً
- يمكن تطبيق أي ميزة بشكل مستقل
- الأولوية للميزات الأكثر تأثيراً على تجربة المستخدم

---

## 📚 مراجع إضافية

- [Phoenix LiveView Docs](https://hexdocs.pm/phoenix_live_view/)
- [WCAG 2.1 Guidelines](https://www.w3.org/WAI/WCAG21/quickref/)
- [Tailwind CSS](https://tailwindcss.com/docs)
- [ARIA Authoring Practices](https://www.w3.org/WAI/ARIA/apg/)

---

**آخر تحديث:** 2026-09-19
