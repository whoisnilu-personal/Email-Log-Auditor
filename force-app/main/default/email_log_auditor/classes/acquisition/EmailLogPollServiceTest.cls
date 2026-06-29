@IsTest
private class EmailLogPollServiceTest {

    // ─── Shared test data helpers ─────────────────────────────────────────

    private static EmailLogPollRequest__c createPollRequest(Integer attemptCount) {
        AuditLogEntry__c audit = new AuditLogEntry__c(
            EntryType__c     = 'PollRequest',
            FailureReason__c = 'unit test poll'
        );
        insert audit;

        EmailLogFile__c logFile = new EmailLogFile__c(
            Label__c            = 'Test Log',
            Direction__c        = 'Outbound',
            ProcessingStatus__c = 'Requested',
            LogSearchId__c      = '0IVg50000000X7F',
            DownloadedDate__c   = Datetime.now()
        );
        insert logFile;

        EmailLogPollRequest__c pr = new EmailLogPollRequest__c(
            AuditLogEntry__c = audit.Id,
            EmailLogFile__c  = logFile.Id,
            LogSearchId__c   = '0IVg50000000X7F',
            PollStatus__c    = 'Pending',
            AttemptCount__c  = attemptCount,
            ScheduledTime__c = Datetime.now().addMinutes(1)
        );
        insert pr;
        return pr;
    }

    // ─── HTTP stubs ───────────────────────────────────────────────────────

    /** Stub: frontdoor.jsp returns Set-Cookie; overview page is Ready. */
    private class ReadyPageStub implements StubProvider {
        private Integer callCount = 0;
        public Object handleMethodCall(
            Object stubbedObject, String stubbedMethodName, Type returnType,
            List<Type> listOfParamTypes, List<String> listOfParamNames,
            List<Object> listOfArgs
        ) {
            callCount++;
            HttpResponse res = new HttpResponse();
            if (callCount == 1) {
                // frontdoor.jsp
                res.setStatusCode(200);
                res.setHeader('Set-Cookie', 'sid=TESTSID; oid=TESTOID');
            } else {
                // overview page — has a FileDownload row containing the logSearchId
                res.setStatusCode(200);
                res.setBody(
                    '<html><body><table>' +
                    '<tr><td>0IVg50000000X7F</td>' +
                    '<td><a href="javascript:srcUp(\'%2Fservlet%2Fservlet.FileDownload%3Ffile%3D0BRG0000001test\')">Download</a></td></tr>' +
                    '</table></body></html>'
                );
            }
            return res;
        }
    }

    /** Stub: frontdoor.jsp ok; overview page Pending (logSearchId present but no FileDownload). */
    private class PendingPageStub implements StubProvider {
        public Object handleMethodCall(
            Object stubbedObject, String stubbedMethodName, Type returnType,
            List<Type> listOfParamTypes, List<String> listOfParamNames,
            List<Object> listOfArgs
        ) {
            HttpResponse res = new HttpResponse();
            HttpRequest req = (HttpRequest) listOfArgs[0];
            if (req.getEndpoint().contains('frontdoor')) {
                res.setStatusCode(200);
                res.setHeader('Set-Cookie', 'sid=SID; oid=OID');
            } else {
                res.setStatusCode(200);
                // logSearchId present in page but no FileDownload in its row
                res.setBody(
                    '<html><body><table>' +
                    '<tr><td>0IVg50000000X7F</td><td>Generating...</td></tr>' +
                    '</table></body></html>'
                );
            }
            return res;
        }
    }

    /** Stub: network error on any request. */
    private class ErrorStub implements StubProvider {
        public Object handleMethodCall(
            Object stubbedObject, String stubbedMethodName, Type returnType,
            List<Type> listOfParamTypes, List<String> listOfParamNames,
            List<Object> listOfArgs
        ) {
            throw new EmailLogAcquisitionService.EmailLogServiceException('Simulated network error');
        }
    }

    // ─── Tests: parseStatus() ────────────────────────────────────────────

    @IsTest
    static void parseStatus_returnsReady_whenRowHasFileDownload() {
        String html =
            '<html><table>' +
            '<tr><td>0IVg50000000X7F</td>' +
            '<td><a href="javascript:srcUp(\'%2Fservlet%2Fservlet.FileDownload%3Ffile%3D0BRG0000001test\')">DL</a></td></tr>' +
            '</table></html>';
        EmailLogPollService.PollResult res = EmailLogPollService.parseStatus(html, '0IVg50000000X7F');
        System.assertEquals('Ready', res.status);
        System.assertEquals('0BRG0000001test', res.fileId);
    }

    @IsTest
    static void parseStatus_returnsPending_whenRowHasNoFileDownload() {
        String html =
            '<html><table>' +
            '<tr><td>0IVg50000000X7F</td><td>Generating...</td></tr>' +
            '</table></html>';
        EmailLogPollService.PollResult res = EmailLogPollService.parseStatus(html, '0IVg50000000X7F');
        System.assertEquals('Pending', res.status);
    }

    @IsTest
    static void parseStatus_returnsFailed_whenLogSearchIdNotOnPage() {
        String html = '<html><body><p>Some other content</p></body></html>';
        EmailLogPollService.PollResult res = EmailLogPollService.parseStatus(html, '0IVg50000000X7F');
        System.assertEquals('Failed', res.status);
    }

    @IsTest
    static void parseStatus_returnsPending_whenBlankHtml() {
        EmailLogPollService.PollResult res = EmailLogPollService.parseStatus('', '0IVg50000000X7F');
        System.assertEquals('Pending', res.status);
    }

