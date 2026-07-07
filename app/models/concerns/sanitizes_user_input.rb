module SanitizesUserInput
  extend ActiveSupport::Concern

  SANITIZER = Class.new do
    include ActionView::Helpers::SanitizeHelper
  end.new

  included do
    before_validation :sanitize_string_attributes
  end

  class_methods do
    def scrub_user_input(value)
      return value unless value.is_a?(String)

      SANITIZER.sanitize(value.unicode_normalize)
    end
  end

  private

  def sanitize_string_attributes
    self.class.fields.each do |field_name, field|
      next unless field.type == String

      value = read_attribute(field_name)
      write_attribute(field_name, self.class.scrub_user_input(value)) if value.is_a?(String)
    end
  end
end
