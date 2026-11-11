/**
 * @description Tests for SLO_SelloutApplyBatch: the decision pass, the invoice pass, the matching
 * pass edge cases and the single summary email that ends a chain.
 */
@IsTest
private class SLO_SelloutApplyBatchTest {

    private static final Date ITEM_DATE = Date.newInstance(2026, 1, 15);

    // The restricted Transaction type picklist may lack Internal Sellout in the org
    private static Boolean selloutTypeActive() {
        for (Schema.PicklistEntry entry : Invoice__c.Transaction_type__c.getDescribe().getPicklistValues()) {
            if (entry.isActive() && 'Internal Sellout'.equals(entry.getValue())) {
                return true;
            }
        }
        return false;
    }

    private static Account makeAccount(String name, Id parentId, String status) {
        Account acc = new Account(
            Name = name,
            ParentId = parentId,
            BillingCountry = 'France',
            BillingStreet = 'Rue de Test 1',
            BillingCity = 'Paris',
            BillingPostalCode = '75001',
            Status__c = status
        );
        insert acc;
        return acc;
    }

    private static SLO_Sellout_Report__c makeReport(Id accountId, String status) {
        SLO_Sellout_Report__c report = new SLO_Sellout_Report__c(
            SLO_Account__c = accountId,
            SLO_Report_Date__c = ITEM_DATE,
            SLO_Status__c = status,
            SLO_Price_Method__c = 'Dedicated_Price_Book',
            SLO_Price_Book__c = Test.getStandardPricebookId()
        );
        insert report;
        return report;
    }

    private static SLO_Sellout_Item__c makeItem(
        Id reportId, String customer, String productCode, Decimal quantity, String status
    ) {
        return new SLO_Sellout_Item__c(
            SLO_Sellout_Report__c = reportId,
            SLO_Customer_Account_Name__c = customer,
            SLO_Product_Code_EAN__c = productCode,
            SLO_Item_Date__c = ITEM_DATE,
            SLO_Quantity__c = quantity,
            SLO_Processing_Status__c = status
        );
    }

    private static String statusOf(Id itemId) {
        return [SELECT SLO_Processing_Status__c FROM SLO_Sellout_Item__c WHERE Id = :itemId].SLO_Processing_Status__c;
    }

