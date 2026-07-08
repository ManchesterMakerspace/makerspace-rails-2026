require 'cgi'

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

      sanitize_plain_text(normalize_for_sanitization(value))
    end

    def sanitize_plain_text(value)
      decoded_value = CGI.unescapeHTML(value)
      CGI.unescapeHTML(SANITIZER.sanitize(decoded_value, tags: [], attributes: []))
    end

    def normalize_for_sanitization(value)
      normalized_value = value.dup
      normalized_value.force_encoding(Encoding::UTF_8) if normalized_value.encoding == Encoding::ASCII_8BIT
      normalized_value = normalized_value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '')
      normalized_value.unicode_normalize
    rescue Encoding::CompatibilityError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
      value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '').unicode_normalize
    end
  end

  private

  def sanitize_string_attributes
    self.class.fields.each_key do |field_name|
      value = read_attribute(field_name)
      write_attribute(field_name, self.class.scrub_user_input(value)) if value.is_a?(String)
    end
  end
end
