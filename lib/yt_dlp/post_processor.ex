defmodule YtDlp.PostProcessor do
  @moduledoc """
  Post-processing utilities for downloaded videos using yt-dlp's ffmpeg integration.

  This module provides helper functions for common post-processing operations:
  - Audio extraction (convert video to MP3, M4A, etc.)
  - Video format conversion
  - Thumbnail extraction
  - Subtitle embedding
  - Video/audio merging

  ## Examples

      # Extract audio as MP3
      {:ok, audio_path} = YtDlp.PostProcessor.extract_audio(url, format: :mp3, quality: "192K")

      # Download best video + audio and merge
      {:ok, video_path} = YtDlp.PostProcessor.download_and_merge(url, format: "bestvideo+bestaudio")

      # Convert to specific format
      {:ok, converted_path} = YtDlp.PostProcessor.convert_format(video_path, to: :mp4)
  """

  alias YtDlp.Command

  @type audio_format :: :mp3 | :m4a | :wav | :opus | :vorbis | :flac
  @type video_format :: :mp4 | :mkv | :webm | :avi | :flv
  @type quality :: String.t()

  @doc """
  Extracts audio from a video URL and converts to specified format.

  ## Options

    * `:format` - Audio format (default: `:mp3`)
    * `:quality` - Audio quality, e.g., "192K", "320K" (default: "192K")
    * `:output_dir` - Directory to save the audio file
    * `:keep_video` - Keep original video file (default: false)

  ## Returns

    * `{:ok, audio_path}` - Path to extracted audio file
    * `{:error, reason}` - Extraction failed
  """
  @spec extract_audio(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def extract_audio(url, opts \\ []) do
    format = Keyword.get(opts, :format, :mp3)
    quality = Keyword.get(opts, :quality, "192K")
    output_dir = Keyword.get(opts, :output_dir, "./downloads")
    keep_video = Keyword.get(opts, :keep_video, false)
    progress_callback = Keyword.get(opts, :progress_callback)

    args = [
      "--extract-audio",
      "--audio-format",
      to_string(format),
      "--audio-quality",
      quality,
      "--output",
      Path.join(output_dir, "%(title)s.%(ext)s"),
      "--print",
      "after_move:filepath"
    ]

    args = if keep_video, do: ["--keep-video" | args], else: args
    args = args ++ [url]

    binary = Command.binary_path()

    case YtDlp.Port.run(binary, args, progress_callback: progress_callback) do
      {:ok, output} ->
        filepath =
          output
          |> String.trim()
          |> String.split("\n")
          |> List.last()
          |> String.trim()

        if File.exists?(filepath) do
          {:ok, filepath}
        else
          {:error, "Audio extraction completed but file not found"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Downloads video and audio separately and merges them using ffmpeg.

  This is useful for getting the best quality video and audio.

  ## Options

    * `:video_format` - Preferred video format (default: "bestvideo")
    * `:audio_format` - Preferred audio format (default: "bestaudio")
    * `:output_format` - Output container format (default: :mp4)
    * `:output_dir` - Directory to save the merged file

  ## Examples

      # Best quality video + audio merged to MP4
      {:ok, path} = YtDlp.PostProcessor.download_and_merge(url)

      # Specific formats
      {:ok, path} = YtDlp.PostProcessor.download_and_merge(
        url,
        video_format: "bestvideo[height<=1080]",
        audio_format: "bestaudio[ext=m4a]",
        output_format: :mkv
      )
  """
  @spec download_and_merge(String.t(), keyword()) ::
          {:ok, %{path: String.t(), url: String.t()}} | {:error, YtDlp.Error.error()}
  def download_and_merge(url, opts \\ []) do
    video_format = Keyword.get(opts, :video_format, "bestvideo")
    audio_format = Keyword.get(opts, :audio_format, "bestaudio")
    output_format = Keyword.get(opts, :output_format, :mp4)
    output_dir = Keyword.get(opts, :output_dir, "./downloads")
    progress_callback = Keyword.get(opts, :progress_callback)

    # Combined format string
    format_string = "#{video_format}+#{audio_format}/best"

    Command.download(url, output_dir,
      format: format_string,
      filename_template: "%(title)s.#{output_format}",
      progress_callback: progress_callback
    )
  end

  @doc """
  Converts a video file to a different format.

  Note: This requires the file to be already downloaded.

  ## Options

    * `:to` - Target format (required)
    * `:video_codec` - Video codec (e.g., "h264", "vp9")
    * `:audio_codec` - Audio codec (e.g., "aac", "opus")
    * `:output_dir` - Output directory

  ## Examples

      {:ok, mp4_path} = YtDlp.PostProcessor.convert_format(
        "/path/to/video.webm",
        to: :mp4,
        video_codec: "h264",
        audio_codec: "aac"
      )
  """
  @spec convert_format(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def convert_format(file_path, opts) do
    to_format = Keyword.fetch!(opts, :to)
    video_codec = Keyword.get(opts, :video_codec)
    audio_codec = Keyword.get(opts, :audio_codec)
    output_dir = Keyword.get(opts, :output_dir, Path.dirname(file_path))

    if File.exists?(file_path) do
      # Build output path
      basename = Path.basename(file_path, Path.extname(file_path))
      output_path = Path.join(output_dir, "#{basename}.#{to_format}")

      # Build ffmpeg args
      args = [
        "--recode-video",
        to_string(to_format)
      ]

      args =
        if video_codec do
          args ++ ["--postprocessor-args", "ffmpeg:-c:v #{video_codec}"]
        else
          args
        end

      args =
        if audio_codec do
          args ++ ["--postprocessor-args", "ffmpeg:-c:a #{audio_codec}"]
        else
          args
        end

      args = args ++ ["--output", output_path, file_path]

      binary = Command.binary_path()

      with {_output, 0} <- System.cmd(binary, args, stderr_to_stdout: true),
           true <- File.exists?(output_path) do
        {:ok, output_path}
      else
        {output, exit_code} ->
          {:error, "Conversion failed (exit #{exit_code}): #{output}"}

        false ->
          {:error, "Conversion completed but output file not found"}
      end
    else
      {:error, "Input file does not exist: #{file_path}"}
    end
  end

  @doc """
  Extracts thumbnail from a video URL.

  ## Options

    * `:format` - Thumbnail format (default: :jpg)
    * `:output_dir` - Directory to save thumbnail

  ## Examples

      {:ok, thumb_path} = YtDlp.PostProcessor.extract_thumbnail(url)
  """
  @spec extract_thumbnail(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def extract_thumbnail(url, opts \\ []) do
    format = Keyword.get(opts, :format, :jpg)
    output_dir = Keyword.get(opts, :output_dir, "./downloads")

    args = [
      "--write-thumbnail",
      "--skip-download",
      "--convert-thumbnails",
      to_string(format),
      "--output",
      Path.join(output_dir, "%(title)s.%(ext)s"),
      url
    ]

    binary = Command.binary_path()

    with {output, 0} <- System.cmd(binary, args, stderr_to_stdout: true),
         title when not is_nil(title) <- extract_title_from_output(output),
         thumb_path = Path.join(output_dir, "#{title}.#{format}"),
         true <- File.exists?(thumb_path) do
      {:ok, thumb_path}
    else
      {output, exit_code} ->
        {:error, "Thumbnail extraction failed (exit #{exit_code}): #{output}"}

      nil ->
        {:error, "Could not determine thumbnail filename"}

      false ->
        {:error, "Thumbnail file not found"}
    end
  end

  @doc """
  Downloads video with embedded subtitles.

  ## Options

    * `:langs` - List of subtitle languages to download (default: ["en"])
    * `:auto_subs` - Include auto-generated subtitles (default: false)
    * `:format` - Video format
    * `:output_dir` - Output directory

  ## Examples

      {:ok, path} = YtDlp.PostProcessor.download_with_subtitles(
        url,
        langs: ["en", "es"],
        auto_subs: true
      )
  """
  @spec download_with_subtitles(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def download_with_subtitles(url, opts \\ []) do
    langs = Keyword.get(opts, :langs, ["en"])
    auto_subs = Keyword.get(opts, :auto_subs, false)
    format = Keyword.get(opts, :format, "best")
    output_dir = Keyword.get(opts, :output_dir, "./downloads")

    args = [
      "--write-subs",
      "--embed-subs",
      "--sub-langs",
      Enum.join(langs, ","),
      "--format",
      format,
      "--output",
      Path.join(output_dir, "%(title)s.%(ext)s"),
      "--print",
      "after_move:filepath",
      url
    ]

    args = if auto_subs, do: ["--write-auto-subs" | args], else: args

    binary = Command.binary_path()

    case System.cmd(binary, args, stderr_to_stdout: true) do
      {output, 0} ->
        filepath =
          output
          |> String.trim()
          |> String.split("\n")
          |> List.last()
          |> String.trim()

        if File.exists?(filepath) do
          {:ok, filepath}
        else
          {:error, "Download completed but file not found"}
        end

      {output, exit_code} ->
        {:error, "Download failed (exit #{exit_code}): #{output}"}
    end
  end

  @doc """
  Format helper: Returns format string for audio-only download.

  ## Examples

      YtDlp.download(url, format: YtDlp.PostProcessor.audio_only(:mp3, "192K"))
  """
  @spec audio_only(audio_format(), quality()) :: String.t()
  def audio_only(_format \\ :mp3, quality \\ "192K") do
    "bestaudio/best[abr<=#{quality}]"
  end

  @doc """
  Format helper: Returns format string for specific video quality.

  ## Examples

      # 1080p or lower
      YtDlp.download(url, format: YtDlp.PostProcessor.video_quality(1080))

      # 4K
      YtDlp.download(url, format: YtDlp.PostProcessor.video_quality(2160))
  """
  @spec video_quality(pos_integer()) :: String.t()
  def video_quality(height) do
    "bestvideo[height<=#{height}]+bestaudio/best[height<=#{height}]"
  end

  # Private helpers

  defp extract_title_from_output(output) do
    case Regex.run(~r/\[download\] Destination: (.+)\./, output) do
      [_, title] -> Path.basename(title)
      _ -> nil
    end
  end
end
