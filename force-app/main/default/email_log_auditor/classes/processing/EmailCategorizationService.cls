/**
 * EmailCategorizationService — assigns Category__c on EmailMessage by evaluating
 * EmailCategoryRule__mdt records in priority order; first match wins.
 *
 * Match field semantics:
 *  - Subject           → case-insensitive contains match against EmailMessage.Subject
 *  - FromAddress       → case-insensitive contains match against EmailMessage.FromAddress
 *  - ParentObjectType  → exact match (case-insensitive) against the SObject type
 *                        of EmailMessage.ParentId (e.g. 'Case')
 *
 * Blank Pattern__c on a rule is treated as a catch-all (always matches its
 * MatchField — used for SystemOther priority 999).
 */
public without sharing virtual class EmailCategorizationService {

    @TestVisible
    private static List<EmailCategoryRule__mdt> RULES_OVERRIDE;

    private final IDmlService dmlService;

    public EmailCategorizationService(IDmlService dmlService) {
        this.dmlService = dmlService;
    }

    /**
     * Categorise every EmailMessage with Category__c == null. Bulk update via DI.
     * @return number of records updated
     */
    public virtual Integer categoriseAll() {
        List<EmailMessage> ems = [
            SELECT Id, Subject, FromAddress, ParentId, Category__c
            FROM EmailMessage
            WHERE Category__c = null
            WITH USER_MODE
            LIMIT 10000
        ];
        return categorise(ems);
    }

    public Integer categorise(List<EmailMessage> ems) {
        if (ems == null || ems.isEmpty()) return 0;
        List<EmailCategoryRule__mdt> rules = loadRules();
        // Build minimal update objects (Id + Category__c only) to avoid
        // re-validating unrelated fields like FromAddress on update.
        List<EmailMessage> toUpdate = new List<EmailMessage>();
        for (EmailMessage em : ems) {
            String category = evaluate(em, rules);
            if (String.isNotBlank(category) && category != em.Category__c) {
                toUpdate.add(new EmailMessage(Id = em.Id, Category__c = category));
            }
        }
        if (toUpdate.isEmpty()) return 0;
        // Use partial success so records blocked by org validation rules
        // (e.g. FromAddress re-validated by Flows on EmailMessage update)
        // don't prevent the rest from being categorised.
        List<Database.SaveResult> results = Database.update(toUpdate, false);
        Integer successCount = 0;
        for (Database.SaveResult sr : results) {
            if (sr.isSuccess()) successCount++;
        }
        return successCount;
    }

    @TestVisible
    private static String evaluate(EmailMessage em, List<EmailCategoryRule__mdt> rules) {
        String parentType = parentObjectType(em.ParentId);
        for (EmailCategoryRule__mdt rule : rules) {
            if (rule.IsActive__c == false) continue;
            if (matches(em, parentType, rule)) return rule.Category__c;
        }
        return null;
    }

    private static Boolean matches(EmailMessage em, String parentType, EmailCategoryRule__mdt rule) {
        String fieldValue = fieldValueFor(em, parentType, rule.MatchField__c);
        // Blank Pattern__c is a catch-all — match if the field has any value, OR
        // for ParentObjectType where blank field means "no parent" → still match.
        if (String.isBlank(rule.Pattern__c)) return true;
        if (String.isBlank(fieldValue)) return false;
        if (rule.MatchField__c == 'ParentObjectType') {
            return fieldValue.equalsIgnoreCase(rule.Pattern__c);
        }
        return fieldValue.toLowerCase().contains(rule.Pattern__c.toLowerCase());
    }

    private static String fieldValueFor(EmailMessage em, String parentType, String matchField) {
        if (matchField == 'Subject') return em.Subject;
        if (matchField == 'FromAddress') return em.FromAddress;
        if (matchField == 'ParentObjectType') return parentType;
        return null;
    }

    private static String parentObjectType(Id parentId) {
        if (parentId == null) return null;
        return parentId.getSObjectType().getDescribe().getName();
    }

    private static List<EmailCategoryRule__mdt> loadRules() {
        if (RULES_OVERRIDE != null) return RULES_OVERRIDE;
        return [
            SELECT Category__c, MatchField__c, Pattern__c, Priority__c, IsActive__c
            FROM EmailCategoryRule__mdt
            ORDER BY Priority__c ASC NULLS LAST
        ];
    }
}
