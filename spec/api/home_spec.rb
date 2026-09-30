require 'swagger_helper'

RSpec.describe 'Member Home API', type: :request do
  before { allow(REDIS).to receive(:set).and_return(true) }
  path '/home' do
    get 'Gets the current member landing page data' do
      tags 'Members'
      operationId 'getHome'
      security [sessionAuth: []]
      produces 'application/json'
      description 'Requires a member session and completed TOTP challenge. Returns only the current member, confirmed Slack acceptance and up to 10 eligible, in-service safety checkouts (Orientation first). Does not contact Slack or initiate provisioning. The nested member.slack.url is null; use slack.newMembersChannelUrl, which uses only cached workspace configuration.'

      response '200', 'current member home data' do
        schema type: :object, required: %w[member slack availableCheckouts], properties: {
          member: { '$ref' => '#/components/schemas/HomeMember' },
          slack: {
            type: :object, required: %w[accepted newMembersChannelUrl], properties: {
              accepted: { type: :boolean },
              newMembersChannelUrl: { type: :string, nullable: true, format: :uri }
            }
          },
          availableCheckouts: {
            type: :array, maxItems: 10, items: {
              type: :object, required: %w[id name shopName requestorAnnotation], properties: {
                id: { type: :string }, name: { type: :string }, shopName: { type: :string },
                requestorAnnotation: { type: :string, nullable: true }
              }
            }
          }
        }
        let(:member) { create(:member, status: 'pending', expirationTime: nil) }
        let!(:orientation) { create(:tool, name: 'Orientation', allow_pending: true, requestor_annotation: 'Bring ID') }
        before { sign_in member }
        run_test! do |response|
          expect(response.parsed_body.dig('member', 'id')).to eq(member.id.to_s)
          expect(response.parsed_body.fetch('availableCheckouts').first).to include('id' => orientation.id.to_s, 'requestorAnnotation' => 'Bring ID')
          expect(response.headers['Cache-Control']).to eq('private, no-store')
        end

        context 'an active board member opening their own Home' do
          let(:member) { create(:member, :current, role: 'board_member') }
          run_test!
        end

        context 'a member with populated integration, subscription and access fields' do
          let(:member) { create(:member, :current) }
          let!(:card) { create(:card, member: member, defer_assignment_effects: true) }
          let!(:event) { MailtrapEvent.create!(member_id: member.id, email: member.email, status: 'delivered', occurred_at: Time.current) }
          before do
            member.set(subscription: true, subscription_id: 'subscription123', customer_id: 'customer123',
              firebase_uid: 'firebase123', address_unit: 'Unit 2', silence_emails: false, notes: 'Member note',
              otp_required_for_login: true, otp_secret_encrypted: 'test-secret',
              resource_manager_shop_ids: [orientation.shop.id.to_s])
            invoice = build(:invoice, member: member, subscription_id: member.subscription_id, plan_id: 'monthly')
            Invoice.collection.insert_one(invoice.attributes)
            SlackUser.create!(member: member, slack_id: 'U123', slack_email: member.email, real_name: 'Slack Member')
            CheckoutApprover.create!(member: member, shop_ids: [orientation.shop.id.to_s], tool_ids: [orientation.id.to_s])
            expect(Service::SlackConnector).not_to receive(:client)
          end

          run_test! do |response|
            data = response.parsed_body.fetch('member')
            expect(data).to include('subscriptionPlanId' => 'monthly', 'totpEnabled' => true,
              'cardId' => card.id.to_s, 'firebaseUid' => 'firebase123', 'isCheckoutApprover' => true)
            expect(data.fetch('slack')).to eq('slackId' => 'U123', 'name' => 'Slack Member', 'url' => nil)
            expect(data.fetch('mailtrap')).to include('id' => event.id.to_s, 'status' => 'delivered', 'value' => 'delivered')
            expect(data.fetch('address')).to include('unit' => 'Unit 2')
          end
        end

        %w[primary secondary].each do |household_role|
          context "a #{household_role} household member" do
            let(:primary) { create(:member, :current) }
            let(:member) { household_role == 'primary' ? primary : create(:member, :current) }
            before do
              member.set(groupName: primary.id.to_s)
              create(:group, member: primary, groupName: primary.id.to_s, groupRep: primary.fullname)
            end

            run_test! do |response|
              data = response.parsed_body.fetch('member')
              expect(data.fetch('householdRole')).to eq(household_role)
              expect(data.fetch('household')).to include('groupName' => primary.id.to_s,
                'role' => household_role, 'primaryMemberName' => primary.fullname)
            end
          end
        end

        context 'an earned member' do
          let!(:earned_membership) { create(:earned_membership, member: member) }

          run_test! do |response|
            expect(response.parsed_body.fetch('member')).to include(
              'earnedMembershipId' => earned_membership.id.to_s, 'earnedMembershipActive' => true
            )
          end
        end
      end

      response '401', 'member authentication or TOTP challenge required' do
        run_test!
      end
    end
  end
end
