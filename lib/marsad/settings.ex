defmodule Marsad.Settings do
  @moduledoc """
  Application settings stored in the database (theme, accent, …).

  Global for now; per-user scoping can be added once authentication exists.
  Unknown or missing values always fall back to curated defaults.
  """

  import Ecto.Query, warn: false

  alias Marsad.Repo
  alias Marsad.Settings.Setting

  @theme_modes ~w(light dark)

  @accents %{
    "ocean" => %{name: "Ocean", hex: "#0369A1", ink: "#FFFFFF"},
    "royal" => %{name: "Royal", hex: "#2563EB", ink: "#FFFFFF"},
    "emerald" => %{name: "Emerald", hex: "#047857", ink: "#FFFFFF"},
    "violet" => %{name: "Violet", hex: "#6D28D9", ink: "#FFFFFF"},
    "amber" => %{name: "Amber", hex: "#B45309", ink: "#FFFFFF"},
    "rose" => %{name: "Rose", hex: "#BE123C", ink: "#FFFFFF"}
  }

  @default_mode "dark"
  @default_accent "ocean"
  @default_interval 15_000
  @min_interval 5_000

  @doc "Curated accent choices as `%{key => %{name, hex, ink}}`."
  def accents, do: @accents

  @doc "Supported theme modes."
  def theme_modes, do: @theme_modes

  @doc "Reads a raw setting value, or `default` when absent."
  def get(key, default \\ nil) do
    case Repo.get_by(Setting, key: key) do
      nil -> default
      %Setting{value: value} -> value
    end
  end

  @doc "Stores a setting value (insert or update)."
  def put(key, value) when is_binary(key) and is_binary(value) do
    %Setting{}
    |> Setting.changeset(%{key: key, value: value})
    |> Repo.insert(
      on_conflict: [set: [value: value]],
      conflict_target: :key,
      returning: true
    )
  end

  def metrics_interval do
    raw = get("metrics_interval", to_string(@default_interval))

    case Integer.parse(raw) do
      {ms, ""} when ms >= @min_interval -> ms
      _ -> @default_interval
    end
  end

  def put_metrics_interval(ms) when is_integer(ms) and ms >= @min_interval do
    put("metrics_interval", to_string(ms))
  end

  def put_metrics_interval(_), do: {:error, :invalid_interval}

  @doc """
  Effective appearance: `%{mode, accent, hex, ink}` with validated values.
  Anything unknown falls back to the defaults.
  """
  def appearance do
    mode = get("theme_mode", @default_mode)
    accent_key = get("accent", @default_accent)
    accent = Map.get(@accents, accent_key, @accents[@default_accent])

    %{
      mode: if(mode in @theme_modes, do: mode, else: @default_mode),
      accent: if(Map.has_key?(@accents, accent_key), do: accent_key, else: @default_accent),
      hex: accent.hex,
      ink: accent.ink
    }
  end
end
