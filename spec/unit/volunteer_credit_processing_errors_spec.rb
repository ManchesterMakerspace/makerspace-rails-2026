# Exercise the real credit helpers without Rails, MongoDB, or Slack.
require 'active_support/all'
require 'mongoid'
require_relative '../spec_helper'

RSpec.describe 'Volunteer credit follow-up error propagation' do
  let(:member) { double(id: BSON::ObjectId.new, subscription_id: 'subscription') }
  let(:failure) { RuntimeError.new('Processing unavailable') }

  before do
    stub_const('VolunteerCredit', Class.new)
    stub_const('FixTicketId', String)
    stub_const('Service::SlackConnector', Module.new)
    stub_const('Service::ErrorReporter', Module.new do
      def self.notify(_error); end
    end)
    load File.expand_path('../../app/models/volunteer_credit.rb', __dir__)
    allow(Mongo::Client).to receive(:new).and_raise('This unit spec must not connect to MongoDB')
    allow(Service::ErrorReporter).to receive(:notify)
    @credit = VolunteerCredit.new(member_id: member.id, description: 'Event attendance', status: 'approved')
    allow(@credit).to receive(:member).and_return(member)
  end

  context 'award notification' do
    before do
      # Failure computing the notification total is rescued by the real helper.
      allow(VolunteerCredit).to receive(:year_count_for).and_raise(failure)
    end

    it 'retains the existing rescued-error behavior by default' do
      expect { @credit.send(:notify_member_credit_awarded) }.not_to raise_error
      expect(Service::ErrorReporter).to have_received(:notify).with(failure)
    end

    it 'reports and rethrows the original error when event closure requests it' do
      expect { @credit.send(:notify_member_credit_awarded, raise_errors: true) }
        .to raise_error { |error| expect(error).to equal(failure) }
      expect(Service::ErrorReporter).to have_received(:notify).with(failure)
    end
  end

  context 'discount processing' do
    before do
      allow(VolunteerCredit).to receive(:discount_id).and_return('discount')
      stub_const('EarnedMembership', Class.new do
        def self.active; end
      end)
      active_memberships = double(where: double(exists?: false))
      allow(EarnedMembership).to receive(:active).and_return(active_memberships)
      allow(VolunteerCredit).to receive(:discount_eligible_year_count_for).and_return(8)
      allow(VolunteerCredit).to receive(:discounts_applied_this_year_for).and_return(0)
      allow(VolunteerCredit).to receive(:credits_per_discount).and_return(8)
      allow(VolunteerCredit).to receive(:max_discounts_per_year).and_return(2)
      allow(VolunteerCredit).to receive(:collection).and_return(double(find_one_and_update: { 'credit_value' => 8 }))
      stub_const('BraintreeService::VolunteerDiscount', Class.new do
        def self.apply(*_arguments); end
      end)
      allow(BraintreeService::VolunteerDiscount).to receive(:apply).and_raise(failure)
      allow(@credit).to receive(:notify_discount_error)
    end

    it 'retains the existing error reporting and discount notice by default' do
      expect { @credit.send(:check_discount_threshold!) }.not_to raise_error
      expect(Service::ErrorReporter).to have_received(:notify).with(failure)
      expect(@credit).to have_received(:notify_discount_error).with(member, failure)
    end

    it 'reports, notifies, and rethrows the original error for event closure' do
      expect { @credit.send(:check_discount_threshold!, raise_errors: true) }
        .to raise_error { |error| expect(error).to equal(failure) }
      expect(Service::ErrorReporter).to have_received(:notify).with(failure)
      expect(@credit).to have_received(:notify_discount_error).with(member, failure)
    end
  end

  context 'discount notices' do
    before do
      stub_const('Service::EmailTemplate', Module.new do
        def self.common_variables(_member); end
      end)
      allow(Service::EmailTemplate).to receive(:common_variables).and_raise(failure)
      stub_const('SlackUser', Class.new do
        def self.find_by(**_attributes); end
      end)
      allow(SlackUser).to receive(:find_by).and_return(nil)
      allow(@credit).to receive(:notify_discount_error)
    end

    { notify_no_subscription: [], notify_discount_applied: [{ amount: 10, cycles_added: 1 }] }.each do |method, arguments|
      it "keeps #{method}'s default handling and propagates the error when requested" do
        expect { @credit.send(method, member, *arguments) }.not_to raise_error
        expect { @credit.send(method, member, *arguments, raise_errors: true) }
          .to raise_error { |error| expect(error).to equal(failure) }
        expect(Service::ErrorReporter).to have_received(:notify).with(failure).twice
      end
    end
  end
end
