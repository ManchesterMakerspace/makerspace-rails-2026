# Repository instructions for agents

Keep the repository's documentation inventories synchronized with behavior:

- Update `docs/mongodb-collections.md` whenever a MongoDB collection is added,
  removed, renamed, or repurposed, or whenever one of its expected indexes is
  added, removed, or changed. Include collection-name overrides and distinguish
  embedded documents from top-level collections.
- Update `docs/member-statuses.md` whenever a supported member status is added,
  removed, renamed, or given different semantics. Also update its mutation-path
  appendix whenever an API endpoint, webhook, callback, job, task, or other
  application path starts or stops changing an existing member's `status`.
- Update `docs/public-resources.MD` whenever a public API endpoint or
  server-rendered public route is added, removed, renamed, or has its method,
  authentication, formats, or parameter contract changed. Update the linked
  feature document at the same time.

Documentation updates are part of the implementation, not optional follow-up
work. In the pull request summary, call out which inventories were updated or
why no inventory change was required.
