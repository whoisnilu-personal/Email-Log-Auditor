/**
 * Stub-API style unit tests for SetDeliveryStatusDefault.
 * No DB inserts (Constitution Principle II); all state is exercised via the
 * trigger.new buffer passed directly into beforeInsert.
 */
@IsTest
private class SetDeliveryStatusDefaultTest {
    @IsTest
    static void blankDeliveryDataIsInitialisedToEmptyArray() {
        EmailMessage em = new EmailMessage();
        Test.startTest();
        new SetDeliveryStatusDefault().beforeInsert(new List<EmailMessage>{ em });
        Test.stopTest();
        System.assertEquals('[]', em.DeliveryData__c, 'Blank DeliveryData__c must be initialised to []');
    }

    @IsTest
    static void existingDeliveryDataIsNotOverwritten() {
        String existing = '[{"recipient":"a@b.com","status":"Delivered"}]';
        EmailMessage em = new EmailMessage(DeliveryData__c = existing);
        Test.startTest();
        new SetDeliveryStatusDefault().beforeInsert(new List<EmailMessage>{ em });
        Test.stopTest();
        System.assertEquals(existing, em.DeliveryData__c, 'Existing DeliveryData__c must not be overwritten');
    }

    @IsTest
    static void messageIdExtractedFromHeadersWhenBlank() {
        EmailMessage em = new EmailMessage(
            Headers = 'From: noreply@example.com\nMessage-ID: <abc123@host.example>\nSubject: hi'
        );
        Test.startTest();
        new SetDeliveryStatusDefault().beforeInsert(new List<EmailMessage>{ em });
        Test.stopTest();
        System.assertEquals('abc123@host.example', em.MessageId__c, 'Message-Id must be extracted and angle brackets stripped');
    }

    @IsTest
    static void blankHeadersLeavesMessageIdNull() {
        EmailMessage em = new EmailMessage(Headers = null);
        Test.startTest();
        new SetDeliveryStatusDefault().beforeInsert(new List<EmailMessage>{ em });
        Test.stopTest();
        System.assertEquals(null, em.MessageId__c, 'Blank Headers must leave MessageId__c null');
    }

    @IsTest
    static void existingMessageIdIsNotOverwritten() {
        EmailMessage em = new EmailMessage(
            MessageId__c = 'preserved@host',
            Headers = 'Message-ID: <new@host>'
        );
        Test.startTest();
        new SetDeliveryStatusDefault().beforeInsert(new List<EmailMessage>{ em });
        Test.stopTest();
        System.assertEquals('preserved@host', em.MessageId__c, 'Existing MessageId__c must not be overwritten');
    }

    @IsTest
    static void emptyAndNullListsAreNoOps() {
        Test.startTest();
        new SetDeliveryStatusDefault().beforeInsert(null);
        new SetDeliveryStatusDefault().beforeInsert(new List<EmailMessage>());
        Test.stopTest();
        System.assert(true, 'No exceptions for null/empty lists');
    }
}
