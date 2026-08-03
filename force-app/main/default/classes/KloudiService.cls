/**
 * KloudiService — OUTBOUND integration with Kloudi (app.kloudi.ai): SMS + contact sync.
 *
 * Auth: the Kloudi API token is stored as DATA on App_Secret__c (Name='KLOUDI_API', Secret_Value__c);
 * Kloudi expects it as a ?token= query parameter (not a header). Read via a without-sharing inner class
 * (system context) so triggers / Flows / journeys / queueables work for any running user, while FLS +
 * Private sharing keep the value out of reps' reach. The app.kloudi.ai host is allow-listed by the
 * Kloudi_API remote site setting. Nothing secret is ever hardcoded — Rahul pastes the token UI-side.
 *
 * Compliance: every LEAD-targeted send is gated — TCPA Clear + SMS consent + not opted out + inside
 * quiet hours (8am–9pm recipient-local). A skip never sends and is logged (a Task) by the caller path.
 */
public with sharing class KloudiService {

    public static final String BASE = 'https://app.kloudi.ai/api/v1/direct';
    @TestVisible private static final String TOKEN_NAME = 'KLOUDI_API';
    @TestVisible private static Datetime nowOverride;   // tests pin "now" to make quiet-hours deterministic
    private static Datetime rightNow() { return nowOverride != null ? nowOverride : Datetime.now(); }

    public class KloudiResult {
        public Boolean ok = false;          // transport succeeded (2xx)
        public Boolean sent = false;        // a message actually left
        public Integer statusCode;
        public String body;
        public String error;                // transport error, 'no_token_configured', 'skipped:<reason>'
        public String skipReason;           // set when the compliance gate blocked the send
    }

    // ---- token (system context) ----
    private static String cachedToken;
    @TestVisible
    private static String token() {
        if (cachedToken != null) return cachedToken;
        cachedToken = new SecretStore().read(TOKEN_NAME);
        return cachedToken;
    }
    private without sharing class SecretStore {
        String read(String name) {
            List<App_Secret__c> r = [SELECT Secret_Value__c FROM App_Secret__c WHERE Name = :name LIMIT 1];
            return r.isEmpty() ? null : r[0].Secret_Value__c;
        }
    }

    // ---- transport ----
    private static KloudiResult doPost(String path, String jsonBody) {
        KloudiResult r = new KloudiResult();
        String tok = token();
        if (String.isBlank(tok)) { r.error = 'no_token_configured'; return r; }
        HttpRequest req = new HttpRequest();
        req.setEndpoint(BASE + path + '?token=' + EncodingUtil.urlEncode(tok, 'UTF-8'));
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(120000);
        req.setBody(jsonBody);
        try {
            HttpResponse resp = new Http().send(req);
            r.statusCode = resp.getStatusCode();
            r.body = resp.getBody();
            r.ok = (resp.getStatusCode() >= 200 && resp.getStatusCode() < 300);
        } catch (Exception e) {
            r.error = 'callout_exception: ' + e.getMessage();
        }
        return r;
    }

    /** POST /list/{listId}/contacts — add/sync a Lead into a Kloudi list. */
    public static KloudiResult addContact(String listId, Lead l) {
        Map<String, Object> body = new Map<String, Object>{
            'first_name' => l.FirstName, 'last_name' => l.LastName,
            'phone' => l.Phone, 'email' => l.Email, 'state' => l.State, 'city' => l.City
        };
        return doPost('/list/' + listId + '/contacts', JSON.serialize(body));
    }

    /** Raw SMS send. POST /messages/sms {source, destination, message}. Transport ONLY — the compliance
     *  gate lives in sendToLead()/the invocable; call this directly only for non-lead/system messages. */
    public static KloudiResult sendSms(String source, String destination, String message) {
        Map<String, Object> body = new Map<String, Object>{
            'source' => source, 'destination' => destination, 'message' => message
        };
        KloudiResult r = doPost('/messages/sms', JSON.serialize(body));
        r.sent = r.ok;
        return r;
    }

    /** Compliance-gated SMS to a Lead. Returns skipReason (no send) when the lead isn't TCPA-clear,
     *  hasn't consented, has opted out, or it's outside quiet hours. Does NO DML (loop-safe for callouts);
     *  the caller (KloudiSendQueueable) persists the skip log after all callouts complete. */
    public static KloudiResult sendToLead(Id leadId, String source, String message) {
        KloudiResult r = new KloudiResult();
        List<Lead> ls = [SELECT Id, Phone, State, Office__c, TCPA_Scrub_Status__c, SMS_Consent__c,
                                SMS_Opt_Out__c, Local_Timezone__c
                         FROM Lead WHERE Id = :leadId LIMIT 1];
        if (ls.isEmpty()) { r.error = 'lead_not_found'; return r; }
        String reason = complianceSkipReason(ls[0]);
        if (reason != null) { r.skipReason = reason; r.error = 'skipped:' + reason; return r; }
        return sendSms(source, ls[0].Phone, message);
    }

    /** null = OK to send; otherwise the reason the send is skipped. */
    @TestVisible
    private static String complianceSkipReason(Lead l) {
        if (l.TCPA_Scrub_Status__c != 'Clear') return 'not_tcpa_clear';
        if (l.SMS_Consent__c != true) return 'no_sms_consent';
        if (l.SMS_Opt_Out__c == true) return 'opted_out';
        if (!insideQuietHours(l)) return 'outside_quiet_hours';
        return null;
    }

    /** 8am–9pm in the recipient's local timezone (Local_Timezone__c, else resolved from phone/state/office, else ET). */
    @TestVisible
    private static Boolean insideQuietHours(Lead l) {
        String tz = String.isNotBlank(l.Local_Timezone__c)
            ? l.Local_Timezone__c
            : LeadTimezoneUtil.resolve(l.Phone, l.State, l.Office__c);
        if (String.isBlank(tz)) tz = 'America/New_York';
        Integer h;
        try { h = Integer.valueOf(rightNow().format('H', tz)); }
        catch (Exception e) { h = Integer.valueOf(rightNow().format('H', 'America/New_York')); }
        return h >= 8 && h < 21;
    }

    // ---- Invocable for Flows / Marketing Cloud journeys (async, compliance-gated) ----
    public class SmsRequest {
        @InvocableVariable(required=true label='Lead') public Id leadId;
        @InvocableVariable(required=true label='From number (our Kloudi source #)') public String source;
        @InvocableVariable(required=true label='Message') public String message;
    }

    @InvocableMethod(label='Send SMS via Kloudi (compliance-gated)'
        description='Sends an SMS to a Lead through Kloudi only if TCPA-clear, consented, not opted out, and inside quiet hours. Runs asynchronously.')
    public static void sendViaKloudi(List<SmsRequest> reqs) {
        if (reqs == null || reqs.isEmpty()) return;
        System.enqueueJob(new KloudiSendQueueable(reqs));
    }
}
