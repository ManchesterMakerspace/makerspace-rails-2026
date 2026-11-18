require 'swagger_helper'

describe 'Admin::Invoices API', type: :request do
  let(:admin) { create(:member, :admin) }
  let(:basic) { create(:member) }
  let(:invoice_option) { create(:invoice_option) }
  let(:invoices) { create_list(:invoice, 3) }
  path '/admin/invoices' do
    get 'Gets a list of invoices' do
      tags 'Invoices'
      operationId "adminListInvoices"
      consumes 'application/json'
      parameter name: :pageNum, in: :query, type: :number, required: false
      parameter name: :orderBy, in: :query, type: :string, required: false
      parameter name: :order, in: :query, type: :string, required: false
      parameter name: :search, in: :query, type: :string, required: false

      parameter name: :settled, in: :query, type: :boolean, required: false,
        description: 'Includes confirmed cash/check receipts held until first-fob issuance as paid.'
      parameter name: :pastDue, in: :query, type: :boolean, required: false,
        description: 'Confirmed cash/check receipts held until first-fob issuance are not past due.'
      parameter name: :refunded, in: :query, type: :boolean, required: false
      parameter name: :refundRequested, in: :query, type: :boolean, required: false

      parameter name: :planId, in: :query, schema: { type: :array, items: { type: :string } }, required: false
      parameter name: :resourceId, in: :query, schema: { type: :array, items: { type: :string } }, required: false
      parameter name: :memberId, in: :query, schema: { type: :array, items: { type: :string } }, required: false
      parameter name: :resourceClass, in: :query, schema: { type: :array, items: { type: :string } }, required: false

      response '200', 'invoices found' do
        before { sign_in admin }
        schema type: :array,
            items: { '$ref' => '#/components/schemas/Invoice' }

        run_test!

        context 'with a confirmed cash/check receipt held until the first fob', requires_transactions: true do
          let(:settled) { true }
          let(:pastDue) { false }
          let!(:receipt) do
            create(:invoice, member: basic, resource_id: basic.id.to_s, resource_class: 'member',
              plan_id: nil, due_date: 1.day.ago).tap(&:submit_for_settlement)
          end

          run_test! do |response|
            row = JSON.parse(response.body).find { |invoice| invoice['id'] == receipt.id.to_s }
            expect(row).to include('settled' => true, 'pastDue' => false)
            expect(receipt.reload.settled_at).to be_nil
          end
        end
      end

      response '403', 'User unauthorized' do
        before { sign_in basic }
        schema '$ref' => '#/components/schemas/error'
        run_test!
      end

      response '401', 'User unauthenticated' do
        schema '$ref' => '#/components/schemas/error'
        run_test!
      end
    end

    post 'Creates an invoice' do
      tags 'Invoices'
      operationId "adminCreateInvoices"
      consumes 'application/json'
      parameter name: :createInvoiceDetails, in: :body, schema: {
        title: :createInvoiceDetails, 
        type: :object,
        properties: {
          id: { type: :string },
          memberId: { type: :string },
          resourceId: { type: :string },
          discountId: { type: :string },
        },
        required: [:id, :memberId, :resourceId]
      }, required: true
      
      response '200', 'invoice created' do
        before { sign_in admin }

        schema '$ref' => '#/components/schemas/Invoice'

        let(:createInvoiceDetails) {{
          id: invoice_option.id,
          memberId: basic.id,
          resourceId: basic.id,
        }}

        run_test!
      end

      response '403', 'User unauthorized' do
        before { sign_in basic }
        schema '$ref' => '#/components/schemas/error'
        let(:createInvoiceDetails) {{
          id: invoice_option.id,
          memberId: basic.id,
          resourceId: basic.id,
        }}
        run_test!
      end

      response '401', 'User unauthenticated' do
        schema '$ref' => '#/components/schemas/error'
        let(:createInvoiceDetails) {{
          id: invoice_option.id,
          memberId: basic.id,
          resourceId: basic.id,
        }}
        run_test!
      end

      response '422', 'missing parameter' do
        before { sign_in admin }
        schema '$ref' => '#/components/schemas/error'
        let(:createInvoiceDetails) {{
          memberId: basic.id,
          resourceId: basic.id,
        }}
        run_test!
      end

      response '404', 'member not found' do
        before { sign_in admin }
        schema '$ref' => '#/components/schemas/error'
        let(:createInvoiceDetails) {{
          id: invoice_option.id,
          memberId: "invalid",
          resourceId: basic.id,
        }}
        run_test!
      end

      response '404', 'invoice option not found' do
        before { sign_in admin }
        schema '$ref' => '#/components/schemas/error'
        let(:createInvoiceDetails) {{
          id: "invalid",
          memberId: basic.id,
          resourceId: basic.id,
        }}
        run_test!
      end
    end
  end

  path "/admin/invoices/{id}" do
    put 'Updates an invoice' do
      tags 'Invoices'
      operationId "adminUpdateInvoice"
      consumes 'application/json'
      parameter name: :id, in: :path, type: :string

      parameter name: :updateInvoiceDetails, in: :body, schema: {
        title: :updateInvoiceDetails,
        type: :object,
        properties: {
          settled: { type: :boolean }
        }
      }, required: true

      response '200', 'invoice updated', requires_transactions: true do
        before { sign_in admin }

        schema '$ref' => '#/components/schemas/Invoice'

        let(:updateInvoiceDetails) {{
          settled: true
        }}
        let(:id) { create(:invoice).id }
        run_test!
      end

      response '403', 'User unauthorized' do
        before { sign_in basic }
        schema '$ref' => '#/components/schemas/error'
        let(:updateInvoiceDetails) {{
          settled: true
        }}
        let(:id) { create(:invoice).id }
        run_test!
      end

      response '401', 'User unauthenticated' do
        schema '$ref' => '#/components/schemas/error'
        let(:updateInvoiceDetails) {{
          settled: true
        }}
        let(:id) { create(:invoice).id }
        run_test!
      end

      response '404', 'Invoice not found' do
        before { sign_in admin }
        schema '$ref' => '#/components/schemas/error'
        let(:updateInvoiceDetails) {{
          settled: true
        }}
        let(:id) { 'invalid' }
        run_test!
      end
    end

    delete 'Deletes an invoice' do
      tags 'Invoices'
      operationId "adminDeleteInvoice"
      parameter name: :id, in: :path, type: :string

      response '204', 'invoice deleted' do
        before { sign_in admin }
        let(:id) { create(:invoice).id }
        run_test!
      end

      response '403', 'User unauthorized' do
        before { sign_in basic }
        schema '$ref' => '#/components/schemas/error'
        let(:id) { create(:invoice).id }
        run_test!
      end

      response '401', 'User unauthenticated' do
        schema '$ref' => '#/components/schemas/error'
        let(:id) { create(:invoice).id }
        run_test!
      end

      response '404', 'Invoice not found' do
        before { sign_in admin }
        schema '$ref' => '#/components/schemas/error'
        let(:id) { 'invalid' }
        run_test!
      end
    end
  end
end
