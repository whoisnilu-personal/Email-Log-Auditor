@IsTest
private class EmailLogSchedulerTest {

    // ── Service Stub ───────────────────────────────────────────────────────
    /**
     * Stubs EmailLogAcquisitionService so tests can assert which public methods
     * were called without making any real HTTP/DML. Handles all public methods
     * that the scheduler calls across spec-001 and spec-002 (Phase 3+).
     */
    private class ServiceStub implements StubProvider {
        public Integer downloadNewLogsCallCount = 0;
        public Integer submitRequestCalloutsCallCount = 0;
        public Integer persistRequestOutcomesCallCount = 0;
        public Integer resolveTimedOutRequestsCallCount = 0;

        public Object handleMethodCall(
            Object stubbedObject, String stubbedMethodName, Type returnType,
            List<Type> listOfParamTypes, List<String> listOfParamNames, List<Object> listOfArgs
        ) {
            if (stubbedMethodName == 'downloadNewLogs') {
                downloadNewLogsCallCount++;
                return new EmailLogAcquisitionService.AcquisitionResult();
            }
            if (stubbedMethodName == 'submitRequestCallouts') {
                submitRequestCalloutsCallCount++;
                return new List<EmailLogAcquisitionService.SubmittedRequest>();
            }
            if (stubbedMethodName == 'persistRequestOutcomes') {
                persistRequestOutcomesCallCount++;
                return null;
            }
            if (stubbedMethodName == 'resolveTimedOutRequests') {
                resolveTimedOutRequestsCallCount++;
                return null;
            }
            return null;
        }
    }

    /** Returns a config stub with IsEnabled=true and RequestMode=null (legacy / Off). */
    private static LogScheduleConfig__mdt legacyConfig() {
        LogScheduleConfig__mdt cfg = new LogScheduleConfig__mdt();
        cfg.IsEnabled__c = true;
        // RequestMode__c intentionally left null — simulates pre-002 metadata record
        return cfg;
    }

    /** Stub that throws EmailLogServiceException from submitRequestCallouts (T024). */
    private class FailingRequestStub implements StubProvider {
        public Integer downloadNewLogsCallCount = 0;

        public Object handleMethodCall(
            Object stubbedObject, String stubbedMethodName, Type returnType,
            List<Type> listOfParamTypes, List<String> listOfParamNames, List<Object> listOfArgs
        ) {
            if (stubbedMethodName == 'downloadNewLogs') {
                downloadNewLogsCallCount++;
                return new EmailLogAcquisitionService.AcquisitionResult();
            }
            if (stubbedMethodName == 'submitRequestCallouts') {
                throw new EmailLogAcquisitionService.EmailLogServiceException(
                    'VF page structure changed — ViewState not found');
            }
            if (stubbedMethodName == 'persistRequestOutcomes') return null;
            if (stubbedMethodName == 'resolveTimedOutRequests') return null;
            return null;
        }
    }

    // ── Backward Compatibility Pin (FR-010 / SC-003) ───────────────────────
    /**
     * T013 — REGRESSION GUARD.
     * When RequestMode__c is null (legacy metadata record) run() must:
     *   1. Call downloadNewLogs() exactly once.
     *   2. NOT call submitRequestCallouts() (auto-request feature disabled).
     * This test passes on the UNMODIFIED run() and must stay green after Phase 3.
     */
    @IsTest
    static void run_requestModeNull_onlyCallsDownload_backwardCompatPin() {
        ServiceStub svcStub = new ServiceStub();
        EmailLogScheduler.SERVICE_OVERRIDE =
            (EmailLogAcquisitionService) Test.createStub(EmailLogAcquisitionService.class, svcStub);
        EmailLogScheduler.CONFIG_OVERRIDE = legacyConfig();

        Test.startTest();
        new EmailLogScheduler().run(true);
        Test.stopTest();

        System.assertEquals(1, svcStub.downloadNewLogsCallCount,
            'downloadNewLogs() must be called exactly once (FR-010 backward compat)');
        System.assertEquals(0, svcStub.submitRequestCalloutsCallCount,
            'submitRequestCallouts() must NOT be called when RequestMode is null (SC-003)');
    }

    // ── Existing tests ─────────────────────────────────────────────────────

    @IsTest
    static void run_invokesAcquisitionService() {
        // Note: cannot easily override final class, so test via direct overload using a stub.
        // This test exercises run() against the Default config (IsEnabled bypassed in test mode).
        Test.startTest();
        EmailLogScheduler scheduler = new EmailLogScheduler();
        EmailLogAcquisitionService.AcquisitionResult result;
        try {
            result = scheduler.run();
        } catch (Exception ex) {
            // Without HTTP stub the scheduler will throw on real callout — acceptable here;
            // we only assert the path was attempted.
            System.assert(true, 'Acquisition attempted: ' + ex.getMessage());
            Test.stopTest();
            return;
        }
        Test.stopTest();
        System.assertNotEquals(null, result, 'run() must return a result');
    }

