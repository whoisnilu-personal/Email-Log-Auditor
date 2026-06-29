/**
 * EmailLogPollService — @InvocableMethod backing the EmailLogPollRequest__c
 * Record-Triggered Flow (scheduled path).
 *
 * REVISED ARCHITECTURE (session ID fix):
 *   The flow's scheduled path runs in a system async context where
 *   UserInfo.getSessionId() returns null. All HTTP work — and the subsequent
 *   DML (clone record, mark ready, enqueue download) — is therefore moved into
 *   EmailLogPollQueueable (Queueable + Database.AllowsCallouts).
 *
 * Flow responsibilities (minimal):
 *   1. Scheduled path fires at ScheduledTime__c.
 *   2. Calls pollStatus() which enqueues EmailLogPollQueueable.
 *   3. Flow ends — all poll logic, clone-record creation, and download
 *      enqueue happen asynchronously in the Queueable.
 *
 * Queueable responsibilities (everything with callouts):
 *   - Obtain session ID via EmailLogAcquisitionService (instance method,
 *     reuses the existing getSessionIdViaVFPage / getVFSessionCookie helpers).
 *   - GET VF overview page and parse status.
 *   - If Pending and within limit → INSERT clone EmailLogPollRequest__c.
 *   - If Ready → UPDATE EmailLogFile__c.ProcessingStatus__c = ReadyToDownload,
 *                 enqueue EmailLogDownloadQueueable.
 *   - If TimedOut / Failed → UPDATE EmailLogFile__c.ProcessingStatus__c.
 *
 * Constitution compliance:
 *   - Constructor DI (IHttpCalloutService, IDmlService) on Queueable (Principle II).
 *   - @TestVisible static overrides for test doubles (Principle III).
 *   - without sharing — internal system service (Principle IV).
 */
public without sharing class EmailLogPollService {

    // ─── Poll constants ───────────────────────────────────────────────────
    public static final Integer MAX_POLL_ATTEMPTS = 30;

    // ─── @InvocableMethod ────────────────────────────────────────────────

    public class PollStatusInput {
        @InvocableVariable(label='Poll Request Id' required=true)
        public Id pollRequestId;
    }

    public class PollStatusOutput {
        /** Always 'Enqueued' — the actual status is determined asynchronously. */
        @InvocableVariable(label='Status')
        public String status;
    }

    /**
     * Called by the Record-Triggered Flow's scheduled path.
     *
     * This method performs NO callouts and NO DML.
     * It enqueues EmailLogPollQueueable which runs in a fresh async transaction
     * where the session ID is available via the VF page trick.
     *
     * The flow therefore requires no callout=true annotation and needs no
     * DML-ordering constraints — it simply enqueues and ends.
     */
    @InvocableMethod(
        label='Enqueue Email Log Poll'
        description='Enqueues EmailLogPollQueueable to poll the VF overview page asynchronously. The Queueable handles clone creation, ready detection, and download dispatch.'
        callout=false
    )
    public static List<PollStatusOutput> pollStatus(List<PollStatusInput> inputs) {
        List<PollStatusOutput> outputs = new List<PollStatusOutput>();
        for (PollStatusInput inp : inputs) {
            PollStatusOutput out = new PollStatusOutput();
            try {
                System.enqueueJob(new EmailLogPollQueueable(inp.pollRequestId));
                out.status = 'Enqueued';
            } catch (Exception ex) {
                // Enqueue failures are non-fatal — the record is left in Pending
                // and will be retried by the next scheduled-path invocation.
                out.status = 'EnqueueFailed';
            }
            outputs.add(out);
        }
        return outputs;
    }

    // ─── Shared status parsing (used by Queueable + tests) ───────────────

    public class PollResult {
        public String status;     // 'Ready' | 'Pending' | 'Failed'
        public String fileId;     // Salesforce file ID (0BR…), null when not Ready
        public String servletPath; // servlet download path, null when not Ready
    }

    /**
     * Parses the VF overview page HTML to determine the status of the log request
     * identified by logSearchId.
     *
     * Strategy: search for the <tr> row that contains the logSearchId.
     *   - Row contains FileDownload → Ready (extract fileId + servletPath).
     *   - Row exists but no FileDownload → Pending (still generating).
     *   - logSearchId not found on page → Failed (or page error).
     *   - Blank HTML → Pending (defensive default).
     */
    public static PollResult parseStatus(String pageHtml, String logSearchId) {
        PollResult res = new PollResult();
        if (String.isBlank(pageHtml) || String.isBlank(logSearchId)) {
            res.status = 'Pending';
            return res;
        }
        if (!pageHtml.contains(logSearchId)) {
            res.status = 'Failed';
            return res;
        }
        for (String row : pageHtml.split('<tr')) {
            if (!row.contains(logSearchId)) continue;
            if (row.contains('FileDownload')) {
                res.status = 'Ready';
                Matcher m = Pattern.compile(
                    'srcUp\\((?:\'|%27)(%2Fservlet%2Fservlet\\.FileDownload%3Ffile%3D([A-Za-z0-9]+)[^\']*?)(?:\'|%27)\\)'
                ).matcher(row);
                if (m.find()) {
                    res.servletPath = EncodingUtil.urlDecode(m.group(1), 'UTF-8');
                    res.fileId = m.group(2).split('&')[0].split('%')[0];
                }
                return res;
            }
            res.status = 'Pending';
            return res;
        }
        res.status = 'Pending';
        return res;
    }
}
