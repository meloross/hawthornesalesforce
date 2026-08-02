/**
 * SlackService — posts messages to Slack via the Slack Web API (chat.postMessage).
 * Auth: the bot token is held on the protected Slack_Config__c custom setting (data, never in git);
 * this class sets "Authorization: Bearer <token>" directly on the request. The endpoint is called
 * directly (allow-listed by the Slack_API remote site setting) — the External Credential path was
 * abandoned because ext-cred credential injection would not resolve in this org.
 * Slack returns HTTP 200 even on logical errors, so we parse "ok" and capture "error"
 * (e.g. not_in_channel, channel_not_found, invalid_auth).
 */
public with sharing class SlackService {

    public static final String ENDPOINT = 'https://slack.com/api';

    @TestVisible
    private static final String SLACK_TOKEN_NAME = 'Slack_Bot_Token';

    /** Bot token from the secured App_Secret__c object. Read WITHOUT sharing so the callout works for
     *  any running user (trigger/queueable/batch); FLS + Private sharing keep the value out of user reach. */
    @TestVisible
    private static String botToken() {
        return new SecretStore().read(SLACK_TOKEN_NAME);
    }

    private without sharing class SecretStore {
        String read(String name) {
            List<App_Secret__c> rows = [SELECT Secret_Value__c FROM App_Secret__c WHERE Name = :name LIMIT 1];
            return rows.isEmpty() ? null : rows[0].Secret_Value__c;
        }
    }

    public class SlackResult {
        public Boolean ok = false;
        public String error;        // Slack error code when ok=false
        public Integer statusCode;
        public String channel;
        public String ts;
        public String rawResponse;
    }

    /** Slack channel id configured for an office code (Office_Distribution_Setting__mdt). Null if none/blank. */
    public static String channelForOffice(String officeCode) {
        if (String.isBlank(officeCode)) return null;
        for (Office_Distribution_Setting__mdt s : Office_Distribution_Setting__mdt.getAll().values()) {
            if (s.Office_Code__c != null && officeCode.equalsIgnoreCase(s.Office_Code__c)) {
                return String.isBlank(s.Slack_Channel_Id__c) ? null : s.Slack_Channel_Id__c;
            }
        }
        return null;
    }

    /** Human-readable office label (CMDT MasterLabel, e.g. "Tampa") for an office code; falls back to the code. */
    public static String officeLabel(String officeCode) {
        if (String.isBlank(officeCode)) return officeCode;
        for (Office_Distribution_Setting__mdt s : Office_Distribution_Setting__mdt.getAll().values()) {
            if (s.Office_Code__c != null && officeCode.equalsIgnoreCase(s.Office_Code__c)) {
                return String.isBlank(s.MasterLabel) ? officeCode : s.MasterLabel;
            }
        }
        return officeCode;
    }

    /** POST chat.postMessage with {channel, text, mrkdwn:true}. Parses ok/error. Never throws. */
    public static SlackResult postMessage(String channelId, String mrkdwnText) {
        SlackResult r = new SlackResult();
        r.channel = channelId;
        if (String.isBlank(channelId)) { r.error = 'no_channel_configured'; return r; }
        String token = botToken();
        if (String.isBlank(token)) { r.error = 'no_token_configured'; return r; }

        Map<String, Object> body = new Map<String, Object>{
            'channel' => channelId,
            'text' => mrkdwnText,
            'mrkdwn' => true
        };
        HttpRequest req = new HttpRequest();
        req.setEndpoint(ENDPOINT + '/chat.postMessage');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + token);
        req.setHeader('Content-Type', 'application/json; charset=utf-8');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(120000);
        req.setBody(JSON.serialize(body));

        try {
            HttpResponse resp = new Http().send(req);
            r.statusCode = resp.getStatusCode();
            r.rawResponse = resp.getBody();
            if (resp.getStatusCode() != 200) {
                r.error = 'http_' + resp.getStatusCode();
                return r;
            }
            Object parsed = JSON.deserializeUntyped(resp.getBody());
            if (parsed instanceof Map<String, Object>) {
                Map<String, Object> m = (Map<String, Object>) parsed;
                r.ok = (m.get('ok') == true);
                if (r.ok) {
                    if (m.get('ts') != null) r.ts = String.valueOf(m.get('ts'));
                } else {
                    r.error = (m.get('error') != null) ? String.valueOf(m.get('error')) : 'unknown_error';
                }
            } else {
                r.error = 'unparseable_response';
            }
        } catch (Exception e) {
            r.error = 'exception: ' + e.getMessage();
        }
        return r;
    }
}
