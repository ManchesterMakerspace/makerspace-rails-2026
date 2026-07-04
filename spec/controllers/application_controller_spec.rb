require 'rails_helper'

RSpec.describe ApplicationController, type: :controller do
  describe '#log_not_found_file_lookup_context' do
    it 'logs the original requested path and translated file lookup locations' do
      request_double = instance_double(
        ActionDispatch::Request,
        original_fullpath: '/missing/file.png?cache=false',
        path: '/missing/file.png'
      )
      allow(controller).to receive(:request).and_return(request_double)
      allow(Rails.logger).to receive(:info)

      controller.send(:log_not_found_file_lookup_context)

      expect(Rails.logger).to have_received(:info) do |message|
        expect(message).to include('[404 file lookup]')
        expect(message).to include('requested_path=/missing/file.png?cache=false')
        expect(message).to include(Rails.root.join('public', 'missing/file.png').to_s)
      end
    end
  end

  describe '#translated_file_lookup_locations' do
    it 'normalizes traversal paths before translating them to local locations' do
      request_double = instance_double(
        ActionDispatch::Request,
        path: '/../secret.txt'
      )
      allow(controller).to receive(:request).and_return(request_double)

      expect(controller.send(:translated_file_lookup_locations)).to include(Rails.root.join('public').to_s)
      expect(controller.send(:translated_file_lookup_locations)).not_to include(a_string_matching('secret.txt'))
    end
  end
end
