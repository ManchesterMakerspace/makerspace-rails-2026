require 'rails_helper'

describe VolunteerTask, type: :model do
  let(:admin)  { create(:member, :admin) }
  let(:member) { create(:member) }

  let(:valid_attrs) do
    {
      title:         'Reorganize woodshop',
      description:   'Sort and label all lumber bins',
      credit_value:  1.0,
      created_by_id: admin.id,
      status:        'available'
    }
  end

  before do
    allow(VolunteerTask).to receive(:max_credit_value).and_return(2.0)
    allow(EarnedMembership).to receive_message_chain(:where, :exists?).and_return(false)
    allow(SlackUser).to receive(:find_by).and_return(nil)
    allow(Service::SlackConnector).to receive(:enque_message)
    allow(Service::SlackConnector).to receive(:send_slack_message)
  end

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(VolunteerTask.new(valid_attrs)).to be_valid
    end

    it 'requires title' do
      expect(VolunteerTask.new(valid_attrs.merge(title: nil))).not_to be_valid
    end

    it 'requires description' do
      expect(VolunteerTask.new(valid_attrs.merge(description: nil))).not_to be_valid
    end

    it 'accepts fractional credit values' do
      expect(VolunteerTask.new(valid_attrs.merge(credit_value: 0.5))).to be_valid
    end

    it 'rejects credit_value above max on create' do
      task = VolunteerTask.new(valid_attrs.merge(credit_value: 3.0))
      expect(task).not_to be_valid
      expect(task.errors[:credit_value]).to be_present
    end

    it 'allows credit_value at exactly the max' do
      expect(VolunteerTask.new(valid_attrs.merge(credit_value: 2.0))).to be_valid
    end

    it 'does not re-validate max credit on update' do
      task = VolunteerTask.create!(valid_attrs.merge(credit_value: 2.0))
      allow(VolunteerTask).to receive(:max_credit_value).and_return(1.0)
      task.title = 'Updated title'
      expect(task).to be_valid
    end
  end

  describe '#claim!' do
    let(:task) { VolunteerTask.create!(valid_attrs) }

    it 'sets status to claimed and records the member' do
      task.claim!(member)
      expect(task.reload.status).to eq('claimed')
      expect(task.claimed_by_id).to eq(member.id)
      expect(task.claimed_at).not_to be_nil
    end

    it 'raises Forbidden if task is not available' do
      task.update!(status: 'claimed')
      expect { task.claim!(member) }.to raise_error(Error::Forbidden)
    end
  end

  describe '#mark_pending!' do
    let(:task) { VolunteerTask.create!(valid_attrs.merge(status: 'claimed', claimed_by_id: member.id)) }

    it 'moves status to pending' do
      task.mark_pending!(member)
      expect(task.reload.status).to eq('pending')
    end

    it 'raises Forbidden if member is not the claimer' do
      other = create(:member)
      expect { task.mark_pending!(other) }.to raise_error(Error::Forbidden)
    end
  end

  describe '#complete!' do
    let(:task) { VolunteerTask.create!(valid_attrs.merge(status: 'pending', claimed_by_id: member.id, credit_value: 1.5)) }

    it 'sets status to completed and issues a credit with correct value' do
      expect { task.complete!(admin) }.to change { VolunteerCredit.count }.by(1)
      expect(task.reload.status).to eq('completed')
      credit = VolunteerCredit.last
      expect(credit.member_id).to eq(member.id)
      expect(credit.credit_value).to eq(1.5)
      expect(credit.status).to eq('approved')
    end

    it 'raises Forbidden if verifier is the claimer' do
      task.update!(claimed_by_id: admin.id)
      expect { task.complete!(admin) }.to raise_error(Error::Forbidden)
    end

    it 'raises Forbidden if task is not pending' do
      task.update!(status: 'claimed')
      expect { task.complete!(admin) }.to raise_error(Error::Forbidden)
    end
  end

  describe '#release!' do
    let(:task) { VolunteerTask.create!(valid_attrs.merge(status: 'claimed', claimed_by_id: member.id)) }

    it 'returns task to available and clears claimant' do
      task.release!(admin, 'No response from member')
      expect(task.reload.status).to eq('available')
      expect(task.claimed_by_id).to be_nil
      expect(task.rejection_reason).to eq('No response from member')
    end

    it 'raises Forbidden if task is not claimed' do
      task.update!(status: 'available', claimed_by_id: nil)
      expect { task.release!(admin, 'reason') }.to raise_error(Error::Forbidden)
    end

    it 'raises Forbidden if admin is the claimer' do
      task.update!(claimed_by_id: admin.id)
      expect { task.release!(admin, 'reason') }.to raise_error(Error::Forbidden)
    end

    it 'attempts to DM the former claimant when Slack linked' do
      slack_user = double('SlackUser', slack_id: 'U456')
      allow(SlackUser).to receive(:find_by).with(member_id: member.id).and_return(slack_user)
      expect(Service::SlackConnector).to receive(:enque_message).with(anything, 'U456', anything)
      task.release!(admin, 'No response from member')
    end
  end

  describe '#reject_pending!' do
    let(:task) { VolunteerTask.create!(valid_attrs.merge(status: 'pending', claimed_by_id: member.id)) }

    it 'returns task to available and clears claimant' do
      task.reject_pending!(admin, 'Work not completed to standard')
      expect(task.reload.status).to eq('available')
      expect(task.claimed_by_id).to be_nil
      expect(task.rejection_reason).to eq('Work not completed to standard')
    end

    it 'raises Forbidden if task is not pending' do
      task.update!(status: 'claimed')
      expect { task.reject_pending!(admin, 'reason') }.to raise_error(Error::Forbidden)
    end

    it 'raises Forbidden if admin is the claimer' do
      task.update!(claimed_by_id: admin.id)
      expect { task.reject_pending!(admin, 'reason') }.to raise_error(Error::Forbidden)
    end

    it 'attempts to DM the former claimant when Slack linked' do
      slack_user = double('SlackUser', slack_id: 'U456')
      allow(SlackUser).to receive(:find_by).with(member_id: member.id).and_return(slack_user)
      expect(Service::SlackConnector).to receive(:enque_message).with(anything, 'U456', anything)
      task.reject_pending!(admin, 'Work not completed to standard')
    end
  end

  describe '#cancel!' do
    let(:task) { VolunteerTask.create!(valid_attrs) }

    it 'sets status to cancelled' do
      task.cancel!
      expect(task.reload.status).to eq('cancelled')
    end
  end
end
