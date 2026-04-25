/*------------------------------------------------------------------------------------
Developer:    GitHub Copilot
Class:        EmailLogFileDownloaderQueueable
Description:  Async Queueable wrapper for EmailLogFileService.
              Enqueue this class to download Salesforce Email Log Files in the
              background (avoids mixed DML / governor limit issues when called
              from trigger context).

              Usage:
                // Download all logs, attach to Task 'a01xx...'
                System.enqueueJob(new EmailLogFileDownloaderQueueable(
                    null,       // all directions
                    'a01xx000000xxxx',
                    true        // save as ContentDocument Files
                ));

                // Download all logs, list only (no save)
                System.enqueueJob(new EmailLogFileDownloaderQueueable(
                    null, null, false
                ));

Test Class:   EmailLogFileServiceTest
History
Date           Author             Comments
--------------------------------------------------------------------------------------
25-04-2026    GitHub Copilot     Initial Release
------------------------------------------------------------------------------------*/
public without sharing class EmailLogFileDownloaderQueueable
    implements Queueable, Database.AllowsCallouts {

    /**
     * Optional filter: 'Inbound', 'Outbound', or null (= all directions).
     * Filtering is done client-side by matching the log entry label after listing.
     */
    private String directionFilter;

    /**
     * SObject record ID to attach downloaded CSV files to.
     * Pass null to download without attaching to a record.
     */
    private Id parentRecordId;

    /**
     * When true, save each CSV as a ContentDocument (File) linked to parentRecordId.
     */
    private Boolean saveAsFile;

    // ─────────────────────────────────────────────────────────────────────────
    // Constructors
    // ─────────────────────────────────────────────────────────────────────────

    public EmailLogFileDownloaderQueueable(
        String  directionFilter,
        Id      parentRecordId,
        Boolean saveAsFile
    ) {
        this.directionFilter = directionFilter;
        this.parentRecordId  = parentRecordId;
        this.saveAsFile      = saveAsFile == true;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Queueable interface
    // ─────────────────────────────────────────────────────────────────────────

    public void execute(QueueableContext ctx) {
        List<EmailLogFileService.DownloadResult> results =
            EmailLogFileService.downloadAllLogs(parentRecordId, saveAsFile);

        List<String> summary = new List<String>();
        for (EmailLogFileService.DownloadResult r : results) {
            Boolean include = (directionFilter == null)
                || r.entry.label.containsIgnoreCase(directionFilter);

            if (!include) continue;

            if (r.success) {
                summary.add('OK  | ' + r.entry.label + ' → ' + r.csvFilename
                    + (r.contentDocumentId != null ? ' [doc:' + r.contentDocumentId + ']' : ''));
            } else {
                summary.add('ERR | ' + r.entry.label + ' → ' + r.errorMessage);
            }
        }

        // Log summary via a platform event or debug — adjust as needed for your org
        System.debug('EmailLogDownload results:\n' + String.join(summary, '\n'));
    }
}