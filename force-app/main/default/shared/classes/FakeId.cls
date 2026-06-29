/**
 * Test utility: generates syntactically valid Salesforce IDs without DML.
 * Lets unit tests fabricate SObject IDs for stub-mocked queries and DML
 * verification, satisfying Constitution Principle II (no DB inserts in unit tests).
 *
 * Usage: Id fakeMessageId = FakeId.build(EmailMessage.SObjectType);
 */
@SuppressWarnings('PMD.ApexDoc')
public class FakeId {
    private static Integer counter = 1;

    public static Id build(Schema.SObjectType sobjectType) {
        String prefix = sobjectType.getDescribe().getKeyPrefix();
        String suffix = String.valueOf(counter++).leftPad(12, '0');
        return Id.valueOf(prefix + suffix);
    }
}