    @IsTest
    static void decisionPassAppliesPlanToEveryRow() {
        Account parent = makeAccount('Parent Wholesaler', null, 'Active');
        Account target = makeAccount('Agora_DM', parent.Id, 'Active');
        insert new Product2(Name = 'P', Barcode__c = '123456', IsActive = true);

        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c reassigned = makeItem(report.Id, 'Agora', '123456', 4, 'Pending_Decision');
        SLO_Sellout_Item__c zero = makeItem(report.Id, 'Agora', '123456', 0, 'Pending_Decision');
        SLO_Sellout_Item__c badProduct = makeItem(report.Id, 'Agora', '999999', 2, 'Error');
        SLO_Sellout_Item__c skipped = makeItem(report.Id, 'Skip Me', '123456', 1, 'Pending_Decision');
        SLO_Sellout_Item__c undecided = makeItem(report.Id, 'Later', '123456', 1, 'Pending_Decision');
        SLO_Sellout_Item__c duplicate = makeItem(report.Id, 'Agora', '123456', 1, 'Skipped');
        duplicate.SLO_Processing_Notes__c = SLO_SelloutImportController.NOTE_DUPLICATE;
        insert new List<SLO_Sellout_Item__c>{ reassigned, zero, badProduct, skipped, undecided, duplicate };

        SLO_SelloutApplyBatch.DecisionPlan plan = new SLO_SelloutApplyBatch.DecisionPlan();
        String agoraKey = SLO_SelloutImportController.nameKey('Agora');
        plan.keyToAccountId.put(agoraKey, target.Id);
        plan.keyToNewName.put(agoraKey, target.Name);
        plan.reassignedKeys.add(agoraKey);
        plan.skipKeys.add(SLO_SelloutImportController.nameKey('Skip Me'));
        // Asked to run on into invoicing, so the chain reports by email
        plan.startInvoicing = true;

        Test.startTest();
        Database.executeBatch(new SLO_SelloutApplyBatch(
            report.Id, parent.Id, SLO_SelloutApplyBatch.MODE_DECISION, null, plan
        ), 200);
        Test.stopTest();

        Assert.areEqual('Matched', statusOf(reassigned.Id));
        Assert.areEqual('Agora_DM',
            [SELECT SLO_Customer_Account_Name__c FROM SLO_Sellout_Item__c WHERE Id = :reassigned.Id]
                .SLO_Customer_Account_Name__c, 'A reassigned line takes the account name');
        Assert.areEqual('Skipped', statusOf(zero.Id));
        Assert.areEqual('Error', statusOf(badProduct.Id), 'The decision resolves the account, not the data');
        Assert.areEqual('Skipped', statusOf(skipped.Id));
        Assert.areEqual('Pending_Decision', statusOf(undecided.Id));
        Assert.areEqual(SLO_SelloutImportController.NOTE_DUPLICATE,
            [SELECT SLO_Processing_Notes__c FROM SLO_Sellout_Item__c WHERE Id = :duplicate.Id].SLO_Processing_Notes__c,
            'A duplicate is not revived by an account decision');
        Assert.areEqual('Draft',
            [SELECT SLO_Status__c FROM SLO_Sellout_Report__c WHERE Id = :report.Id].SLO_Status__c);
        Assert.areEqual('Sellout account decisions applied - ready for review',
            SLO_SelloutApplyBatch.lastSummarySubject);
    }

    @IsTest
    static void decisionPassWithoutPlanDoesNothing() {
        Account parent = makeAccount('Parent Wholesaler', null, 'Active');
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c row = makeItem(report.Id, 'Agora', '1', 1, 'Pending_Decision');
        insert row;

        SLO_SelloutApplyBatch batch =
            new SLO_SelloutApplyBatch(report.Id, parent.Id, SLO_SelloutApplyBatch.MODE_DECISION);
        batch.execute(null, new List<SLO_Sellout_Item__c>{ row });
        batch.finish(null);

        Assert.areEqual('Pending_Decision', statusOf(row.Id));
        Assert.isNull(SLO_SelloutApplyBatch.lastSummarySubject, 'A decision pass alone never emails');
    }

    @IsTest
    static void invoicePassCreatesInvoicesAndReportsCompletion() {
        if (!selloutTypeActive()) {
            return;
        }
        Account parent = makeAccount('Parent Wholesaler', null, 'Active');
        Account child = makeAccount('Known Shop', parent.Id, 'Active');
        Product2 pricedProduct = new Product2(Name = 'P', Barcode__c = '123456', IsActive = true);
        insert pricedProduct;
        insert new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(), Product2Id = pricedProduct.Id, UnitPrice = 10, IsActive = true
        );

        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c item = makeItem(report.Id, 'Known Shop', '123456', 3, 'Matched');
        item.SLO_Matched_Account__c = child.Id;
        insert item;

        Test.startTest();
        Database.executeBatch(
            new SLO_SelloutApplyBatch(report.Id, parent.Id, SLO_SelloutApplyBatch.MODE_INVOICE), 200
        );
        Test.stopTest();

