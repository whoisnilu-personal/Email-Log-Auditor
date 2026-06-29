@IsTest
private class EmailCategorizationServiceTest {

    private class DmlStub implements StubProvider {
        public List<List<SObject>> updatedBatches = new List<List<SObject>>();
        public Object handleMethodCall(
            Object stubbedObject, String stubbedMethodName, Type returnType,
            List<Type> listOfParamTypes, List<String> listOfParamNames, List<Object> listOfArgs
        ) {
            if (stubbedMethodName == 'updateRecords') {
                updatedBatches.add((List<SObject>) listOfArgs[0]);
            }
            return null;
        }
    }

    private static EmailCategoryRule__mdt rule(String cat, String field, String pattern, Integer pri, Boolean active) {
        EmailCategoryRule__mdt r = new EmailCategoryRule__mdt();
        r.Category__c = cat;
        r.MatchField__c = field;
        r.Pattern__c = pattern;
        r.Priority__c = pri;
        r.IsActive__c = active;
        return r;
    }

    private static EmailCategorizationService newSvc(DmlStub d) {
        IDmlService dml = (IDmlService) Test.createStub(IDmlService.class, d);
        return new EmailCategorizationService(dml);
    }

    @IsTest
    static void rulesEvaluatedInPriorityOrder_firstMatchWins() {
        EmailCategorizationService.RULES_OVERRIDE = new List<EmailCategoryRule__mdt>{
            rule('PasswordReset', 'Subject', 'reset', 10, true),
            rule('SystemOther', 'Subject', null, 999, true)
        };
        EmailMessage em = new EmailMessage(Subject = 'Please reset your password');
        DmlStub d = new DmlStub();

        Test.startTest();
        Integer updated = newSvc(d).categorise(new List<EmailMessage>{ em });
        Test.stopTest();

        System.assertEquals(1, updated);
        System.assertEquals('PasswordReset', em.Category__c);
    }

    @IsTest
    static void caseInsensitiveContainsMatch() {
        EmailCategorizationService.RULES_OVERRIDE = new List<EmailCategoryRule__mdt>{
            rule('FlowError', 'Subject', 'unhandled fault', 30, true)
        };
        EmailMessage em = new EmailMessage(Subject = 'Re: UNHANDLED Fault Email - flow ABC');
        DmlStub d = new DmlStub();
        Test.startTest();
        newSvc(d).categorise(new List<EmailMessage>{ em });
        Test.stopTest();
        System.assertEquals('FlowError', em.Category__c);
    }

    @IsTest
    static void inactiveRuleIsSkipped() {
        EmailCategorizationService.RULES_OVERRIDE = new List<EmailCategoryRule__mdt>{
            rule('PasswordReset', 'Subject', 'reset', 10, false),
            rule('SystemOther', 'Subject', null, 999, true)
        };
        EmailMessage em = new EmailMessage(Subject = 'Please reset your password');
        DmlStub d = new DmlStub();
        Test.startTest();
        newSvc(d).categorise(new List<EmailMessage>{ em });
        Test.stopTest();
        System.assertEquals('SystemOther', em.Category__c, 'Inactive rule must be skipped');
    }

    @IsTest
    static void catchAllSystemOtherFiresLast() {
        EmailCategorizationService.RULES_OVERRIDE = new List<EmailCategoryRule__mdt>{
            rule('PasswordReset', 'Subject', 'reset', 10, true),
            rule('SystemOther', 'Subject', null, 999, true)
        };
        EmailMessage em = new EmailMessage(Subject = 'Order confirmation #123');
        DmlStub d = new DmlStub();
        Test.startTest();
        newSvc(d).categorise(new List<EmailMessage>{ em });
        Test.stopTest();
        System.assertEquals('SystemOther', em.Category__c);
    }

    @IsTest
    static void parentObjectType_caseRule_matchesCaseEmails() {
        EmailCategorizationService.RULES_OVERRIDE = new List<EmailCategoryRule__mdt>{
            rule('CaseMessage', 'ParentObjectType', 'Case', 10, true),
            rule('SystemOther', 'Subject', null, 999, true)
        };
        Account a = new Account(Name = 'Acme');
        insert a;
        Case c = new Case(Subject = 'Test', AccountId = a.Id);
        insert c;
        EmailMessage em = new EmailMessage(Subject = 'Re: Test', ParentId = c.Id);
        DmlStub d = new DmlStub();
        Test.startTest();
        newSvc(d).categorise(new List<EmailMessage>{ em });
        Test.stopTest();
        System.assertEquals('CaseMessage', em.Category__c);
    }

    @IsTest
    static void emptyListReturnsZero() {
        EmailCategorizationService.RULES_OVERRIDE = new List<EmailCategoryRule__mdt>();
        DmlStub d = new DmlStub();
        Test.startTest();
        Integer n = newSvc(d).categorise(new List<EmailMessage>());
        Test.stopTest();
        System.assertEquals(0, n);
        System.assertEquals(0, d.updatedBatches.size());
    }
}
