# Adding a New Frontend Route (React + Rails)

This project uses a React SPA (`makerspace-react-2026`) served by Rails (`makerspace-rails-2026`).
A route must be configured in **both layers** to reliably display.

## 1) Add the route constant in React

File: `src/app/constants.ts`

- Add a `Routing` constant for the new path.
- If it is member-scoped, prefer placeholders (for example `:memberId`) like existing routes.

Example:

```ts
export const CheckInActivity = `${Profile}/checkin-activity`;
```

## 2) Register the route in React router

Private pages go in `src/app/PrivateRouting.tsx`.
Public pages go in `src/app/PublicRouting.tsx`.

- Import the page component.
- Add a `<Route ... />` with the matching `Routing.*` path.
- If access should be role/permission-based, wrap the route in the proper capability condition.

Example (private):

```tsx
<Route exact path={Routing.CheckInActivity} component={MemberCheckInActivity} />
```

## 3) Ensure App-level login redirect logic does not treat route as public

File: `src/app/App.tsx`

`publicPaths` is used to decide post-login redirects. Keep this list limited to truly public routes.

Current code:

```ts
const publicPaths = [Routing.Login, Routing.SignUp, Routing.PasswordReset];
```

If you add a new **public** route, include it here if it should bypass authenticated redirect behavior.

## 4) Wire navigation links to the exact route shape

When linking to the page, ensure the URL exactly matches the route pattern.

For member routes, use constants/placeholders when possible instead of raw strings.

## 5) Rails must allow SPA fallback to `application#application`

File: `makerspace-rails-2026/config/routes.rb`

Required catch-all route (already present):

```rb
get '*path', to: 'application#application'
```

This is what allows direct browser loads (or refresh) on React routes like `/members/:memberId/checkin-activity`.
Without this, Rails returns 404 before React can render.

## 6) Rails `ApplicationController` format restrictions

File: `makerspace-rails-2026/app/controllers/application_controller.rb`

Current restrictions:

- `allow_only_html_requests` (for `application` action)
- `filter_requests` only allows formats matching `html|json`

Implication:
- SPA page loads must request HTML (normal browser navigation does).
- API calls from the route should use JSON endpoints under `/api/...`.
- If your new page fetches from new backend endpoints, add those endpoints under `/api` routes and controller actions that return JSON.

## 7) Backend endpoints used by the route must exist and be authorized

If the route page fetches data, verify:

- Route exists in Rails `scope :api` (`config/routes.rb`)
- Controller action exists
- Access control allows the current member

For `MemberCheckInActivity`, frontend fetches:

- `/api/admin/cards?memberId=...`
- `/api/admin/checkins?...`
- `/api/admin/rejections?...`

`/api/admin/cards` exists, but `checkins` and `rejections` endpoints are not defined in current `routes.rb`. If missing, the page can render but appear broken/empty due to failed data calls.

## 8) Quick verification checklist

1. Navigate directly to the new URL in browser.
2. Refresh page on that URL (tests Rails SPA fallback).
3. Confirm React route component mounts.
4. Confirm API requests from the page return 200/expected auth (not 401/403/404).
5. Confirm capability/permission gates allow expected users.

---

## Most likely reason `MemberCheckInActivity` appears to "not display"

The React route itself is present in `PrivateRouting.tsx` and Rails SPA fallback is present.
The larger risk is failed API requests from that page 
(notably missing `/api/admin/checkins` and `/api/admin/rejections` route definitions in Rails), 
which can make the page look non-functional even when routing works.