        Assert.areEqual('Invoice_Created', statusOf(item.Id));
        Assert.areEqual('Sellout processing complete - 2 invoices created', SLO_SelloutApplyBatch.lastSummarySubject);
    }

    @IsTest
    static void failedInvoicePassReportsEveryStageOnce() {
        Account parent = makeAccount('Parent Wholesaler', null, 'Active');
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'In_Process');

        // Totals carried from earlier links, so every section of the summary is written
        SLO_SelloutApplyBatch.RunContext context = new SLO_SelloutApplyBatch.RunContext();
        context.importRan = true;
        context.duplicatesRemoved = 2;
        context.importFlaggedForReview = 1;
        context.matchRan = true;
        context.itemsPendingDecision = 3;
        context.unmatchedNameCount = 1;
        context.decisionRan = true;
        context.decisionItemsReassigned = 1;
        context.decisionDuplicates = 1;
        context.decisionQuantityConflicts = 1;
        context.decisionProductErrors = 1;
        context.lineItemsAddedToExistingInvoices = 1;
        context.duplicateGroupsSkipped = 1;
        context.itemsQuantityMismatch = 1;
        context.addError('earlier failure');

        Test.startTest();
        // No items at all, so the pass fails and the chain ends with one summary
        new SLO_SelloutApplyBatch(report.Id, parent.Id, SLO_SelloutApplyBatch.MODE_INVOICE, context).finish(null);
        Test.stopTest();

        Assert.isTrue(SLO_SelloutApplyBatch.lastSummarySubject.startsWith('Sellout processing needs your decision'),
            SLO_SelloutApplyBatch.lastSummarySubject);
        Assert.areNotEqual('In_Process',
            [SELECT SLO_Status__c FROM SLO_Sellout_Report__c WHERE Id = :report.Id].SLO_Status__c);
    }

    @IsTest
    static void invoicePassLeavingItemsWaitingSaysIncomplete() {
        Account parent = makeAccount('Parent Wholesaler', null, 'Active');
        Account child = makeAccount('Known Shop', parent.Id, 'Active');
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c item = makeItem(report.Id, 'Known Shop', '1', 1, 'Matched');
        item.SLO_Matched_Account__c = child.Id;
        insert item;

        // The cursor already sits on the only item, so this pass resolves nothing and leaves it waiting
        SLO_SelloutApplyBatch.RunContext context = new SLO_SelloutApplyBatch.RunContext();
        context.invoiceCursorId = item.Id;
        context.zeroProgressPasses = 1;

        Test.startTest();
        new SLO_SelloutApplyBatch(report.Id, parent.Id, SLO_SelloutApplyBatch.MODE_INVOICE, context).finish(null);
        Test.stopTest();

        Assert.isTrue(SLO_SelloutApplyBatch.lastSummarySubject.startsWith('Sellout processing incomplete'),
            SLO_SelloutApplyBatch.lastSummarySubject);
    }

    @IsTest
    static void invoicePassWithIssuesButNoInvoicesSaysSo() {
        Account parent = makeAccount('Parent Wholesaler', null, 'Active');
        Account child = makeAccount('Known Shop', parent.Id, 'Active');
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        // No product exists for this code, so the pass flags the line and invoices nothing
        SLO_Sellout_Item__c item = makeItem(report.Id, 'Known Shop', '999999', 1, 'Matched');
        item.SLO_Matched_Account__c = child.Id;
        insert item;

        Test.startTest();
        new SLO_SelloutApplyBatch(report.Id, parent.Id, SLO_SelloutApplyBatch.MODE_INVOICE).finish(null);
        Test.stopTest();

        Assert.areEqual('Error', statusOf(item.Id));
        Assert.areEqual('Sellout processing finished with issues', SLO_SelloutApplyBatch.lastSummarySubject);
    }

    @IsTest
    static void matchPassHandlesBlankZeroAndInactiveRows() {
        Account parent = makeAccount('Parent Wholesaler', null, 'Active');
        makeAccount('Old Shop', parent.Id, 'N');
        makeAccount('Known Shop', parent.Id, 'Active');
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c blank = makeItem(report.Id, 'Cleared', '1', 1, 'Pending');
        SLO_Sellout_Item__c zero = makeItem(report.Id, 'Known Shop', '1', 0, 'Pending');
        SLO_Sellout_Item__c inactive = makeItem(report.Id, 'Old Shop', '1', 1, 'Pending');
        SLO_Sellout_Item__c known = makeItem(report.Id, 'Known Shop', '1', 1, 'Pending');
        insert new List<SLO_Sellout_Item__c>{ blank, zero, inactive, known };
        // The customer name is required on save, so a blank one only exists in memory - its flag
        // then fails to save and is counted as an error rather than stopping the scope
        blank.SLO_Customer_Account_Name__c = null;

        SLO_SelloutApplyBatch batch =
            new SLO_SelloutApplyBatch(report.Id, parent.Id, SLO_SelloutApplyBatch.MODE_MATCH);

        Test.startTest();
        batch.start(null);
        batch.execute(null, new List<SLO_Sellout_Item__c>{ blank, zero, inactive, known });
        batch.finish(null);
        Test.stopTest();

        Assert.areEqual('Pending', statusOf(blank.Id), 'The unsaved row is left as it was');
        Assert.areEqual('Skipped', statusOf(zero.Id));
        Assert.areEqual('Pending_Decision', statusOf(inactive.Id));
        Assert.areEqual(SLO_SelloutImportController.NOTE_ACCOUNT_INACTIVE,
            [SELECT SLO_Processing_Notes__c FROM SLO_Sellout_Item__c WHERE Id = :inactive.Id].SLO_Processing_Notes__c);
        Assert.areEqual('Matched', statusOf(known.Id));
    }

    @IsTest
    static void matchPassWithEverythingMatchedParksReportInDraft() {
        Account parent = makeAccount('Parent Wholesaler', null, 'Active');
        makeAccount('Known Shop', parent.Id, 'Active');
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        insert makeItem(report.Id, 'Known Shop', '1', 1, 'Pending');

        Test.startTest();
        Database.executeBatch(
            new SLO_SelloutApplyBatch(report.Id, parent.Id, SLO_SelloutApplyBatch.MODE_MATCH), 200
        );
        Test.stopTest();

        Assert.areEqual('Draft', [SELECT SLO_Status__c FROM SLO_Sellout_Report__c WHERE Id = :report.Id].SLO_Status__c);
        Assert.isNull(SLO_SelloutApplyBatch.lastSummarySubject, 'Matching alone reports on screen, not by email');
    }

    @IsTest
    static void startBuildsLocatorForEveryMode() {
        Account parent = makeAccount('Parent Wholesaler', null, 'Active');
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        insert makeItem(report.Id, 'Known Shop', '1', 1, 'Matched');

        for (String mode : new List<String>{
            SLO_SelloutApplyBatch.MODE_MATCH, SLO_SelloutApplyBatch.MODE_AUTO_STEP,
            SLO_SelloutApplyBatch.MODE_DECISION, SLO_SelloutApplyBatch.MODE_INVOICE
        }) {
            Database.QueryLocator locator =
                new SLO_SelloutApplyBatch(report.Id, parent.Id, mode).start(null);
            Assert.isNotNull(locator, 'No locator for mode ' + mode);
        }
        Assert.areEqual('In_Process',
            [SELECT SLO_Status__c FROM SLO_Sellout_Report__c WHERE Id = :report.Id].SLO_Status__c);
    }

    @IsTest
    static void autoAcceptMatchHandsOverToAutoSteps() {
        Account parent = makeAccount('Parent Wholesaler', null, 'Active');
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'In_Process');
        insert makeItem(report.Id, 'Known Shop', '1', 1, 'Matched');

        SLO_SelloutApplyBatch.RunContext context = new SLO_SelloutApplyBatch.RunContext();
        context.autoAccept = true;
        context.autoStage = 5;

        Test.startTest();
        new SLO_SelloutApplyBatch(report.Id, parent.Id, SLO_SelloutApplyBatch.MODE_MATCH, context).finish(null);
        Test.stopTest();

        Assert.areEqual(0, context.autoStage, 'Matching restarts the auto accept stages');
        Assert.isTrue(context.matchRan);
    }

    @IsTest
    static void autoAcceptStagesRunInOrderAndReport() {
        Account parent = makeAccount('Parent Wholesaler', null, 'Active');
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'In_Process');
        insert new List<SLO_Sellout_Item__c>{
            makeItem(report.Id, 'Brand New Shop', '1', 1, 'Pending_Decision'),
            makeItem(report.Id, 'Broken Row', '999999', 1, 'Error')
        };

        SLO_SelloutApplyBatch.RunContext context = new SLO_SelloutApplyBatch.RunContext();
        context.autoAccept = true;

        Test.startTest();
        for (Integer stage = 0; stage < 3; stage++) {
            Assert.areEqual(stage, context.autoStage);
            new SLO_SelloutApplyBatch(report.Id, parent.Id, SLO_SelloutApplyBatch.MODE_AUTO_STEP, context).finish(null);
        }
        Test.stopTest();

        Assert.areEqual(3, context.autoStage, 'Each finish advances one stage');
        Assert.isNotNull(SLO_SelloutApplyBatch.lastSummarySubject, 'An auto accept run always reports');
        Assert.areNotEqual('In_Process',
            [SELECT SLO_Status__c FROM SLO_Sellout_Report__c WHERE Id = :report.Id].SLO_Status__c);
    }

    @IsTest
    static void autoAcceptWithNothingLeftCompletesReport() {
        Account parent = makeAccount('Parent Wholesaler', null, 'Active');
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'In_Process');

        SLO_SelloutApplyBatch.RunContext context = new SLO_SelloutApplyBatch.RunContext();
        context.autoAccept = true;
        context.autoStage = 2;

        Test.startTest();
        new SLO_SelloutApplyBatch(report.Id, parent.Id, SLO_SelloutApplyBatch.MODE_AUTO_STEP, context).finish(null);
        Test.stopTest();

        Assert.areEqual('Completed',
            [SELECT SLO_Status__c FROM SLO_Sellout_Report__c WHERE Id = :report.Id].SLO_Status__c);
        Assert.isNotNull(SLO_SelloutApplyBatch.lastSummarySubject);
    }

    @IsTest
    static void autoAcceptWithOutstandingItemsMarksReportError() {
        Account parent = makeAccount('Parent Wholesaler', null, 'Active');
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'In_Process');
        insert makeItem(report.Id, 'Waiting Shop', '1', 1, 'Pending_Decision');

        SLO_SelloutApplyBatch.RunContext context = new SLO_SelloutApplyBatch.RunContext();
        context.autoAccept = true;
        context.addWarning('Something was left over');

        Test.startTest();
        new SLO_SelloutApplyBatch(report.Id, parent.Id, SLO_SelloutApplyBatch.MODE_DECISION, context, null).finish(null);
        Test.stopTest();

        SLO_Sellout_Report__c saved =
            [SELECT SLO_Status__c, SLO_Error_Message__c FROM SLO_Sellout_Report__c WHERE Id = :report.Id];
        Assert.areEqual('Error', saved.SLO_Status__c);
        Assert.isTrue(saved.SLO_Error_Message__c.contains('Something was left over'), saved.SLO_Error_Message__c);
    }

    @IsTest
    static void scopeSizeAndInProcessHelpersAreSafe() {
        Assert.areEqual(200, SLO_SelloutApplyBatch.scopeSizeForAttempt(null));
        Assert.areEqual(200, SLO_SelloutApplyBatch.scopeSizeForAttempt(0));
        Assert.areEqual(50, SLO_SelloutApplyBatch.scopeSizeForAttempt(9));

        // An unknown report must not throw - the flag guards the screen only
        SLO_SelloutApplyBatch.markInProcess(null);

        SLO_SelloutApplyBatch.RunContext context = new SLO_SelloutApplyBatch.RunContext();
        for (Integer i = 0; i < 12; i++) {
            context.addError('error ' + i);
            context.addWarning('warning ' + i);
        }
        Assert.areEqual(10, context.errorSamples.size());
        Assert.areEqual(10, context.warnings.size());
    }
}
