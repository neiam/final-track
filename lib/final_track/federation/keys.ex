defmodule FinalTrack.Federation.Keys do
  @moduledoc "RSA keys for HTTP signatures, as PEM."

  @doc "A new 2048-bit key pair: `{public_pem, private_pem}`."
  def generate do
    private = :public_key.generate_key({:rsa, 2048, 65_537})
    {:RSAPrivateKey, _, modulus, exponent, _, _, _, _, _, _, _} = private
    public = {:RSAPublicKey, modulus, exponent}

    {pem(:SubjectPublicKeyInfo, public), pem(:RSAPrivateKey, private)}
  end

  def decode(pem) do
    [entry] = :public_key.pem_decode(pem)
    :public_key.pem_entry_decode(entry)
  end

  defp pem(type, key), do: :public_key.pem_encode([:public_key.pem_entry_encode(type, key)])
end
