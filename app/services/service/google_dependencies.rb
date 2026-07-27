module Service
  module GoogleDependencies
    class << self
      def load!
        mutex.synchronize do
          return if @loaded

          require "googleauth"
          require "google/apis/drive_v3"
          require "google/apis/sheets_v4"
          require "google/apis/admin_directory_v1"
          require "google/apis/calendar_v3"
          @loaded = true
        end
      end

      def load_pdf!
        mutex.synchronize do
          return if @pdf_loaded

          require "wicked_pdf"
          require "wkhtmltopdf-binary"
          @pdf_loaded = true
        end
      end

      private

      def mutex
        @mutex ||= Mutex.new
      end
    end
  end
end
