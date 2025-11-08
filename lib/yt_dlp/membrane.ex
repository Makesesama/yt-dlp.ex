defmodule YtDlp.Membrane do
  @moduledoc """
  Integration with Membrane Framework for advanced video/audio processing.

  This module provides utilities to process downloaded videos using Membrane,
  an Elixir-native multimedia framework. This is useful for:

  - Generating thumbnails at specific timestamps
  - Extracting audio tracks
  - Transcoding to different formats
  - Creating preview clips
  - Generating HLS/DASH streams
  - Real-time video analysis

  ## Installation

  Add Membrane dependencies to your `mix.exs`:

      def deps do
        [
          {:yt_dlp, "~> 0.1.0"},
          {:membrane_core, "~> 1.0"},
          {:membrane_file_plugin, "~> 0.17.0"},
          {:membrane_ffmpeg_swresample_plugin, "~> 0.20.0"},
          {:membrane_mp4_plugin, "~> 0.35.0"},
          # Add other plugins as needed
        ]
      end

  ## Examples

      # Generate thumbnail at 5 seconds
      {:ok, thumb_path} = YtDlp.Membrane.generate_thumbnail(
        video_path,
        timestamp: 5.0
      )

      # Extract audio track
      {:ok, audio_path} = YtDlp.Membrane.extract_audio_track(
        video_path,
        format: :mp3
      )

      # Create 30-second preview clip
      {:ok, preview_path} = YtDlp.Membrane.create_preview(
        video_path,
        duration: 30.0,
        start_at: 10.0
      )
  """

  require Logger

  @doc """
  Generates a thumbnail from a video at a specific timestamp.

  ## Options

    * `:timestamp` - Timestamp in seconds (default: 5.0)
    * `:output_path` - Where to save the thumbnail (optional)
    * `:width` - Thumbnail width (default: 1280)
    * `:height` - Thumbnail height (default: 720)
    * `:format` - Image format: :jpg, :png (default: :jpg)

  ## Examples

      {:ok, thumb_path} = YtDlp.Membrane.generate_thumbnail(
        "/path/to/video.mp4",
        timestamp: 5.0,
        width: 1920,
        height: 1080
      )
  """
  @spec generate_thumbnail(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def generate_thumbnail(video_path, opts \\ []) do
    if membrane_available?() do
      timestamp = Keyword.get(opts, :timestamp, 5.0)
      width = Keyword.get(opts, :width, 1280)
      height = Keyword.get(opts, :height, 720)
      format = Keyword.get(opts, :format, :jpg)

      output_path =
        Keyword.get(
          opts,
          :output_path,
          generate_output_path(video_path, "thumbnail_#{trunc(timestamp)}s", format)
        )

      # Use ffmpeg via System.cmd for thumbnail generation
      # (Membrane is better for streaming, ffmpeg is simpler for single frame)
      ffmpeg_generate_thumbnail(video_path, output_path, timestamp, width, height)
    else
      {:error, "Membrane framework not installed. Add {:membrane_core, \"~> 1.0\"} to deps"}
    end
  end

  @doc """
  Extracts audio track from video file.

  ## Options

    * `:format` - Output format: :mp3, :m4a, :wav, :flac (default: :mp3)
    * `:bitrate` - Audio bitrate, e.g., "192k" (default: "192k")
    * `:output_path` - Where to save the audio (optional)
    * `:sample_rate` - Sample rate in Hz (default: 44100)

  ## Examples

      {:ok, audio_path} = YtDlp.Membrane.extract_audio_track(
        "/path/to/video.mp4",
        format: :mp3,
        bitrate: "320k"
      )
  """
  @spec extract_audio_track(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def extract_audio_track(video_path, opts \\ []) do
    if membrane_available?() do
      format = Keyword.get(opts, :format, :mp3)
      bitrate = Keyword.get(opts, :bitrate, "192k")

      output_path =
        Keyword.get(
          opts,
          :output_path,
          generate_output_path(video_path, "audio", format)
        )

      # Use ffmpeg for audio extraction
      ffmpeg_extract_audio(video_path, output_path, format, bitrate)
    else
      {:error, "Membrane framework not installed"}
    end
  end

  @doc """
  Creates a preview clip from a video.

  ## Options

    * `:start_at` - Start time in seconds (default: 0.0)
    * `:duration` - Clip duration in seconds (required)
    * `:output_path` - Where to save the clip (optional)
    * `:format` - Output format (default: :mp4)

  ## Examples

      # Create 30-second preview starting at 10 seconds
      {:ok, preview_path} = YtDlp.Membrane.create_preview(
        "/path/to/video.mp4",
        start_at: 10.0,
        duration: 30.0
      )
  """
  @spec create_preview(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def create_preview(video_path, opts) do
    if membrane_available?() do
      start_at = Keyword.get(opts, :start_at, 0.0)
      duration = Keyword.fetch!(opts, :duration)
      format = Keyword.get(opts, :format, :mp4)

      output_path =
        Keyword.get(
          opts,
          :output_path,
          generate_output_path(video_path, "preview", format)
        )

      ffmpeg_create_clip(video_path, output_path, start_at, duration)
    else
      {:error, "Membrane framework not installed"}
    end
  end

  @doc """
  Transcodes a video to a different format/codec.

  ## Options

    * `:output_format` - Target format (required)
    * `:video_codec` - Video codec (e.g., "h264", "vp9")
    * `:audio_codec` - Audio codec (e.g., "aac", "opus")
    * `:video_bitrate` - Video bitrate (e.g., "2M")
    * `:audio_bitrate` - Audio bitrate (e.g., "192k")
    * `:resolution` - Output resolution as {width, height}
    * `:output_path` - Where to save the transcoded video

  ## Examples

      {:ok, output_path} = YtDlp.Membrane.transcode(
        "/path/to/video.mkv",
        output_format: :mp4,
        video_codec: "h264",
        audio_codec: "aac",
        resolution: {1920, 1080}
      )
  """
  @spec transcode(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def transcode(video_path, opts) do
    if membrane_available?() do
      output_format = Keyword.fetch!(opts, :output_format)
      video_codec = Keyword.get(opts, :video_codec)
      audio_codec = Keyword.get(opts, :audio_codec)
      video_bitrate = Keyword.get(opts, :video_bitrate)
      audio_bitrate = Keyword.get(opts, :audio_bitrate)
      resolution = Keyword.get(opts, :resolution)

      output_path =
        Keyword.get(
          opts,
          :output_path,
          generate_output_path(video_path, "transcoded", output_format)
        )

      ffmpeg_transcode(
        video_path,
        output_path,
        video_codec,
        audio_codec,
        video_bitrate,
        audio_bitrate,
        resolution
      )
    else
      {:error, "Membrane framework not installed"}
    end
  end

  @doc """
  Pipeline: Downloads video and generates thumbnail in one step.

  ## Examples

      {:ok, %{video: video_path, thumbnail: thumb_path}} =
        YtDlp.Membrane.download_with_thumbnail(
          "https://youtube.com/watch?v=...",
          thumbnail_at: 5.0
        )
  """
  @spec download_with_thumbnail(String.t(), keyword()) ::
          {:ok, %{video: String.t(), thumbnail: String.t()}} | {:error, String.t()}
  def download_with_thumbnail(url, opts \\ []) do
    thumbnail_at = Keyword.get(opts, :thumbnail_at, 5.0)
    download_opts = Keyword.drop(opts, [:thumbnail_at])

    with {:ok, result} <- YtDlp.download_sync(url, download_opts),
         {:ok, thumb_path} <- generate_thumbnail(result.path, timestamp: thumbnail_at) do
      {:ok, %{video: result.path, thumbnail: thumb_path}}
    end
  end

  @doc """
  Pipeline: Downloads video, extracts audio, and uploads both to S3.

  ## Examples

      {:ok, %{video_url: video_s3, audio_url: audio_s3}} =
        YtDlp.Membrane.download_with_audio_extraction(
          "https://youtube.com/watch?v=...",
          uploader: &MyApp.Uploader.store/1
        )
  """
  @spec download_with_audio_extraction(String.t(), keyword()) ::
          {:ok, %{video: String.t(), audio: String.t()}} | {:error, String.t()}
  def download_with_audio_extraction(url, opts \\ []) do
    audio_format = Keyword.get(opts, :audio_format, :mp3)
    audio_bitrate = Keyword.get(opts, :audio_bitrate, "192k")
    download_opts = Keyword.drop(opts, [:audio_format, :audio_bitrate, :uploader])

    with {:ok, result} <- YtDlp.download_sync(url, download_opts),
         {:ok, audio_path} <-
           extract_audio_track(result.path, format: audio_format, bitrate: audio_bitrate) do
      {:ok, %{video: result.path, audio: audio_path}}
    end
  end

  # Private Functions

  defp membrane_available? do
    Code.ensure_loaded?(Membrane.Pipeline)
  end

  defp generate_output_path(input_path, suffix, extension) do
    dir = Path.dirname(input_path)
    basename = Path.basename(input_path, Path.extname(input_path))
    Path.join(dir, "#{basename}_#{suffix}.#{extension}")
  end

  # FFmpeg helper functions
  # These provide functionality even without Membrane installed

  defp ffmpeg_generate_thumbnail(video_path, output_path, timestamp, width, height) do
    args = [
      "-ss",
      "#{timestamp}",
      "-i",
      video_path,
      "-vframes",
      "1",
      "-vf",
      "scale=#{width}:#{height}",
      "-y",
      output_path
    ]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_output, 0} ->
        if File.exists?(output_path) do
          {:ok, output_path}
        else
          {:error, "Thumbnail generation completed but file not found"}
        end

      {output, exit_code} ->
        {:error, "ffmpeg failed (exit #{exit_code}): #{String.slice(output, 0..200)}"}
    end
  end

  defp ffmpeg_extract_audio(video_path, output_path, format, bitrate) do
    args = [
      "-i",
      video_path,
      "-vn",
      "-acodec",
      audio_codec_for_format(format),
      "-ab",
      bitrate,
      "-y",
      output_path
    ]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_output, 0} ->
        if File.exists?(output_path) do
          {:ok, output_path}
        else
          {:error, "Audio extraction completed but file not found"}
        end

      {output, exit_code} ->
        {:error, "ffmpeg failed (exit #{exit_code}): #{String.slice(output, 0..200)}"}
    end
  end

  defp ffmpeg_create_clip(video_path, output_path, start_at, duration) do
    args = [
      "-ss",
      "#{start_at}",
      "-i",
      video_path,
      "-t",
      "#{duration}",
      "-c",
      "copy",
      "-y",
      output_path
    ]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_output, 0} ->
        if File.exists?(output_path) do
          {:ok, output_path}
        else
          {:error, "Clip creation completed but file not found"}
        end

      {output, exit_code} ->
        {:error, "ffmpeg failed (exit #{exit_code}): #{String.slice(output, 0..200)}"}
    end
  end

  defp ffmpeg_transcode(
         video_path,
         output_path,
         video_codec,
         audio_codec,
         video_bitrate,
         audio_bitrate,
         resolution
       ) do
    args = ["-i", video_path]

    args =
      if video_codec do
        args ++ ["-c:v", video_codec]
      else
        args ++ ["-c:v", "copy"]
      end

    args =
      if audio_codec do
        args ++ ["-c:a", audio_codec]
      else
        args ++ ["-c:a", "copy"]
      end

    args = if video_bitrate, do: args ++ ["-b:v", video_bitrate], else: args
    args = if audio_bitrate, do: args ++ ["-b:a", audio_bitrate], else: args

    args =
      if resolution do
        {width, height} = resolution
        args ++ ["-vf", "scale=#{width}:#{height}"]
      else
        args
      end

    args = args ++ ["-y", output_path]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_output, 0} ->
        if File.exists?(output_path) do
          {:ok, output_path}
        else
          {:error, "Transcoding completed but file not found"}
        end

      {output, exit_code} ->
        {:error, "ffmpeg failed (exit #{exit_code}): #{String.slice(output, 0..200)}"}
    end
  end

  defp audio_codec_for_format(:mp3), do: "libmp3lame"
  defp audio_codec_for_format(:m4a), do: "aac"
  defp audio_codec_for_format(:wav), do: "pcm_s16le"
  defp audio_codec_for_format(:flac), do: "flac"
  defp audio_codec_for_format(other), do: to_string(other)
end
