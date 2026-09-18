# Shared content policy for modal details and /checkout active. The caller must
# supply an authorized, active checkout; listing queries preload tool and shop.
class CheckoutDisplay
  def self.details(checkout)
    tool = checkout.tool
    [
      ["Tool", tool.name], ["Shop", tool.shop.name], ["Description", tool.description],
      ["Notes", tool.notes], ["Users channel", Service::SlackChannelCache.normalize_name(tool.users_channel)],
      ["Wiki", PublicCatalog.safe_url(tool.effective_wiki_url)],
      ["Checked out", checkout.checked_out_at&.to_date&.iso8601],
      ["Reservable", tool.reservable? ? "Yes" : "No"]
    ].filter_map do |label, value|
      next if value.blank?
      value = "Use the Member Portal (link is too long)." if label == "Wiki" && value.length > 2800
      "#{label}: #{value.to_s.first(2800)}"
    end
  end

  def self.escape(text)
    text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
      .tr('`*_~', "'\u2217\uFF3F\uFF5E")
  end

  def self.text(checkouts)
    return "You have no active tool checkouts in this shop." if checkouts.empty?
    # Leave headroom below Slack's message limit, without breaking an escape entity.
    sections = checkouts.map { |row| escape(details(row).join("\n")) }
    text = +""
    sections.each do |section|
      if text.length + section.length > 35000
        text << "\nUse the Member Portal to view the remaining checkouts."
        break
      end
      text << "\n\n" unless text.empty?
      text << section
    end
    text
  end
end
