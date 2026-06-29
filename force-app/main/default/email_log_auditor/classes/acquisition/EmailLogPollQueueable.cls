/**
 * EmailLogPollQueueable — Async Queueable that performs the actual poll callout
 * and all DML for the EmailLogPollRequest__c polling chain.
 *
 * Why a Queueable?
 *   UserInfo.getSessionId() returns null in a Record-Triggered Flow's scheduled-path
 *   async transaction, making it impossible to construct the VF session cookie there.
 *   A Queueable runs in its own fresh async transaction where the session ID IS
 *   available via the EmailLogAcquisitionService.getSessionIdViaVFPage() helper.
 *
 * Execution contract:
 *   Phase 1 — Callouts only:
 *     a. Build VF session cookie via getSessionIdViaVFPage() + getVFSessionCookie().
 *     b. GET VF overview page and parse status with EmailLogPollService.parseStatus().
 *   Phase 2 — DML only (after all callouts complete):
 *     - Ready   → UPDATE EmailLogFile__c.ProcessingStatus = ReadyToDownload,
 *                 UPDATE EmailLogPollRequest__c.PollStatus = Ready,
 *                 enqueue EmailLogDownloadQueueable.
 *     - Pending → INSERT clone EmailLogPollRequest__c (AttemptCount+1, ScheduledTime+1min).
 *     - TimedOut → UPDATE EmailLogFile__c.ProcessingStatus = RequestTimedOut,
 *                  UPDATE EmailLogPollRequest__c.PollStatus = TimedOut.
 *     - Failed  → UPDATE EmailLogFile__c.ProcessingStatus = RequestFailed,
 *                  UPDATE EmailLogPollRequest__c.PollStatus = Failed.
 *
 * Constitution compliance:
 *   - Constructor DI for IHttpCalloutService + IDmlService (Principle II).
 *   - @TestVisible static overrides for test doubles (Principle III).
 *   - without sharing — internal system infrastructure (Principle IV).
 */
