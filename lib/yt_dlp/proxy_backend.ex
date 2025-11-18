defmodule YtDlp.ProxyBackend do
  @moduledoc """
  Behaviour for implementing custom proxy management backends.

  This allows users to plug in their own proxy management systems
  (database-backed, Redis, external services, etc.) without modifying
  the library code.

  ## Example Implementation

      defmodule MyApp.CustomProxyBackend do
        @behaviour YtDlp.ProxyBackend

        @impl true
        def get_proxy(_opts) do
          # Your custom logic: query database, call API, etc.
          {:ok, %{url: "http://proxy.example.com:8080", timeout: 30_000}}
        end

        @impl true
        def report_success(proxy_url, _opts) do
          # Update your system
          MyApp.ProxyStats.increment_success(proxy_url)
          :ok
        end

        @impl true
        def report_failure(proxy_url, _opts) do
          # Update your system
          MyApp.ProxyStats.increment_failure(proxy_url)
          :ok
        end
      end

  ## Configuration

      # In config/config.exs
      config :yt_dlp,
        proxy_backend: MyApp.CustomProxyBackend,
        proxy_backend_opts: [
          pool_name: :main,
          timeout: 5_000
        ]

  ## Usage

      # The library will automatically use your backend
      {:ok, download_id} = YtDlp.download(url, use_proxy_manager: true)

  """

  @type proxy :: %{
          url: String.t(),
          timeout: pos_integer()
        }

  @type opts :: keyword()

  @doc """
  Gets the next proxy to use.

  Should return `{:ok, proxy}` with a map containing at least `:url` and `:timeout`,
  or `{:error, reason}` if no proxy is available.

  The `opts` parameter contains any configuration passed from the application
  config or runtime options.

  ## Examples

      @impl true
      def get_proxy(opts) do
        strategy = Keyword.get(opts, :strategy, :round_robin)

        case MyApp.ProxyDB.get_next_proxy(strategy) do
          %{url: url, timeout: timeout} ->
            {:ok, %{url: url, timeout: timeout}}

          nil ->
            {:error, :no_proxies}
        end
      end
  """
  @callback get_proxy(opts) :: {:ok, proxy()} | {:error, term()}

  @doc """
  Reports a successful use of a proxy.

  This callback is called after a successful download using the proxy.
  Implementations should update their tracking/statistics accordingly.

  ## Examples

      @impl true
      def report_success(proxy_url, _opts) do
        from(p in Proxy, where: p.url == ^proxy_url)
        |> Repo.update_all(inc: [success_count: 1])

        :ok
      end
  """
  @callback report_success(proxy_url :: String.t(), opts) :: :ok

  @doc """
  Reports a failed use of a proxy.

  This callback is called after a failed download using the proxy.
  Implementations should update their tracking/statistics and may
  choose to disable the proxy if it exceeds failure thresholds.

  ## Examples

      @impl true
      def report_failure(proxy_url, opts) do
        threshold = Keyword.get(opts, :failure_threshold, 3)

        proxy = Repo.get_by!(Proxy, url: proxy_url)
        new_failures = proxy.failure_count + 1

        proxy
        |> Proxy.changeset(%{
          failure_count: new_failures,
          enabled: new_failures < threshold
        })
        |> Repo.update!()

        :ok
      end
  """
  @callback report_failure(proxy_url :: String.t(), opts) :: :ok

  @doc """
  Optional callback to get statistics about proxies.

  If not implemented, returns `{:error, :not_implemented}`.
  """
  @callback get_stats(opts) :: {:ok, [map()]} | {:error, term()}

  @optional_callbacks get_stats: 1
end
