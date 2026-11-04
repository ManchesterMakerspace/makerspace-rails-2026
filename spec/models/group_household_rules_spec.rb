require 'rails_helper'

RSpec.describe Group, 'household size, payment and seats' do
  HOUSEHOLD_SPEC_PLAN = 'household-membership-one-month-recurring'.freeze
  HOUSEHOLD_SPEC_ADDRESS = { address_street: '12 Main St', address_postal_code: '03101' }.freeze

  def primary_on_plan(plan_id: HOUSEHOLD_SPEC_PLAN, settled: true, member_attrs: {})
    member = create(:member, HOUSEHOLD_SPEC_ADDRESS.merge(member_attrs))
    create(:invoice, member: member, resource_id: member.id.to_s, resource_class: 'member', plan_id: plan_id,
                     settled_at: settled ? Time.now : nil)
    member
  end

  def household_for(primary)
    primary.update_attributes!(groupName: primary.id.to_s)
    Group.create!(groupName: primary.id.to_s, groupRep: primary.fullname, expiry: primary.expirationTime)
  end

  describe '.size_for' do
    it 'is 2 when the plan says nothing' do
      expect(described_class.size_for(primary_on_plan)).to eq(2)
    end

    it 'uses the household size set on the plan' do
      create(:invoice_option, plan_id: HOUSEHOLD_SPEC_PLAN, household_size: 3)

      expect(described_class.size_for(primary_on_plan)).to eq(3)
    end

    it 'treats a household plan with no size as 2' do
      create(:invoice_option, plan_id: HOUSEHOLD_SPEC_PLAN)

      expect(described_class.size_for(primary_on_plan)).to eq(2)
    end
  end

  describe '.payment_accepted_for?' do
    def accepted?(primary)
      described_class.payment_accepted_for?(primary.reload)
    end

    it 'is true once the household payment is settled, even before the first fob (no expiry yet)' do
      expect(accepted?(primary_on_plan)).to be(true)
    end

    it 'is false when there is no household payment, or it is not settled yet' do
      expect(accepted?(create(:member))).to be(false)
      expect(accepted?(primary_on_plan(settled: false))).to be(false)
    end

    it 'is false when the settled payment was refunded or is being disputed' do
      refunded = primary_on_plan
      Invoice.where(resource_id: refunded.id.to_s).first.update!(refunded: true)
      disputed = primary_on_plan
      Invoice.where(resource_id: disputed.id.to_s).first.update!(dispute_requested: Time.now, dispute_settled: false)

      expect(accepted?(refunded)).to be(false)
      expect(accepted?(disputed)).to be(false)
    end

    it 'is true while the paid time runs and false once it has run out' do
      current = primary_on_plan(member_attrs: { expirationTime: (Time.now + 10.days).to_i * 1000 })
      lapsed = primary_on_plan(member_attrs: { expirationTime: (Time.now - 2.days).to_i * 1000 })

      expect(accepted?(current)).to be(true)
      expect(accepted?(lapsed)).to be(false)
    end

    it 'stays true between billing cycles, when the newest invoice is not paid yet but the paid time still runs' do
      primary = primary_on_plan(member_attrs: { expirationTime: (Time.now + 10.days).to_i * 1000 })
      create(:invoice, member: primary, resource_id: primary.id.to_s, resource_class: 'member', plan_id: HOUSEHOLD_SPEC_PLAN, settled_at: nil)

      expect(accepted?(primary)).to be(true)
    end
  end

  describe '#add_subordinate' do
    let(:primary) { primary_on_plan }
    let(:group) { household_for(primary) }

    it 'links a member whose address matches, with St/Street style differences' do
      secondary = create(:member, address_street: '12 main street apt 2', address_postal_code: '03101')

      expect(group.add_subordinate(secondary)).to be_nil

      expect(secondary.reload.groupName).to eq(primary.id.to_s)
    end

    it 'refuses a different address, naming both addresses' do
      secondary = create(:member, address_street: '14 Main St', address_postal_code: '03101')

      expect { group.add_subordinate(secondary) }
        .to raise_error(::Error::UnprocessableEntity, /Address mismatch: .*14 Main St, 03101.*12 Main St, 03101/)
      expect(secondary.reload.groupName).to be_nil
    end

    it 'links a different address when an admin gives a reason, and returns the override details' do
      secondary = create(:member, address_street: '14 Main St', address_postal_code: '03101')

      override = group.add_subordinate(secondary, address_override_reason: 'Moving in next week')

      expect(override).to eq(reason: 'Moving in next week', household_address: '12 Main St, 03101', member_address: '14 Main St, 03101')
      expect(secondary.reload.groupName).to eq(primary.id.to_s)
    end

    it 'refuses a blank override reason' do
      secondary = create(:member, address_street: '14 Main St', address_postal_code: '03101')

      expect { group.add_subordinate(secondary, address_override_reason: '   ') }.to raise_error(::Error::UnprocessableEntity, /Address mismatch/)
    end

    it 'refuses another member when the household is full' do
      group.add_subordinate(create(:member, HOUSEHOLD_SPEC_ADDRESS))

      expect(group.reload.seats_used).to eq(2)
      expect(group.full?).to be(true)
      expect { group.add_subordinate(create(:member, HOUSEHOLD_SPEC_ADDRESS)) }.to raise_error(::Error::UnprocessableEntity, /household is full \(2 of 2/)
    end

    it 'allows a third adult on a plan that covers three' do
      create(:invoice_option, plan_id: HOUSEHOLD_SPEC_PLAN, household_size: 3)
      group.add_subordinate(create(:member, HOUSEHOLD_SPEC_ADDRESS))

      expect { group.add_subordinate(create(:member, HOUSEHOLD_SPEC_ADDRESS)) }.not_to raise_error
      expect(group.reload.seats_used).to eq(3)
    end
  end
end

RSpec.describe InvoiceOption, 'household size' do
  it 'accepts a whole number of 2 or more, or none' do
    expect(build(:invoice_option, plan_id: 'household-x', household_size: 3)).to be_valid
    expect(build(:invoice_option, plan_id: 'household-x', household_size: nil)).to be_valid
    expect(build(:invoice_option, plan_id: 'household-x', household_size: 1)).not_to be_valid
    expect(build(:invoice_option, plan_id: 'household-x', household_size: 2.5)).not_to be_valid
  end

  it 'counts a household plan with no size as 2, and a plan that is not a household plan as none' do
    expect(build(:invoice_option, plan_id: 'household-x').effective_household_size).to eq(2)
    expect(build(:invoice_option, plan_id: 'household-x', household_size: 4).effective_household_size).to eq(4)
    expect(build(:invoice_option, plan_id: 'individual-x').effective_household_size).to be_nil
  end
end
