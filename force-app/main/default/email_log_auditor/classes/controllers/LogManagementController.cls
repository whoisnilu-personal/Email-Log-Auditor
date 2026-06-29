/**
 * LogManagementController — Aura controller backing logManagementPanel.
 * Lists cached EmailLogFile__c rows, deletes (file + ContentDocument), and
 * retries Failed log files by re-enqueueing the batch processor.
 */
public without sharing class LogManagementController {

    @TestVisible
    private static IDmlService dml = new DmlService();

    @TestVisible
    private static Boolean BATCH_DISPATCH_DISABLED = false;

    public class CachedLogRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String label;
        @AuraEnabled public String direction;
        @AuraEnabled public String processingStatus;
        @AuraEnabled public Datetime downloadedDate;
        @AuraEnabled public Decimal rowCount;
        @AuraEnabled public Decimal matchCount;
        @AuraEnabled public Decimal errorCount;
        @AuraEnabled public Boolean canRetry;
        // T054 — US3 request date range fields
        @AuraEnabled public Datetime requestedStartDate;
        @AuraEnabled public Datetime requestedEndDate;
    }

    @AuraEnabled(cacheable=true)
    public static List<CachedLogRow> getCachedLogs(Integer pageSize, Integer pageOffset) {
        Integer ps = (pageSize == null || pageSize <= 0) ? 20 : Math.min(pageSize, 200);
        Integer po = (pageOffset == null || pageOffset < 0) ? 0 : pageOffset;

        List<CachedLogRow> out = new List<CachedLogRow>();
        for (EmailLogFile__c f : [
            SELECT Id, Label__c, Direction__c, ProcessingStatus__c,
                   DownloadedDate__c, RowCount__c, MatchCount__c, ErrorCount__c,
                   RequestedStartDate__c, RequestedEndDate__c
            FROM EmailLogFile__c
            WITH USER_MODE
            ORDER BY DownloadedDate__c DESC NULLS LAST
            LIMIT :ps OFFSET :po
        ]) {
            CachedLogRow row = new CachedLogRow();
            row.id = f.Id;
            row.label = f.Label__c;
            row.direction = f.Direction__c;
            row.processingStatus = f.ProcessingStatus__c;
            row.downloadedDate = f.DownloadedDate__c;
            row.rowCount = f.RowCount__c;
            row.matchCount = f.MatchCount__c;
            row.errorCount = f.ErrorCount__c;
            // T055 — extended canRetry: also true for US2 timed-out and failed requests
            row.canRetry = (f.ProcessingStatus__c == 'Failed'
                || f.ProcessingStatus__c == 'RequestTimedOut'
                || f.ProcessingStatus__c == 'RequestFailed');
            // T055 — map request date range fields
            row.requestedStartDate = f.RequestedStartDate__c;
            row.requestedEndDate   = f.RequestedEndDate__c;
            out.add(row);
        }
        return out;
    }

    @AuraEnabled
    public static void deleteLogFile(Id logFileId) {
        if (logFileId == null) {
            throw new AuraHandledException('logFileId is required');
        }
        List<EmailLogFile__c> existing = [
            SELECT Id FROM EmailLogFile__c WHERE Id = :logFileId WITH USER_MODE LIMIT 1
        ];
        if (existing.isEmpty()) {
            throw new AuraHandledException('Log file not found: ' + logFileId);
        }

        // Find ContentDocument(s) linked to this record and delete them
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink link : [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :logFileId
            WITH USER_MODE
        ]) {
            docIds.add(link.ContentDocumentId);
        }
        if (!docIds.isEmpty()) {
            List<ContentDocument> docs = [
                SELECT Id FROM ContentDocument WHERE Id IN :docIds
            ];
            if (!docs.isEmpty()) {
                dml.deleteRecords(docs);
            }
        }

        dml.deleteRecords(existing);
    }

    @AuraEnabled
    public static void retryProcessing(Id logFileId) {
        if (logFileId == null) {
            throw new AuraHandledException('logFileId is required');
        }
        List<EmailLogFile__c> rows = [
            SELECT Id, ProcessingStatus__c, RequestParams__c
            FROM EmailLogFile__c
            WHERE Id = :logFileId
            WITH USER_MODE
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            throw new AuraHandledException('Log file not found: ' + logFileId);
        }
        EmailLogFile__c f = rows[0];

        // T056 — handle US2 request-retry statuses
        if (f.ProcessingStatus__c == 'RequestTimedOut' || f.ProcessingStatus__c == 'RequestFailed') {
            EmailLogAcquisitionService.RequestParams params = parseRequestParams(f.RequestParams__c);
            f.ProcessingStatus__c = 'Requested';
            dml.updateRecords(new List<EmailLogFile__c>{ f });
            if (!BATCH_DISPATCH_DISABLED && !Test.isRunningTest()) {
                System.enqueueJob(new ScheduleConfigController.RequestNowJob(params));
            }
            return;
        }

        if (f.ProcessingStatus__c != 'Failed') {
            throw new AuraHandledException(
                'Only Failed, RequestTimedOut, or RequestFailed log files can be retried (current status: '
                + f.ProcessingStatus__c + ')'
            );
        }
        f.ProcessingStatus__c = 'New';
        dml.updateRecords(new List<EmailLogFile__c>{ f });

        if (!BATCH_DISPATCH_DISABLED && !Test.isRunningTest()) {
            Database.executeBatch(new EmailLogBatchProcessor(logFileId), 200);
        }
    }

    /**
     * T056 helper — parse RequestParams__c JSON into an acquisition service RequestParams.
     * Falls back to safe defaults if the JSON is missing or malformed.
     */
    private static EmailLogAcquisitionService.RequestParams parseRequestParams(String json) {
        EmailLogAcquisitionService.RequestParams p = new EmailLogAcquisitionService.RequestParams();
        if (String.isBlank(json)) {
            p.startDatetime = Datetime.now().addDays(-1);
            p.endDatetime   = Datetime.now();
            p.direction     = 'Outbound';
            return p;
        }
        try {
            Map<String, Object> m = (Map<String, Object>) System.JSON.deserializeUntyped(json);
            p.direction   = m.containsKey('direction')   ? (String) m.get('direction')   : 'Outbound';
            p.emailFilter = m.containsKey('emailFilter') ? (String) m.get('emailFilter') : null;
        } catch (Exception ex) {
            p.direction = 'Outbound';
        }
        // startDatetime/endDatetime not stored in RequestParams__c JSON —
        // will be re-determined by EmailLogAcquisitionService using the row dates.
        // Pass a 1-day window ending now as a safe fallback.
        p.startDatetime = Datetime.now().addDays(-1);
        p.endDatetime   = Datetime.now();
        return p;
    }
}
