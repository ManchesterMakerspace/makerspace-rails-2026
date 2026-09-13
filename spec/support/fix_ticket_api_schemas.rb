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
    FixPerson: person,
    FixTicketCapabilities: object.call(capabilities),
    FixTicket: object.call(ticket),
    FixTicketEvent: object.call({ id: string, kind: string, actor: string, note: nullable_string,
      changes: { type: :object, additionalProperties: { type: :array, items: {} }, description: 'Redacted before/after values for changed fields; no reporter identity.' }, createdAt: timestamp }),
    FixTicketDetail: { allOf: [ref.call('FixTicket'), object.call({ events: array.call(ref.call('FixTicketEvent')), deliveryFailed: boolean })] },
    FixTicketPage: object.call({ tickets: array.call(ref.call('FixTicket')), total: integer, page: integer, pageSize: integer }),
    FixTicketCatalog: object.call({ shops: array.call(person), tools: array.call(object.call({ id: string, name: string, shopId: string, outOfService: boolean })),
      assignees: array.call(person), canCreate: boolean, creationUnavailableReason: nullable_string, openCount: integer,
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
