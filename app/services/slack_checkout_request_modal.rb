class SlackCheckoutRequestModal
  MAX_OPTIONS = 100

  class << self
    def build(shop, member)
      tools = eligible_tools(shop, member)
      raise ::Error::UnprocessableEntity.new("This shop has no tools you can request") if tools.empty?
      raise ::Error::UnprocessableEntity.new("This shop has more than 100 eligible tools; use the Member Portal") if tools.length > MAX_OPTIONS

      {
        type: "modal",
        callback_id: "checkout_request_submit",
        private_metadata: { shop_id: shop.id.to_s }.to_json,
        title: plain("Request a checkout"),
        submit: plain("Request"),
        close: plain("Cancel"),
        blocks: [
          {
            type: "input", block_id: "tool", label: plain("Tool"),
            element: {
              type: "static_select", action_id: "tool", placeholder: plain("Select a tool"),
              options: tools.map { |tool| { text: plain(tool.name.first(75)), value: tool.id.to_s } }
            }
          },
          {
            type: "input", block_id: "note", optional: true, label: plain("Note"),
            element: { type: "plain_text_input", action_id: "note", max_length: 128 }
          }
        ]
      }
    end

    def eligible_tools(shop, member)
      Tool.where(shop_id: shop.id, :disabled.ne => true, :open.ne => true).order_by(name: :asc).to_a.select do |tool|
        eligible?(member, tool) &&
          !ToolCheckout.where(member_id: member.id, tool_id: tool.id, revoked_at: nil).exists?
      end
    end

    def eligible?(member, tool)
      return false if tool.nil? || tool.open || tool.disabled? || tool.shop.nil? || tool.shop.disabled?
      member.status == "pending" ? tool.allow_pending : member.active_unexpired? && member.status == "activeMember"
    end

    private

    def plain(text)
      { type: "plain_text", text: text, emoji: true }
    end

    def option(tool)
      { text: plain(tool.name.to_s.first(75)), value: tool.id.to_s }
    end
  end
end