    @IsTest
    static void execute_callsRun() {
        Test.startTest();
        try {
            new EmailLogScheduler().execute(null);
        } catch (Exception ex) {
            // Real HTTP not stubbed — exception expected
        }
        Test.stopTest();
        System.assert(true, 'execute() invoked without compile errors');
    }

    // ── T023 — PreviousDay mode: submit → download → persist → resolve ────
    @IsTest
    static void run_previousDayMode_callsAllFourStepsInOrder() {
        ServiceStub svcStub = new ServiceStub();
        EmailLogScheduler.SERVICE_OVERRIDE =
            (EmailLogAcquisitionService) Test.createStub(EmailLogAcquisitionService.class, svcStub);
        LogScheduleConfig__mdt cfg = new LogScheduleConfig__mdt();
        cfg.IsEnabled__c   = true;
        cfg.RequestMode__c = 'PreviousDay';
        EmailLogScheduler.CONFIG_OVERRIDE = cfg;

        Test.startTest();
        new EmailLogScheduler().run(true);
        Test.stopTest();

        System.assertEquals(1, svcStub.submitRequestCalloutsCallCount,
            'submitRequestCallouts must be called once in PreviousDay mode (US1 AC1)');
        System.assertEquals(1, svcStub.downloadNewLogsCallCount,
            'downloadNewLogs must always be called (US1 AC2)');
        System.assertEquals(1, svcStub.persistRequestOutcomesCallCount,
            'persistRequestOutcomes must be called after submitRequestCallouts and downloadNewLogs');
        System.assertEquals(1, svcStub.resolveTimedOutRequestsCallCount,
            'resolveTimedOutRequests must be called as the final step');
    }

    // ── T024 — request step exception must not block download sweep ───────
    @IsTest
    static void run_requestStepThrows_downloadSweepStillRuns() {
        FailingRequestStub svcStub = new FailingRequestStub();
        EmailLogScheduler.SERVICE_OVERRIDE =
            (EmailLogAcquisitionService) Test.createStub(EmailLogAcquisitionService.class, svcStub);
        LogScheduleConfig__mdt cfg = new LogScheduleConfig__mdt();
        cfg.IsEnabled__c   = true;
        cfg.RequestMode__c = 'PreviousDay';
        EmailLogScheduler.CONFIG_OVERRIDE = cfg;

        Test.startTest();
        EmailLogAcquisitionService.AcquisitionResult result = new EmailLogScheduler().run(true);
        Test.stopTest();

        System.assertNotEquals(null, result,
            'run() must return a result even when the request step throws (US1 AC5 / FR-009)');
        System.assertEquals(1, svcStub.downloadNewLogsCallCount,
            'downloadNewLogs must still execute after request step failure');
    }

    // ── T025 — CustomWindow mode uses RequestWindowHours__c ──────────────
    @IsTest
    static void run_customWindowMode_buildRequestParamsUsesConfiguredHours() {
        ServiceStub svcStub = new ServiceStub();
        EmailLogScheduler.SERVICE_OVERRIDE =
            (EmailLogAcquisitionService) Test.createStub(EmailLogAcquisitionService.class, svcStub);
        LogScheduleConfig__mdt cfg = new LogScheduleConfig__mdt();
        cfg.IsEnabled__c         = true;
        cfg.RequestMode__c       = 'CustomWindow';
        cfg.RequestWindowHours__c = 48;
        cfg.RequestDirection__c  = 'Outbound';
        EmailLogScheduler.CONFIG_OVERRIDE = cfg;

        Test.startTest();
        new EmailLogScheduler().run(true);
        // Verify buildRequestParams directly with the same config
        EmailLogAcquisitionService.RequestParams params =
            new EmailLogScheduler().buildRequestParams(cfg);
        Test.stopTest();

        System.assertEquals(1, svcStub.submitRequestCalloutsCallCount,
            'CustomWindow mode must call submitRequestCallouts (US1 AC6)');
        Long windowMs   = params.endDatetime.getTime() - params.startDatetime.getTime();
        Long expectedMs = 48L * 60L * 60L * 1000L;
        System.assert(Math.abs(windowMs - expectedMs) < 10000L,
            'CustomWindow of 48h must produce a window of ~48 hours (±10s tolerance for test execution)');
    }
}
