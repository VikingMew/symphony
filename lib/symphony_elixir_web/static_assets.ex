defmodule SymphonyElixirWeb.StaticAssets do
  @moduledoc false

  @dashboard_css_paths [
    Path.expand("../../priv/static/dashboard/layout.css", __DIR__),
    Path.expand("../../priv/static/dashboard/components.css", __DIR__)
  ]
  @phoenix_html_js_path Application.app_dir(:phoenix_html, "priv/static/phoenix_html.js")
  @phoenix_js_path Application.app_dir(:phoenix, "priv/static/phoenix.js")
  @phoenix_live_view_js_path Application.app_dir(:phoenix_live_view, "priv/static/phoenix_live_view.js")

  for path <- @dashboard_css_paths, do: @external_resource(path)
  @external_resource @phoenix_html_js_path
  @external_resource @phoenix_js_path
  @external_resource @phoenix_live_view_js_path

  @dashboard_css Enum.map_join(@dashboard_css_paths, &File.read!/1)
  @phoenix_html_js File.read!(@phoenix_html_js_path)
  @phoenix_js File.read!(@phoenix_js_path)
  @phoenix_live_view_js File.read!(@phoenix_live_view_js_path)

  @assets %{
    "/dashboard.css" => {"text/css", @dashboard_css},
    "/vendor/phoenix_html/phoenix_html.js" => {"application/javascript", @phoenix_html_js},
    "/vendor/phoenix/phoenix.js" => {"application/javascript", @phoenix_js},
    "/vendor/phoenix_live_view/phoenix_live_view.js" => {"application/javascript", @phoenix_live_view_js}
  }

  @spec fetch(String.t()) :: {:ok, String.t(), binary()} | :error
  def fetch(path) when is_binary(path) do
    case Map.fetch(@assets, path) do
      {:ok, {content_type, body}} -> {:ok, content_type, body}
      :error -> :error
    end
  end
end
