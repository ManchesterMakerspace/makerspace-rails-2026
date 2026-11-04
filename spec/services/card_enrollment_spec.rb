require 'rails_helper'

RSpec.describe CardEnrollment, requires_transactions: true do
  let(:actor) { create(:member, :admin, expirationTime: 1.day.from_now.to_i * 1000) }
  let(:member) { create(:member, member_contract_signed_date: Date.today, expirationTime: 1.day.from_now.to_i * 1000) }
  let(:service) { described_class.new(actor, 'admin') }
  around do |example|
    previous = ENV['READER_KEY_ENCRYPTION_KEY']
    ENV['READER_KEY_ENCRYPTION_KEY'] = Base64.strict_encode64('x' * 32)
    example.run
  ensure
    ENV['READER_KEY_ENCRYPTION_KEY'] = previous
  end

  it 'stages, resumes, blocks fallback, then commits a replacement atomically and idempotently' do
    old = create(:card, member: member, uid: '01020304')
    prepared = service.prepare!(member.id, '05060708', true)
    expect(Card.where(uid: '05060708')).not_to exist
    expect(old.reload.validity).to eq('activeMember')
    expect(service.prepare!(member.id, '05060708', true)[:material]).to eq(prepared[:material])
    expect(service.show(prepared[:id])).not_to have_key(:material)
    expect { CardManagement.assign!({ member_id: member.id, uid: '05060708' }, actor) }.to raise_error(CardManagement::Conflict)
    expect { service.commit!(prepared[:id], prepared[:revision], 'bad') }.to raise_error(CardManagement::Conflict)
    expect(old.reload.validity).to eq('activeMember')
    result = service.commit!(prepared[:id], prepared[:revision], prepared[:material]['digest'])
    expect(result[:state]).to eq('completed')
    expect(old.reload.validity).to eq('lost')
    credential = NfcCardCredential.find(result[:cardId])
    expect(NfcCredentialCodec.open(credential.sealed)).to eq(prepared[:material])
    expect(credential.memberId).to eq(member.id)
    expect(service.commit!(prepared[:id], prepared[:revision], prepared[:material]['digest'])).to eq(result)
    expect(service.prepare!(member.id, '05060708', true)).not_to have_key(:material)
    expect(AuditLog.where(event_type: 'card_enrollment_completed').count).to eq(1)
  end

  it 'rejects revoked operators and unsigned or unverified recipients before programming' do
    expect { service.prepare!(member.id, '05060708', false) }.to raise_error(CardEnrollment::Invalid)
    member.set(member_contract_signed_date: nil)
    expect { service.prepare!(member.id, '05060708', true) }.to raise_error(CardEnrollment::Invalid)
    actor.set(role: 'member')
    expect { service.prepare!(member.id, '05060708', true) }.to raise_error(Error::Forbidden)
  end

  it 'rolls back assignment and preserves recovery material when enrollment audit fails' do
    old = create(:card, member: member, uid: '01020304')
    prepared = service.prepare!(member.id, '05060708', true)
    allow(Service::AuditLogger).to receive(:log).and_return(nil)
    expect { service.commit!(prepared[:id], prepared[:revision], prepared[:material]['digest']) }.to raise_error(CardManagement::Unavailable)
    expect(old.reload.validity).to eq('activeMember')
    expect(Card.where(uid: '05060708')).not_to exist
    expect(service.show(prepared[:id])[:state]).to eq('pending')
  end
  it 'rejects commit after a competing assignment and keeps the pending material' do
    prepared = service.prepare!(member.id, '05060708', true)
    CardManagement.assign!({ member_id: member.id, uid: '11121314' }, actor)
    expect { service.commit!(prepared[:id], prepared[:revision], prepared[:material]['digest']) }.to raise_error(CardManagement::Conflict)
    expect(service.show(prepared[:id])[:state]).to eq('pending')
  end

  it 'rechecks a volunteer checkout before committing and never grants replacement authority' do
    tool = create(:tool, grants_fob_issuance: true)
    volunteer = create(:member, :current)
    checkout = create(:tool_checkout, member: volunteer, tool: tool)
    issuer_service = described_class.new(volunteer, 'issuer')
    prepared = issuer_service.prepare!(member.id, '05060708', true)
    checkout.set(revoked_at: Time.current)
    expect { issuer_service.commit!(prepared[:id], prepared[:revision], prepared[:material]['digest']) }.to raise_error(Error::Forbidden)
    checkout.set(revoked_at: nil)
    create(:card, member: member, uid: '01020304')
    expect { issuer_service.commit!(prepared[:id], prepared[:revision], prepared[:material]['digest']) }.to raise_error(Error::Forbidden)
  end

  it 'rejects malformed and missing member IDs without creating an enrollment' do
    expect { service.prepare!([], '05060708', true) }.to raise_error(CardEnrollment::Invalid)
    expect { service.prepare!(BSON::ObjectId.new, '05060708', true) }.to raise_error(Error::NotFound)
    expect(NfcCardEnrollment.where(state: 'pending')).not_to exist
  end

end
