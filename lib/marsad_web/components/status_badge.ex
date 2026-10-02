defmodule MarsadWeb.Components.StatusBadge do
  use Phoenix.Component

  attr :status, :string, required: true
  attr :size, :atom, default: :md, values: [:sm, :md, :lg]
  attr :class, :string, default: ""

  def status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-full font-medium",
      badge_size(@size),
      badge_color(@status),
      @class
    ]}>
      <span class="w-1.5 h-1.5 rounded-full bg-current"></span>
      <%= format_status(@status) %>
    </span>
    """
  end

  defp badge_size(:sm), do: "px-2 py-0.5 text-xs"
  defp badge_size(:md), do: "px-2.5 py-1 text-xs"
  defp badge_size(:lg), do: "px-3 py-1.5 text-sm"

  defp badge_color("running"), do: "bg-green-500/10 text-green-400"
  defp badge_color("stopped"), do: "bg-gray-500/10 text-gray-400"
  defp badge_color("restarting"), do: "bg-yellow-500/10 text-yellow-400"
  defp badge_color("paused"), do: "bg-blue-500/10 text-blue-400"
  defp badge_color("exited"), do: "bg-red-500/10 text-red-400"
  defp badge_color("dead"), do: "bg-red-500/10 text-red-400"
  defp badge_color("active"), do: "bg-green-500/10 text-green-400"
  defp badge_color("inactive"), do: "bg-gray-500/10 text-gray-400"
  defp badge_color("failed"), do: "bg-red-500/10 text-red-400"
  defp badge_color(_), do: "bg-gray-500/10 text-gray-400"

  defp format_status(status) do
    status
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
