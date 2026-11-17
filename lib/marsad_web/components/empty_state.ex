defmodule MarsadWeb.Components.EmptyState do
  use Phoenix.Component
  import MarsadWeb.CoreComponents

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :action, :map, default: nil
  attr :class, :string, default: ""
  attr :id, :string, default: nil

  def empty_state(assigns) do
    ~H"""
    <div id={@id} class={["flex flex-col items-center justify-center py-16 px-4 text-center", @class]}>
      <div class="w-20 h-20 rounded-full bg-gray-800 flex items-center justify-center mb-4">
        <.icon name={@icon} class="w-10 h-10 text-gray-600" />
      </div>
      <h3 class="text-lg font-semibold mb-2">{@title}</h3>
      <p class="text-sm text-gray-400 max-w-md mb-6">{@description}</p>
      <.action_button :if={@action} action={@action} />
    </div>
    """
  end

  defp action_button(%{action: action} = assigns) when is_map(action) do
    ~H"""
    <button phx-click={@action.event} class="btn btn-primary">
      <.icon :if={@action.icon} name={@action.icon} class="w-4 h-4 mr-2" />
      {@action.label}
    </button>
    """
  end

  defp action_button(assigns), do: ~H""
end
