defmodule YtDlp.Command do
  @moduledoc """
  Executes yt-dlp commands using Elixir ports.

  This module provides a low-level interface for running yt-dlp commands
  and handling their output. It uses System.cmd/3 for simple command execution.
  """

  require Logger

  @type command_result :: {:ok, map()} | {:error, String.t()}

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

  ## Returns

    * `{:ok, output}` - Command succeeded with stdout output
    * `{:error, reason}` - Command failed with error message

  ## Examples

      iex> YtDlp.Command.run(["--version"])
      {:ok, "2024.10.07\\n"}

      iex> YtDlp.Command.run(["--help"])
      {:ok, "Usage: yt-dlp [OPTIONS] URL [URL...]\\n..."}
  """
  @spec run([String.t()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 300_000)
    binary = binary_path()

    Logger.debug("Running yt-dlp command: #{binary} #{Enum.join(args, " ")}")

    case System.cmd(binary, args, stderr_to_stdout: true, timeout: timeout) do
      {output, 0} ->
        {:ok, output}

      {output, exit_code} ->
        Logger.error("yt-dlp command failed (exit code #{exit_code}): #{output}")
        {:error, "Command failed with exit code #{exit_code}: #{String.trim(output)}"}
    end
  catch
    :exit, {:timeout, _} ->
      {:error, "Command timed out after #{timeout}ms"}
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

      iex> YtDlp.Command.run_json(["--dump-json", "--playlist-items", "1", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"])
      {:ok, %{"id" => "dQw4w9WgXcQ", "title" => "Rick Astley - Never Gonna Give You Up", ...}}
  """
  @spec run_json([String.t()], keyword()) :: {:ok, map() | list()} | {:error, String.t()}
  def run_json(args, opts \\ []) do
    case run(args, opts) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, json} -> {:ok, json}
          {:error, error} -> {:error, "Failed to parse JSON: #{inspect(error)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
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
          {:error, "Download completed but file not found: #{filepath}"}
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
                {:error, "Download completed but file not found: #{filepath}"}
              end

            {:error, reason} ->
              {:error, reason}
          end
        catch
          :exit, {:timeout, _} ->
            YtDlp.Port.cancel(port_pid)
            {:error, "Download timed out after #{timeout}ms"}

          :exit, reason ->
            {:error, "Download process exited: #{inspect(reason)}"}
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
end
