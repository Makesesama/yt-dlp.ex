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
      {:jason, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/Makesesama/yt-dlp.ex"}
    ]
  end
end
