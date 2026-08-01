/**
 * SlackDigestScheduler — Schedulable that runs the daily per-office pipeline digest.
 * Schedule once (e.g. daily 8am): System.schedule('HFS Slack Daily Digest','0 0 8 * * ?', new SlackDigestScheduler());
 */
public with sharing class SlackDigestScheduler implements Schedulable {
    public void execute(SchedulableContext sc) {
        // Scope 50: a few offices post in one transaction (well under the 100-callout limit),
        // and tests run in a single execute() chunk.
        Database.executeBatch(new SlackDigestBatch(), 50);
    }
}
