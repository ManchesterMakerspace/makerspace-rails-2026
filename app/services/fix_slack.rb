class FixSlack
  class << self
    def member!(payload)
      team = payload['team_id'] || payload.dig('team', 'id')
      expected = ENV['SLACK_TEAM_ID'].presence || Service::SlackConnector.slack_team_id
      raise Error::Forbidden.new unless expected.present? && team == expected
      id = payload['user_id'] || payload.dig('user', 'id')
      member = SlackUser.where(slack_id: id).first&.member
      raise Error::Forbidden.new unless member && !%w[revoked inactive suspended].include?(member.status)
      member
    end
    def plain(text) = { type: 'plain_text', text: text.to_s.first(150) }
    def option(label, value) = { text: plain(label.to_s.first(75)), value: value.to_s }
    def text_block(text) = { type: 'section', text: { type: 'plain_text', text: text.to_s.first(2900) } }
    def input(id, label, value: nil, optional: false, options: nil, multi: false)
      element = if options
        { type: multi ? 'multi_static_select' : 'static_select', action_id: id, options: options }
      else
        { type: 'plain_text_input', action_id: id, multiline: multi }
      end
      if value.present?
        if options
          selected = options.select { |o| Array(value).map(&:to_s).include?(o[:value]) }
          element[multi ? :initial_options : :initial_option] = multi ? selected : selected.first if selected.any?
        else
          element[:initial_value] = value.to_s
        end
      end
      { type: 'input', block_id: id, label: plain(label), optional: optional, element: element }
    end
    def external(id, label, selected: [], multi: false)
      element = { type: multi ? 'multi_external_select' : 'external_select', action_id: "fix_search_#{id}", min_query_length: 0 }
      element[multi ? :initial_options : :initial_option] = multi ? selected : selected.first if selected.any?
      { type: 'input', block_id: id, label: plain(label), optional: true, element: element }
    end
    def options(member, payload)
      field = payload['action_id'].to_s.delete_prefix('fix_search_')
      term = Regexp.escape(payload['value'].to_s.first(100))
      rows = case field
      when 'tool_id'
        FixTicketService.catalog_tools(member).where(name: /#{term}/i).order_by(name: :asc).limit(100).map { |t| option("#{t.shop&.name}: #{t.name}", t.id) }
      when 'shop_id'
        [option('No shop', 'none')] + FixTicketService.catalog_shops(member).where(name: /#{term}/i).order_by(name: :asc).limit(99).map { |s| option(s.name, s.id) }
      when 'member_ids', 'assignee_id'
        data = JSON.parse(payload.dig('view', 'private_metadata') || '{}')
        if field == 'member_ids'
          ticket = FixTicket.find(data['id'])
          raise Error::Forbidden.new unless FixTicketPolicy.new(member, ticket).staff?
        end
        members = if field == 'assignee_id'
          Member.where(:id.in => FixTicketPolicy.new(member).scope.distinct(:assignee_ids))
        else
          Member.where(status: 'activeMember', :expirationTime.gt => Time.current.to_i * 1000)
        end
        members.any_of({ firstname: /#{term}/i }, { lastname: /#{term}/i }).limit(100).map { |m| option(m.fullname, m.id) }
      else []
      end
      { options: rows }
    end
    def yes_no(id, label, value = false)
      input(id, label, value: value.to_s, options: [option('No', 'false'), option('Yes', 'true')])
    end
    def modal(callback, blocks, metadata = {}, submit: 'Save')
      view = { type: 'modal', callback_id: callback, title: plain('Fix tickets'), close: plain('Close'),
        private_metadata: metadata.to_json, blocks: blocks }
      view[:submit] = plain(submit) if submit
      view
    end
    def command_view(member, text)
      command = text.split.first
      return new_view(member) if command == 'new'
      return detail(member, command) if BSON::ObjectId.legal?(command.to_s)
      list(member, { 'mode' => %w[mine assigned queue public].include?(command) ? command : 'mine' })
    end
    def new_view(member)
      FixTicketService.capacity!(member)
      blocks = [text_block('Your identity is hidden except after an admin privacy acknowledgment. Text may identify you. When configured, full notes are shared in the central tickets channel.'),
        input('title', 'Title'), input('description', 'Description', multi: true),
        input('category', 'Category', options: FixTicket::CATEGORIES.map { |v| option(v.capitalize, v) }),
        external('shop_id', 'Shop (optional)'),
        external('tool_id', 'Tool (optional; selects its shop)'),
        input('uncatalogued_tool', 'Uncatalogued tool name', optional: true),
        input('priority', 'Priority (1 highest; shifts your existing priorities)', optional: true, options: (1..10).map { |n| option(n, n) }),
        yes_no('i_broke_it', 'I broke it'), yes_no('i_can_fix_it', 'I can fix it!'),
        yes_no('public_read_only', 'Public read-only: current members can read all notes')]
      modal('fix_new', blocks, { submission_key: SecureRandom.uuid }, submit: 'Submit report')
    end
    def list(member, query)
      query = query.stringify_keys.merge('page_size' => 10)
      result = FixTicketQuery.call(member, query)
      blocks = [text_block("#{query['mode']}: #{result[:total]} tickets · page #{result[:page] + 1}"),
        { type: 'actions', elements: [button('New report', 'new'), button('Filters / sort', 'filters', query)] }]
      result[:tickets].each do |t|
        blocks << text_block("#{t[:title]} · #{t[:status]} · Priority #{t[:priority] || '—'}\nCreated #{t[:createdAt]} · Updated #{t[:updatedAt]}")
        blocks << { type: 'actions', elements: [button('View ticket', 'view', { id: t[:id], query: query })] }
      end
      pages = []
      pages << button('Previous', 'page', query.merge('page' => result[:page] - 1)) if result[:page] > 0
      pages << button('Next', 'page', query.merge('page' => result[:page] + 1)) if (result[:page] + 1) * 10 < result[:total]
      blocks << { type: 'actions', elements: pages } if pages.any?
      modal('fix_list', blocks, query, submit: nil)
    end
    def button(label, action, data = {})
      { type: 'button', text: plain(label), action_id: "fix_#{action}", value: data.to_json }
    end
    def filters(query)
      tool = Tool.where(id: query['tool_id']).first if query['tool_id'].present?
      assignee = Member.where(id: query['assignee_id']).first if query['assignee_id'].present?
      modal('fix_filters', [
        input('mode', 'List', value: query['mode'], options: %w[mine assigned queue public].map { |v| option(v, v) }),
        external('shop_id', 'Shop (clear for all)', selected: query['shop_id'].present? ? [option(query['shop_id'] == 'none' ? 'No shop' : Shop.where(id: query['shop_id']).first&.name || 'Shop', query['shop_id'])] : []),
        input('priority', 'Priority', value: query['priority'], options: [option('All priorities', 'all'), option('Unprioritized', 'none')] + (1..10).map { |n| option(n, n) }),
        input('statuses', 'Statuses', value: query['statuses'] || FixTicket::ACTIVE, multi: true, options: FixTicket::STATUSES.map { |v| option(v.tr('_', ' '), v) }),
        input('category', 'Category', optional: true, value: query['category'], options: [option('All categories', 'all')] + FixTicket::CATEGORIES.map { |v| option(v, v) }),
        input('confirmation', 'Confirmation', optional: true, value: query['confirmation'], options: [option('All confirmations', 'all')] + FixTicket::CONFIRMATIONS.map { |v| option(v.tr('_', ' '), v) }),
        external('tool_id', 'Tool', selected: query['tool_id'].present? ? [option(tool ? "#{tool.shop&.name}: #{tool.name}" : 'Former tool', query['tool_id'])] : []),
        external('assignee_id', 'Assignee', selected: query['assignee_id'].present? ? [option(assignee&.fullname || 'Former member', query['assignee_id'])] : []),
        input('sort', 'Sort by', value: query['sort'] || 'priority', options: %w[priority created_at updated_at].map { |v| option(v.tr('_', ' '), v) }),
        input('direction', 'Direction', value: query['direction'] || 'asc', options: [option('Ascending', 'asc'), option('Descending', 'desc')])
      ], query, submit: 'Apply')
    end
    def detail(member, id, query = {})
      ticket = FixTicket.where(id: FixTicketService.parse_id(id)).first
      raise Error::NotFound.new unless ticket
      t = FixTicketPresenter.ticket(ticket, member, detail: true)
      blocks = [text_block("#{t[:title]}\n#{t[:description]}\n#{t[:status]} · #{t[:confirmation]} · Priority #{t[:priority] || '—'}\n#{t[:outOfService] ? 'Tool out of service' : ''}\nCreated #{t[:createdAt]} · Updated #{t[:updatedAt]}"),
        text_block("Assignees: #{t[:assignees].map { |a| a[:name] }.join(', ')}\n#{ShortUrl.base_url}/fix-tickets/#{id}")]
      blocks << text_block("Bounty: #{ShortUrl.base_url}#{t[:bountyUrl]}") if t[:bountyUrl]
      # The complete ticket history is available in the linked portal.
      t[:events].last(10).each { |e| blocks << text_block("#{e[:actor]} · #{e[:createdAt]}\n#{e[:note] || e[:kind]}") }
      actions = [button('Back to list', 'page', query.presence || { 'mode' => 'mine' })]
      actions << button('Add note', 'note', { id: id, query: query }) if t[:capabilities][:canAddNote]
      actions << button('Change status', 'status', { id: id, query: query, revision: ticket.revision }) if t[:capabilities][:canChangeStatus]
      actions << button('Assignments', 'assign', { id: id, query: query }) if t[:capabilities][:canManage]
      actions << button('Edit / announcement', 'edit', { id: id, query: query }) if t[:capabilities][:canManage]
      actions << button(t[:outOfService] ? 'Restore tool service' : 'Mark tool out of service', 'outage', { id: id, query: query, out_of_service: !t[:outOfService] }) if t[:toolId] && t[:capabilities][:canManage]
      actions << button('Visibility', 'visibility', { id: id, query: query }) if t[:capabilities][:canManageVisibility]
      actions.each_slice(5) { |group| blocks << { type: 'actions', elements: group } }
      actions = []
      actions << button('Unassign myself', 'unassign', { id: id, query: query }) if t[:capabilities][:canUnassign]
      actions << button('Withdraw', 'withdraw', { id: id, query: query }) if t[:capabilities][:canWithdraw]
      blocks << { type: 'actions', elements: actions } if actions.any?
      modal('fix_detail', blocks, { id: id, query: query }, submit: nil)
    end
    def values(payload)
      (payload.dig('view', 'state', 'values') || {}).transform_values do |block|
        value = block.values.first
        value['value'] || value.dig('selected_option', 'value') || value['selected_options']&.map { |o| o['value'] }
      end
    end
    def interaction(payload)
      member = member!(payload)
      return options(member, payload) if payload['type'] == 'block_suggestion'
      if payload['type'] == 'block_actions'
        action = payload.fetch('actions').first
        data = JSON.parse(action['value'])
        type = action['action_id'].delete_prefix('fix_')
        view = case type
        when 'new' then new_view(member)
        when 'view' then detail(member, data['id'], data['query'] || {})
        when 'page' then list(member, data)
        when 'filters' then filters(data)
        when 'unassign'
          FixTicketService.assign!(id: data['id'], actor: member, unassign_self: true)
          list(member, { 'mode' => 'assigned' })
        when 'withdraw'
          FixTicketService.withdraw!(id: data['id'], actor: member)
          detail(member, data['id'], data['query'] || {})
        when 'outage'
          ticket = FixTicket.find(data['id'])
          raise Error::Forbidden.new unless FixTicketPolicy.new(member, ticket).staff? && ticket.tool
          ToolAvailabilityService.set!(tool: ticket.tool, actor: member, value: data['out_of_service'])
          detail(member, data['id'], data['query'] || {})
        when 'edit'
          ticket = FixTicket.find(data['id'])
          raise Error::Forbidden.new unless FixTicketPolicy.new(member, ticket).staff?
          modal('fix_edit', [input('title', 'Title', value: ticket.title), input('description', 'Description', value: ticket.description, multi: true),
            input('category', 'Category', value: ticket.category, options: FixTicket::CATEGORIES.map { |v| option(v, v) }),
            external('shop_id', 'Shop', selected: ticket.shop ? [option(ticket.shop.name, ticket.shop_id)] : []),
            external('tool_id', 'Tool', selected: ticket.tool ? [option(ticket.tool.name, ticket.tool_id)] : []),
            input('uncatalogued_tool', 'Uncatalogued tool name', value: ticket.uncatalogued_tool, optional: true),
            input('announcement_note', 'Shop/tool announcement note', value: ticket.announcement_note, optional: true, multi: true),
            yes_no('announce_to_slack', 'Publish designated shop/tool summaries', ticket.announce_to_slack)], data.merge('revision' => ticket.revision))
        when 'note' then modal('fix_note', [input('note', 'Note (shared to central Slack when configured)', multi: true)], data)
        when 'status' then modal('fix_status', [input('status', 'Status', options: (FixTicket::STATUSES - ['withdrawn']).map { |v| option(v.tr('_', ' '), v) }), input('confirmation', 'Confirmation', optional: true, options: FixTicket::CONFIRMATIONS.map { |v| option(v.tr('_', ' '), v) }), input('note', 'Note (required to close/reopen or cannot confirm)', optional: true, multi: true)], data)
        when 'visibility' then modal('fix_visibility', [yes_no('public_read_only', 'Publish full ticket and history to current members')], data)
        when 'assign'
          ticket = FixTicket.find(data['id'])
          raise Error::Forbidden.new unless FixTicketPolicy.new(member, ticket).staff?
          choices = ticket.assignee_ids.map { |id| option(Member.find(id).fullname, id) }
          modal('fix_assign', [external('member_ids', 'Assignees', selected: choices, multi: true)], data)
        end
        client = Service::SlackConnector.client
        client.views_update(view_id: payload.dig('view', 'id'), view: view) if view
        return {}
      end
      data, form = JSON.parse(payload.dig('view', 'private_metadata') || '{}'), values(payload)
      callback = payload.dig('view', 'callback_id')
      case callback
      when 'fix_new'
        %w[shop_id tool_id].each { |key| form.delete(key) if form[key] == 'none' }
        form['shop_id'] = Tool.find(form['tool_id']).shop_id.to_s if form['tool_id'].present?
        %w[i_broke_it i_can_fix_it public_read_only].each { |key| form[key] = form[key] == 'true' }
        ticket = FixTicketService.create!(actor: member, attributes: form.merge('submission_key' => data['submission_key']))
        data['id'] = ticket.id.to_s
      when 'fix_filters'
        return { response_action: 'update', view: list(member, form.reject { |_, v| v == 'all' }.merge('page' => 0)) }
      when 'fix_edit'
        %w[shop_id tool_id].each { |key| form[key] = nil if form[key] == 'none' }
        form['announce_to_slack'] = form['announce_to_slack'] == 'true'
        FixTicketService.update!(id: data['id'], actor: member, attributes: form.merge('revision' => data['revision']))
      when 'fix_note' then FixTicketService.note!(id: data['id'], actor: member, note: form['note'])
      when 'fix_status' then FixTicketService.update!(id: data['id'], actor: member, attributes: form.compact.merge('revision' => data['revision']))
      when 'fix_visibility' then FixTicketService.update!(id: data['id'], actor: member, attributes: { public_read_only: form['public_read_only'] == 'true' })
      when 'fix_assign' then FixTicketService.assign!(id: data['id'], actor: member, member_ids: form['member_ids'])
      end
      { response_action: 'update', view: detail(member, data['id'], data['query'] || {}) }
    rescue Error::CustomError, Mongoid::Errors::Validations => error
      if payload['type'] == 'view_submission'
        key = payload.dig('view', 'state', 'values')&.keys&.first || 'title'
        { response_action: 'errors', errors: { key => error.message.first(150) } }
      else
        Service::SlackConnector.client.views_update(view_id: payload.dig('view', 'id'), view: modal('fix_error', [text_block(error.message)], {}, submit: nil))
        {}
      end
    end
  end
end