public without sharing class EmailLogPollQueueable
    implements Queueable, Database.AllowsCallouts {

    // ─── DI overrides (Principle III) ────────────────────────────────────
    @TestVisible
    private static IHttpCalloutService HTTP_OVERRIDE;
    @TestVisible
    private static IDmlService DML_OVERRIDE;
    @TestVisible
    private static EmailLogAcquisitionService SERVICE_OVERRIDE;

    // ─── State ────────────────────────────────────────────────────────────
    private final Id pollRequestId;

    // ─── Constructor ──────────────────────────────────────────────────────
    public EmailLogPollQueueable(Id pollRequestId) {
        this.pollRequestId = pollRequestId;
    }

    // ─── Queueable entry ─────────────────────────────────────────────────
    public void execute(QueueableContext ctx) {
        IHttpCalloutService http = HTTP_OVERRIDE != null
            ? HTTP_OVERRIDE
            : new HttpCalloutService();
        IDmlService dml = DML_OVERRIDE != null
            ? DML_OVERRIDE
            : new DmlService();
        EmailLogAcquisitionService svc = SERVICE_OVERRIDE != null
            ? SERVICE_OVERRIDE
            : new EmailLogAcquisitionService(http, dml);

        run(pollRequestId, svc, dml);
    }

    // ─── Core poll logic (package-private for unit tests) ────────────────

    @TestVisible
    static void run(
        Id pollRequestId,
        EmailLogAcquisitionService svc,
        IDmlService dml
    ) {
        // ── Query the poll record ─────────────────────────────────────────
        List<EmailLogPollRequest__c> recs = [
            SELECT Id, LogSearchId__c, EmailLogFile__c, AttemptCount__c,
                   AuditLogEntry__c
            FROM EmailLogPollRequest__c
            WHERE Id = :pollRequestId
            LIMIT 1
        ];
        if (recs.isEmpty()) return;

        EmailLogPollRequest__c rec = recs[0];
        Integer attemptCount = rec.AttemptCount__c != null
            ? rec.AttemptCount__c.intValue()
            : 0;

        // ── Guard: max attempts ───────────────────────────────────────────
        if (attemptCount >= EmailLogPollService.MAX_POLL_ATTEMPTS) {
            markLogFile(rec.EmailLogFile__c, 'RequestTimedOut', dml);
            updatePollRecord(rec.Id, 'TimedOut', dml);
            return;
        }

        // ─── Phase 1: Callouts ────────────────────────────────────────────
        EmailLogPollService.PollResult pollResult;
        try {
            String instanceDomain = svc.getInstanceDomain();
            String sessionId      = svc.getSessionIdViaVFPage(instanceDomain);
            String vfCookies      = svc.getVFSessionCookie(instanceDomain, sessionId);
            String pageHtml       = svc.fetchVFOverviewPage(instanceDomain, vfCookies);
            pollResult = EmailLogPollService.parseStatus(pageHtml, rec.LogSearchId__c);
        } catch (Exception ex) {
            // Callout failure → mark failed; do not retry automatically
            markLogFile(rec.EmailLogFile__c, 'RequestFailed', dml);
            updatePollRecord(rec.Id, 'Failed', dml);
            return;
        }

        // ─── Phase 2: DML only ────────────────────────────────────────────
        if (pollResult.status == 'Ready') {
            // Update FileId + ServletPath on the EmailLogFile__c if we got them
            List<EmailLogFile__c> logFiles = [
                SELECT Id, ProcessingStatus__c, FileId__c, ServletPath__c
                FROM EmailLogFile__c
                WHERE Id = :rec.EmailLogFile__c
                LIMIT 1
            ];
            if (!logFiles.isEmpty()) {
                EmailLogFile__c lf = logFiles[0];
                lf.ProcessingStatus__c = 'ReadyToDownload';
                if (String.isNotBlank(pollResult.fileId)) {
                    lf.FileId__c       = pollResult.fileId;
                    lf.ServletPath__c  = pollResult.servletPath;
                }
                dml.updateRecords(new List<EmailLogFile__c>{ lf });
            }
            updatePollRecord(rec.Id, 'Ready', dml);
            System.enqueueJob(new EmailLogDownloadQueueable(rec.EmailLogFile__c));

        } else if (pollResult.status == 'Pending') {
            // Clone the poll record with incremented attempt count and next scheduled time
            dml.insertRecords(new List<EmailLogPollRequest__c>{
                new EmailLogPollRequest__c(
                    AuditLogEntry__c = rec.AuditLogEntry__c,
                    EmailLogFile__c  = rec.EmailLogFile__c,
                    LogSearchId__c   = rec.LogSearchId__c,
                    PollStatus__c    = 'Pending',
                    AttemptCount__c  = attemptCount + 1,
                    ScheduledTime__c = Datetime.now().addMinutes(1)
                )
            });

        } else {
            // Failed
            markLogFile(rec.EmailLogFile__c, 'RequestFailed', dml);
            updatePollRecord(rec.Id, 'Failed', dml);
        }
    }

    // ─── DML helpers ─────────────────────────────────────────────────────

    private static void markLogFile(
        Id logFileId,
        String status,
        IDmlService dml
    ) {
        if (logFileId == null) return;
        List<EmailLogFile__c> rows = [
            SELECT Id, ProcessingStatus__c
            FROM EmailLogFile__c
            WHERE Id = :logFileId
            LIMIT 1
        ];
        if (rows.isEmpty()) return;
        rows[0].ProcessingStatus__c = status;
        dml.updateRecords(rows);
    }

    private static void updatePollRecord(
        Id pollRecId,
        String status,
        IDmlService dml
    ) {
        dml.updateRecords(new List<EmailLogPollRequest__c>{
            new EmailLogPollRequest__c(
                Id            = pollRecId,
                PollStatus__c = status
            )
        });
    }
}
