@IsTest
private class EmailLogBatchProcessorTest {

    private static final String CSV_HEADER =
        '"Date","Source IP","Source/Destination","Bytes","Recipient Address","Sender Address","Remote Host","Subject","Status","Message ID","Event Type","Message Size","Mail Pause","Cipher Strength","Cipher","Cipher Suite","Direction","Notification","Status Code","Diagnostic"';

    private static final String CSV_ROW =
        '"2026-04-26T10:00:00.000Z","1.2.3.4","sender","100","a@x.com","from@y.com","host","Subj","250 ok","<m1@host>","D","100","","256","TLS","aes","Out","","250","ok"';

    private class CapturingMatcher extends EmailMessageMatcherService {
        public List<EmailDeliveryRecord> received = new List<EmailDeliveryRecord>();
        public CapturingMatcher() { super(null); }
        public override EmailMessageMatcherService.MatchResult matchAndEnrich(
            List<EmailDeliveryRecord> rs, Id sourceFileId
        ) {
            if (rs != null) received.addAll(rs);
            EmailMessageMatcherService.MatchResult r = new EmailMessageMatcherService.MatchResult();
            r.matched = rs == null ? 0 : rs.size();
            return r;
        }
    }

    private class NoOpCategorizer extends EmailCategorizationService {
        public Integer calls = 0;
        public NoOpCategorizer() { super(null); }
        public override Integer categoriseAll() { calls++; return 0; }
    }

    private static EmailLogFile__c seedLogFileWithCsv(String csv) {
        ContentVersion cv = new ContentVersion(
            Title = 'Email Log', PathOnClient = 'log.csv',
            VersionData = Blob.valueOf(csv), IsMajorVersion = true
        );
        insert cv;
        Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1].ContentDocumentId;
        EmailLogFile__c lf = new EmailLogFile__c(
            FileId__c = '0BRC' + String.valueOf(Math.mod(Crypto.getRandomLong(), 10000000)),
            Label__c = 'Batch test',
            ProcessingStatus__c = 'Processing',
            Direction__c = 'Outbound',
            DownloadedDate__c = Datetime.now(),
            ContentDocumentId__c = docId
        );
        insert lf;
        return lf;
    }

    @IsTest
    static void start_returnsRowsWithoutHeader() {
        String csv = CSV_HEADER + '\n' + CSV_ROW + '\n' + CSV_ROW;
        EmailLogFile__c lf = seedLogFileWithCsv(csv);
        EmailLogBatchProcessor p = new EmailLogBatchProcessor(lf.Id);

        Test.startTest();
        Iterable<String> it = p.start(null);
        Test.stopTest();

        List<String> rows = new List<String>();
        for (String s : it) rows.add(s);
        System.assertEquals(2, rows.size(), 'Header must be skipped');
    }

    @IsTest
    static void execute_dispatchesParsedRecordsToMatcher() {
        EmailLogFile__c lf = seedLogFileWithCsv(CSV_HEADER + '\n' + CSV_ROW);
        CapturingMatcher matcher = new CapturingMatcher();
        EmailLogBatchProcessor.MATCHER_OVERRIDE = matcher;
        EmailLogBatchProcessor.CATEGORIZER_OVERRIDE = new NoOpCategorizer();

        EmailLogBatchProcessor p = new EmailLogBatchProcessor(lf.Id);

        Test.startTest();
        p.execute(null, new List<String>{ CSV_ROW });
        p.finish(null);
        Test.stopTest();

        System.assertEquals(1, matcher.received.size());
        System.assertEquals('m1@host', matcher.received[0].messageId);
        System.assertEquals('a@x.com', matcher.received[0].recipient);

        EmailLogFile__c after = [SELECT ProcessingStatus__c, RowCount__c FROM EmailLogFile__c WHERE Id = :lf.Id];
        System.assertEquals('Processed', after.ProcessingStatus__c);
        System.assertEquals(1, after.RowCount__c);
    }

    @IsTest
    static void emptyCsv_completesWithZeroRows() {
        EmailLogFile__c lf = seedLogFileWithCsv(CSV_HEADER);
        EmailLogBatchProcessor.MATCHER_OVERRIDE = new CapturingMatcher();
        EmailLogBatchProcessor.CATEGORIZER_OVERRIDE = new NoOpCategorizer();
        EmailLogBatchProcessor p = new EmailLogBatchProcessor(lf.Id);

        Test.startTest();
        Iterable<String> it = p.start(null);
        List<String> rows = new List<String>();
        for (String s : it) rows.add(s);
        p.finish(null);
        Test.stopTest();

        System.assertEquals(0, rows.size());
        EmailLogFile__c after = [SELECT ProcessingStatus__c, RowCount__c FROM EmailLogFile__c WHERE Id = :lf.Id];
        System.assertEquals('Processed', after.ProcessingStatus__c);
    }

    @IsTest
    static void parseRow_handlesAngleBracketMessageId() {
        EmailDeliveryRecord r = EmailLogBatchProcessor.parseRow(CSV_ROW, 1);
        System.assertEquals('m1@host', r.messageId);
        System.assertEquals('Delivered', r.deliveryStatus);
    }

    @IsTest
    static void splitCsv_handlesQuotedCommas() {
        String line = '"a","b,c","d"';
        List<String> cols = EmailLogBatchProcessor.splitCsv(line);
        System.assertEquals(3, cols.size());
        System.assertEquals('b,c', cols[1]);
    }
}
