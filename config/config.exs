import Config

# Configure the YtDlp application
config :yt_dlp,
  # Maximum number of concurrent downloads
  max_concurrent_downloads: 3,
  # Default output directory for downloads
  output_dir: "./downloads"

# Import environment specific config
import_config "#{config_env()}.exs"
