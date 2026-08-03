/**
 * KloudiInboundResource — PUBLIC inbound webhook for Kloudi SMS replies.
 *
 * Security = an unguessable token BAKED INTO THE URL PATH (the urlMapping below). Only a caller
 * configured with the exact URL reaches it; every other path returns 404. There is NO shared secret
 * for Rahul to manage. The token lives in this class in the PRIVATE repo — the accepted trade-off for
 * a no-extra-secret, unguessable-URL webhook. To rotate: change the urlMapping token + redeploy + update
 * Kloudi. Exposed unauthenticated via a Salesforce Site's guest user (see the Site setup steps).
 *
 * Always returns 200 fast so Kloudi never retry-storms: routing runs inline (a few DML) and the Slack
 * alert is enqueued (async). Errors are swallowed to a debug log — never a non-200 that triggers retries.
 */
@RestResource(urlMapping='/kloudi/inbound/6e2f5daf749068dca0e8b29ce7a33df246d7df27')
global without sharing class KloudiInboundResource {

    @HttpPost
    global static void handlePost() {
        RestResponse res = RestContext.response;
        try {
            String raw = (RestContext.request != null && RestContext.request.requestBody != null)
                ? RestContext.request.requestBody.toString() : null;
            KloudiInboundService.process(raw);
        } catch (Exception e) {
            System.debug('Kloudi inbound error: ' + e.getMessage() + ' / ' + e.getStackTraceString());
        }
        if (res != null) {
            res.addHeader('Content-Type', 'application/json');
            res.statusCode = 200;
            res.responseBody = Blob.valueOf('{"ok":true}');
        }
    }
}
