defmodule FinalTrack.Themes do
  @moduledoc """
  Catalog of UI themes available to the app.

  Names map 1:1 to daisyUI theme plugin entries in `assets/css/app.css`;
  keep the two in sync. Shared with clayman, diogramos and pin_flip.
  """

  @neiam ~w(her afterdark forest sky clays stones)
  @builtin ~w(light dark)
  @custom ~w(blueprint)

  @type theme :: String.t()

  @spec all() :: [theme()]
  def all, do: @builtin ++ @neiam ++ @custom

  @spec neiam() :: [theme()]
  def neiam, do: @neiam

  @spec default() :: theme()
  def default, do: "afterdark"

  @doc """
  The pair "system" resolves to, following the OS preference.

  These are the two themes actually named `light` and `dark` — the ones
  daisyUI declares with a matching `color-scheme`, so form controls,
  scrollbars and the like are rendered by the browser to match. Any of the
  other themes can be chosen explicitly; only these two are picked
  automatically.
  """
  @spec system_light() :: theme()
  def system_light, do: "light"

  @spec system_dark() :: theme()
  def system_dark, do: "dark"

  @spec valid?(theme()) :: boolean()
  def valid?(theme) when is_binary(theme), do: theme in all() or theme == "system"
  def valid?(_), do: false
end
