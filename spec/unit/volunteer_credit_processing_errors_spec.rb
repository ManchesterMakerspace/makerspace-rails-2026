# Exercise the real credit helpers without Rails, MongoDB, or Slack.
require 'active_support/all'
require 'mongoid'
require_relative '../spec_helper'

RSpec.describe 'Volunteer credit follow-up error propagation' do
  let(:member) { double(id: BSON::ObjectId.new) }
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
      allow(VolunteerCredit).to receive(:discount_eligible_year_count_for).and_raise(failure)
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
end
