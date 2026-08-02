require 'rails_helper'

RSpec.describe Service::MemberProvisioning do
  before do
    allow(MemberSubscriber).to receive(:send_slack_invite)
    allow(Service::AuditLogger).to receive(:log)
    allow(Honeybadger).to receive(:notify)
    allow(ENV).to receive(:[]).and_call_original
  end

  def active_member_with_card(status: 'activeMember')
    member = create(
      :member,
      status: status,
      expirationTime: 1.month.from_now.to_i * 1000
    )
    Card.create!(member: member, uid: SecureRandom.hex(6))
    member.reload
  end

  describe 'activation eligibility' do
    it 'requires a future expiration, a usable fob, and a non-blocked status' do
      %w[activeMember nonMember suspended].each do |status|
        expect(active_member_with_card(status: status)).to be_provisioning_eligible
      end

      %w[revoked inactive].each do |status|
        expect(active_member_with_card(status: status)).not_to be_provisioning_eligible
      end

      member = active_member_with_card
      member.access_cards.first.set(validity: 'lost')
      expect(member.reload).not_to be_provisioning_eligible

      member.access_cards.first.set(validity: 'activeMember')
      member.set(expirationTime: 1.day.ago.to_i * 1000)
      expect(member.reload).not_to be_provisioning_eligible
    end
  end

  describe 'activation callbacks' do
    it 'queues reconciliation when expiration or status changes' do
      member = create(:member)

      expect do
        member.update!(expirationTime: 2.months.from_now.to_i * 1000)
      end.to have_enqueued_job(MemberProvisioningJob).with(member.id.to_s)

      expect do
        member.update!(status: 'suspended')
      end.to have_enqueued_job(MemberProvisioningJob).with(member.id.to_s)
    end

    it 'queues reconciliation when a fob is issued or its usability changes' do
      member = create(:member)
      card = nil

      expect do
        card = Card.create!(member: member, uid: SecureRandom.hex(6))
      end.to have_enqueued_job(MemberProvisioningJob).with(member.id.to_s)

      expect do
        card.update!(card_location: 'lost')
      end.to have_enqueued_job(MemberProvisioningJob).with(member.id.to_s)
    end
  end

  describe '.invite_slack' do
    it 'uses a matching SlackUser email as invitation confirmation without reinviting' do
      member = create(:member, email: 'Member@Example.com')
      SlackUser.create!(
        slack_email: 'member@example.com',
        slack_id: 'U123',
        name: 'member'
      )
      expect(Service::SlackConnector).not_to receive(:invite_to_slack)

      result = described_class.invite_slack(member)

      expect(result[:status]).to eq(:confirmed)
      member.reload
      expect(member.slack_invite_source).to eq('slack_user_record')
      expect(member.slack_invite_confirmed_at).to be_present
    end

    it 'records API confirmation and the selected invitation mode' do
      member = create(:member)
      allow(Service::SlackConnector).to receive(:invite_to_slack).and_return(ok: true)
      allow(Service::SlackConnector).to receive(:new_signup_invite_mode)
        .and_return('single_channel_guest')

      described_class.invite_slack(member)

      member.reload
      expect(member.slack_invite_source).to eq('api')
      expect(member.slack_invite_mode).to eq('single_channel_guest')
      expect(member.slack_invite_confirmed_at).to be_present
    end

    it 'marks manual invitation required when no admin token is available' do
      member = create(:member)
      allow(ENV).to receive(:[]).with('SLACK_INVITES_ENABLED').and_return('true')
      allow(ENV).to receive(:[]).with('SLACK_ADMIN_TOKEN').and_return(nil)
      allow(Service::SlackConnector).to receive(:invite_to_slack)
        .and_raise(Error::NotAllowed.new('token missing'))

      described_class.invite_slack(member)

      expect(member.reload.slack_manual_action_required).to eq('invite')
      expect(Service::AuditLogger).to have_received(:log).with(
        hash_including(
          event_type: 'slack_manual_invite_required',
          slack_channel: Service::SlackConnector.admin_channel
        )
      )
    end

    it 'blocks revoked and inactive members' do
      %w[revoked inactive].each do |status|
        member = create(:member, status: status)
        expect do
          described_class.invite_slack(member, raise_errors: true)
        end.to raise_error(Error::NotAllowed, /revoked or inactive/)
      end
    end
  end

  describe '.provision_google' do
    it 'confirms both permissions and does not duplicate existing access' do
      member = active_member_with_card
      allow(ENV).to receive(:[]).with('GDRIVE_INVITES_ENABLED').and_return('true')
      allow(ENV).to receive(:[]).with('RESOURCES_FOLDER').and_return('resources')
      allow(ENV).to receive(:[]).with('GOOGLE_TRANSFER_SHARE').and_return('transfer')

      existing_writer = double(
        email_address: member.email,
        role: 'writer',
        id: 'permission-1'
      )
      drive = double
      allow(Service::GoogleDrive).to receive(:load_gdrive).and_return(drive)
      allow(drive).to receive(:list_permissions)
        .with('resources', anything)
        .and_return(double(permissions: []))
      allow(drive).to receive(:list_permissions)
        .with('transfer', anything)
        .and_return(double(permissions: [existing_writer]))
      allow(drive).to receive(:create_permission)

      result = described_class.provision_google(member, raise_errors: true)

      expect(result[:resources][:status]).to eq(:created)
      expect(result[:transfer][:status]).to eq(:confirmed)
      expect(drive).to have_received(:create_permission).once
      member.reload
      expect(member.google_resources_access_confirmed_at).to be_present
      expect(member.google_transfer_access_confirmed_at).to be_present

      described_class.provision_google(member, raise_errors: true)
      expect(drive).to have_received(:create_permission).once
    end

    it 'strictly rejects members who are not activated' do
      member = create(:member, expirationTime: 1.month.from_now.to_i * 1000)

      expect do
        described_class.provision_google(member, raise_errors: true)
      end.to raise_error(Error::NotAllowed, /usable fob/)
    end
  end

  describe 'Slack reconciliation and promotion' do
    it 'leaves an accepted guest unchanged until activation' do
      member = create(:member, expirationTime: 1.month.from_now.to_i * 1000)
      user = {
        'id' => 'U123',
        'name' => 'member',
        'profile' => { 'email' => member.email, 'real_name' => member.fullname },
        'is_ultra_restricted' => true
      }
      expect(Service::SlackConnector).not_to receive(:promote_to_regular)

      result = described_class.reconcile_slack_member(member, user)

      expect(result[:status]).to eq(:guest)
      expect(member.reload.slack_joined_at).to be_present
    end

    it 'marks manual promotion required when the legacy promotion call fails' do
      member = active_member_with_card
      user = {
        'id' => 'U123',
        'name' => 'member',
        'profile' => { 'email' => member.email, 'real_name' => member.fullname },
        'is_ultra_restricted' => true
      }
      allow(Service::SlackConnector).to receive(:promote_to_regular)
        .and_raise(StandardError.new('legacy endpoint failed'))

      result = described_class.reconcile_slack_member(member, user)

      expect(result[:status]).to eq(:manual_promotion_required)
      expect(member.reload.slack_manual_action_required).to eq('promotion')
    end
  end

  describe '.backfill!' do
    it 'records local and remote confirmation without changing remote access' do
      member = create(:member)
      SlackUser.create!(
        member: member,
        slack_email: member.email,
        slack_id: 'U123',
        name: 'member'
      )
      allow(described_class).to receive(:slack_users_by_email).and_return({})
      allow(described_class).to receive(:google_permission_emails)
        .and_return(Set.new([member.email]))
      expect(Service::SlackConnector).not_to receive(:invite_to_slack)
      expect(Service::SlackConnector).not_to receive(:promote_to_regular)

      result = described_class.backfill!

      expect(result[:slack_invited]).to eq(1)
      expect(member.reload.slack_invite_source).to eq('slack_user_record')
      expect(member.google_resources_access_confirmed_at).to be_present
      expect(member.google_transfer_access_confirmed_at).to be_present
    end
  end

  describe '.provisioning_status' do
    it 'keeps unreconciled legacy members unknown' do
      member = create(:member)
      expect(described_class.provisioning_status(member).dig(:slack, :status)).to eq('unknown')
    end

    it 'invalidates current-email confirmation after an email change' do
      member = create(:member)
      member.set(
        provisioning_initialized_at: Time.current,
        provisioning_email: member.email,
        slack_invite_confirmed_at: Time.current,
        slack_invite_source: 'api',
        google_resources_access_confirmed_at: Time.current
      )

      member.update!(email: 'changed@example.com')

      member.reload
      expect(member.provisioning_email).to eq('changed@example.com')
      expect(member.slack_invite_confirmed_at).to be_nil
      expect(member.slack_manual_action_required).to eq('invite')
      expect(member.google_resources_access_confirmed_at).to be_nil
    end
  end
end
