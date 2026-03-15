defmodule SymphonyElixir.Linear.ImageDownloader do
  @moduledoc """
  Downloads images referenced in Linear issue descriptions and comments
  into the workspace so agents can see them. Rewrites markdown image
  references to point to local files.
  """

  require Logger

  @screenshots_dir "screenshots"
  @download_timeout_ms 30_000
  @max_images 20
  @max_download_concurrency 5
  @markdown_image_regex ~r/!\[([^\]]*)\]\(([^)]+)\)/

  @spec download_for_issue(map(), Path.t()) :: :ok
  def download_for_issue(%{description: description}, workspace) do
    download_issue_images(description, workspace)
  end

  def download_for_issue(_issue, _workspace), do: :ok

  @spec download_issue_images(String.t() | nil, Path.t()) :: :ok
  def download_issue_images(nil, _workspace), do: :ok

  def download_issue_images(description, workspace) when is_binary(description) do
    description
    |> extract_image_urls()
    |> download_urls(workspace)
  end

  @spec download_comment_images([map()], Path.t()) :: :ok
  def download_comment_images(comments, workspace) when is_list(comments) do
    comments
    |> Enum.flat_map(fn comment ->
      body = Map.get(comment, :body) || Map.get(comment, "body") || ""
      extract_image_urls(body)
    end)
    |> download_urls(workspace)
  end

  @spec rewrite_image_refs(String.t() | nil) :: String.t() | nil
  def rewrite_image_refs(nil), do: nil

  def rewrite_image_refs(description) when is_binary(description) do
    if String.contains?(description, "![") do
      Regex.replace(@markdown_image_regex, description, fn _full, alt, url ->
        if image_url?(url) do
          filename = url_to_filename(url)
          "![#{alt}](./#{@screenshots_dir}/#{filename})"
        else
          "![#{alt}](#{url})"
        end
      end)
    else
      description
    end
  end

  @spec extract_image_urls(String.t()) :: [{String.t(), String.t()}]
  def extract_image_urls(text) when is_binary(text) do
    @markdown_image_regex
    |> Regex.scan(text)
    |> Enum.flat_map(fn
      [_, alt, url] when url != "" ->
        if image_url?(url), do: [{alt, url}], else: []

      _ ->
        []
    end)
    |> Enum.uniq_by(fn {_alt, url} -> url end)
  end

  def extract_image_urls(_), do: []

  # --- Private ---

  defp download_urls([], _workspace), do: :ok

  defp download_urls(urls, workspace) do
    screenshots_path = Path.join(workspace, @screenshots_dir)

    case File.mkdir_p(screenshots_path) do
      :ok ->
        urls
        |> Enum.take(@max_images)
        |> Task.async_stream(
          fn {_alt, url} -> download_image(url, screenshots_path) end,
          max_concurrency: @max_download_concurrency,
          timeout: @download_timeout_ms + 10_000,
          on_timeout: :kill_task
        )
        |> Stream.run()

        :ok

      {:error, reason} ->
        Logger.warning("Failed to create screenshots directory: #{inspect(reason)}")
        :ok
    end
  end

  defp download_image(url, screenshots_path) do
    filename = url_to_filename(url)
    dest = Path.join(screenshots_path, filename)

    if File.exists?(dest) do
      Logger.debug("Screenshot already downloaded: #{filename}")
    else
      Logger.info("Downloading screenshot: #{url}")

      case do_download(url) do
        {:ok, body} ->
          File.write!(dest, body)
          Logger.info("Screenshot saved: #{dest}")

        {:error, reason} ->
          Logger.warning("Failed to download screenshot #{url}: #{inspect(reason)}")
      end
    end
  end

  defp do_download(url) do
    case Req.get(url,
           connect_options: [timeout: @download_timeout_ms],
           receive_timeout: @download_timeout_ms,
           max_redirects: 5
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp image_url?(url) do
    uri = URI.parse(url)
    is_binary(uri.scheme) and uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != ""
  end

  defp url_to_filename(url) do
    uri = URI.parse(url)
    basename = if is_binary(uri.path) and uri.path != "", do: Path.basename(uri.path), else: nil

    if basename && has_image_extension?(basename) do
      sanitize_filename(basename)
    else
      hash = :erlang.phash2(url) |> Integer.to_string(16) |> String.downcase()
      sanitize_filename("screenshot_#{hash}.png")
    end
  end

  @image_extensions [".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".bmp", ".avif"]

  defp has_image_extension?(filename) do
    ext = filename |> Path.extname() |> String.downcase()
    ext in @image_extensions
  end

  defp sanitize_filename(name) do
    name
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")
    |> String.slice(0, 200)
  end
end