    // ─── Tests: @InvocableMethod (enqueue only) ───────────────────────────

    @IsTest
    static void pollStatus_enqueuesQueueable() {
        EmailLogPollRequest__c pr = createPollRequest(0);

        Test.startTest();
        EmailLogPollService.PollStatusInput inp = new EmailLogPollService.PollStatusInput();
        inp.pollRequestId = pr.Id;
        List<EmailLogPollService.PollStatusOutput> results =
            EmailLogPollService.pollStatus(
                new List<EmailLogPollService.PollStatusInput>{ inp }
            );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals('Enqueued', results[0].status,
            'InvocableMethod should return Enqueued when job is queued successfully');
    }

    // ─── Tests: EmailLogPollQueueable.run() ───────────────────────────────

    @IsTest
    static void pollQueueable_marksTimedOut_whenAttemptLimitReached() {
        EmailLogPollRequest__c pr = createPollRequest(EmailLogPollService.MAX_POLL_ATTEMPTS);
        IDmlService dml = new DmlService();
        EmailLogAcquisitionService svc = new EmailLogAcquisitionService(
            new HttpCalloutService(), dml
        );
        EmailLogAcquisitionService.VF_SESSION_ID_OVERRIDE = 'FAKE_SESSION';

        Test.startTest();
        EmailLogPollQueueable.run(pr.Id, svc, dml);
        Test.stopTest();

        EmailLogPollRequest__c updated = [
            SELECT PollStatus__c FROM EmailLogPollRequest__c WHERE Id = :pr.Id
        ];
        System.assertEquals('TimedOut', updated.PollStatus__c);

        EmailLogFile__c lf = [
            SELECT ProcessingStatus__c FROM EmailLogFile__c WHERE Id = :pr.EmailLogFile__c
        ];
        System.assertEquals('RequestTimedOut', lf.ProcessingStatus__c);
    }

    @IsTest
    static void pollQueueable_createsClonesRecord_whenPending() {
        EmailLogPollRequest__c pr = createPollRequest(0);
        IHttpCalloutService httpStub =
            (IHttpCalloutService) Test.createStub(IHttpCalloutService.class, new PendingPageStub());
        IDmlService dml = new DmlService();
        EmailLogAcquisitionService svc = new EmailLogAcquisitionService(httpStub, dml);
        EmailLogAcquisitionService.VF_SESSION_ID_OVERRIDE = 'FAKE_SESSION';

        Integer before = [
            SELECT COUNT() FROM EmailLogPollRequest__c WHERE EmailLogFile__c = :pr.EmailLogFile__c
        ];

        Test.startTest();
        EmailLogPollQueueable.run(pr.Id, svc, dml);
        Test.stopTest();

        Integer after = [
            SELECT COUNT() FROM EmailLogPollRequest__c WHERE EmailLogFile__c = :pr.EmailLogFile__c
        ];
        System.assertEquals(before + 1, after, 'A clone record should be created when status is Pending');
    }

    @IsTest
    static void pollQueueable_marksReadyAndEnqueuesDownload_whenReady() {
        EmailLogPollRequest__c pr = createPollRequest(0);
        IHttpCalloutService httpStub =
            (IHttpCalloutService) Test.createStub(IHttpCalloutService.class, new ReadyPageStub());
        IDmlService dml = new DmlService();
        EmailLogAcquisitionService svc = new EmailLogAcquisitionService(httpStub, dml);
        EmailLogAcquisitionService.VF_SESSION_ID_OVERRIDE = 'FAKE_SESSION';

        Test.startTest();
        EmailLogPollQueueable.run(pr.Id, svc, dml);
        Test.stopTest();

        EmailLogFile__c lf = [
            SELECT ProcessingStatus__c FROM EmailLogFile__c WHERE Id = :pr.EmailLogFile__c
        ];
        System.assertEquals('ReadyToDownload', lf.ProcessingStatus__c,
            'EmailLogFile__c should be marked ReadyToDownload when poll returns Ready');

        EmailLogPollRequest__c updated = [
            SELECT PollStatus__c FROM EmailLogPollRequest__c WHERE Id = :pr.Id
        ];
        System.assertEquals('Ready', updated.PollStatus__c);
    }

    @IsTest
    static void pollQueueable_marksFailed_onNetworkError() {
        EmailLogPollRequest__c pr = createPollRequest(0);
        IHttpCalloutService httpStub =
            (IHttpCalloutService) Test.createStub(IHttpCalloutService.class, new ErrorStub());
        IDmlService dml = new DmlService();
        EmailLogAcquisitionService svc = new EmailLogAcquisitionService(httpStub, dml);
        EmailLogAcquisitionService.VF_SESSION_ID_OVERRIDE = 'FAKE_SESSION';

        Test.startTest();
        EmailLogPollQueueable.run(pr.Id, svc, dml);
        Test.stopTest();

        EmailLogPollRequest__c updated = [
            SELECT PollStatus__c FROM EmailLogPollRequest__c WHERE Id = :pr.Id
        ];
        System.assertEquals('Failed', updated.PollStatus__c);
    }

    @IsTest
    static void pollQueueable_doesNothing_whenRecordNotFound() {
        Id fakeId = FakeId.build(EmailLogPollRequest__c.SObjectType);
        IDmlService dml = new DmlService();
        EmailLogAcquisitionService svc = new EmailLogAcquisitionService(
            new HttpCalloutService(), dml
        );

        Test.startTest();
        // Should not throw
        EmailLogPollQueueable.run(fakeId, svc, dml);
        Test.stopTest();

        System.assert(true, 'Non-existent poll request ID should be handled gracefully');
    }
}
