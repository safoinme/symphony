defmodule SymphonyElixir.Linear.ImageDownloaderTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.ImageDownloader

  describe "extract_image_urls/1" do
    test "extracts markdown image URLs" do
      text = """
      Here is a screenshot:
      ![bug](https://cdn.linear.app/images/bug.png)

      And another:
      ![expected](https://cdn.linear.app/images/expected.jpg)
      """

      urls = ImageDownloader.extract_image_urls(text)
      assert length(urls) == 2
      assert {"bug", "https://cdn.linear.app/images/bug.png"} in urls
      assert {"expected", "https://cdn.linear.app/images/expected.jpg"} in urls
    end

    test "deduplicates URLs" do
      text = """
      ![a](https://example.com/img.png)
      ![b](https://example.com/img.png)
      """

      urls = ImageDownloader.extract_image_urls(text)
      assert length(urls) == 1
    end

    test "ignores non-http URLs" do
      text = "![local](file:///tmp/img.png)"
      assert ImageDownloader.extract_image_urls(text) == []
    end

    test "ignores non-image markdown links" do
      text = "[click here](https://example.com)"
      assert ImageDownloader.extract_image_urls(text) == []
    end

    test "returns empty list for nil" do
      assert ImageDownloader.extract_image_urls(nil) == []
    end

    test "returns empty list for text with no images" do
      assert ImageDownloader.extract_image_urls("Just plain text") == []
    end
  end

  describe "rewrite_image_refs/1" do
    test "rewrites markdown image URLs to local paths" do
      description = "Bug: ![screenshot](https://cdn.linear.app/uploads/bug.png)"
      rewritten = ImageDownloader.rewrite_image_refs(description)

      assert rewritten =~ "![screenshot](./screenshots/bug.png)"
      refute rewritten =~ "cdn.linear.app"
    end

    test "handles multiple images" do
      description = """
      ![a](https://example.com/a.png)
      Some text
      ![b](https://example.com/b.jpg)
      """

      rewritten = ImageDownloader.rewrite_image_refs(description)
      assert rewritten =~ "./screenshots/a.png"
      assert rewritten =~ "./screenshots/b.jpg"
    end

    test "returns nil for nil" do
      assert ImageDownloader.rewrite_image_refs(nil) == nil
    end

    test "preserves text without images" do
      text = "No images here"
      assert ImageDownloader.rewrite_image_refs(text) == text
    end

    test "generates filename for URLs without image extension" do
      description = "![pic](https://example.com/api/image/12345)"
      rewritten = ImageDownloader.rewrite_image_refs(description)
      assert rewritten =~ "./screenshots/screenshot_"
      assert rewritten =~ ".png"
    end
  end

  describe "download_issue_images/2" do
    test "returns :ok for nil description" do
      assert :ok = ImageDownloader.download_issue_images(nil, "/tmp/test")
    end

    test "returns :ok for description with no images" do
      assert :ok = ImageDownloader.download_issue_images("No images", "/tmp/test")
    end
  end

  describe "download_comment_images/2" do
    test "returns :ok for empty comments" do
      assert :ok = ImageDownloader.download_comment_images([], "/tmp/test")
    end

    test "returns :ok for comments with no images" do
      comments = [%{body: "Just text"}, %{body: "More text"}]
      assert :ok = ImageDownloader.download_comment_images(comments, "/tmp/test")
    end
  end
end
