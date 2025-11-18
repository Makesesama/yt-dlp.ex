defmodule YtDlp.Command do
  @moduledoc """
  Executes yt-dlp commands using Elixir ports.

  This module provides a low-level interface for running yt-dlp commands
  and handling their output. It uses System.cmd/3 for simple command execution.
  """

  require Logger
  alias YtDlp.Error
  alias YtDlp.Proxy

  @type command_result :: {:ok, map()} | {:error, Error.error()}

  @doc """
  Gets the path to the yt-dlp binary.

  Returns the value of YT_DLP_PATH environment variable if set,
  otherwise defaults to "yt-dlp" (assuming it's in PATH via Nix).
  """
  @spec binary_path() :: String.t()
  def binary_path do
    System.get_env("YT_DLP_PATH", "yt-dlp")
  end

  @doc """
  Executes a yt-dlp command with the given arguments.

  ## Parameters

    * `args` - List of command-line arguments to pass to yt-dlp
    * `opts` - Keyword list of options (default: [])
      * `:timeout` - Command timeout in milliseconds (default: 300_000 - 5 minutes)
      * `:proxy` - Proxy URL to use (e.g., "http://proxy.example.com:8080")
      * `:use_proxy_manager` - Use ProxyManager for automatic proxy rotation (default: false)

  ## Returns

    * `{:ok, output}` - Command succeeded with stdout output
    * `{:error, reason}` - Command failed with error message

  ## Examples

      # Get yt-dlp version
      YtDlp.Command.run(["--version"])
      # => {:ok, "2025.10.22\\n"}

      # Get help text
      YtDlp.Command.run(["--help"])
      # => {:ok, "Usage: yt-dlp [OPTIONS] URL [URL...]\\n..."}

      # With specific proxy
      YtDlp.Command.run(["--version"], proxy: "http://proxy.example.com:8080")

      # With automatic proxy rotation
      YtDlp.Command.run(["--version"], use_proxy_manager: true)
  """
  @spec run([String.t()], keyword()) :: {:ok, String.t()} | {:error, Error.error()}
  def run(args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 300_000)
    use_proxy_manager = Keyword.get(opts, :use_proxy_manager, false)
    proxy_opt = Keyword.get(opts, :proxy)

    {args_with_proxy, proxy_info} = add_proxy_args(args, proxy_opt, use_proxy_manager)
    binary = binary_path()

    Logger.debug("Running yt-dlp command: #{binary} #{Enum.join(args_with_proxy, " ")}")

    effective_timeout = get_effective_timeout(proxy_info, timeout)
    result = execute_command(binary, args_with_proxy, effective_timeout)

    report_proxy_result(proxy_info, result)
    result
  end

  @doc """
  Executes a yt-dlp command and returns parsed JSON output.

  This is useful for commands that output JSON (using --dump-json or --print-json flags).

  ## Parameters

    * `args` - List of command-line arguments (should include JSON output flags)
    * `opts` - Keyword list of options (passed to run/2)

  ## Returns

    * `{:ok, decoded_json}` - Successfully parsed JSON output
    * `{:error, reason}` - Command failed or JSON parsing failed

  ## Examples

      # Returns decoded JSON with video metadata
      YtDlp.Command.run_json(["--dump-json", "--playlist-items", "1", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"])
      # => {:ok, %{"id" => "dQw4w9WgXcQ", "title" => "Rick Astley - Never Gonna Give You Up", ...}}
  """
  @spec run_json([String.t()], keyword()) :: {:ok, map() | list()} | {:error, Error.error()}
  def run_json(args, opts \\ []) do
    case run(args, opts) do
      {:ok, output} ->
        # yt-dlp may output warnings before JSON, extract just the JSON part
        json_output = extract_json(output)

        case Jason.decode(json_output) do
          {:ok, json} ->
            {:ok, json}

          {:error, _error} ->
            {:error,
             Error.parse_error("Failed to parse JSON output",
               input: String.slice(json_output, 0, 200),
               expected: "valid JSON"
             )}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Extract JSON from output that may contain warnings
  defp extract_json(output) do
    # Find the first { or [ to start of JSON
    output
    |> String.split("\n")
    |> Enum.drop_while(fn line ->
      trimmed = String.trim(line)

      trimmed == "" or String.starts_with?(trimmed, "WARNING:") or
        not (String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "["))
    end)
    |> Enum.join("\n")
  end

  @doc """
  Gets video information without downloading.

  ## Parameters

    * `url` - Video URL
    * `opts` - Additional options

  ## Returns

    * `{:ok, video_info}` - Map containing video metadata
    * `{:error, reason}` - Failed to get video info
  """
  @spec get_info(String.t(), keyword()) :: command_result()
  def get_info(url, opts \\ []) do
    args = [
      "--dump-json",
      "--no-playlist",
      "--skip-download",
      url
    ]

    run_json(args, opts)
  end

  @doc """
  Downloads a video to the specified directory.

  This uses Port-based communication for real-time progress tracking.

  ## Parameters

    * `url` - Video URL
    * `output_dir` - Directory to save the video (default: current directory)
    * `opts` - Additional options
      * `:format` - Video format (default: "best")
      * `:filename_template` - Output filename template (default: "%(title)s.%(ext)s")
      * `:progress_callback` - Function to call with progress updates: `(progress :: map()) -> any()`
      * `:timeout` - Download timeout in milliseconds (default: 1_800_000 - 30 minutes)

  ## Returns

    * `{:ok, %{path: video_path, url: url}}` - Download succeeded
    * `{:error, reason}` - Download failed

  ## Progress Callback

  The progress callback receives a map with the following fields:

      %{
        percent: 45.2,           # Download percentage (0-100)
        total_size: "10.5MiB",  # Total file size
        downloaded: "4.75MiB",   # Downloaded so far
        speed: "1.2MiB/s",       # Current download speed
        eta: "00:05"             # Estimated time remaining
      }
  """
  @spec download(String.t(), String.t(), keyword()) :: command_result()
  def download(url, output_dir \\ ".", opts \\ []) do
    format = Keyword.get(opts, :format, "best")
    filename_template = Keyword.get(opts, :filename_template, "%(title)s.%(ext)s")
    timeout = Keyword.get(opts, :timeout, 1_800_000)
    progress_callback = Keyword.get(opts, :progress_callback)

    output_path = Path.join(output_dir, filename_template)

    args = [
      "--format",
      format,
      "--output",
      output_path,
      "--no-playlist",
      "--newline",
      "--progress",
      "--print",
      "after_move:filepath",
      url
    ]

    binary = binary_path()

    # Use Port for streaming progress
    case YtDlp.Port.run(binary, args, timeout: timeout, progress_callback: progress_callback) do
      {:ok, output} ->
        # The last line should contain the actual file path
        filepath =
          output
          |> String.trim()
          |> String.split("\n")
          |> List.last()
          |> String.trim()

        # Verify file exists
        if filepath != "" and File.exists?(filepath) do
          {:ok, %{path: filepath, url: url}}
        else
          {:error,
           Error.not_found_error("Download completed but file not found",
             resource: :file,
             identifier: filepath
           )}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Downloads a video with a reference to cancel it.

  Returns a PID that can be used to cancel the download via `cancel_download/1`.

  ## Parameters

    * `url` - Video URL
    * `output_dir` - Directory to save the video
    * `opts` - Download options (same as `download/3`)
    * `reply_to` - PID to send result message to

  ## Returns

    * `{:ok, pid}` - Download started, returns PID for cancellation
  """
  @spec download_async(String.t(), String.t(), keyword(), pid()) :: {:ok, pid()}
  def download_async(url, output_dir \\ ".", opts \\ [], reply_to) do
    format = Keyword.get(opts, :format, "best")
    filename_template = Keyword.get(opts, :filename_template, "%(title)s.%(ext)s")
    timeout = Keyword.get(opts, :timeout, 1_800_000)
    progress_callback = Keyword.get(opts, :progress_callback)

    output_path = Path.join(output_dir, filename_template)

    args = [
      "--format",
      format,
      "--output",
      output_path,
      "--no-playlist",
      "--newline",
      "--progress",
      "--print",
      "after_move:filepath",
      url
    ]

    binary = binary_path()

    # Start Port GenServer for this download
    {:ok, port_pid} = GenServer.start_link(YtDlp.Port, {binary, args, progress_callback})

    # Start a task to wait for completion and send result to reply_to
    Task.start(fn ->
      result =
        try do
          case GenServer.call(port_pid, :wait_for_completion, timeout) do
            {:ok, output} ->
              filepath =
                output
                |> String.trim()
                |> String.split("\n")
                |> List.last()
                |> String.trim()

              if filepath != "" and File.exists?(filepath) do
                {:ok, %{path: filepath, url: url}}
              else
                {:error,
                 Error.not_found_error("Download completed but file not found",
                   resource: :file,
                   identifier: filepath
                 )}
              end

            {:error, reason} ->
              {:error, reason}
          end
        catch
          :exit, {:timeout, _} ->
            YtDlp.Port.cancel(port_pid)

            {:error,
             Error.timeout_error("Download timed out",
               timeout: timeout,
               operation: :download
             )}

          :exit, reason ->
            {:error,
             Error.command_error("Download process exited unexpectedly",
               output: inspect(reason)
             )}
        end

      send(reply_to, {:download_result, url, result})
    end)

    {:ok, port_pid}
  end

  @doc """
  Cancels an active download.

  ## Parameters

    * `port_pid` - PID returned from `download_async/4`
  """
  @spec cancel_download(pid()) :: :ok
  def cancel_download(port_pid) do
    YtDlp.Port.cancel(port_pid)
  end

  # Classify command errors into structured error types
  defp classify_command_error(output, exit_code, args) do
    output_lower = String.downcase(output)
    command = "yt-dlp " <> Enum.join(args, " ")

    cond do
      network_error?(output_lower) ->
        build_network_error(output, args)

      not_found_error?(output_lower) ->
        build_not_found_error(args)

      timeout_error?(output_lower) ->
        Error.timeout_error("Download timed out", operation: :download)

      validation_error?(output_lower) ->
        Error.validation_error("Invalid yt-dlp options", value: args)

      dependency_error?(output_lower) ->
        build_dependency_error()

      true ->
        Error.command_error("yt-dlp command failed",
          exit_code: exit_code,
          output: String.trim(output),
          command: command
        )
    end
  end

  defp network_error?(output_lower) do
    String.contains?(output_lower, "unable to download") or
      String.contains?(output_lower, "http error") or
      String.contains?(output_lower, "urlopen error") or
      String.contains?(output_lower, "connection") or
      String.contains?(output_lower, "network")
  end

  defp not_found_error?(output_lower) do
    String.contains?(output_lower, "video unavailable") or
      String.contains?(output_lower, "not found") or
      String.contains?(output_lower, "no video formats") or
      String.contains?(output_lower, "this video is unavailable")
  end

  defp timeout_error?(output_lower) do
    String.contains?(output_lower, "timed out") or
      String.contains?(output_lower, "timeout")
  end

  defp validation_error?(output_lower) do
    String.contains?(output_lower, "unrecognized") or
      String.contains?(output_lower, "invalid") or
      String.contains?(output_lower, "usage:")
  end

  defp dependency_error?(output_lower) do
    String.contains?(output_lower, "ffmpeg") and
      String.contains?(output_lower, "not found")
  end

  defp build_network_error(output, args) do
    url = Enum.find(args, &String.starts_with?(&1, "http"))

    Error.network_error("Network error during download",
      url: url,
      reason: String.trim(output)
    )
  end

  defp build_not_found_error(args) do
    url = Enum.find(args, &String.starts_with?(&1, "http"))

    Error.not_found_error("Video not found or unavailable",
      resource: :video,
      identifier: url
    )
  end

  defp build_dependency_error do
    Error.dependency_error("FFmpeg is required for this operation",
      dependency: "ffmpeg",
      required_for: "post-processing"
    )
  end

  # Adds proxy arguments to the command args list
  defp add_proxy_args(args, proxy_opt, use_proxy_manager) do
    cond do
      # Explicit proxy provided
      proxy_opt ->
        {["--proxy", proxy_opt | args], nil}

      # Use proxy manager
      use_proxy_manager ->
        case Proxy.get_proxy() do
          {:ok, proxy} ->
            Logger.debug("Using proxy from backend: #{proxy.url}")
            {["--proxy", proxy.url | args], proxy}

          {:error, :no_proxies} ->
            Logger.warning("Proxy backend has no available proxies, continuing without proxy")
            {args, nil}

          {:error, reason} ->
            Logger.warning(
              "Failed to get proxy from backend: #{inspect(reason)}, continuing without proxy"
            )

            {args, nil}
        end

      # No proxy
      true ->
        {args, nil}
    end
  end

  defp get_effective_timeout(proxy_info, default_timeout) do
    case proxy_info do
      %{timeout: proxy_timeout} -> proxy_timeout
      _ -> default_timeout
    end
  end

  defp execute_command(binary, args, timeout) do
    task =
      Task.async(fn ->
        try do
          System.cmd(binary, args, stderr_to_stdout: true)
        catch
          kind, reason ->
            {:error, {kind, reason}}
        end
      end)

    try do
      handle_task_result(Task.await(task, timeout), args)
    catch
      :exit, {:timeout, _} ->
        Task.shutdown(task, :brutal_kill)

        {:error,
         Error.timeout_error("Command timed out",
           timeout: timeout,
           operation: :yt_dlp_command
         )}
    end
  end

  defp handle_task_result(task_result, args) do
    case task_result do
      {:error, {_kind, :enoent}} ->
        {:error,
         Error.dependency_error("yt-dlp binary not found",
           dependency: "yt-dlp",
           required_for: "video downloads"
         )}

      {:error, {kind, reason}} ->
        {:error,
         Error.command_error("Binary not accessible",
           output: "#{inspect(kind)} - #{inspect(reason)}"
         )}

      {output, 0} ->
        {:ok, output}

      {output, exit_code} ->
        Logger.error("yt-dlp command failed (exit code #{exit_code}): #{output}")
        error = classify_command_error(output, exit_code, args)
        {:error, error}
    end
  end

  defp report_proxy_result(nil, _result), do: :ok

  defp report_proxy_result(proxy_info, result) do
    case result do
      {:ok, _} -> Proxy.report_success(proxy_info.url)
      {:error, _} -> Proxy.report_failure(proxy_info.url)
    end
  end
end
