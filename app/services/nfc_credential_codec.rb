require 'openssl'
require 'base64'
require 'securerandom'

# Wire/storage compatible with ts-data-api's reader/v1 credential envelope.
module NfcCredentialCodec
  def self.key
    value = Base64.strict_decode64(ENV.fetch('READER_KEY_ENCRYPTION_KEY', ''))
    raise ArgumentError unless value.bytesize == 32
    value
  rescue ArgumentError
    raise CardManagement::Unavailable, 'Reader credential encryption is not configured.'
  end

  def self.generate(uid)
    contents = SecureRandom.random_bytes(32) + 'MSP1' + [1].pack('N') + "\0" * 8
    { 'keyA' => SecureRandom.hex(6), 'keyB' => SecureRandom.hex(6),
      'contents' => contents.unpack1('H*'), 'version' => 1,
      'digest' => Digest::SHA256.hexdigest([uid].pack('H*') + contents) }
  end

  def self.seal(material)
    cipher = OpenSSL::Cipher.new('aes-256-gcm').encrypt
    cipher.key = key
    iv = SecureRandom.random_bytes(12)
    cipher.iv = iv
    ciphertext = cipher.update(material.to_json) + cipher.final
    { 'iv' => Base64.strict_encode64(iv), 'tag' => Base64.strict_encode64(cipher.auth_tag),
      'ciphertext' => Base64.strict_encode64(ciphertext) }
  end

  def self.open(sealed)
    cipher = OpenSSL::Cipher.new('aes-256-gcm').decrypt
    cipher.key = key
    cipher.iv = Base64.strict_decode64(sealed.fetch('iv'))
    cipher.auth_tag = Base64.strict_decode64(sealed.fetch('tag'))
    JSON.parse(cipher.update(Base64.strict_decode64(sealed.fetch('ciphertext'))) + cipher.final)
  rescue OpenSSL::Cipher::CipherError, KeyError, ArgumentError, JSON::ParserError
    raise CardManagement::Unavailable, 'Unable to recover enrollment material. Contact an administrator.'
  end
end
