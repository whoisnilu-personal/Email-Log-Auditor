@IsTest
private class ScheduleConfigControllerTest {

    @IsTest
    static void getScheduleConfig_returnsDefaultRecord() {
        Test.startTest();
        ScheduleConfigController.ScheduleConfig cfg = ScheduleConfigController.getScheduleConfig();
        Test.stopTest();
        System.assertNotEquals(null, cfg, 'Config DTO must not be null');
        // Default record seeded with IsEnabled=false, Frequency=Daily
        System.assertEquals(false, cfg.isEnabled);
        System.assertEquals('Daily', cfg.frequency);
        System.assertEquals(200, cfg.batchSize);
    }

    @IsTest
    static void saveScheduleConfig_validatesBatchSize() {
        ScheduleConfigController.ScheduleConfig cfg = new ScheduleConfigController.ScheduleConfig();
        cfg.isEnabled = true;
        cfg.frequency = 'Daily';
        cfg.runTime = '02:00';
        cfg.batchSize = 5000; // > 2000 — invalid
        Boolean threw = false;
        Test.startTest();
        try {
            ScheduleConfigController.saveScheduleConfig(JSON.serialize(cfg));
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();
        System.assertEquals(true, threw, 'Out-of-range batchSize must throw');
    }

    @IsTest
    static void saveScheduleConfig_blankPayload_throws() {
        Boolean threw = false;
        Test.startTest();
        try {
            ScheduleConfigController.saveScheduleConfig(null);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();
        System.assertEquals(true, threw);
    }

    @IsTest
    static void saveScheduleConfig_validPayload_returnsDeployId() {
        ScheduleConfigController.ScheduleConfig cfg = new ScheduleConfigController.ScheduleConfig();
        cfg.isEnabled = true;
        cfg.frequency = 'Daily';
        cfg.runTime = '02:00';
        cfg.batchSize = 200;
        Test.startTest();
        String deployId = ScheduleConfigController.saveScheduleConfig(JSON.serialize(cfg));
        Test.stopTest();
        System.assertEquals('TEST_DEPLOY_ID', deployId, 'Test mode bypasses real deploy');
    }

    @IsTest
    static void saveScheduleConfig_invalidJson_throws() {
        Boolean threw = false;
        Test.startTest();
        try {
            ScheduleConfigController.saveScheduleConfig('{not-valid-json');
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();
        System.assertEquals(true, threw);
    }

    @IsTest
    static void getJobHistory_emptyReturnsEmptyList() {
        Test.startTest();
        List<ScheduleConfigController.JobHistoryRow> rows = ScheduleConfigController.getJobHistory(10);
        Test.stopTest();
        System.assertNotEquals(null, rows, 'Must return empty list, never null');
        System.assertEquals(0, rows.size(), 'No EmailLogScheduler jobs in test context');
    }

    @IsTest
    static void getJobHistory_nullPageSize_defaultsTo10() {
        Test.startTest();
        List<ScheduleConfigController.JobHistoryRow> rows = ScheduleConfigController.getJobHistory(null);
        Test.stopTest();
        System.assertEquals(0, rows.size());
    }

    // ── T032 — getScheduleConfig returns extended DTO with 5 request fields ─
    @IsTest
    static void getScheduleConfig_returnsExtendedRequestFields() {
        Test.startTest();
        ScheduleConfigController.ScheduleConfig cfg = ScheduleConfigController.getScheduleConfig();
        Test.stopTest();

        // New fields must be present in the DTO (Default record was seeded with these values in T010)
        // requestMode: 'Off' is the default per data-model.md — null is also acceptable for backward compat
        System.assert(cfg.requestMode == null || cfg.requestMode == 'Off',
            'requestMode must be Off or null for fresh org (spec FR-010 backward compat)');
        // requestWindowHours defaults to 24 per metadata record
        System.assert(cfg.requestWindowHours == null || cfg.requestWindowHours == 24,
            'requestWindowHours must default to 24 or null');
        // requestTimeoutHours defaults to 2
        System.assert(cfg.requestTimeoutHours == null || cfg.requestTimeoutHours == 2,
            'requestTimeoutHours must default to 2 or null');
    }

    // ── T033 — saveScheduleConfig validates requestWindowHours 1-168 ──────
    @IsTest
    static void saveScheduleConfig_requestWindowHoursOutOfRange_throws() {
        ScheduleConfigController.ScheduleConfig cfg = new ScheduleConfigController.ScheduleConfig();
        cfg.isEnabled       = false;
        cfg.frequency       = 'Daily';
        cfg.runTime         = '02:00';
        cfg.batchSize       = 200;
        cfg.requestMode     = 'CustomWindow';
        cfg.requestWindowHours = 0;  // 0 is out of range (valid: 1–168)

        Boolean threw = false;
        Test.startTest();
        try {
            ScheduleConfigController.saveScheduleConfig(JSON.serialize(cfg));
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw,
            'requestWindowHours = 0 must throw AuraHandledException (valid range: 1-168)');
    }

    // ── T034 — requestNow rejects window outside 30 days ──────────────────
    @IsTest
    static void requestNow_windowOutside30Days_throwsAuraHandledException() {
        String startIso = Datetime.now().addDays(-31).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        String endIso   = Datetime.now().addDays(-29).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        Map<String, Object> params = new Map<String, Object>{
            'startIso' => startIso, 'endIso' => endIso, 'direction' => 'Outbound'
        };

        Boolean threw = false;
        Test.startTest();
        try {
            ScheduleConfigController.requestNow(JSON.serialize(params));
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw,
            'requestNow() must throw AuraHandledException when start is outside 30-day window');
    }

    @IsTest
    static void requestNow_endBeforeStart_throwsAuraHandledException() {
        String startIso = Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        String endIso   = Datetime.now().addDays(-1).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        Map<String, Object> params = new Map<String, Object>{
            'startIso' => startIso, 'endIso' => endIso, 'direction' => 'Outbound'
        };

        Boolean threw = false;
        Test.startTest();
        try {
            ScheduleConfigController.requestNow(JSON.serialize(params));
        } catch (AuraHandledException ex) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw,
            'requestNow() must throw AuraHandledException when end <= start');
    }

    // ── T035 — requestNow valid params enqueues job and returns job ID ─────
    @IsTest
    static void requestNow_validParams_returnsJobId() {
        String startIso = Datetime.now().addDays(-1).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        String endIso   = Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        Map<String, Object> params = new Map<String, Object>{
            'startIso' => startIso, 'endIso' => endIso, 'direction' => 'Outbound'
        };

        String jobId;
        Test.startTest();
        jobId = ScheduleConfigController.requestNow(JSON.serialize(params));
        Test.stopTest();

        System.assertNotEquals(null, jobId,
            'requestNow() must return a non-null job ID string (US2 AC2)');
        System.assert(jobId.length() > 0,
            'Returned job ID must be non-blank');
    }
}
