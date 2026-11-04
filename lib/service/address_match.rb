module Service
  # Decides whether two street addresses are the same household address. Forgiving about case, punctuation,
  # "St"/"Street" style words, directions and a unit written into the street line; strict about the street number,
  # the rest of the street name and the postal code (first five digits). The separate unit field is not compared.
  module AddressMatch
    WORDS = {
      'street' => 'st', 'st' => 'st', 'avenue' => 'ave', 'ave' => 'ave', 'av' => 'ave', 'road' => 'rd', 'rd' => 'rd',
      'drive' => 'dr', 'dr' => 'dr', 'lane' => 'ln', 'ln' => 'ln', 'court' => 'ct', 'ct' => 'ct',
      'boulevard' => 'blvd', 'blvd' => 'blvd', 'place' => 'pl', 'pl' => 'pl', 'circle' => 'cir', 'cir' => 'cir',
      'highway' => 'hwy', 'hwy' => 'hwy', 'terrace' => 'ter', 'ter' => 'ter', 'parkway' => 'pkwy', 'pkwy' => 'pkwy',
      'square' => 'sq', 'sq' => 'sq', 'route' => 'rt', 'rte' => 'rt', 'rt' => 'rt',
      'north' => 'n', 'south' => 's', 'east' => 'e', 'west' => 'w'
    }.freeze
    # A unit written into the street line ("12 Main St Apt 3"): the word and the token after it are dropped.
    UNIT_WORDS = %w[apt apartment unit ste suite fl floor rm room bldg building lot].freeze

    def self.street_key(street)
      tokens = I18n.transliterate(street.to_s).downcase.gsub(/[^a-z0-9 #]/, ' ').gsub('#', ' # ').split
      kept = []
      skip_next = false
      tokens.each do |token|
        if skip_next
          skip_next = false
          next
        end
        if UNIT_WORDS.include?(token) || token == '#'
          skip_next = true
          next
        end
        kept << (WORDS[token] || token)
      end
      kept.join(' ')
    end

    def self.postal_key(postal)
      postal.to_s.gsub(/\D/, '')[0, 5]
    end

    def self.same?(street_a, postal_a, street_b, postal_b)
      key_a = street_key(street_a)
      key_b = street_key(street_b)
      return false if key_a.blank? || key_b.blank?

      key_a == key_b && postal_key(postal_a).present? && postal_key(postal_a) == postal_key(postal_b)
    end

    def self.members_match?(one, other)
      same?(one.address_street, one.address_postal_code, other.address_street, other.address_postal_code)
    end

    # "12 Main St, 03101" for messages and the audit log.
    def self.describe(member)
      [member.address_street.to_s.strip.presence, member.address_postal_code.to_s.strip.presence].compact.join(', ').presence || 'no address on file'
    end
  end
end
