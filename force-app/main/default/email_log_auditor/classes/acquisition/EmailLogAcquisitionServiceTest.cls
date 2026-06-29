/**
 * Stub-API tests for EmailLogAcquisitionService (T019).
 * All HTTP via IHttpCalloutService stub, all DML via IDmlService stub — zero real callouts/DML.
 */
@IsTest
private class EmailLogAcquisitionServiceTest {

    // ── HTTP Stub ──────────────────────────────────────────────────────────
    private class HttpStub implements StubProvider {
        Map<String, HttpResponse> responsesByUrlContains = new Map<String, HttpResponse>();
        HttpResponse defaultResponse;
        Integer callCount = 0;

        public Object handleMethodCall(
            Object stubbedObject, String stubbedMethodName, Type returnType,
            List<Type> listOfParamTypes, List<String> listOfParamNames, List<Object> listOfArgs
        ) {
            callCount++;
            HttpRequest req = (HttpRequest) listOfArgs[0];
            String url = req.getEndpoint();
            for (String key : responsesByUrlContains.keySet()) {
                if (url.contains(key)) return responsesByUrlContains.get(key);
            }
            return defaultResponse != null ? defaultResponse : ok('OK');
        }
    }

    // ── DML Stub ───────────────────────────────────────────────────────────
    private class DmlStub implements StubProvider {
        public List<List<SObject>> insertedBatches = new List<List<SObject>>();
        public List<List<SObject>> updatedBatches = new List<List<SObject>>();

        public Object handleMethodCall(
            Object stubbedObject, String stubbedMethodName, Type returnType,
            List<Type> listOfParamTypes, List<String> listOfParamNames, List<Object> listOfArgs
        ) {
            List<SObject> records = (List<SObject>) listOfArgs[0];
            if (stubbedMethodName == 'insertRecords') {
                // Assign fake IDs so downstream code that reads .Id keeps working
                Schema.SObjectType sot = records.isEmpty() ? null : records[0].getSObjectType();
                for (Integer i = 0; i < records.size(); i++) {
                    if (sot != null) records[i].Id = FakeId.build(sot);
                }
                insertedBatches.add(records);
            } else if (stubbedMethodName == 'updateRecords') {
                updatedBatches.add(records);
            }
            return null;
        }
    }

    private static HttpResponse ok(String body) {
        HttpResponse r = new HttpResponse();
        r.setStatusCode(200);
        r.setBody(body);
        r.setHeader('Set-Cookie', 'sid=VFSESS123; oid=00DXX0000000001');
        return r;
    }

    private static HttpResponse okZip(Blob zipBody) {
        HttpResponse r = new HttpResponse();
        r.setStatusCode(200);
        r.setHeader('Content-Type', 'application/zip');
        r.setHeader('Content-Disposition', 'attachment; filename="EmailLog_0BRC.zip"');
        r.setBodyAsBlob(zipBody);
        return r;
    }

    private static HttpResponse ok200OverviewWithFile(String fileId) {
        HttpResponse r = new HttpResponse();
        r.setStatusCode(200);
        r.setBody(
            '<html>srcUp(%27%2Fservlet%2Fservlet.FileDownload%3Ffile%3D' + fileId
            + '%26isdtp%3Dp1%27) title="Daily Log ' + fileId + '"</html>'
        );
        r.setHeader('Set-Cookie', 'sid=VFSESS123; oid=00DXX0000000001');
        return r;
    }

    private static Blob buildZipWithCsv(String csv) {
        Compression.ZipWriter w = new Compression.ZipWriter();
        w.addEntry('EmailLog_0BRC.csv', Blob.valueOf(csv));
        return w.getArchive();
    }

    // ── Helpers ────────────────────────────────────────────────────────────
    private static EmailLogAcquisitionService newSvc(HttpStub h, DmlStub d) {
        IHttpCalloutService http = (IHttpCalloutService) Test.createStub(IHttpCalloutService.class, h);
        IDmlService dml = (IDmlService) Test.createStub(IDmlService.class, d);
        return new EmailLogAcquisitionService(http, dml);
    }

