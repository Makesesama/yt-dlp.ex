# YtDlp.ex Examples

This directory contains example scripts demonstrating various use cases for the YtDlp library.

## Running the Examples

Make sure you have yt-dlp installed (it's included in the nix flake):

```bash
# Using nix
nix develop

# Run an example
mix run examples/demo.exs
```

## Available Examples

### 1. `demo.exs` - Comprehensive Demo

A complete demonstration of all features:

```bash
mix run examples/demo.exs
```

**Features shown:**
- Check yt-dlp installation
- Get video information
- Simple async downloads
- Real-time progress tracking
- Synchronous downloads
- Download cancellation
- Multiple concurrent downloads
- List all downloads
- Custom download options (format, output dir, filename template)
- Simulated S3 upload workflow

### 2. `waffle_integration.exs` - S3 Upload Workflow

Shows how to integrate with Waffle for S3 uploads:

```bash
mix run examples/waffle_integration.exs
```

**Features shown:**
- Download → Upload → Cleanup workflow
- Progress monitoring
- Batch processing multiple videos
- Error handling
- Metadata extraction
- Custom progress handlers

**Key module:** `VideoProcessor`

```elixir
# Simple usage
{:ok, s3_url, metadata} = VideoProcessor.download_and_upload(
  "https://youtube.com/watch?v=...",
  user
)

# Batch processing
results = VideoProcessor.batch_download_and_upload(
  video_urls,
  user
)
```

### 3. `liveview_integration.ex` - Phoenix LiveView Example

A complete Phoenix LiveView implementation for real-time video downloads:

**Features shown:**
- Real-time progress updates via LiveView
- Cancel downloads from UI
- Multiple concurrent downloads
- Status badges and progress bars
- S3 upload after download
- Phoenix PubSub integration

**Usage:**

Add to your Phoenix router:

```elixir
# router.ex
live "/videos/download", MyAppWeb.VideoDownloadLive
```

Then add the module to your app and visit `/videos/download`.

## Example Use Cases

### Quick Download

```elixir
# Simple download
{:ok, download_id} = YtDlp.download("https://youtube.com/watch?v=...")

# Wait for completion
{:ok, result} = YtDlp.download_sync("https://youtube.com/watch?v=...")
IO.puts("Downloaded to: #{result.path}")
```

### With Progress Tracking

```elixir
{:ok, download_id} = YtDlp.download(
  "https://youtube.com/watch?v=...",
  progress_callback: fn progress ->
    IO.write("\r#{progress.percent}% at #{progress.speed}")
  end
)
```

### Download → S3 Upload

```elixir
# Download
{:ok, result} = YtDlp.download_sync(url)

# Upload with Waffle
{:ok, _} = MyApp.VideoUploader.store({result.path, user})

# Cleanup
File.rm(result.path)
```

### Multiple Videos

```elixir
video_urls
|> Task.async_stream(fn url ->
  {:ok, result} = YtDlp.download_sync(url)
  MyApp.VideoUploader.store({result.path, user})
end, max_concurrency: 3)
|> Enum.to_list()
```

## Waffle Integration

To use with Waffle, add to your `mix.exs`:

```elixir
def deps do
  [
    {:yt_dlp, "~> 0.1.0"},
    {:waffle, "~> 1.1"},
    {:waffle_ecto, "~> 0.0"}
  ]
end
```

Define an uploader:

```elixir
defmodule MyApp.VideoUploader do
  use Waffle.Definition
  use Waffle.Ecto.Definition

  @versions [:original]

  def storage_dir(_version, {_file, scope}) do
    "uploads/videos/user-#{scope.user_id}"
  end

  def filename(version, _) do
    version
  end
end
```

Use in your context:

```elixir
defmodule MyApp.Videos do
  def download_and_store(video_url, user) do
    # Download with yt-dlp
    {:ok, result} = YtDlp.download_sync(video_url)

    # Upload to S3 with Waffle
    {:ok, video} = %Video{}
    |> Video.changeset(%{
      user_id: user.id,
      title: "Video Title",
      url: video_url
    })
    |> Ecto.Changeset.put_change(:file, result.path)
    |> Repo.insert()

    # Cleanup
    File.rm(result.path)

    {:ok, video}
  end
end
```

## Testing

These examples use real video URLs. For testing, we use short, public domain videos:

- `https://www.youtube.com/watch?v=aqz-KE-bpKQ` - Big Buck Bunny trailer (30s)
- `https://www.youtube.com/watch?v=jNQXAC9IVRw` - Me at the zoo (19s)

## Troubleshooting

### yt-dlp not found

```bash
# Check if yt-dlp is available
which yt-dlp

# In nix environment
nix develop
yt-dlp --version
```

### Network errors

Add retry logic:

```elixir
defmodule Downloader do
  def download_with_retry(url, retries \\ 3) do
    case YtDlp.download_sync(url) do
      {:ok, result} -> {:ok, result}
      {:error, reason} when retries > 0 ->
        Process.sleep(2000)
        download_with_retry(url, retries - 1)
      error -> error
    end
  end
end
```

### Progress not updating

Make sure to use `--newline` flag (already included in the library) and that the progress callback is being invoked.

## More Information

See the main [README](../README.md) for complete API documentation.
