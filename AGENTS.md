# Documentation maintenance

Keep the operational inventories and API specification synchronized with every code change:

- Update `docs/email.MD` whenever code that sends email is added or changed. Document the trigger, recipient, subject, and the template-selection or fallback behavior.
- Update `docs/environment-vars.MD` whenever a dependency on an environment variable is added, or an existing environment-variable dependency is entirely removed.
- Update `docs/public-resources.MD` whenever the inventory of public, deep-linkable Rails resources changes.
- Update `docs/mongodb-collections.md` whenever a MongoDB collection is added or an existing collection is entirely removed.
- Update `docs/jobs-tasks-services.MD` whenever job/task code changes so that it continues to cover every job returned by `GET /api/admin/system_configs` or accepted by `POST /api/admin/system_configs/run_job`, all recurring work configured in `config/schedule.rb`, and every other Rake task whose source identifies it as intended to recur in production.
- Keep the Swagger API interface current whenever an API endpoint is added, changed, or removed, including changes to routes, authentication or authorization requirements, parameters, request bodies, response bodies, or status codes. Update the relevant executable specification under `spec/api/`, regenerate `swagger/v1/swagger.json` with `bundle exec rake rswag:specs:swaggerize`, and commit the regenerated specification.
