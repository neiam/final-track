defmodule FinalTrack.Covers.Image do
  @moduledoc """
  Recognises cover image formats by their leading bytes, not by a file name
  or a Content-Type header, either of which can say anything.
  """

  @max_bytes 8 * 1024 * 1024

  def max_bytes, do: @max_bytes

  @doc "`{:ok, ext}` for a JPEG, PNG or WebP within the size limit, else an error."
  def sniff(bytes) when byte_size(bytes) > @max_bytes, do: {:error, :too_large}
  def sniff(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "jpg"}
  def sniff(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: {:ok, "png"}
  def sniff(<<"RIFF", _size::binary-size(4), "WEBP", _::binary>>), do: {:ok, "webp"}
  def sniff(_), do: {:error, :not_an_image}

  @doc "The Content-Type to serve a stored cover with, from its key's extension."
  def content_type(key) do
    case Path.extname(key) do
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      _ -> "image/jpeg"
    end
  end
end
