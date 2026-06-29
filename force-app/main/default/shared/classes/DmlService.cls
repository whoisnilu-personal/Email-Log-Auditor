/**
 * SECURITY: without sharing — this is a low-level DML wrapper used by admin/system
 * context services in the email_log_auditor domain. Sharing enforcement is
 * applied (or intentionally bypassed) by the calling service per the
 * Constitution Principle IV.
 *
 * Production implementation of IDmlService — thin delegation to Database.* DML.
 * Tests inject Test.createStub() against IDmlService instead of using this class.
 */
public without sharing class DmlService implements IDmlService {
    public void insertRecords(List<SObject> records) {
        if (records == null || records.isEmpty()) {
            return;
        }
        Database.insert(records, true);
    }

    public void updateRecords(List<SObject> records) {
        if (records == null || records.isEmpty()) {
            return;
        }
        Database.update(records, true);
    }

    public void deleteRecords(List<SObject> records) {
        if (records == null || records.isEmpty()) {
            return;
        }
        Database.delete(records, true);
    }
}
