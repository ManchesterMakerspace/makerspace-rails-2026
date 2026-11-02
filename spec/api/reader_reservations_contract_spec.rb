require 'swagger_helper'

RSpec.describe 'Private reader reservation protocol', type: :request do
  around do |example|
    previous=ENV['READER_RESERVATION_SERVICE_SECRET']
    ENV['READER_RESERVATION_SERVICE_SECRET']='reader-contract-secret-at-least-32-characters'
    example.run
  ensure
    ENV['READER_RESERVATION_SERVICE_SECRET']=previous
  end
  path '/internal/reader_reservations/sync' do
    post 'Synchronize reader attendance (private ts-data-api ingress only)' do
      tags 'Reader reservations (internal)'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :Authorization, in: :header, required: true, schema: {type: :string}, description: 'Dedicated server-to-server Bearer secret; not browser authentication'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object, required: %w[deviceId operations], properties: {
          deviceId: {type: :string, pattern: '^[a-f0-9]{24}$'},
          operations: {type: :array, maxItems: 16, items: {
            type: :object, required: %w[kind reservationId revision], properties: {
              kind: {type: :string, enum: %w[monitor claim release checkpoint]},
              reservationId: {type: :string}, revision: {type: :integer, minimum: 0},
              checkinId: {type: :string}, checkendId: {type: :string},
              observedAt: {type: :integer}, coveredFrom: {type: :integer}, through: {type: :integer}, uncertain: {type: :boolean}
            }
          }}
        }
      }
      let(:body) { {deviceId:'0123456789abcdef01234567',operations:[]} }
      let(:Authorization) { "Bearer #{ENV['READER_RESERVATION_SERVICE_SECRET']}" }
      response '200', 'Operations synchronized; stale and blocked outcomes are explicit' do
        schema type: :object, required: %w[results serverTime], properties: {
          serverTime: {type: :integer}, results: {type: :array, items: {type: :object, properties: {
            reservationId: {type: :string}, outcome: {type: :string, enum: %w[accepted stale gone blocked]},
            revision: {type: :integer}, status: {type: :string},
            monitored: {type: :boolean}, arrivedAt: {type: :integer, nullable: true}
          }}}
        }
        before { allow(ReaderReservationService).to receive(:sync!).and_return(results:[],serverTime:1_800_000_000_000) }
        run_test!
      end
      response '401', 'Missing or invalid service credential' do
        let(:Authorization) { 'Bearer invalid' }
        run_test!
      end
      response '409', 'Session upload pending or conflicting replay/state' do
        before { allow(ReaderReservationService).to receive(:sync!).and_raise(ReaderReservationService::Conflict, 'Session pending') }
        run_test!
      end
      response '422', 'Invalid operation or scope' do
        before { allow(ReaderReservationService).to receive(:sync!).and_raise(ArgumentError, 'Invalid operation') }
        run_test!
      end
    end
  end
end
