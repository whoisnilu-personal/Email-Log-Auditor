/**
 * DML abstraction for AWAF dependency injection at the database boundary.
 * Production: DmlService.
 * Tests: Test.createStub() against this interface.
 */
public interface IDmlService {
    void insertRecords(List<SObject> records);
    void updateRecords(List<SObject> records);
    void deleteRecords(List<SObject> records);
}
