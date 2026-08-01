/**
 * TCPAScrubInvocable — lets a Flow (or another process) kick off the TCPA scrub batch.
 */
public with sharing class TCPAScrubInvocable {
    @InvocableMethod(label='Run TCPA Scrub Batch' description='Runs the TCPA scrub batch over Pending leads (scope 2000). Returns the batch job Id.')
    public static List<String> run(List<String> ignored) {
        Id jobId = Database.executeBatch(new TCPAScrubBatch(), 2000);
        return new List<String>{ String.valueOf(jobId) };
    }
}
