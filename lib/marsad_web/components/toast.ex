defmodule MarsadWeb.Components.Toast do
  use Phoenix.Component
  import MarsadWeb.CoreComponents
  alias Phoenix.LiveView.JS

  attr :id, :string, required: true
  attr :type, :atom, default: :info, values: [:success, :error, :warning, :info]
  attr :message, :string, required: true
  attr :title, :string, default: nil
  attr :duration, :integer, default: 3000
  attr :closable, :boolean, default: true

  def toast(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="Toast"
      data-duration={@duration}
      class="fixed bottom-4 right-4 z-[9999] max-w-md pointer-events-auto"
    >
      <div class={[
        "flex items-start gap-3 p-4 rounded-lg shadow-xl border backdrop-blur-sm",
        "animate-slide-up transition-all duration-200",
        toast_classes(@type)
      ]}>
        <.icon name={toast_icon(@type)} class="w-5 h-5 flex-shrink-0 mt-0.5" />
        <div class="flex-1 min-w-0">
          <p :if={@title} class="text-sm font-semibold mb-1"><%= @title %></p>
          <p class="text-sm"><%= @message %></p>
        </div>
        <button
          :if={@closable}
          phx-click={hide_toast(@id)}
          class="flex-shrink-0 hover:opacity-70 transition-opacity"
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      </div>
    </div>
    """
  end

  defp toast_classes(:success), do: "bg-green-500/10 border-green-500/20 text-green-400"
  defp toast_classes(:error), do: "bg-red-500/10 border-red-500/20 text-red-400"
  defp toast_classes(:warning), do: "bg-yellow-500/10 border-yellow-500/20 text-yellow-400"
  defp toast_classes(:info), do: "bg-blue-500/10 border-blue-500/20 text-blue-400"

  defp toast_icon(:success), do: "hero-check-circle"
  defp toast_icon(:error), do: "hero-x-circle"
  defp toast_icon(:warning), do: "hero-exclamation-triangle"
  defp toast_icon(:info), do: "hero-information-circle"

  defp hide_toast(id) do
    JS.add_class("animate-slide-down", to: "##{id}")
    |> JS.hide(to: "##{id}", time: 200, transition: "opacity-0")
  end
end
