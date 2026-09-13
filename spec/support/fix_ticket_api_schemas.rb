# Reusable response contracts for repair-ticket endpoints.
module FixTicketApiSchemas
  ref = ->(name) { { '$ref' => "#/components/schemas/#{name}" } }
  object = ->(properties, required = properties.keys) { { type: :object, properties: properties, required: required } }
  string = { type: :string }
  nullable_string = { type: :string, nullable: true }
  boolean = { type: :boolean }
  integer = { type: :integer }
  timestamp = { type: :string, format: 'date-time' }
  array = ->(item) { { type: :array, items: item } }
  person = object.call({ id: string, name: string })
  capabilities = %w[canRead canAddNote canChangeStatus canManage canManageVisibility publicLocked canWithdraw canUnassign canCreateBounty canNominateReward canReviewReward canReveal].to_h { |key| [key, boolean] }
  ticket = {
    id: string, reference: string, title: string, description: string,
    closedBy: person.merge(nullable: true, description: 'Closer identity only for closed tickets closed by someone other than the reporter; otherwise null.'),
    category: { type: :string, enum: %w[damaged broken missing other] },
    status: { type: :string, enum: %w[open in_progress waiting_for_parts resolved rejected withdrawn] },
    confirmation: { type: :string, enum: %w[unverified confirmed could_not_confirm] },
    priority: { type: :integer, nullable: true, minimum: 1, maximum: 10 },
    submittedPriority: { type: :integer, nullable: true, minimum: 1, maximum: 10 },
    shopId: nullable_string, shopName: nullable_string, toolId: nullable_string, toolName: nullable_string,
    toolHidden: boolean, outOfService: boolean, uncataloguedTool: nullable_string,
    publicReadOnly: boolean, iBrokeIt: boolean, iCanFixIt: boolean,
    assignees: array.call(ref.call('FixPerson')), announceToSlack: boolean, announcementNote: string,
    bountyId: nullable_string, bountyUrl: nullable_string, rewardStatus: nullable_string,
    revision: { type: :integer, minimum: 0 }, createdAt: timestamp, updatedAt: timestamp,
    capabilities: ref.call('FixTicketCapabilities')
  }
  SCHEMAS = {
    VolunteerTaskWrite: { type: :object, properties: {
          title: { type: :string }, description: { type: :string }, credit_value: { type: :number, exclusiveMinimum: true, minimum: 0, description: 'Positive credit value. Creation is capped; admin/board updates have no upper limit and credit changes are audited.' },
          shop_id: { type: :string, nullable: true }, status: { type: :string, enum: VolunteerTask::VALID_STATUSES },
          days: { type: :integer, nullable: true }, prerequisite_tool_ids: { type: :array, items: { type: :string } }
        } },
    FixTicketUpdate: { type: :object, properties: {
        revision: { type: :integer }, status: { type: :string, enum: FixTicket::STATUSES }, confirmation: { type: :string, enum: FixTicket::CONFIRMATIONS },
        note: { type: :string, maxLength: 10000, description: 'Nonblank notes require at least two non-whitespace characters. State transitions may require a note.' }, title: { type: :string, maxLength: 150, pattern: FixTicket::SAFE_NAME_PATTERN }, description: { type: :string }, category: { type: :string },
        shop_id: { type: :string, nullable: true }, tool_id: { type: :string, nullable: true }, uncatalogued_tool: { type: :string, pattern: "(?:#{FixTicket::SAFE_NAME_PATTERN})|^$" },
        public_read_only: { type: :boolean }, announce_to_slack: { type: :boolean }, announcement_note: { type: :string }, nominate_reward: { type: :boolean }
      } },
    FixSlackInteractionPayload: { type: :object, required: %w[type team user], properties: {
      type: { type: :string, enum: %w[block_suggestion block_actions view_submission] },
      team: object.call({ id: string }), user: object.call({ id: string }), action_id: string, value: string,
      actions: array.call(object.call({ action_id: string, value: string })),
      view: { type: :object, properties: { id: string, callback_id: string, private_metadata: { type: :string, description: 'JSON-encoded ticket ID, revision, query or submission key.' },
        state: { type: :object, properties: { values: { type: :object, additionalProperties: { type: :object, description: 'Block IDs map to action IDs and value, selected_option or selected_options.' } } } } } } } },
    FixSlackInteractionResponse: { anyOf: [
      { type: :object, maxProperties: 0 },
      object.call({ options: array.call(object.call({ text: object.call({ type: { type: :string, enum: ['plain_text'] }, text: string }), value: string })) }),
      object.call({ response_action: { type: :string, enum: ['update'] }, view: { type: :object, required: %w[type title blocks], properties: { type: { type: :string, enum: ['modal'] }, title: { type: :object }, callback_id: string, private_metadata: string, blocks: array.call({ type: :object }) } } }),
      object.call({ response_action: { type: :string, enum: ['errors'] }, errors: { type: :object, additionalProperties: string } }) ] },
    CheckoutApproverWrite: { type: :object, properties: { member_id: string, shop_ids: array.call(string), tool_ids: array.call(string) } },
    PublicCatalogShop: object.call({ id: string, name: string, wiki_url: nullable_string,
      tools: array.call(object.call({ id: string, name: string, open: boolean, out_of_service: boolean })) }),
    PublicCatalogTool: object.call({ id: string, name: string, description: nullable_string, open: boolean, out_of_service: boolean,
      wiki_url: nullable_string, shop: object.call({ id: string, name: string, wiki_url: nullable_string }) }),
    ShopWrite: { type: :object, properties: {
      name: string, wiki_url: nullable_string, gdrive_id: nullable_string, slack_channel: nullable_string,
      disabled: boolean, reservable: boolean, color_id: string, floor_name: nullable_string, capacity: integer,
      resource_manager_ids: { type: :array, items: string, description: 'Admin/board only. Replace Resource Manager assignments; omit to preserve, [] to clear. IDs must belong to Resource Managers, Admins, or Board members; their roles are preserved.' },
      max_concurrent_reservations: integer, reservation_horizon_days: integer, minimum_advance_notice_hours: { type: :number },
      prohibit_same_day_reservations: boolean, reservation_full_day: boolean, max_reservation_duration_hours: { type: :number },
      reservation_requires_approval: boolean, reservation_prerequisite_tool_ids: array.call(string),
      duration_fees: array.call({ type: :object, properties: { invoice_option_id: string, minimum_hours: { type: :number }, maximum_hours: { type: :number, nullable: true }, full_day: boolean } }) } },
    ToolCheckout: object.call({ id: string, memberId: string, toolId: string, outOfService: boolean,
      checkedOutAt: timestamp, revokedAt: { type: :string, format: 'date-time', nullable: true },
      revocationReason: nullable_string, signedOffVia: nullable_string, approvedById: nullable_string,
      toolName: nullable_string, shopName: nullable_string, shopId: nullable_string, shopWikiUrl: nullable_string,
      memberName: nullable_string, memberEmail: nullable_string, approvedByName: nullable_string, active: boolean,
      toolNotes: nullable_string }, %i[id memberId toolId outOfService active]),
    ToolCheckoutRequest: object.call({ id: string, memberId: string, toolId: string, outOfService: boolean,
      memberName: nullable_string, memberEmail: nullable_string, memberStatus: nullable_string,
      toolName: nullable_string, shopId: nullable_string, shopName: nullable_string, note: nullable_string,
      requestDate: timestamp, status: string, messageId: nullable_string, checkedOutId: nullable_string,
      memberSlackUrl: nullable_string }, %i[id memberId toolId outOfService status]),
    FixPerson: person,
    FixTicketCapabilities: object.call(capabilities),
    FixTicket: object.call(ticket),
    FixTicketEvent: object.call({ id: string, kind: string, actor: string, note: nullable_string,
      changes: { type: :object, additionalProperties: { type: :array, items: {} }, description: 'Redacted before/after values; assignment-name deltas omitted and assignment actors neutralized to avoid identifying the reporter.' }, createdAt: timestamp }),
    FixTicketDetail: { allOf: [ref.call('FixTicket'), object.call({ events: array.call(ref.call('FixTicketEvent')), deliveryFailed: boolean })] },
    FixTicketPage: object.call({ tickets: array.call(ref.call('FixTicket')), total: integer, page: integer, pageSize: integer }),
    FixTicketCatalog: object.call({ shops: array.call(person), tools: array.call(object.call({ id: string, name: string, shopId: string, outOfService: boolean })),
      assignees: array.call(person), canCreate: boolean, creationUnavailableReason: nullable_string, openCount: integer,
      bountyMaxCredit: { type: :number, minimum: 0.5, default: 2, description: 'Configured maximum credits when converting a ticket to a bounty.' },
      openLimit: { type: :integer, nullable: true, minimum: 1 }, centralSlackEnabled: boolean }),
    FixReporterReveal: object.call({ id: nullable_string, name: string }),
    FixOutageResult: object.call({ outOfService: boolean, affectedCount: integer,
      affectedReservations: array.call(object.call({ id: string, startAt: timestamp, endAt: timestamp })) }),
    FixDeliveryQueued: object.call({ queued: boolean }),
    FixError: { type: :object, properties: { error: string, message: string } },
    FixBountyDetail: object.call({ id: string, title: string, description: string, status: string, creditValue: { type: :number },
      ticketId: nullable_string, shopId: nullable_string, shopName: nullable_string, taskNumber: integer,
      prerequisiteToolIds: array.call(string), prerequisiteToolNames: array.call(string),
      claimedById: nullable_string, claimedByName: nullable_string, createdById: nullable_string, createdByName: nullable_string,
      verifiedById: nullable_string, verifiedByName: nullable_string, parentTaskId: nullable_string,
      claimedAt: { type: :string, format: 'date-time', nullable: true }, completedAt: { type: :string, format: 'date-time', nullable: true },
      createdAt: timestamp, updatedAt: timestamp, days: { type: :integer, nullable: true },
      nextAvailable: { type: :string, nullable: true }, rejectionReason: nullable_string, isChildTask: boolean, isCoolingDown: boolean,
      capabilities: object.call({ canClaim: boolean, canSubmitCompletion: boolean }) },
      %i[id title description status creditValue ticketId capabilities])
  }.tap do |schemas|
    schemas[:VolunteerTask] = object.call(schemas[:FixBountyDetail][:properties].except(:capabilities))
  end.freeze
end