    /** Creates a service from a sequenced stub (T014-T018) */
    private static EmailLogAcquisitionService newSvcSeq(SequencedHttpStub h, DmlStub d) {
        IHttpCalloutService http = (IHttpCalloutService) Test.createStub(IHttpCalloutService.class, h);
        IDmlService dml = (IDmlService) Test.createStub(IDmlService.class, d);
        return new EmailLogAcquisitionService(http, dml);
    }

    // ── T014 — Sequenced stub + ViewState/redirect response factories ──────
    /**
     * Serves responses in declaration order; avoids URL-key ambiguity when
     * both GET and POST hit the same editEmailLogSearch.apexp endpoint.
     */
    private class SequencedHttpStub implements StubProvider {
        private List<HttpResponse> responses;
        private Integer idx = 0;
        public Integer callCount = 0;

        SequencedHttpStub(List<HttpResponse> responses) {
            this.responses = responses;
        }

        public Object handleMethodCall(
            Object stubbedObject, String stubbedMethodName, Type returnType,
            List<Type> listOfParamTypes, List<String> listOfParamNames, List<Object> listOfArgs
        ) {
            callCount++;
            if (idx < responses.size()) return responses[idx++];
            HttpResponse empty = new HttpResponse();
            empty.setStatusCode(200);
            empty.setBody('');
            return empty;
        }
    }

    /** HTML page with all four ViewState hidden inputs (GET response for editEmailLogSearch.apexp) */
    private static HttpResponse okViewStatePage() {
        HttpResponse r = new HttpResponse();
        r.setStatusCode(200);
        r.setHeader('Set-Cookie', 'sid=VFSESS123; oid=00DXX0000000001');
        r.setBody(
            '<html><body>' +
            '<input type="hidden" name="com.salesforce.visualforce.ViewState" value="TESTVS123==" />' +
            '<input type="hidden" name="com.salesforce.visualforce.ViewStateVersion" value="TESTVSV" />' +
            '<input type="hidden" name="com.salesforce.visualforce.ViewStateMAC" value="TESTMAC==" />' +
            '<input type="hidden" name="com.salesforce.visualforce.ViewStateCSRF" value="TESTCSRF==" />' +
            '<form id="theForm"></form>' +
            '</body></html>'
        );
        return r;
    }

    /** HTTP 302 to EmailLogSearchOverview (successful POST response) */
    private static HttpResponse ok302Redirect() {
        HttpResponse r = new HttpResponse();
        r.setStatusCode(302);
        r.setHeader('Location', '/email/logs/EmailLogSearchOverview?isdtp=p1');
        r.setBody('');
        return r;
    }

    /** HTTP 200 with Salesforce errorMsg div (failed POST response) */
    private static HttpResponse ok200WithError(String errorMsg) {
        HttpResponse r = new HttpResponse();
        r.setStatusCode(200);
        r.setHeader('Set-Cookie', 'sid=VFSESS123; oid=00DXX0000000001');
        r.setBody(
            '<html><body>' +
            '<div class="errorMsg">' + errorMsg + '</div>' +
            '</body></html>'
        );
        return r;
    }

    // ── Tests ──────────────────────────────────────────────────────────────
    @IsTest
    static void listAvailableLogs_returnsParsedEntries() {
        HttpStub h = new HttpStub();
        h.responsesByUrlContains.put('frontdoor.jsp', ok('frontdoor'));
        h.responsesByUrlContains.put('EmailLogSearchOverview', ok200OverviewWithFile('0BRC2000000ABC'));
        DmlStub d = new DmlStub();

        Test.startTest();
        List<EmailLogAcquisitionService.EmailLogEntry> entries = newSvc(h, d).listAvailableLogs();
        Test.stopTest();

        System.assertEquals(1, entries.size(), 'Should parse one entry');
        System.assertEquals('0BRC2000000ABC', entries[0].fileId);
    }

    @IsTest
    static void isFirstRun_returnsTrue_whenNoEmailLogFileExists() {
        Test.startTest();
        Boolean firstRun = newSvc(new HttpStub(), new DmlStub()).isFirstRun();
        Test.stopTest();
        System.assertEquals(true, firstRun, 'No EmailLogFile__c rows ⇒ first run');
    }

