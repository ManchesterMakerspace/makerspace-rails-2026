# Uses an ephemeral test key; no database, Rails boot or deployment credentials.
require 'json'
require 'digest'
require 'open3'
require_relative '../../app/services/card_management'
require_relative '../../app/services/nfc_credential_codec'
ENV['READER_KEY_ENCRYPTION_KEY'] = Base64.strict_encode64('x' * 32)
material = NfcCredentialCodec.generate('00112233')
sealed = NfcCredentialCodec.seal(material)
script = <<~JS
  const crypto = require('node:crypto');
  let input=''; process.stdin.on('data',d=>input+=d); process.stdin.on('end',()=>{
    const {sealed,material}=JSON.parse(input), key=Buffer.alloc(32,120);
    const decipher=crypto.createDecipheriv('aes-256-gcm',key,Buffer.from(sealed.iv,'base64'));
    decipher.setAuthTag(Buffer.from(sealed.tag,'base64'));
    const result=JSON.parse(Buffer.concat([decipher.update(Buffer.from(sealed.ciphertext,'base64')),decipher.final()]));
    if(JSON.stringify(result)!==JSON.stringify(material)) throw Error('Ruby to Node mismatch');
    const bytes=Buffer.from(result.contents,'hex');
    if(bytes.length!==48 || bytes.subarray(32,36).toString()!=='MSP1' || bytes.readUInt32BE(36)!==1 || bytes.subarray(40).some(b=>b!==0)) throw Error('Firmware metadata mismatch');
    const digest=crypto.createHash('sha256').update(Buffer.from('00112233','hex')).update(bytes).digest('hex');
    if(digest!==result.digest) throw Error('Firmware digest mismatch');
    const iv=crypto.randomBytes(12),cipher=crypto.createCipheriv('aes-256-gcm',key,iv);
    const ciphertext=Buffer.concat([cipher.update(JSON.stringify(result)),cipher.final()]);
    process.stdout.write(JSON.stringify({iv:iv.toString('base64'),tag:cipher.getAuthTag().toString('base64'),ciphertext:ciphertext.toString('base64')}));
  });
JS
output, error, status = Open3.capture3('node', '-e', script, stdin_data: { sealed: sealed, material: material }.to_json)
raise error unless status.success?
raise 'Node to Ruby mismatch' unless NfcCredentialCodec.open(JSON.parse(output)) == material
puts 'PASS Ruby/Node AES-GCM interoperability and firmware credential layout/digest'
