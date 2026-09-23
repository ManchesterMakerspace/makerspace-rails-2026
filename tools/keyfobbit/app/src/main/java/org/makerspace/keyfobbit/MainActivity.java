package org.makerspace.keyfobbit;

import android.app.*;
import android.content.*;
import android.nfc.*;
import android.nfc.tech.MifareClassic;
import android.os.*;
import android.text.InputType;
import android.view.*;
import android.widget.*;
import com.google.android.gms.auth.api.signin.*;
import com.google.android.gms.common.api.ApiException;
import com.google.firebase.*;
import com.google.firebase.auth.*;
import org.json.JSONObject;
import java.net.URLEncoder;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class MainActivity extends Activity implements NfcAdapter.ReaderCallback {
    private static final int GOOGLE_SIGN_IN = 7104;
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private LinearLayout content;
    private TextView status;
    private NfcAdapter nfcAdapter;
    private ApiClient api;
    private boolean authenticated;
    private GoogleSignInClient googleSignInClient;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        nfcAdapter = NfcAdapter.getDefaultAdapter(this);
        showLogin();
    }

    @Override protected void onResume() {
        super.onResume();
        if (authenticated) enableReader();
    }

    @Override protected void onPause() {
        if (nfcAdapter != null) nfcAdapter.disableReaderMode(this);
        super.onPause();
    }

    @Override protected void onDestroy() {
        executor.shutdownNow();
        super.onDestroy();
    }

    private void showLogin() {
        authenticated = false;
        content = screen();
        title("Keyfobbit");
        label("Board or administrator sign-in");
        EditText server = input("Server URL", InputType.TYPE_TEXT_VARIATION_URI);
        server.setText(getPreferences(MODE_PRIVATE).getString("server", "https://memberspace.example.org"));
        EditText email = input("Email", InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS);
        EditText password = input("Password", InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        Button signIn = button("Sign in");
        Button firebaseSignIn = button("Sign in with Google / Firebase");
        status = label("");
        signIn.setOnClickListener(v -> {
            String root = server.getText().toString().trim();
            if (!root.toLowerCase(Locale.US).startsWith("https://")) {
                status.setText("Use an HTTPS server URL."); return;
            }
            api = new ApiClient(root);
            getPreferences(MODE_PRIVATE).edit().putString("server", root).apply();
            signIn.setEnabled(false);
            status.setText("Signing in…");
            JSONObject member = new JSONObject();
            JSONObject request = new JSONObject();
            try {
                member.put("email", email.getText().toString().trim());
                member.put("password", password.getText().toString());
                request.put("member", member);
            } catch (Exception ignored) { }
            runNetwork(() -> api.post("/api/members/sign_in", request), response -> {
                signIn.setEnabled(true);
                if (response.status == 202 && response.body.optBoolean("totpRequired")) showTotp();
                else completeAuthentication(response);
            });
        });
        firebaseSignIn.setOnClickListener(v -> beginFirebaseLogin(server.getText().toString().trim()));
    }

    private void beginFirebaseLogin(String root) {
        if (!root.toLowerCase(Locale.US).startsWith("https://")) {
            status.setText("Use an HTTPS server URL."); return;
        }
        api = new ApiClient(root);
        getPreferences(MODE_PRIVATE).edit().putString("server", root).apply();
        status.setText("Loading Firebase configuration…");
        runNetwork(() -> api.get("/api/config"), response -> {
            if (response.status != 200) { status.setText(response.message()); return; }
            JSONObject config = response.body;
            String apiKey = config.optString("firebase_api_key");
            String projectId = config.optString("firebase_project_id");
            String appId = config.optString("firebase_app_id");
            String webClientId = config.optString("firebase_web_client_id");
            if (apiKey.isEmpty() || projectId.isEmpty() || appId.isEmpty() || webClientId.isEmpty()) {
                status.setText("Firebase native sign-in is not configured on this server."); return;
            }
            FirebaseApp firebaseApp;
            try { firebaseApp = FirebaseApp.getInstance("keyfobbit"); }
            catch (IllegalStateException missing) {
                FirebaseOptions options = new FirebaseOptions.Builder().setApiKey(apiKey)
                        .setProjectId(projectId).setApplicationId(appId).build();
                firebaseApp = FirebaseApp.initializeApp(this, options, "keyfobbit");
            }
            GoogleSignInOptions options = new GoogleSignInOptions.Builder(GoogleSignInOptions.DEFAULT_SIGN_IN)
                    .requestIdToken(webClientId).requestEmail().build();
            googleSignInClient = GoogleSignIn.getClient(this, options);
            status.setText("Choose a Google account…");
            startActivityForResult(googleSignInClient.getSignInIntent(), GOOGLE_SIGN_IN);
        });
    }

    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != GOOGLE_SIGN_IN) return;
        try {
            GoogleSignInAccount account = GoogleSignIn.getSignedInAccountFromIntent(data).getResult(ApiException.class);
            AuthCredential credential = GoogleAuthProvider.getCredential(account.getIdToken(), null);
            FirebaseAuth.getInstance(FirebaseApp.getInstance("keyfobbit")).signInWithCredential(credential)
                    .addOnSuccessListener(result -> result.getUser().getIdToken(true)
                            .addOnSuccessListener(token -> authenticateFirebaseToken(token.getToken()))
                            .addOnFailureListener(error -> status.setText("Firebase token error: " + error.getMessage())))
                    .addOnFailureListener(error -> status.setText("Firebase sign-in failed: " + error.getMessage()));
        } catch (ApiException error) {
            status.setText("Google sign-in failed (" + error.getStatusCode() + ").");
        }
    }

    private void authenticateFirebaseToken(String token) {
        status.setText("Signing in…");
        JSONObject request = new JSONObject();
        try { request.put("idToken", token); } catch (Exception ignored) { }
        runNetwork(() -> api.post("/api/auth/firebase_login", request), response -> {
            if (response.status == 202 && response.body.optBoolean("totpRequired")) showTotp();
            else completeAuthentication(response);
        });
    }

    private void showTotp() {
        content = screen();
        title("Two-factor authentication");
        EditText code = input("6-digit code", InputType.TYPE_CLASS_NUMBER);
        Button verify = button("Verify");
        status = label("");
        verify.setOnClickListener(v -> {
            verify.setEnabled(false);
            JSONObject request = new JSONObject();
            try { request.put("code", code.getText().toString().trim()); } catch (Exception ignored) { }
            runNetwork(() -> api.post("/api/members/totp_sessions", request), response -> {
                verify.setEnabled(true);
                completeAuthentication(response);
            });
        });
    }

    private void completeAuthentication(ApiClient.Response response) {
        if (response.status < 200 || response.status >= 300) { status.setText(response.message()); return; }
        if (response.body.optBoolean("totpEnrollmentRequired")) {
            status.setText("TOTP enrollment is required. Complete setup in the member portal, then sign in again.");
            return;
        }
        String role = response.body.optString("role");
        if (!role.equals("admin") && !role.equals("board_member")) {
            status.setText("Access denied: board or administrator role required."); return;
        }
        authenticated = true;
        showScanner();
    }

    private void showScanner() {
        content = screen();
        title("Scan access card");
        status = label(nfcAdapter == null ? "This device has no NFC reader." :
                (!nfcAdapter.isEnabled() ? "Enable NFC in Android settings." : "Hold a MIFARE Classic card against the device."));
        Button logout = button("Sign out");
        logout.setOnClickListener(v -> showLogin());
        enableReader();
    }

    private void enableReader() {
        if (nfcAdapter != null && nfcAdapter.isEnabled()) {
            nfcAdapter.enableReaderMode(this, this,
                    NfcAdapter.FLAG_READER_NFC_A | NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK,
                    null);
        }
    }

    @Override public void onTagDiscovered(Tag tag) {
        if (!authenticated) return;
        if (MifareClassic.get(tag) == null) {
            runOnUiThread(() -> status.setText("Unsupported tag: scan a MIFARE Classic card."));
            return;
        }
        String uid = uidHex(tag.getId());
        runOnUiThread(() -> status.setText("Card " + uid + " — looking up…"));
        String encoded = urlEncode(uid);
        runNetwork(() -> api.get("/api/admin/cards/by_uid?uid=" + encoded), response -> showCard(uid, response));
    }

    private void showCard(String uid, ApiClient.Response response) {
        if (response.status == 404) {
            status.setText("Card " + uid + " was not found.");
            new AlertDialog.Builder(this).setTitle("Unknown card")
                    .setMessage("Card " + uid + " has no card record. Add it to rejections?")
                    .setNegativeButton("Cancel", null)
                    .setPositiveButton("Add rejection", (d, w) -> addRejection(uid)).show();
            return;
        }
        if (response.status == 401 || response.status == 403) {
            authenticated = false;
            new AlertDialog.Builder(this).setTitle("Session ended").setMessage(response.message())
                    .setPositiveButton("Sign in", (d, w) -> showLogin()).setCancelable(false).show();
            return;
        }
        if (response.status < 200 || response.status >= 300) { status.setText(response.message()); return; }
        JSONObject card = response.body;
        String memberId = card.optString("memberId");
        if (memberId.isEmpty()) memberId = card.optJSONObject("member") == null ? "" : card.optJSONObject("member").optString("id");
        String details = "UID: " + card.optString("uid", uid) + "\nHolder: " + card.optString("holder", "—") +
                "\nValidity: " + card.optString("validity", "—") + "\nExpiry: " + card.optString("expiry", "—");
        AlertDialog.Builder dialog = new AlertDialog.Builder(this).setTitle("Card found").setMessage(details).setNegativeButton("Scan another", null);
        if (!memberId.isEmpty()) {
            String id = memberId;
            dialog.setPositiveButton("View member", (d, w) -> fetchMember(id));
        }
        dialog.show();
        status.setText("Ready for another card.");
    }

    private void addRejection(String uid) {
        status.setText("Adding rejection…");
        JSONObject request = new JSONObject();
        try { request.put("uid", uid); } catch (Exception ignored) { }
        runNetwork(() -> api.post("/api/admin/rejections", request), response -> {
            if (response.status == 201) status.setText("Card " + uid + " added to rejections.");
            else status.setText(response.message());
        });
    }

    private void fetchMember(String id) {
        status.setText("Loading member…");
        runNetwork(() -> api.get("/api/members/" + urlEncode(id)), response -> {
            if (response.status < 200 || response.status >= 300) { status.setText(response.message()); return; }
            JSONObject m = response.body;
            String details = "Name: " + m.optString("firstname") + " " + m.optString("lastname") +
                    "\nEmail: " + m.optString("email", "—") + "\nStatus: " + m.optString("status", "—") +
                    "\nRole: " + m.optString("role", "—") + "\nExpiration: " + m.optString("expirationTime", "—");
            new AlertDialog.Builder(this).setTitle("Member details").setMessage(details).setPositiveButton("Done", null).show();
            status.setText("Ready for another card.");
        });
    }

    private interface Request { ApiClient.Response execute() throws Exception; }
    private interface Result { void accept(ApiClient.Response response); }
    private void runNetwork(Request request, Result result) {
        executor.execute(() -> {
            try { ApiClient.Response response = request.execute(); runOnUiThread(() -> result.accept(response)); }
            catch (Exception e) { runOnUiThread(() -> status.setText("Network error: " + e.getMessage())); }
        });
    }

    static String uidHex(byte[] bytes) {
        StringBuilder result = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) result.append(String.format(Locale.US, "%02X", value & 0xff));
        return result.toString();
    }

    private static String urlEncode(String value) {
        try { return URLEncoder.encode(value, "UTF-8"); }
        catch (Exception impossible) { throw new IllegalStateException(impossible); }
    }

    private LinearLayout screen() {
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setPadding(dp(24), dp(36), dp(24), dp(24));
        setContentView(layout);
        return layout;
    }
    private void title(String text) { TextView v = label(text); v.setTextSize(28); v.setPadding(0, 0, 0, dp(24)); }
    private TextView label(String text) { TextView v = new TextView(this); v.setText(text); v.setTextSize(17); v.setPadding(0, dp(8), 0, dp(8)); content.addView(v); return v; }
    private EditText input(String hint, int type) { EditText v = new EditText(this); v.setHint(hint); v.setInputType(type); content.addView(v, new LinearLayout.LayoutParams(-1, -2)); return v; }
    private Button button(String text) { Button v = new Button(this); v.setText(text); LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(-1, -2); p.setMargins(0, dp(16), 0, 0); content.addView(v, p); return v; }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
}
