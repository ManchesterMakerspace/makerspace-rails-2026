# Google token

This project uses Google for federated authentication (optional), drive, calendar, and resources.
In the Google Cloud Console API Library, select the project associated with GOOGLE_ID and enable:
* Google Drive API
* Google Calendar API
* Admin SDK API


You will need GOOGLE_ID, GOOGLE_SECRET, and GOOGLE_TOKEN to make API calls.
Also include environment secrets  GOOGLE_RESERVATIONS_CALENDAR_ID and optionally GOOGLE_CUSTOMER_ID

## Configure the OAuth consent screen
Under Google Auth Platform → Audience:
* Prefer Internal if the app is only used by your Workspace organization.
* Otherwise add the Workspace administrator as a test user.
* Avoid leaving an external app in Testing for production: those authorizations normally expire after seven days

3. Configure the OAuth client
Open Google Auth Platform → Clients and select the Web application client represented by GOOGLE_ID.
Add this authorized redirect URI:
https://developers.google.com/oauthplayground
If the existing client is not a Web application client, create one. In that case, update both GOOGLE_ID and GOOGLE_SECRET to the new client’s credentials. The refresh token must be generated with that same client ID and secret.
4. Configure OAuth Playground
Open the OAuth 2.0 Playground.
Click the gear icon and configure:
OAuth flow: Server-side
Access type: Offline
Force prompt: Consent Screen
Enable Use your own OAuth credentials
Enter the project’s OAuth client ID and client secret
Google requires offline access to return a refresh token, and forcing consent helps ensure a new refresh token is issued. Google OAuth server flow documentation
5. Authorize all project scopes
Under Step 1, use “Input your own scopes” and enter:
https://www.googleapis.com/auth/drive
https://www.googleapis.com/auth/admin.directory.resource.calendar
https://www.googleapis.com/auth/calendar
Then click Authorize APIs.

Sign in with a Google Workspace administrator or delegated administrator who:
* Can manage buildings and calendar resources.
*Has edit access to the dedicated reservations calendar.
* Has access to the Drive folders used by the portal.

Approve all requested permissions.

Exchange the authorization code

In Playground Step 2:
Click Exchange authorization code for tokens.
Copy the resulting Refresh token, not the access token.
Set the environment variables together:

GOOGLE_ID=<the OAuth client ID used in Playground>
GOOGLE_SECRET=<the matching client secret>
GOOGLE_TOKEN=<the new refresh token>
GOOGLE_RESERVATIONS_CALENDAR_ID=<dedicated calendar ID>
GOOGLE_CUSTOMER_ID=my_customer

Treat the client secret and refresh token as production secrets; do not commit them.

7. Restart and reconcile

Restart Rails and the background-job workers, then run:
```
bundle exec rake google_resources:reconcile
```
That task queues synchronization for existing shops and tools. Confirm the worker logs show successful Directory resource creation or matching, followed by successful Calendar synchronization when making a test reservation.
