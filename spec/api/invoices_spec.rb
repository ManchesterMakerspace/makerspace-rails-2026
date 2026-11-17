require 'swagger_helper'

describe 'Invoices API', type: :request do
  path '/invoices' do
    get 'Gets a list of invoices' do
      tags 'Invoices'
      operationId "listInvoices"
      consumes 'application/json'
      parameter name: :pageNum, in: :query, type: :number, required: false
      parameter name: :orderBy, in: :query, type: :string, required: false
      parameter name: :order, in: :query, type: :string, required: false

      parameter name: :settled, in: :query, type: :boolean, required: false,
        description: 'Includes confirmed cash/check receipts held until first-fob issuance as paid.'
      parameter name: :pastDue, in: :query, type: :boolean, required: false,
        description: 'Confirmed cash/check receipts held until first-fob issuance are not past due.'
      parameter name: :refunded, in: :query, type: :boolean, required: false
      parameter name: :refundRequested, in: :query, type: :boolean, required: false

      parameter name: :planId, in: :query, schema: { type: :array, items: { type: :string } }, required: false
      parameter name: :resourceId, in: :query, schema: { type: :array, items: { type: :string } }, required: false
      parameter name: :resourceClass, in: :query, schema: { type: :array, items: { type: :string } }, required: false

      response '200', 'invoices found' do
        let(:member) { create(:member) }
        let(:invoices) { create_list(:invoice, member: member) }
        before { sign_in member }

        schema type: :array,
            items: { '$ref' => '#/components/schemas/Invoice' }

        run_test!

        context 'with a confirmed cash/check receipt held until the first fob', requires_transactions: true do
          let(:settled) { true }
          let(:pastDue) { false }
          let!(:receipt) do
            create(:invoice, member: member, resource_id: member.id.to_s, resource_class: 'member',
              plan_id: nil, due_date: 1.day.ago).tap(&:submit_for_settlement)
          end

          run_test! do |response|
            row = JSON.parse(response.body).find { |invoice| invoice['id'] == receipt.id.to_s }
            expect(row).to include('settled' => true, 'pastDue' => false)
            expect(receipt.reload.settled_at).to be_nil
          end
        end
      end

      response '401', 'User not authenticated' do
        schema '$ref' => '#/components/schemas/error'
        run_test!
      end
    end

    post 'Create an invoice' do
      tags 'Invoices'
      operationId 'createInvoice'
      consumes 'application/json'
      parameter name: :createInvoiceDetails, in: :body, schema: {
        title: :createInvoiceDetails,
        type: :object,
        properties: {
          id: { type: :string },
          discountId: { type: :string }
        },
        required: [:id]
      }, required: true

      response '200', 'invoice created' do
        before { sign_in create(:member) }

        schema '$ref' => '#/components/schemas/Invoice'

        let(:createInvoiceDetails) {{ id: create(:invoice_option).id }}

        run_test!
      end

      response '401', 'User not authenticated' do
        schema '$ref' => '#/components/schemas/error'
        let(:createInvoiceDetails) {{ id: create(:invoice_option).id }}
        run_test!
      end

      response '422', 'parameter missing' do
        before { sign_in create(:member) }
        schema '$ref' => '#/components/schemas/error'
        let(:createInvoiceDetails)  {{ discountId: 'some_discount' }}
        run_test!
      end

      response '404', 'invoice option not found' do
        before { sign_in create(:member) }
        schema '$ref' => '#/components/schemas/error'
        let(:createInvoiceDetails) {{ id: 'invalid' }}
        run_test!
      end
    end
  end
end