    @IsTest
    static void downloadAvailableLogs_skipsAlreadyCachedFiles() {
        // Seed cache with the file we'll pretend is available
        EmailLogFile__c cached = new EmailLogFile__c(
            FileId__c = '0BRC2000000ABC', Label__c = 'Cached', DownloadedDate__c = Datetime.now(),
            ProcessingStatus__c = 'Processed', Direction__c = 'Outbound'
        );
        insert cached;

        HttpStub h = new HttpStub();
        h.responsesByUrlContains.put('frontdoor.jsp', ok('frontdoor'));
        h.responsesByUrlContains.put('EmailLogSearchOverview', ok200OverviewWithFile('0BRC2000000ABC'));
        DmlStub d = new DmlStub();

        Test.startTest();
        EmailLogAcquisitionService.AcquisitionResult result = newSvc(h, d).downloadNewLogs();
        Test.stopTest();

        System.assertEquals(0, result.downloadedCount, 'Cached file must be skipped');
        System.assertEquals(1, result.skippedCount);
        System.assertEquals(0, d.insertedBatches.size(), 'No DML expected for cache hit');
    }

    @IsTest
    static void downloadAvailableLogs_downloadsAndCachesNewFile() {
        Blob zip = buildZipWithCsv('Date,From,To,Status\n2026-04-01,a@x.com,b@y.com,Delivered');
        HttpStub h = new HttpStub();
        h.responsesByUrlContains.put('frontdoor.jsp', ok('frontdoor'));
        h.responsesByUrlContains.put('EmailLogSearchOverview', ok200OverviewWithFile('0BRC2000000NEW'));
        h.responsesByUrlContains.put('servlet.FileDownload', okZip(zip));
        DmlStub d = new DmlStub();

        Test.startTest();
        EmailLogAcquisitionService.AcquisitionResult result = newSvc(h, d).downloadNewLogs();
        Test.stopTest();

        System.assertEquals(1, result.downloadedCount);
        System.assertEquals(0, result.skippedCount);
        // Three insert batches expected: ContentVersion, ContentDocumentLink, EmailLogFile__c
        System.assert(d.insertedBatches.size() >= 1, 'At least one insert performed');
        Boolean foundLogFile = false;
        for (List<SObject> batch : d.insertedBatches) {
            if (!batch.isEmpty() && batch[0] instanceof EmailLogFile__c) {
                foundLogFile = true;
                EmailLogFile__c lf = (EmailLogFile__c) batch[0];
                System.assertEquals('0BRC2000000NEW', lf.FileId__c);
                System.assertEquals('Processing', lf.ProcessingStatus__c);
            }
        }
        System.assertEquals(true, foundLogFile, 'EmailLogFile__c row must be inserted');
    }

    // ── T015 — submitRequestCallouts: 30-day window rejection ─────────────
    @IsTest
    static void submitRequestCallouts_windowOutside30Days_returnsFailedWithNoCallout() {
        SequencedHttpStub h = new SequencedHttpStub(new List<HttpResponse>());
        DmlStub d = new DmlStub();

        EmailLogAcquisitionService.RequestParams params = new EmailLogAcquisitionService.RequestParams();
        params.startDatetime = Datetime.now().addDays(-31);
        params.endDatetime   = Datetime.now().addDays(-30);
        params.direction     = 'Outbound';

        Test.startTest();
        List<EmailLogAcquisitionService.SubmittedRequest> results =
            newSvcSeq(h, d).submitRequestCallouts(params);
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Must return exactly one failed SubmittedRequest');
        System.assertEquals(false, results[0].success, 'Out-of-range window must be success=false');
        System.assert(results[0].failureMessage != null &&
            results[0].failureMessage.toLowerCase().contains('30'),
            'Failure message must reference the 30-day constraint');
        System.assertEquals(0, h.callCount, 'No callouts must be made for rejected window (US1 AC5 / FR-004)');
    }

