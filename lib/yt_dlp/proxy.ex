defmodule YtDlp.Proxy do
  @moduledoc """
  Unified interface for proxy operations that delegates to configured backend.

  This module automatically uses either the default `YtDlp.ProxyManager` or
  a custom backend implementing the `YtDlp.ProxyBackend` behaviour.

  ## Configuration

      # Use default in-memory backend (YtDlp.ProxyManager)
      config :yt_dlp,
        proxies: [...]

      # Use custom backend
      config :yt_dlp,
        proxy_backend: MyApp.CustomProxyBackend,
        proxy_backend_opts: [
          pool_name: :main,
          timeout: 5_000
        ]

  ## Usage

      # Get proxy (automatically uses configured backend)
      {:ok, proxy} = YtDlp.Proxy.get_proxy()

      # Report results
      YtDlp.Proxy.report_success(proxy.url)
      YtDlp.Proxy.report_failure(proxy.url)

  The library uses this module internally, so downloads with `use_proxy_manager: true`
  will automatically use your custom backend if configured.
  """

  @doc """
  Gets the next proxy from the configured backend.

  ## Examples

      {:ok, proxy} = YtDlp.Proxy.get_proxy()
      # => {:ok, %{url: "http://proxy.example.com:8080", timeout: 30_000}}
  """
  @spec get_proxy(keyword()) :: {:ok, map()} | {:error, term()}
  def get_proxy(opts \\ []) do
    case backend() do
      {module, backend_opts} when is_atom(module) ->
        # Custom backend - call directly
        merged_opts = Keyword.merge(backend_opts, opts)
        module.get_proxy(merged_opts)

      YtDlp.ProxyManager ->
        # Default backend - use GenServer
        YtDlp.ProxyManager.get_proxy()
    end
  end

  @doc """
  Reports successful use of a proxy.

  ## Examples

      YtDlp.Proxy.report_success("http://proxy.example.com:8080")
  """
  @spec report_success(String.t(), keyword()) :: :ok
  def report_success(proxy_url, opts \\ []) do
    case backend() do
      {module, backend_opts} when is_atom(module) ->
        merged_opts = Keyword.merge(backend_opts, opts)
        module.report_success(proxy_url, merged_opts)

      YtDlp.ProxyManager ->
        YtDlp.ProxyManager.report_success(proxy_url)
    end
  end

  @doc """
  Reports failed use of a proxy.

  ## Examples

      YtDlp.Proxy.report_failure("http://proxy.example.com:8080")
  """
  @spec report_failure(String.t(), keyword()) :: :ok
  def report_failure(proxy_url, opts \\ []) do
    case backend() do
      {module, backend_opts} when is_atom(module) ->
        merged_opts = Keyword.merge(backend_opts, opts)
        module.report_failure(proxy_url, merged_opts)

      YtDlp.ProxyManager ->
        YtDlp.ProxyManager.report_failure(proxy_url)
    end
  end

  @doc """
  Gets statistics from the configured backend.

  Not all backends may implement this. Returns `{:error, :not_implemented}`
  if the backend doesn't support statistics.

  ## Examples

      {:ok, stats} = YtDlp.Proxy.get_stats()
  """
  @spec get_stats(keyword()) :: {:ok, [map()]} | {:error, term()}
  def get_stats(opts \\ []) do
    case backend() do
      {module, backend_opts} when is_atom(module) ->
        merged_opts = Keyword.merge(backend_opts, opts)

        if function_exported?(module, :get_stats, 1) do
          module.get_stats(merged_opts)
        else
          {:error, :not_implemented}
        end

      YtDlp.ProxyManager ->
        {:ok, YtDlp.ProxyManager.get_stats()}
    end
  end

  # Private Functions

  defp backend do
    case Application.get_env(:yt_dlp, :proxy_backend) do
      nil ->
        # Use default ProxyManager
        YtDlp.ProxyManager

      module when is_atom(module) ->
        # Custom backend
        opts = Application.get_env(:yt_dlp, :proxy_backend_opts, [])
        {module, opts}
    end
  end
end
