/**
 * TCPAScrubService — calls TCPA Litigator List to scrub phone numbers.
 * Auth via Named Credential (External Credential holds the Basic-auth secret).
 * Primary: callout:TCPA_Litigator_List ; on 5xx/timeout retry once on backup.
 */
public with sharing class TCPAScrubService {

    public static final String PRIMARY = 'callout:TCPA_Litigator_List';
    public static final String BACKUP  = 'callout:TCPA_Litigator_List_Backup';

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

    /** Mass scrub. POST /scrub/phones/ with phones (digits), type=all, small_list=true. */
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

        try {
            Map<String, Object> top = (Map<String, Object>) JSON.deserializeUntyped(raw);
            Object results = top.get('results');
            if (results instanceof Map<String, Object>) {
                Map<String, Object> rm = (Map<String, Object>) results;
                Boolean singleShape = rm.containsKey('clean') || rm.containsKey('is_bad_number');
                if (singleShape && digits.size() == 1) {
                    out.put(digits[0], parseNode(digits[0], rm, raw));
                } else {
                    for (String key : rm.keySet()) {
                        if (rm.get(key) instanceof Map<String, Object>) {
                            String ph = normalize(key);
                            if (ph != null) out.put(ph, parseNode(ph, (Map<String, Object>) rm.get(key), raw));
                        }
                    }
                }
            } else if (results instanceof List<Object>) {
                for (Object o : (List<Object>) results) {
                    if (o instanceof Map<String, Object>) {
                        Map<String, Object> m = (Map<String, Object>) o;
                        String ph = normalize(String.valueOf(m.get('phone')));
                        if (ph != null) out.put(ph, parseNode(ph, m, raw));
                    }
                }
            }
        } catch (Exception e) {
            for (String d : digits) { out.put(d, errorResult(d, 'Parse error: ' + e.getMessage(), raw)); }
            return out;
        }

        // Any requested digit with no result -> Error
        for (String d : digits) {
            if (!out.containsKey(d)) out.put(d, errorResult(d, 'No result returned for phone', raw));
        }
        return out;
    }

    /** Single scrub. POST /scrub/phone/ — used for the one-number sanity test. */
    public static ScrubResult scrubOne(String phone) {
        String d = normalize(phone);
        if (d == null) return errorResult(phone, 'Blank phone', null);
        Map<String, Object> body = new Map<String, Object>{ 'phone' => d, 'type' => 'all' };
        String payload = JSON.serialize(body);

        HttpResponse resp = doCallout(PRIMARY + '/scrub/phone/', payload);
        if (resp == null || resp.getStatusCode() >= 500) {
            resp = doCallout(BACKUP + '/scrub/phone/', payload);
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
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Accept', 'application/json');
            req.setTimeout(120000);
            req.setBody(payload);
            return new Http().send(req);
        } catch (Exception e) {
            return null;
        }
    }

    private static ScrubResult parseNode(String phone, Map<String, Object> m, String raw) {
        ScrubResult r = new ScrubResult();
        r.phone = phone;
        r.rawResponse = raw;
        String cleanStr = String.valueOf(m.get('clean'));
        r.clean = (cleanStr == '1' || cleanStr == 'true');
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