    // ── T016 — submitRequestCallouts: single-window success ───────────────
    @IsTest
    static void submitRequestCallouts_singleWindow_successOn302() {
        SequencedHttpStub h = new SequencedHttpStub(new List<HttpResponse>{
            ok('frontdoor'), okViewStatePage(), ok302Redirect()
        });
        DmlStub d = new DmlStub();

        EmailLogAcquisitionService.RequestParams params = new EmailLogAcquisitionService.RequestParams();
        params.startDatetime = Datetime.now().addDays(-1);
        params.endDatetime   = Datetime.now();
        params.direction     = 'Outbound';

        Test.startTest();
        List<EmailLogAcquisitionService.SubmittedRequest> results =
            newSvcSeq(h, d).submitRequestCallouts(params);
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Single window must produce exactly one result');
        System.assertEquals(true, results[0].success,
            'HTTP 302 redirect must be treated as success (US1 AC1 / R-005)');
        System.assertEquals(3, h.callCount, 'Expected 3 callouts: frontdoor.jsp + GET ViewState + POST');
    }

    // ── T017 — submitRequestCallouts: POST returns 200 with error ─────────
    @IsTest
    static void submitRequestCallouts_postReturns200WithError_returnsFailedRequest() {
        SequencedHttpStub h = new SequencedHttpStub(new List<HttpResponse>{
            ok('frontdoor'), okViewStatePage(), ok200WithError('Date is out of range')
        });
        DmlStub d = new DmlStub();

        EmailLogAcquisitionService.RequestParams params = new EmailLogAcquisitionService.RequestParams();
        params.startDatetime = Datetime.now().addDays(-1);
        params.endDatetime   = Datetime.now();
        params.direction     = 'Outbound';

        Test.startTest();
        List<EmailLogAcquisitionService.SubmittedRequest> results =
            newSvcSeq(h, d).submitRequestCallouts(params);
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(false, results[0].success,
            'HTTP 200 with errorMsg div must be treated as failure (R-005)');
        System.assert(results[0].failureMessage != null &&
            results[0].failureMessage.contains('Date is out of range'),
            'Failure message must contain the Salesforce error text extracted from errorMsg div');
    }

    // ── T018 — submitRequestCallouts: 8-day range splits into 2 sub-windows ─
    @IsTest
    static void submitRequestCallouts_8DayRange_splitsTwoWindows() {
        SequencedHttpStub h = new SequencedHttpStub(new List<HttpResponse>{
            ok('frontdoor'),
            okViewStatePage(), ok302Redirect(),  // sub-window 1
            okViewStatePage(), ok302Redirect()   // sub-window 2
        });
        DmlStub d = new DmlStub();

        EmailLogAcquisitionService.RequestParams params = new EmailLogAcquisitionService.RequestParams();
        params.endDatetime   = Datetime.now();
        params.startDatetime = params.endDatetime.addDays(-8);  // 192 hours > 168-hour (7-day) limit
        params.direction     = 'Outbound';

        Test.startTest();
        List<EmailLogAcquisitionService.SubmittedRequest> results =
            newSvcSeq(h, d).submitRequestCallouts(params);
        Test.stopTest();

        System.assertEquals(2, results.size(),
            '8-day range must auto-split into 2 sub-windows of ≤7 days each (spec FR-003)');
        System.assertEquals(5, h.callCount,
            'Expected 5 callouts: 1 frontdoor.jsp + 2×GET ViewState + 2×POST');
    }

    // ── T019 — persistRequestOutcomes: success outcome creates Requested row ─
    @IsTest
    static void persistRequestOutcomes_successOutcome_insertsRequestedLogFileRow() {
        DmlStub d = new DmlStub();

        EmailLogAcquisitionService.SubmittedRequest sr = new EmailLogAcquisitionService.SubmittedRequest();
        sr.requestedStartDatetime = Datetime.now().addDays(-1);
        sr.requestedEndDatetime   = Datetime.now();
        sr.direction   = 'Outbound';
        sr.emailFilter = null;
        sr.success     = true;

        Test.startTest();
        newSvcSeq(new SequencedHttpStub(new List<HttpResponse>()), d)
            .persistRequestOutcomes(new List<EmailLogAcquisitionService.SubmittedRequest>{ sr });
        Test.stopTest();

        Boolean foundRequestedRow = false;
        for (List<SObject> batch : d.insertedBatches) {
            if (!batch.isEmpty() && batch[0] instanceof EmailLogFile__c) {
                EmailLogFile__c lf = (EmailLogFile__c) batch[0];
                if (lf.ProcessingStatus__c == 'Requested') {
                    foundRequestedRow = true;
                    System.assertNotEquals(null, lf.RequestedStartDate__c,
                        'RequestedStartDate__c must be populated on Requested row (spec US1 AC1 / FR-005)');
                    System.assertNotEquals(null, lf.RequestedEndDate__c,
                        'RequestedEndDate__c must be populated on Requested row');
                    System.assertNotEquals(null, lf.RequestParams__c,
                        'RequestParams__c JSON must be stored for retry capability');
                }
            }
        }
        System.assertEquals(true, foundRequestedRow,
            'Must insert EmailLogFile__c with ProcessingStatus__c = Requested for success outcome');
    }

