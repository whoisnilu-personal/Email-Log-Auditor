/**
 * EmailLogDownloadQueueable — Async download job enqueued by EmailLogPollService
 * when it detects that the requested email log file is Ready on the overview page.
 *
 * Runs EmailLogAcquisitionService.downloadNewLogs() in a Queueable context so that:
 *   1. The callout-before-DML rule is satisfied in its own async transaction.
 *   2. The Flow's scheduled path transaction completes cleanly (no blocking download).
 *
 * Implements Database.AllowsCallouts so it can perform HTTP callouts inside
 * the Queueable execute() method.
 */
public without sharing class EmailLogDownloadQueueable
    implements Queueable, Database.AllowsCallouts {

    @TestVisible
    private static IHttpCalloutService HTTP_OVERRIDE;
    @TestVisible
    private static IDmlService DML_OVERRIDE;

    private Set<Id> logFileIds;

    public EmailLogDownloadQueueable(Id logFileId) {
        this.logFileIds = new Set<Id>{ logFileId };
    }

    public EmailLogDownloadQueueable(Set<Id> logFileIds) {
        this.logFileIds = logFileIds;
    }

    public void execute(QueueableContext ctx) {
        IHttpCalloutService http = HTTP_OVERRIDE != null
            ? HTTP_OVERRIDE
            : new HttpCalloutService();
        IDmlService dml = DML_OVERRIDE != null
            ? DML_OVERRIDE
            : new DmlService();

        EmailLogAcquisitionService svc = new EmailLogAcquisitionService(http, dml);
        svc.downloadReadyLogs(this.logFileIds);
    }
}
