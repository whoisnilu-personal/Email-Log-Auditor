@IsTest
private class EmailMessageMatcherServiceTest {

    private class DmlStub implements StubProvider {
        public List<List<SObject>> insertedBatches = new List<List<SObject>>();
        public List<List<SObject>> updatedBatches = new List<List<SObject>>();
        public Object handleMethodCall(
            Object stubbedObject, String stubbedMethodName, Type returnType,
            List<Type> listOfParamTypes, List<String> listOfParamNames, List<Object> listOfArgs
        ) {
            List<SObject> records = (List<SObject>) listOfArgs[0];
            if (stubbedMethodName == 'insertRecords') insertedBatches.add(records);
            else if (stubbedMethodName == 'updateRecords') updatedBatches.add(records);
            return null;
        }
    }

    private static EmailMessageMatcherService newSvc(DmlStub d) {
        IDmlService dml = (IDmlService) Test.createStub(IDmlService.class, d);
        return new EmailMessageMatcherService(dml);
    }

    private static EmailDeliveryRecord row(String mid, String to, String evt, Datetime ts) {
        EmailDeliveryRecord r = new EmailDeliveryRecord();
        r.messageId = mid;
        r.recipient = to;
        r.eventType = evt;
        r.sendDatetime = ts;
        r.csvRowNumber = 1;
        r.rawCsvRow = 'mid=' + mid;
        return r;
    }

    @IsTest
    static void unmatchedRow_createsAuditLogEntry() {
        DmlStub d = new DmlStub();
        Id sourceId = FakeId.build(EmailLogFile__c.SObjectType);

        Test.startTest();
        EmailMessageMatcherService.MatchResult r = newSvc(d).matchAndEnrich(
            new List<EmailDeliveryRecord>{ row('orphan@host', 'a@x.com', 'D', Datetime.now()) },
            sourceId
        );
        Test.stopTest();

        System.assertEquals(0, r.matched);
        System.assertEquals(1, r.unmatched);
        System.assertEquals(1, d.insertedBatches.size());
        AuditLogEntry__c ale = (AuditLogEntry__c) d.insertedBatches[0][0];
        System.assertEquals('Unmatched', ale.EntryType__c);
        System.assertEquals(sourceId, ale.SourceFile__c);
    }

    @IsTest
    static void blankMessageId_logsAsMissingMessageId() {
        DmlStub d = new DmlStub();
        Test.startTest();
        EmailMessageMatcherService.MatchResult r = newSvc(d).matchAndEnrich(
            new List<EmailDeliveryRecord>{ row(null, 'a@x.com', 'D', Datetime.now()) },
            FakeId.build(EmailLogFile__c.SObjectType)
        );
        Test.stopTest();
        System.assertEquals(1, r.unmatched);
        AuditLogEntry__c ale = (AuditLogEntry__c) d.insertedBatches[0][0];
        System.assertEquals('MissingMessageId', ale.EntryType__c);
    }

    @IsTest
    static void matchedRow_appendsRecipientToDeliveryDataJson() {
        // Seed an EmailMessage with an empty array
        EmailMessage em = new EmailMessage(
            MessageId__c = 'm1@host', DeliveryData__c = '[]', Status = '3'
        );
        insert em;

        DmlStub d = new DmlStub();
        Datetime ts = Datetime.newInstance(2026, 4, 26, 10, 0, 0);
        Test.startTest();
        EmailMessageMatcherService.MatchResult r = newSvc(d).matchAndEnrich(
            new List<EmailDeliveryRecord>{ row('m1@host', 'a@x.com', 'D', ts) },
            FakeId.build(EmailLogFile__c.SObjectType)
        );
        Test.stopTest();

        System.assertEquals(1, r.matched);
        System.assertEquals(0, r.unmatched);
        System.assertEquals(1, r.updated, 'EmailMessage must be updated');
        System.assertEquals(1, d.updatedBatches.size());
        EmailMessage updated = (EmailMessage) d.updatedBatches[0][0];
        System.assert(updated.DeliveryData__c.contains('a@x.com'));
        System.assert(updated.DeliveryData__c.contains('Delivered'));
    }

    @IsTest
    static void mergeRows_olderTimestampDoesNotOverwrite() {
        // Helper: ensure the static merge rule honours newer-wins
        EmailMessageMatcherService.DeliveryEntry existing = new EmailMessageMatcherService.DeliveryEntry();
        existing.recipient = 'a@x.com';
        existing.status = 'Delivered';
        existing.timestamp = Datetime.newInstance(2026, 4, 26, 12, 0, 0);
        List<EmailMessageMatcherService.DeliveryEntry> list1 = new List<EmailMessageMatcherService.DeliveryEntry>{ existing };

        EmailDeliveryRecord older = row('m1', 'a@x.com', 'P', Datetime.newInstance(2026, 4, 26, 10, 0, 0));
        Boolean changed = EmailMessageMatcherService.mergeRows(list1, new List<EmailDeliveryRecord>{ older });
        System.assertEquals(false, changed, 'Older timestamp must NOT overwrite');
        System.assertEquals('Delivered', list1[0].status);
    }

    @IsTest
    static void mergeRows_newerTimestampOverwrites() {
        EmailMessageMatcherService.DeliveryEntry existing = new EmailMessageMatcherService.DeliveryEntry();
        existing.recipient = 'a@x.com';
        existing.status = 'Pending';
        existing.timestamp = Datetime.newInstance(2026, 4, 26, 8, 0, 0);
        List<EmailMessageMatcherService.DeliveryEntry> list1 = new List<EmailMessageMatcherService.DeliveryEntry>{ existing };

        EmailDeliveryRecord newer = row('m1', 'a@x.com', 'D', Datetime.newInstance(2026, 4, 26, 10, 0, 0));
        Boolean changed = EmailMessageMatcherService.mergeRows(list1, new List<EmailDeliveryRecord>{ newer });
        System.assertEquals(true, changed);
        System.assertEquals('Delivered', list1[0].status);
    }

    @IsTest
    static void emptyAndNullInputsReturnZeroResults() {
        DmlStub d = new DmlStub();
        EmailMessageMatcherService svc = newSvc(d);
        Test.startTest();
        EmailMessageMatcherService.MatchResult r1 = svc.matchAndEnrich(null, null);
        EmailMessageMatcherService.MatchResult r2 = svc.matchAndEnrich(new List<EmailDeliveryRecord>(), null);
        Test.stopTest();
        System.assertEquals(0, r1.matched);
        System.assertEquals(0, r2.matched);
        System.assertEquals(0, d.insertedBatches.size());
    }
}