    // ── T020 — persistRequestOutcomes: failure creates RequestFailed + AuditLogEntry ─
    @IsTest
    static void persistRequestOutcomes_failureOutcome_insertsRequestFailedRowAndAuditEntry() {
        DmlStub d = new DmlStub();

        EmailLogAcquisitionService.SubmittedRequest sr = new EmailLogAcquisitionService.SubmittedRequest();
        sr.requestedStartDatetime = Datetime.now().addDays(-1);
        sr.requestedEndDatetime   = Datetime.now();
        sr.direction       = 'Outbound';
        sr.success         = false;
        sr.failureMessage  = 'Date is out of range — Salesforce error';

        Test.startTest();
        newSvcSeq(new SequencedHttpStub(new List<HttpResponse>()), d)
            .persistRequestOutcomes(new List<EmailLogAcquisitionService.SubmittedRequest>{ sr });
        Test.stopTest();

        Boolean foundFailedRow  = false;
        Boolean foundAuditEntry = false;
        for (List<SObject> batch : d.insertedBatches) {
            if (batch.isEmpty()) continue;
            if (batch[0] instanceof EmailLogFile__c) {
                EmailLogFile__c lf = (EmailLogFile__c) batch[0];
                if (lf.ProcessingStatus__c == 'RequestFailed') foundFailedRow = true;
            }
            if (batch[0] instanceof AuditLogEntry__c) {
                AuditLogEntry__c entry = (AuditLogEntry__c) batch[0];
                if (entry.FailureReason__c != null &&
                    entry.FailureReason__c.contains('Date is out of range')) {
                    foundAuditEntry = true;
                }
            }
        }
        System.assertEquals(true, foundFailedRow,
            'Must insert EmailLogFile__c with ProcessingStatus__c = RequestFailed (spec US1 AC5)');
        System.assertEquals(true, foundAuditEntry,
            'Must insert AuditLogEntry__c with Salesforce error text for failed request');
    }

    // ── T021 — resolveTimedOutRequests: stale row transitions to RequestTimedOut ─
    @IsTest
    static void resolveTimedOutRequests_staleRequestedRow_updatedToRequestTimedOut() {
        // Real insert required — resolveTimedOutRequests() queries EmailLogFile__c directly
        EmailLogFile__c staleRow = new EmailLogFile__c(
            Label__c            = 'Requested: stale test row',
            ProcessingStatus__c = 'Requested',
            DownloadedDate__c   = Datetime.now().addHours(-3),  // 3h ago > default 2h timeout
            Direction__c        = 'Outbound'
        );
        insert staleRow;

        DmlStub d = new DmlStub();

        Test.startTest();
        newSvcSeq(new SequencedHttpStub(new List<HttpResponse>()), d).resolveTimedOutRequests();
        Test.stopTest();

        System.assertEquals(1, d.updatedBatches.size(),
            'One update batch expected for the stale row (spec FR-017 / US3 AC3)');
        EmailLogFile__c updated = (EmailLogFile__c) d.updatedBatches[0][0];
        System.assertEquals('RequestTimedOut', updated.ProcessingStatus__c,
            'Stale Requested row must transition to RequestTimedOut');
    }

    // ── T022 — resolveTimedOutRequests: no stale rows → no DML ───────────
    @IsTest
    static void resolveTimedOutRequests_noStaleRows_noDmlCalled() {
        DmlStub d = new DmlStub();

        Test.startTest();
        newSvcSeq(new SequencedHttpStub(new List<HttpResponse>()), d).resolveTimedOutRequests();
        Test.stopTest();

        System.assertEquals(0, d.updatedBatches.size(),
            'resolveTimedOutRequests() must not call DML when no stale rows exist (guard-clause coverage)');
    }
}
