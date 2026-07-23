module Service
  module GoogleWorkspace
    DIRECTORY_SCOPE = "https://www.googleapis.com/auth/admin.directory.resource.calendar".freeze
    CALENDAR_SCOPE = "https://www.googleapis.com/auth/calendar".freeze

    class << self
      def authorization(scopes)
        Google::Auth::UserRefreshCredentials.new(
          client_id: ENV["GOOGLE_ID"],
          client_secret: ENV["GOOGLE_SECRET"],
          refresh_token: ENV["GOOGLE_TOKEN"],
          scope: Array(scopes)
        )
      end

      def directory
        service = Google::Apis::AdminDirectoryV1::DirectoryService.new
        service.authorization = authorization(DIRECTORY_SCOPE)
        service
      end

      def calendar
        service = Google::Apis::CalendarV3::CalendarService.new
        service.authorization = authorization(CALENDAR_SCOPE)
        service
      end

      def customer_id
        ENV["GOOGLE_CUSTOMER_ID"].presence || "my_customer"
      end

      def reservations_calendar_id
        ENV["GOOGLE_RESERVATIONS_CALENDAR_ID"].presence
      end

      def ensure_resource!(record, category)
        if record.google_resource_id.present?
          begin
            resource = directory.get_calendar_resource(customer_id, record.google_resource_id)
            if resource.resource_name != record.name
              resource.resource_name = record.name
              resource = directory.update_calendar_resource(customer_id, resource.resource_id, resource)
            end
            record.set(resource_email: resource.resource_email)
            return resource
          rescue Google::Apis::ClientError => error
            raise unless error.status_code == 404
          end
        end

        matches = calendar_resources.select do |resource|
          resource.resource_name.to_s.casecmp?(record.name.to_s) &&
            resource.resource_category.to_s.casecmp?(category.to_s)
        end

        raise "Multiple Google resources match #{record.name}" if matches.length > 1
        resource = matches.first || directory.calendar_resource(
          customer_id,
          Google::Apis::AdminDirectoryV1::CalendarResource.new(
            resource_id: record.id.to_s,
            resource_name: record.name,
            resource_category: category
          )
        )

        record.set(
          google_resource_id: resource.resource_id,
          resource_email: resource.resource_email
        )
        resource
      end

      def delete_resource!(resource_id)
        return if resource_id.blank?
        directory.delete_calendar_resource(customer_id, resource_id)
      end

      private

      def calendar_resources
        resources = []
        page_token = nil
        loop do
          response = directory.list_calendar_resources(
            customer_id,
            max_results: 100,
            page_token: page_token
          )
          resources.concat(Array(response.items))
          page_token = response.next_page_token
          break if page_token.blank?
        end
        resources
      end
    end
  end
end
