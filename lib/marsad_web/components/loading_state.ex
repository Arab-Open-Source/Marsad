defmodule MarsadWeb.Components.LoadingState do
  use Phoenix.Component
  import MarsadWeb.CoreComponents

  attr :text, :string, default: "Loading..."
  attr :size, :atom, default: :md, values: [:sm, :md, :lg]
  attr :class, :string, default: ""

  def loading_spinner(assigns) do
    ~H"""
    <div class={["flex items-center justify-center gap-3", @class]}>
      <.icon name="hero-arrow-path" class={["animate-spin", spinner_size(@size)]} />
      <span :if={@text} class={text_size(@size)}><%= @text %></span>
    </div>
    """
  end

  attr :rows, :integer, default: 5
  attr :class, :string, default: ""

  def skeleton_loader(assigns) do
    ~H"""
    <div class={["animate-pulse space-y-3", @class]}>
      <div :for={_ <- 1..@rows} class="flex items-center gap-3">
        <div class="w-10 h-10 bg-gray-700 rounded"></div>
        <div class="flex-1 space-y-2">
          <div class="h-4 bg-gray-700 rounded w-3/4"></div>
          <div class="h-3 bg-gray-700 rounded w-1/2"></div>
        </div>
      </div>
    </div>
    """
  end

  attr :overlay, :boolean, default: false
  attr :text, :string, default: "Loading..."

  def loading_overlay(assigns) do
    ~H"""
    <div class={[
      "absolute inset-0 flex items-center justify-center z-50",
      if(@overlay, do: "bg-gray-900/50 backdrop-blur-sm", else: "")
    ]}>
      <.loading_spinner text={@text} size={:lg} />
    </div>
    """
  end

  defp spinner_size(:sm), do: "w-4 h-4"
  defp spinner_size(:md), do: "w-6 h-6"
  defp spinner_size(:lg), do: "w-8 h-8"

  defp text_size(:sm), do: "text-xs"
  defp text_size(:md), do: "text-sm"
  defp text_size(:lg), do: "text-base"
end
