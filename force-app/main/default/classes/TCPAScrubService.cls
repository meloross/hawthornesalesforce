/**
 * TCPAScrubService — calls TCPA Litigator List to scrub phone numbers.
 * Auth: the org's External Credential will not inject Basic auth (same failure seen with Slack), so we
 * call the raw vendor URL and build the "Authorization: Basic base64(user:pass)" header ourselves from
 * the App_Secret__c record Name='TCPA_API' (Username__c + Secret_Value__c). The two hosts are allow-listed
 * by the TCPA_Litigator_List / TCPA_Litigator_List_Backup Remote Site Settings.
 * Primary: https://api.tcpalitigatorlist.com ; on 5xx/timeout retry once on the api101 backup host.
 */
public with sharing class TCPAScrubService {

    public static final String PRIMARY = 'https://api.tcpalitigatorlist.com';
    public static final String BACKUP  = 'https://api101.tcpalitigatorlist.com';
    @TestVisible private static final String TCPA_SECRET_NAME = 'TCPA_API';

    public class ScrubResult {
        public String phone;
        public Boolean clean = false;
        public Boolean isBadNumber = false;
        public String status;
        public List<String> statusArray = new List<String>();
        public String phoneType;
        public Boolean isError = false;
        public String errorMessage;
        public String rawResponse;
    }

    /** Digits only. Returns null for blank. */
    public static String normalize(String phone) {
        if (String.isBlank(phone)) return null;
        String digits = phone.replaceAll('[^0-9]', '');
        return String.isBlank(digits) ? null : digits;
    }

    /**
     * Mass scrub. POST /scrub/phones/ with phones (digits), type=all, small_list=true.
     *
     * REAL mass response shape (confirmed from pilot log, Job_Key 707fn00000rh09vAAA) — NOT the
     * single-endpoint "results" shape:
     *   { "meta":{...}, "match_statistics":[...], "match":[ {phone_number,status,...} ], "clean":{ "<phone>":{...} } }
     *   - phone present under top-level "clean"    -> Clear
     *   - phone present in the top-level "match" array -> Do Not Contact
     *   - phone in NEITHER                          -> Error (safe default; absence never becomes Clear)
     * Response keys carry a leading 1 (11-digit, e.g. "19125062784") while the sent digits may be
     * 10-digit, so ALL matching is done on the last 10 digits (see last10()).
     */
    public static Map<String, ScrubResult> scrubPhones(List<String> phones) {
        Map<String, ScrubResult> out = new Map<String, ScrubResult>();
        List<String> digits = new List<String>();
        Set<String> seen = new Set<String>();
        if (phones != null) {
            for (String p : phones) {
                String d = normalize(p);
                if (d != null && !seen.contains(d)) { seen.add(d); digits.add(d); }
            }
        }
        if (digits.isEmpty()) return out;

        Map<String, Object> body = new Map<String, Object>{
            'phones' => digits, 'type' => 'all', 'small_list' => true
        };
        String payload = JSON.serialize(body);

        HttpResponse resp = doCallout(PRIMARY + '/scrub/phones/', payload);
        if (resp == null || resp.getStatusCode() >= 500) {
            resp = doCallout(BACKUP + '/scrub/phones/', payload);
        }
        String raw = (resp != null) ? resp.getBody() : null;

        if (resp == null || resp.getStatusCode() >= 300) {
            String msg = (resp == null) ? 'Callout failed / timeout' : ('HTTP ' + resp.getStatusCode());
            for (String d : digits) { out.put(d, errorResult(d, msg, raw)); }
            return out;
        }

        // Index the response by last-10-digits: clean phones -> Clear; match phones -> DNC node.
        Set<String> cleanByLast10 = new Set<String>();
        Map<String, Map<String, Object>> matchByLast10 = new Map<String, Map<String, Object>>();
        try {
            Map<String, Object> top = (Map<String, Object>) JSON.deserializeUntyped(raw);
            // Top-level vendor error (e.g. {"error":"You do not have enough credits"}) -> every phone Error.
            if (top.containsKey('error') && top.get('error') != null) {
                String em = String.valueOf(top.get('error'));
                for (String d : digits) { out.put(d, errorResult(d, em, raw)); }
                return out;
            }
            indexClean(top.get('clean'), cleanByLast10);
            indexMatch(top.get('match'), matchByLast10);
        } catch (Exception e) {
            for (String d : digits) { out.put(d, errorResult(d, 'Parse error: ' + e.getMessage(), raw)); }
            return out;
        }

        for (String d : digits) {
            String key = last10(d);
            if (key != null && matchByLast10.containsKey(key)) {
                out.put(d, matchNode(d, matchByLast10.get(key), raw));   // in "match" => Do Not Contact
            } else if (key != null && cleanByLast10.contains(key)) {
                out.put(d, cleanNode(d, raw));                            // in "clean" => Clear
            } else {
                out.put(d, errorResult(d, 'No result returned for phone', raw));  // absent => Error
            }
        }
        return out;
    }

    /** Canonical phone key = last 10 digits (strips an optional leading 1 / country code on either side). */
    @TestVisible
    private static String last10(String phone) {
        if (phone == null) return null;
        String d = phone.replaceAll('[^0-9]', '');
        if (String.isBlank(d)) return null;
        return (d.length() > 10) ? d.substring(d.length() - 10) : d;
    }

    /** Top-level "clean" is a map keyed by phone (values like {"phone_number":..}); tolerate a list too. */
    private static void indexClean(Object cleanObj, Set<String> sink) {
        if (cleanObj instanceof Map<String, Object>) {
            Map<String, Object> cm = (Map<String, Object>) cleanObj;
            for (String k : cm.keySet()) {
                String key = last10(k);                              // the map key is normally the phone
                if (key == null) key = last10(extractPhone(cm.get(k)));
                if (key != null) sink.add(key);
            }
        } else if (cleanObj instanceof List<Object>) {
            for (Object el : (List<Object>) cleanObj) {
                String key = last10(extractPhone(el));
                if (key != null) sink.add(key);
            }
        }
    }

    /** Top-level "match" is an array of litigator/DNC hits; tolerate a phone-keyed map too. */
    private static void indexMatch(Object matchObj, Map<String, Map<String, Object>> sink) {
        if (matchObj instanceof List<Object>) {
            for (Object el : (List<Object>) matchObj) { addMatch(el, sink); }
        } else if (matchObj instanceof Map<String, Object>) {
            Map<String, Object> mm = (Map<String, Object>) matchObj;
            for (String k : mm.keySet()) {
                Object node = mm.get(k);
                String key = last10(k);                              // key may itself be the phone
                if (key != null) {
                    sink.put(key, (node instanceof Map<String, Object>)
                        ? (Map<String, Object>) node : new Map<String, Object>());
                } else {
                    addMatch(node, sink);
                }
            }
        }
    }

    private static void addMatch(Object el, Map<String, Map<String, Object>> sink) {
        String key = last10(extractPhone(el));
        if (key == null) return;
        sink.put(key, (el instanceof Map<String, Object>) ? (Map<String, Object>) el : new Map<String, Object>());
    }

    /** Pull a phone from an element: phone_number/phone/number field on a map, else digits of a scalar. */
    private static String extractPhone(Object el) {
        if (el instanceof Map<String, Object>) {
            Map<String, Object> m = (Map<String, Object>) el;
            for (String k : new List<String>{'phone_number', 'phone', 'number'}) {
                if (m.get(k) != null) {
                    String d = normalize(String.valueOf(m.get(k)));
                    if (d != null) return d;
                }
            }
            return null;
        }
        return (el != null) ? normalize(String.valueOf(el)) : null;
    }

    /** Phone found under "clean" => clean=true (Clear). */
    private static ScrubResult cleanNode(String phone, String raw) {
        ScrubResult r = new ScrubResult();
        r.phone = phone;
        r.rawResponse = raw;
        r.clean = true;
        r.isBadNumber = false;
        r.isError = false;
        return r;
    }

    /** Phone found in "match" => not clean (Do Not Contact); carry status/status_array/type/bad defensively. */
    private static ScrubResult matchNode(String phone, Map<String, Object> m, String raw) {
        ScrubResult r = new ScrubResult();
        r.phone = phone;
        r.rawResponse = raw;
        r.clean = false;          // present in "match" => litigator/DNC hit => never Clear
        r.isError = false;
        if (m != null) {
            Object bad = m.get('is_bad_number');
            r.isBadNumber = (bad != null) && (String.valueOf(bad) == 'true' || String.valueOf(bad) == '1');
            if (m.get('status') != null) r.status = String.valueOf(m.get('status'));
            if (m.get('phone_type') != null) r.phoneType = String.valueOf(m.get('phone_type'));
            if (m.get('status_array') instanceof List<Object>) {
                for (Object s : (List<Object>) m.get('status_array')) r.statusArray.add(String.valueOf(s));
            }
        }
        return r;
    }

    /** Single scrub. POST /scrub/phone/ — used for the one-number sanity test. */
    public static ScrubResult scrubOne(String phone) {
        String d = normalize(phone);
        if (d == null) return errorResult(phone, 'Blank phone', null);
        // Single endpoint is WordPress/form-based: send form-urlencoded phone_number={digits}&type=all.
        String payload = 'phone_number=' + EncodingUtil.urlEncode(d, 'UTF-8') + '&type=all';

        HttpResponse resp = doCallout(PRIMARY + '/scrub/phone/', payload, 'application/x-www-form-urlencoded');
        if (resp == null || resp.getStatusCode() >= 500) {
            resp = doCallout(BACKUP + '/scrub/phone/', payload, 'application/x-www-form-urlencoded');
        }
        String raw = (resp != null) ? resp.getBody() : null;
        if (resp == null || resp.getStatusCode() >= 300) {
            String msg = (resp == null) ? 'Callout failed / timeout' : ('HTTP ' + resp.getStatusCode());
            return errorResult(d, msg, raw);
        }
        try {
            Map<String, Object> top = (Map<String, Object>) JSON.deserializeUntyped(raw);
            Object results = top.get('results');
            Map<String, Object> node = (results instanceof Map<String, Object>)
                ? (Map<String, Object>) results : top;
            return parseNode(d, node, raw);
        } catch (Exception e) {
            return errorResult(d, 'Parse error: ' + e.getMessage(), raw);
        }
    }

    private static HttpResponse doCallout(String endpoint, String payload) {
        return doCallout(endpoint, payload, 'application/json');
    }

    private static HttpResponse doCallout(String endpoint, String payload, String contentType) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod('POST');
            req.setHeader('Authorization', basicAuthHeader());   // Basic auth built here, not by an External Credential
            req.setHeader('Content-Type', contentType);
            req.setHeader('Accept', 'application/json');
            req.setTimeout(120000);
            req.setBody(payload);
            return new Http().send(req);
        } catch (Exception e) {
            return null;
        }
    }

    // ---- Basic auth built in Apex (the org's External Credential won't inject it) ----
    private static String cachedAuthHeader;
    @TestVisible
    private static String basicAuthHeader() {
        if (cachedAuthHeader != null) return cachedAuthHeader;
        String user = '';
        String pass = '';
        for (App_Secret__c s : new SecretStore().read(TCPA_SECRET_NAME)) {
            user = (s.Username__c != null) ? s.Username__c.trim() : '';
            pass = (s.Secret_Value__c != null) ? s.Secret_Value__c.trim() : '';
        }
        cachedAuthHeader = 'Basic ' + EncodingUtil.base64Encode(Blob.valueOf(user + ':' + pass));
        return cachedAuthHeader;
    }

    /** Reads the credential in system context (without sharing) so the batch/scheduler works for any
     *  running user, while FLS + Private sharing keep the value out of reps' reach (mirrors SlackService). */
    private without sharing class SecretStore {
        List<App_Secret__c> read(String name) {
            return [SELECT Username__c, Secret_Value__c FROM App_Secret__c WHERE Name = :name LIMIT 1];
        }
    }

    private static ScrubResult parseNode(String phone, Map<String, Object> m, String raw) {
        ScrubResult r = new ScrubResult();
        r.phone = phone;
        r.rawResponse = raw;
        // Explicit vendor error (e.g. {"error":"You do not have enough credits"}) -> Error, non-callable.
        if (m.containsKey('error') && m.get('error') != null) {
            r.isError = true;
            r.errorMessage = String.valueOf(m.get('error'));
            return r;
        }
        // 'clean' must be explicitly present and parseable as 0/1 (or true/false).
        // Missing or unparseable -> Error (never allow an ambiguous response to become Clear or DNC).
        Object cleanRaw = m.get('clean');
        if (!m.containsKey('clean') || cleanRaw == null) {
            r.isError = true;
            r.errorMessage = 'Missing clean field in response';
            return r;
        }
        String cleanStr = String.valueOf(cleanRaw);
        Boolean cleanIsOne  = (cleanStr == '1' || cleanStr == 'true');
        Boolean cleanIsZero = (cleanStr == '0' || cleanStr == 'false');
        if (!cleanIsOne && !cleanIsZero) {
            r.isError = true;
            r.errorMessage = 'Unparseable clean value: ' + cleanStr;
            return r;
        }
        r.clean = cleanIsOne;   // Clear is possible ONLY when clean is explicitly 1/true
        String badStr = String.valueOf(m.get('is_bad_number'));
        r.isBadNumber = (badStr == 'true' || badStr == '1');
        if (m.get('status') != null) r.status = String.valueOf(m.get('status'));
        if (m.get('phone_type') != null) r.phoneType = String.valueOf(m.get('phone_type'));
        if (m.get('status_array') instanceof List<Object>) {
            for (Object s : (List<Object>) m.get('status_array')) r.statusArray.add(String.valueOf(s));
        }
        return r;
    }

    private static ScrubResult errorResult(String phone, String msg, String raw) {
        ScrubResult r = new ScrubResult();
        r.phone = phone;
        r.isError = true;
        r.errorMessage = msg;
        r.rawResponse = raw;
        return r;
    }
}
