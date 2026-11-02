require 'rails_helper'

RSpec.describe Service::MemberSoftDelete do
  let(:actor) { create(:member, :admin) }
  let(:removal_results) do
    {
      gdrive_resources: { status: :not_found },
      gdrive_transfer_share: { status: :not_found },
      slack: { status: :not_found }
    }
  end

  before do
    allow(Service::MemberAccess).to receive(:full_deprovision).and_return(removal_results)
    allow(Service::AuditLogger).to receive(:log)
  end

  describe '.delete!' do
    it 'deprovisions access, sets merged_at, and logs the action' do
      member = create(:member, status: 'inactive')

      described_class.delete!(member, actor: actor)

      expect(Service::MemberAccess).to have_received(:full_deprovision).with(member, alert: false)
      expect(member.reload.merged_at).to be_present
      expect(Service::AuditLogger).to have_received(:log).with(
        hash_including(
          log_type: 'member',
          event_type: 'member_soft_deleted',
          resource_type: 'Member',
          resource_id: member.id,
          actor: actor,
          subject: member
        )
      )
    end

    it 'hides the member from default queries once deleted' do
      member = create(:member, status: 'inactive')

      described_class.delete!(member, actor: actor)

      expect(Member.where(id: member.id).first).to be_nil
      expect(Member.unscoped.where(id: member.id).first).to be_present
    end

    it 'raises and does not deprovision when the member is currently active and unexpired' do
      member = create(:member, status: 'activeMember', expirationTime: 1.day.from_now.to_i * 1000)

      expect { described_class.delete!(member, actor: actor) }.to raise_error(Service::MemberSoftDelete::ActiveMembershipError)

      expect(Service::MemberAccess).not_to have_received(:full_deprovision)
      expect(member.reload.merged_at).to be_nil
    end

    it 'raises when a live subscription exists regardless of status' do
      member = create(:member, status: 'inactive', subscription: true)

      expect { described_class.delete!(member, actor: actor) }.to raise_error(Service::MemberSoftDelete::ActiveMembershipError)
    end

    it 'raises when the member is already deleted' do
      member = create(:member, status: 'inactive')
      member.update_attribute(:merged_at, Time.current)

      expect { described_class.delete!(member, actor: actor) }.to raise_error(Service::MemberSoftDelete::AlreadyDeletedError)
    end

    describe 'status' do
      it 'sets an active but expired account to inactive' do
        member = create(:member, status: 'activeMember', expirationTime: nil)

        described_class.delete!(member, actor: actor)

        expect(member.reload.status).to eq('inactive')
      end

      it 'marks the cards of a deleted member invalid' do
        member = create(:member, status: 'activeMember', expirationTime: nil)
        card = create(:card, member: member, uid: SecureRandom.hex(6))

        described_class.delete!(member, actor: actor)

        expect(card.reload.validity).to eq('inactive')
      end

      %w[revoked suspended].each do |status|
        it "keeps a #{status} status, since that is a deliberate block" do
          member = create(:member, status: status, expirationTime: nil)

          described_class.delete!(member, actor: actor)

          expect(member.reload.status).to eq(status)
          expect(member.merged_at).to be_present
        end
      end
    end

    describe 'open invoices' do
      let(:member) { create(:member, status: 'inactive', expirationTime: nil) }

      it 'refuses when the member has an unpaid invoice, and changes nothing' do
        create(:invoice, member: member)

        expect { described_class.delete!(member, actor: actor) }
          .to raise_error(Service::MemberSoftDelete::OpenInvoicesError, /1 open invoice .*unpaid, or paid but not yet applied/)

        expect(Service::MemberAccess).not_to have_received(:full_deprovision)
        expect(member.reload.merged_at).to be_nil
        expect(member.status).to eq('inactive')
      end

      it 'refuses when the member has a paid invoice that is held and not applied yet' do
        create(:invoice, member: member, transaction_id: 'held_txn')

        expect { described_class.delete!(member, actor: actor) }
          .to raise_error(Service::MemberSoftDelete::OpenInvoicesError)
      end

      it 'counts every open invoice in the message' do
        create(:invoice, member: member, transaction_id: 'held_txn_a')
        create(:invoice, member: member, transaction_id: 'held_txn_b')

        expect { described_class.delete!(member, actor: actor) }
          .to raise_error(Service::MemberSoftDelete::OpenInvoicesError, /2 open invoices/) { |error| expect(error.count).to eq(2) }
      end

      it 'also finds an invoice recorded only against the member as its resource' do
        create(:invoice, member: create(:member), resource_class: 'member', resource_id: member.id.to_s)

        expect { described_class.delete!(member, actor: actor) }
          .to raise_error(Service::MemberSoftDelete::OpenInvoicesError)
      end

      it 'ignores settled invoices and refunded ones' do
        create(:settled_invoice, member: member, transaction_id: 'done_txn')
        create(:invoice, member: member, transaction_id: 'refunded_txn', refunded: true)

        expect { described_class.delete!(member, actor: actor) }.not_to raise_error
        expect(member.reload.merged_at).to be_present
      end

      it 'ignores other members invoices' do
        create(:invoice, member: create(:member))

        expect { described_class.delete!(member, actor: actor) }.not_to raise_error
      end
    end

    describe 'removing the member from Slack and Google Drive' do
      let(:member) { create(:member, status: 'inactive', expirationTime: nil) }

      def results_with(overrides)
        removal_results.merge(overrides)
      end

      it 'stops, leaves the account visible, and says what failed when the Slack removal errors' do
        allow(Service::MemberAccess).to receive(:full_deprovision)
          .and_return(results_with(slack: { status: :error, message: 'not_allowed_token_type' }))

        expect { described_class.delete!(member, actor: actor) }
          .to raise_error(Service::MemberSoftDelete::ManualRemovalRequiredError, /Slack: not_allowed_token_type/) do |error|
            expect(error.problems).to eq(['Slack: not_allowed_token_type'])
          end

        expect(member.reload.merged_at).to be_nil
        expect(member.status).to eq('inactive')
        expect(Service::AuditLogger).not_to have_received(:log)
      end

      it 'stops when a Drive removal errors, naming the folder' do
        allow(Service::MemberAccess).to receive(:full_deprovision)
          .and_return(results_with(gdrive_resources: { status: :error, message: 'quota' }))

        expect { described_class.delete!(member, actor: actor) }
          .to raise_error(Service::MemberSoftDelete::ManualRemovalRequiredError, /Google Drive \(Resources folder\): quota/)
      end

      it 'stops when Slack removal was skipped for a member who is in Slack' do
        SlackUser.create!(member: member, slack_id: 'U_IN_SLACK')
        allow(Service::MemberAccess).to receive(:full_deprovision)
          .and_return(results_with(slack: { status: :skipped, reason: 'SLACK_ADMIN_TOKEN not configured' }))

        expect { described_class.delete!(member, actor: actor) }
          .to raise_error(Service::MemberSoftDelete::ManualRemovalRequiredError, /SLACK_ADMIN_TOKEN not configured/)
      end

      it 'does not stop when Slack removal was skipped for a member who has no Slack account' do
        allow(Service::MemberAccess).to receive(:full_deprovision)
          .and_return(results_with(slack: { status: :skipped, reason: 'SLACK_ADMIN_TOKEN not configured' }))

        expect { described_class.delete!(member, actor: actor) }.not_to raise_error
      end

      it 'stops when Drive removal was skipped for a member who was given Drive access' do
        member.set(google_resources_access_confirmed_at: Time.current)
        allow(Service::MemberAccess).to receive(:full_deprovision)
          .and_return(results_with(gdrive_resources: { status: :skipped, reason: 'GDRIVE_INVITES_ENABLED is not true' }))

        expect { described_class.delete!(member, actor: actor) }
          .to raise_error(Service::MemberSoftDelete::ManualRemovalRequiredError, /GDRIVE_INVITES_ENABLED/)
      end

      it 'does not stop when Drive removal was skipped for a member who never had Drive access' do
        allow(Service::MemberAccess).to receive(:full_deprovision)
          .and_return(results_with(gdrive_resources: { status: :skipped, reason: 'GDRIVE_INVITES_ENABLED is not true' }))

        expect { described_class.delete!(member, actor: actor) }.not_to raise_error
      end

      it 'finishes when the admin confirms they removed the member by hand, and records the confirmation' do
        allow(Service::MemberAccess).to receive(:full_deprovision)
          .and_return(results_with(slack: { status: :error, message: 'not_allowed_token_type' }))

        described_class.delete!(member, actor: actor, manual_removal_confirmed: true)

        expect(member.reload.merged_at).to be_present
        expect(member.status).to eq('inactive')
        expect(Service::AuditLogger).to have_received(:log).with(
          hash_including(
            event_type: 'member_soft_deleted',
            message_details: a_string_matching(/confirmed removing them by hand: Slack: not_allowed_token_type/)
          )
        )
      end

      it 'treats a deprovision that returned nothing as no problems' do
        allow(Service::MemberAccess).to receive(:full_deprovision).and_return(nil)

        expect { described_class.delete!(member, actor: actor) }.not_to raise_error
      end

      it 'puts the removal results in the audit entry' do
        allow(Service::MemberAccess).to receive(:full_deprovision)
          .and_return(results_with(slack: { status: :ok }, gdrive_resources: { status: :ok }))

        described_class.delete!(member, actor: actor)

        expect(Service::AuditLogger).to have_received(:log).with(
          hash_including(message_details: a_string_matching(/Slack: ok\. Google Drive: ok\/not_found\./))
        )
      end
    end
  end

  describe '.restore!' do
    it 'clears merged_at and logs the action' do
      member = create(:member, status: 'inactive')
      member.update_attribute(:merged_at, Time.current)

      described_class.restore!(member, actor: actor)

      expect(member.reload.merged_at).to be_nil
      expect(Service::AuditLogger).to have_received(:log).with(
        hash_including(
          log_type: 'member',
          event_type: 'member_restored',
          resource_type: 'Member',
          resource_id: member.id,
          actor: actor,
          subject: member
        )
      )
    end

    it 'leaves the status inactive, for an admin to reactivate' do
      member = create(:member, status: 'activeMember', expirationTime: nil)
      described_class.delete!(member, actor: actor)

      described_class.restore!(member.reload, actor: actor)

      expect(member.reload.status).to eq('inactive')
      expect(member.merged_at).to be_nil
    end

    it 'raises when the member is not deleted' do
      member = create(:member, status: 'inactive')

      expect { described_class.restore!(member, actor: actor) }.to raise_error(Service::MemberSoftDelete::NotDeletedError)
    end
  end
end
