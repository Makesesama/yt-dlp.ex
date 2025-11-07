defmodule YtDlp.MixProject do
  use Mix.Project

  def project do
    [
      app: :yt_dlp,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Elixir wrapper for yt-dlp with GenServer-based download management",
      package: package(),
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {YtDlp.Application, []}
    ]
  end

  defp deps do
    [
      # Core dependencies
      {:jason, "~> 1.4"},

      # Development and testing
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}

      # Optional: Membrane Framework for advanced video processing
      # Uncomment these if you want to use YtDlp.Membrane module:
      # {:membrane_core, "~> 1.0"},
      # {:membrane_file_plugin, "~> 0.17.0"},
      # {:membrane_ffmpeg_swresample_plugin, "~> 0.20.0"},
      # {:membrane_mp4_plugin, "~> 0.35.0"}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/Makesesama/yt-dlp.ex"}
    ]
  end
end
