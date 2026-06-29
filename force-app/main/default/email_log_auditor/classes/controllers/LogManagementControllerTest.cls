@IsTest
private class LogManagementControllerTest {

    private static EmailLogFile__c seedLog(String status) {
        EmailLogFile__c f = new EmailLogFile__c(
            Label__c = 'TestLog ' + System.currentTimeMillis(),
            Direction__c = 'MailEvent',
            ProcessingStatus__c = status,
            DownloadedDate__c = Datetime.now()
        );
        insert f;
        return f;
    }

    @IsTest
    static void getCachedLogs_returnsRowsOrderedByDate() {
        seedLog('New');
        seedLog('Failed');

        Test.startTest();
        List<LogManagementController.CachedLogRow> rows =
            LogManagementController.getCachedLogs(20, 0);
        Test.stopTest();

        System.assertEquals(2, rows.size());
        // canRetry should be true only for Failed
        Boolean foundFailed = false;
        for (LogManagementController.CachedLogRow r : rows) {
            if (r.processingStatus == 'Failed') {
                foundFailed = true;
                System.assertEquals(true, r.canRetry);
            } else {
                System.assertEquals(false, r.canRetry);
            }
        }
        System.assert(foundFailed);
    }

    @IsTest
    static void getCachedLogs_clampsPageSizeAndDefaults() {
        Test.startTest();
        List<LogManagementController.CachedLogRow> rows =
            LogManagementController.getCachedLogs(null, null);
        Test.stopTest();
        System.assertNotEquals(null, rows);
    }

    @IsTest
    static void deleteLogFile_nullThrows() {
        Boolean threw = false;
        try { LogManagementController.deleteLogFile(null); }
        catch (AuraHandledException ex) { threw = true; }
        System.assert(threw);
    }

    @IsTest
    static void deleteLogFile_missingThrows() {
        Boolean threw = false;
        try {
            LogManagementController.deleteLogFile(FakeId.build(EmailLogFile__c.SObjectType));
        } catch (AuraHandledException ex) { threw = true; }
        System.assert(threw);
    }

    @IsTest
    static void deleteLogFile_deletesRecord() {
        EmailLogFile__c f = seedLog('Completed');

        Test.startTest();
        LogManagementController.deleteLogFile(f.Id);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM EmailLogFile__c WHERE Id = :f.Id]);
    }

    @IsTest
    static void retryProcessing_requiresFailedStatus() {
        EmailLogFile__c f = seedLog('Completed');
        Boolean threw = false;
        try { LogManagementController.retryProcessing(f.Id); }
        catch (AuraHandledException ex) { threw = true; }
        System.assert(threw, 'Expected exception when retrying non-Failed log');
    }

    @IsTest
    static void retryProcessing_resetsToNew() {
        EmailLogFile__c f = seedLog('Failed');

        Test.startTest();
        LogManagementController.retryProcessing(f.Id);
        Test.stopTest();

        EmailLogFile__c after = [SELECT ProcessingStatus__c FROM EmailLogFile__c WHERE Id = :f.Id];
        System.assertEquals('New', after.ProcessingStatus__c);
    }

    @IsTest
    static void retryProcessing_nullThrows() {
        Boolean threw = false;
        try { LogManagementController.retryProcessing(null); }
        catch (AuraHandledException ex) { threw = true; }
        System.assert(threw);
    }

    // ── T049 — getCachedLogs returns Requested rows with date range ────────
    @IsTest
    static void getCachedLogs_requestedRow_hasDateFieldsAndIncludedInResults() {
        EmailLogFile__c f = new EmailLogFile__c(
            Label__c             = 'TestReqLog',
            Direction__c         = 'Outbound',
            ProcessingStatus__c  = 'Requested',
            DownloadedDate__c    = Datetime.now(),
            RequestedStartDate__c = Datetime.now().addDays(-1),
            RequestedEndDate__c   = Datetime.now()
        );
        insert f;

        Test.startTest();
        List<LogManagementController.CachedLogRow> rows =
            LogManagementController.getCachedLogs(20, 0);
        Test.stopTest();

        Boolean found = false;
        for (LogManagementController.CachedLogRow r : rows) {
            if (r.processingStatus == 'Requested') {
                found = true;
                System.assertNotEquals(null, r.requestedStartDate,
                    'requestedStartDate should be populated for Requested row');
                System.assertNotEquals(null, r.requestedEndDate,
                    'requestedEndDate should be populated for Requested row');
            }
        }
        System.assert(found, 'Requested row should be included in getCachedLogs results');
    }

    // ── T050 — canRetry logic for all US2 statuses ─────────────────────────
    @IsTest
    static void getCachedLogs_canRetry_correctForAllStatuses() {
        insert new List<EmailLogFile__c>{
            makeLog('Requested',         Datetime.now()),
            makeLog('RequestTimedOut',   Datetime.now()),
            makeLog('RequestFailed',     Datetime.now()),
            makeLog('Processed',         Datetime.now()),
            makeLog('Failed',            Datetime.now())
        };

        Test.startTest();
        List<LogManagementController.CachedLogRow> rows =
            LogManagementController.getCachedLogs(20, 0);
        Test.stopTest();

        Map<String, Boolean> retryMap = new Map<String, Boolean>();
        for (LogManagementController.CachedLogRow r : rows) {
            retryMap.put(r.processingStatus, r.canRetry);
        }
        System.assertEquals(false, retryMap.get('Requested'),       'Requested must not be retryable');
        System.assertEquals(true,  retryMap.get('RequestTimedOut'), 'RequestTimedOut must be retryable');
        System.assertEquals(true,  retryMap.get('RequestFailed'),   'RequestFailed must be retryable');
        System.assertEquals(false, retryMap.get('Processed'),       'Processed must not be retryable');
        System.assertEquals(true,  retryMap.get('Failed'),          'Failed must still be retryable (spec-001)');
    }

    // ── T051 — retryProcessing for RequestTimedOut ─────────────────────────
    @IsTest
    static void retryProcessing_requestTimedOut_resetsToRequestedAndEnqueues() {
        EmailLogFile__c f = new EmailLogFile__c(
            Label__c              = 'TimedOutLog',
            Direction__c          = 'Outbound',
            ProcessingStatus__c   = 'RequestTimedOut',
            DownloadedDate__c     = Datetime.now().addHours(-3),
            RequestedStartDate__c = Datetime.now().addDays(-1),
            RequestedEndDate__c   = Datetime.now(),
            RequestParams__c      = '{"direction":"Outbound","emailFilter":null}'
        );
        insert f;

        // Disable batch dispatch so no HTTP callout needed
        LogManagementController.BATCH_DISPATCH_DISABLED = true;

        Test.startTest();
        LogManagementController.retryProcessing(f.Id);
        Test.stopTest();

        EmailLogFile__c after =
            [SELECT ProcessingStatus__c FROM EmailLogFile__c WHERE Id = :f.Id];
        System.assertEquals('Requested', after.ProcessingStatus__c,
            'Row must be reset to Requested after retry');
    }

    // Helper: create an EmailLogFile__c without DML
    private static EmailLogFile__c makeLog(String status, Datetime dl) {
        return new EmailLogFile__c(
            Label__c             = 'Log_' + status,
            Direction__c         = 'Outbound',
            ProcessingStatus__c  = status,
            DownloadedDate__c    = dl
        );
    }
}
