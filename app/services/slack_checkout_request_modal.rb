class SlackCheckoutRequestModal
  MAX_OPTIONS = 100

  class << self
    def build(shop, member)
      tools = ToolCheckoutRequestEligibility.eligible_tools(member: member, shop: shop)
      open_requests = ToolCheckoutRequest.where(member_id: member.id, status: "open").to_a
        .select { |request| request.tool&.shop_id.to_s == shop.id.to_s }
        .sort_by { |request| request.tool.name.to_s.downcase }
      if tools.length > MAX_OPTIONS
        raise ::Error::UnprocessableEntity.new(
          "More than 100 tools are eligible in this shop; use the Member Portal to request a checkout"
        )
      end
      if tools.empty? && open_requests.empty?
        raise ::Error::UnprocessableEntity.new("No tools are currently eligible for checkout")
      end

      view = {
        type: "modal",
        callback_id: "checkout_request_submit",
        private_metadata: { shop_id: shop.id.to_s }.to_json,
        title: plain("Request a checkout"),
        close: plain("Cancel"),
        blocks: []
      }
      if open_requests.present?
        names = open_requests.map { |request| "• #{request.tool.name.to_s.first(75)} _(request open)_" }
        names.each_slice(25).with_index do |slice, index|
          heading = index.zero? ? "*Already requested:*\n" : ""
          view[:blocks] << { type: "section", text: { type: "mrkdwn", text: heading + slice.join("\n") } }
        end
      end
      if tools.present?
        view[:submit] = plain("Request")
        view[:blocks] << {
          type: "input",
          block_id: "tool",
          label: plain("Tool"),
          element: {
            type: "static_select",
            action_id: "tool",
            placeholder: plain("Select a tool"),
            options: tools.map { |tool| option(tool) }
          }
        }
        view[:blocks] << {
          type: "input",
          block_id: "note",
          optional: true,
          label: plain("Note"),
          element: { type: "plain_text_input", action_id: "note", max_length: 128 }
        }
      end
      view
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
