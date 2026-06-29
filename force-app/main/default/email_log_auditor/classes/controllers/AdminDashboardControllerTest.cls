@IsTest
private class AdminDashboardControllerTest {

    private static EmailMessage seed(String subject, String category, String json) {
        EmailMessage em = new EmailMessage(
            Subject = subject, Status = '3', FromAddress = 'from@x.com',
            MessageDate = Datetime.now(), Category__c = category, DeliveryData__c = json
        );
        insert em;
        return em;
    }

    @IsTest
    static void getDeliveryMetrics_aggregatesAcrossDeliveryDataJson() {
        seed('a', 'CaseMessage', '[{"recipient":"a@x.com","status":"Delivered","timestamp":"2026-04-26T10:00:00.000Z"},{"recipient":"b@x.com","status":"Bounced","timestamp":"2026-04-26T10:00:00.000Z"}]');
        seed('b', 'CaseMessage', '[{"recipient":"c@x.com","status":"Deferred","timestamp":"2026-04-26T10:00:00.000Z"}]');

        Test.startTest();
        AdminDashboardController.DeliveryMetrics m = AdminDashboardController.getDeliveryMetrics();
        Test.stopTest();

        System.assertEquals(2, m.totalEmails);
        System.assertEquals(1, m.delivered);
        System.assertEquals(1, m.bounced);
        System.assertEquals(1, m.deferred);
    }

    @IsTest
    static void getEmailsByCategory_filtersAndPaginates() {
        seed('Subj-a', 'PasswordReset', '[]');
        seed('Subj-b', 'PasswordReset', '[]');
        seed('Subj-c', 'FlowError', '[]');

        Test.startTest();
        List<AdminDashboardController.EmailRow> rows =
            AdminDashboardController.getEmailsByCategory('PasswordReset', null, null, 10, 0);
        Test.stopTest();

        System.assertEquals(2, rows.size(), 'Only PasswordReset rows expected');
        for (AdminDashboardController.EmailRow r : rows) {
            System.assertEquals('PasswordReset', r.category);
        }
    }

    @IsTest
    static void getEmailsByCategory_emptyResultIsEmptyListNotNull() {
        Test.startTest();
        List<AdminDashboardController.EmailRow> rows =
            AdminDashboardController.getEmailsByCategory('FlowError', null, null, 10, 0);
        Test.stopTest();
        System.assertNotEquals(null, rows);
        System.assertEquals(0, rows.size());
    }

    @IsTest
    static void worstStatus_bouncedTrumpsDelivered() {
        EmailMessage em = seed('mixed', 'SystemOther',
            '[{"recipient":"a","status":"Delivered","timestamp":"2026-04-26T10:00:00.000Z"},{"recipient":"b","status":"Bounced","timestamp":"2026-04-26T10:00:00.000Z"}]');
        Test.startTest();
        List<AdminDashboardController.EmailRow> rows =
            AdminDashboardController.getEmailsByCategory('SystemOther', null, null, 10, 0);
        Test.stopTest();
        System.assertEquals('Bounced', rows[0].worstStatus);
    }

    @IsTest
    static void parseDeliveryData_invalidJsonReturnsEmpty() {
        List<AdminDashboardController.DeliveryEntryDto> result =
            AdminDashboardController.parseDeliveryData('{not-json');
        System.assertNotEquals(null, result);
        System.assertEquals(0, result.size());
    }
}
