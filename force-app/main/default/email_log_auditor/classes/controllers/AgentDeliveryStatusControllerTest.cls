@IsTest
private class AgentDeliveryStatusControllerTest {

    @IsTest
    static void nullRecordId_throws() {
        Boolean threw = false;
        try {
            AgentDeliveryStatusController.getDeliveryStatusForRecord(null, 'Case');
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Expected AuraHandledException for null recordId');
    }

    @IsTest
    static void caseParentPath_returnsRowsWithParsedDeliveryData() {
        Case c = new Case(Subject = 'Test case', Status = 'New', Origin = 'Web');
        insert c;

        EmailMessage em = new EmailMessage(
            Subject = 'Reply', Status = '3', FromAddress = 'a@x.com',
            MessageDate = Datetime.now(), ParentId = c.Id, Category__c = 'CaseMessage',
            DeliveryData__c = '[{"recipient":"u@x.com","status":"Delivered","timestamp":"2026-04-26T10:00:00.000Z"}]'
        );
        insert em;

        Test.startTest();
        List<AgentDeliveryStatusController.DeliveryStatusRow> rows =
            AgentDeliveryStatusController.getDeliveryStatusForRecord(c.Id, 'Case');
        Test.stopTest();

        System.assertEquals(1, rows.size());
        System.assertEquals(true, rows[0].hasDeliveryData);
        System.assertEquals(1, rows[0].deliveryEntries.size());
        System.assertEquals('Delivered', rows[0].deliveryEntries[0].status);
    }

    @IsTest
    static void contactRelatedToPath_returnsRows() {
        Contact ct = new Contact(LastName = 'X');
        insert ct;

        EmailMessage em = new EmailMessage(
            Subject = 'Outbound', Status = '3', FromAddress = 'a@x.com',
            MessageDate = Datetime.now(), RelatedToId = ct.Id, Category__c = 'PasswordReset',
            DeliveryData__c = '[]'
        );
        insert em;

        Test.startTest();
        List<AgentDeliveryStatusController.DeliveryStatusRow> rows =
            AgentDeliveryStatusController.getDeliveryStatusForRecord(ct.Id, 'Contact');
        Test.stopTest();

        System.assertEquals(1, rows.size());
        System.assertEquals(false, rows[0].hasDeliveryData);
        System.assertEquals(0, rows[0].deliveryEntries.size());
    }

    @IsTest
    static void noMatches_returnsEmptyList() {
        Case c = new Case(Subject = 'Empty', Status = 'New', Origin = 'Web');
        insert c;

        Test.startTest();
        List<AgentDeliveryStatusController.DeliveryStatusRow> rows =
            AgentDeliveryStatusController.getDeliveryStatusForRecord(c.Id, 'Case');
        Test.stopTest();

        System.assertNotEquals(null, rows);
        System.assertEquals(0, rows.size());
    }

    @IsTest
    static void parseDeliveryData_invalidJsonReturnsEmpty() {
        List<AgentDeliveryStatusController.DeliveryEntryDto> result =
            AgentDeliveryStatusController.parseDeliveryData('{garbage');
        System.assertNotEquals(null, result);
        System.assertEquals(0, result.size());
    }
}
