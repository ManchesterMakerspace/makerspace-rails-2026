require 'rails_helper'

RSpec.describe CardManagement do
  let(:actor) { create(:member, :admin) }
  let(:member) { create(:member, expirationTime: 1.day.from_now.to_i * 1000) }
  let(:card) { create(:card, uid: '000AFF', member: member) }

  it 'keeps an existing card active when duplicate assignment fails' do
    existing = create(:card, uid: '01020304', member: member)
    card
    expect { described_class.assign!({ member_id: member.id, uid: card.uid }, actor) }.to raise_error(CardManagement::Conflict)
    expect(existing.reload.validity).to eq('activeMember')
  end

  it 'rejects a stale release after membership renewal' do
    member.set(expirationTime: 1.day.ago.to_i * 1000)
    version = described_class.version(card, member)
    member.set(expirationTime: 1.day.from_now.to_i * 1000)
    expect { described_class.release!(card.id, version, actor) }.to raise_error(CardManagement::Conflict)
    expect(Card.where(id: card.id)).to exist
  end

  it 'releases expired assignments and leaves the member intact' do
    card
    member.set(expirationTime: 1.day.ago.to_i * 1000)
    described_class.release!(card.id, described_class.version(card.reload), actor)
    expect(Card.where(id: card.id)).not_to exist
    expect(Member.where(id: member.id)).to exist
  end

  it 'detects a renewal racing between eligibility checking and deletion' do
    card
    member.set(expirationTime: 1.day.ago.to_i * 1000)
    token = described_class.version(card.reload)
    renewed = false
    allow(described_class).to receive(:reason).and_wrap_original do |original, *arguments|
      unless renewed
        renewed = true
        # Another request's write: separate thread/session, no card callback needed.
        Thread.new { Member.where(id: member.id).update_all(expirationTime: 1.day.from_now.to_i * 1000) }.value
      end
      original.call(*arguments)
    end
    expect { described_class.release!(card.id, token, actor) }.to raise_error(CardManagement::Conflict)
    expect(Card.where(id: card.id)).to exist
    expect(AuditLog.where(event_type: 'card_released', resource_id: card.id)).not_to exist
  end

  it 'releases lost orphaned cards, but not other orphaned cards' do
    card.update!(card_location: 'lost')
    member.delete
    orphan = card.reload
    expect(described_class.reason(orphan)).to eq('Lost card')
    described_class.release!(orphan.id, described_class.version(orphan), actor)
    expect(Card.where(id: orphan.id)).not_to exist
  end

  it 'does not grant release solely for stolen or suspended status' do
    card.update!(card_location: 'stolen')
    expect(described_class.reason(card, member)).to be_nil
    member.set(status: 'suspended')
    expect(described_class.reason(card, member)).to be_nil
  end

  it 'rolls back deletion if audit persistence fails' do
    card.update!(card_location: 'lost')
    allow(Service::AuditLogger).to receive(:log).and_return(nil)
    expect { described_class.release!(card.id, described_class.version(card), actor) }.to raise_error(CardManagement::Unavailable)
    expect(Card.where(id: card.id)).to exist
  end
end
