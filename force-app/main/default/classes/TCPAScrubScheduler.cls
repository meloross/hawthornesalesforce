/**
 * TCPAScrubScheduler — schedule to run the TCPA scrub batch (scope 2000).
 * e.g. System.schedule('TCPA Scrub Nightly', '0 0 2 * * ?', new TCPAScrubScheduler());
 */
public with sharing class TCPAScrubScheduler implements Schedulable {
    public void execute(SchedulableContext sc) {
        Database.executeBatch(new TCPAScrubBatch(), 2000);
    }
}
