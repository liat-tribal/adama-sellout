@isTest
private with sharing class SLO_SelloutDailyAutoBatchTest {

    private static String sourceTransactionType() {
        for (Schema.PicklistEntry entry : Invoice__c.Transaction_type__c.getDescribe().getPicklistValues()) {
            if (entry.isActive() && !entry.getValue().startsWith('Internal Sellout')) {
                return entry.getValue();
            }
        }
        return null;
    }

    private static String orderStatus() {
        for (Schema.PicklistEntry entry : Order.Status.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                return entry.getValue();
            }
        }
        return null;
    }

    @TestSetup
    static void setup() {
        Account parent = new Account(
            Name = 'Daily Parent',
            BillingStreet = '1 Rue Test',
            BillingCity = 'Paris',
            BillingCountryCode = 'FR',
            BillingPostalCode = '75001',
            SLO_Automatic_Sellout__c = true,
            SLO_Sellout_Method__c = SLO_SelloutDailyAutoBatch.REQUIRED_METHOD
        );
        insert parent;

        Order goodOrder = new Order(
            AccountId = parent.Id, Status = orderStatus(), EffectiveDate = Date.today(),
            Customer_name_Description__c = 'Customer, One'
        );
        Order noNameOrder = new Order(
            AccountId = parent.Id, Status = orderStatus(), EffectiveDate = Date.today()
        );
        insert new List<Order>{ goodOrder, noNameOrder };

        Invoice__c invoice = new Invoice__c(
            Name = 'DAILY-1', Account_Name__c = parent.Id, Invoice_Date__c = Date.newInstance(2026, 3, 5),
            Transaction_type__c = sourceTransactionType(), Status__c = 'Closed', Valid__c = true,
            Usage_Company__c = 'TEST_CO', SLO_Sellout_Reviewed__c = false
        );
        insert invoice;

        insert new List<Invoice_Line_Item__c>{
            new Invoice_Line_Item__c(
                Invoice_Number__c = invoice.Id, Order__c = goodOrder.Id, Product_Name__c = 'SKU-1',
                Quantity__c = 10.50, Valid__c = true
            ),
            new Invoice_Line_Item__c(
                Invoice_Number__c = invoice.Id, Order__c = noNameOrder.Id, Product_Name__c = 'SKU-2',
                Quantity__c = 3, Valid__c = true
            )
        };
    }

    private static Account parent() {
        return [SELECT Id, Name FROM Account WHERE Name = 'Daily Parent' LIMIT 1];
    }

    @isTest
    static void schedulerRegistersJob() {
        Test.startTest();
        Id jobId = System.schedule(
            'SLO Daily Test Job', SLO_SelloutDailyAutoScheduler.CRON_DAILY_0200, new SLO_SelloutDailyAutoScheduler()
        );
        Test.stopTest();
        CronTrigger scheduledJob = [SELECT CronExpression FROM CronTrigger WHERE Id = :jobId];
        System.assertEquals(SLO_SelloutDailyAutoScheduler.CRON_DAILY_0200, scheduledJob.CronExpression);
    }

    @isTest
    static void scheduleDailyRegistersJob() {
        // Where the org already runs the daily job (e.g. production), a second job with the same name
        // cannot be scheduled; check the existing one instead
        List<CronTrigger> existing = [
            SELECT CronExpression FROM CronTrigger
            WHERE CronJobDetail.Name = 'SLO Daily Automated Sellout'
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            System.assertEquals(SLO_SelloutDailyAutoScheduler.CRON_DAILY_0200, existing[0].CronExpression);
            // Scheduling again must be refused, so the existing job is never duplicated
            Boolean refused = false;
            try {
                SLO_SelloutDailyAutoScheduler.scheduleDaily();
            } catch (AsyncException e) {
                refused = true;
            }
            System.assert(refused, 'A second daily job with the same name must not be scheduled');
            return;
        }
        Test.startTest();
        Id jobId = SLO_SelloutDailyAutoScheduler.scheduleDaily();
        Test.stopTest();
        CronTrigger scheduledJob = [SELECT CronExpression, CronJobDetail.Name FROM CronTrigger WHERE Id = :jobId];
        System.assertEquals(SLO_SelloutDailyAutoScheduler.CRON_DAILY_0200, scheduledJob.CronExpression);
        System.assertEquals('SLO Daily Automated Sellout', scheduledJob.CronJobDetail.Name);
    }

    @isTest
    static void csvBuilderWritesHeaderDateAndCountsSkippedLines() {
        SLO_SelloutDailyCsvBuilder.BuildResult result = SLO_SelloutDailyCsvBuilder.build(parent().Id);
        System.assertEquals(1, result.rowCount, 'Only the line with a customer name is written');
        System.assertEquals(1, result.skippedLines, 'The line without a customer name is skipped');
        List<String> lines = result.csv.split('\n');
        System.assertEquals(SLO_SelloutDailyCsvBuilder.HEADER, lines[0]);
        Invoice_Line_Item__c written = [
            SELECT Id FROM Invoice_Line_Item__c
            WHERE Invoice_Number__c = :result.invoiceIds[0] AND Product_Name__c != null
              AND Order__r.Customer_name_Description__c != null
            LIMIT 1
        ];
        System.assertEquals('05/03/26,SKU-1,10.5,"Customer, One",' + written.Id, lines[1]);
        System.assertEquals(1, result.invoiceIds.size());
    }

    @isTest
    static void csvBuilderIgnoresInvoicesBeforeStartDate() {
        Account parentAccount = parent();
        Order ord = [SELECT Id FROM Order WHERE Customer_name_Description__c = 'Customer, One' LIMIT 1];
        Invoice__c oldInvoice = new Invoice__c(
            Name = 'DAILY-OLD', Account_Name__c = parentAccount.Id, Invoice_Date__c = Date.newInstance(2025, 12, 31),
            Transaction_type__c = sourceTransactionType(), Status__c = 'Closed', Valid__c = true,
            Usage_Company__c = 'TEST_CO', SLO_Sellout_Reviewed__c = false
        );
        Invoice__c boundaryInvoice = new Invoice__c(
            Name = 'DAILY-EDGE', Account_Name__c = parentAccount.Id, Invoice_Date__c = Date.newInstance(2026, 1, 1),
            Transaction_type__c = sourceTransactionType(), Status__c = 'Closed', Valid__c = true,
            Usage_Company__c = 'TEST_CO', SLO_Sellout_Reviewed__c = false
        );
        insert new List<Invoice__c>{ oldInvoice, boundaryInvoice };
        insert new List<Invoice_Line_Item__c>{
            new Invoice_Line_Item__c(
                Invoice_Number__c = oldInvoice.Id, Order__c = ord.Id, Product_Name__c = 'SKU-OLD',
                Quantity__c = 1, Valid__c = true
            ),
            new Invoice_Line_Item__c(
                Invoice_Number__c = boundaryInvoice.Id, Order__c = ord.Id, Product_Name__c = 'SKU-EDGE',
                Quantity__c = 2, Valid__c = true
            )
        };

        SLO_SelloutDailyCsvBuilder.BuildResult result = SLO_SelloutDailyCsvBuilder.build(parentAccount.Id);
        System.assertEquals(2, result.rowCount, 'Only the 2026 invoices are written');
        System.assert(!result.csv.contains('SKU-OLD'), 'Invoice before the start date is ignored');
        System.assert(result.csv.contains('SKU-EDGE'), 'Invoice after the start date is included');
        System.assert(!result.invoiceIds.contains(oldInvoice.Id), 'Old invoice is never flagged');
    }

    @isTest
    static void csvBuilderReturnsEmptyResultForAccountWithoutInvoices() {
        Account other = new Account(Name = 'No Invoices');
        insert other;
        SLO_SelloutDailyCsvBuilder.BuildResult result = SLO_SelloutDailyCsvBuilder.build(other.Id);
        System.assertEquals(0, result.rowCount);
        System.assertEquals(null, result.csv);
    }

    @isTest
    static void csvHelpersFormatValues() {
        System.assertEquals('"a""b"', SLO_SelloutDailyCsvBuilder.escape('a"b'));
        System.assertEquals('', SLO_SelloutDailyCsvBuilder.escape(null));
        System.assertEquals('01/02/09', SLO_SelloutDailyCsvBuilder.formatDate(Date.newInstance(2009, 2, 1)));
        System.assertEquals('4', SLO_SelloutDailyCsvBuilder.formatQuantity(4.00));
    }

    @isTest
    static void batchCreatesReportWithCountsAndFlagsInvoicesOnce() {
        Account parentAccount = parent();

        Test.startTest();
        Database.executeBatch(new SLO_SelloutDailyAutoBatch(), SLO_SelloutDailyAutoBatch.SCOPE_SIZE);
        Test.stopTest();

        List<SLO_Sellout_Report__c> reports = [
            SELECT Id, SLO_Lines_Processed__c, SLO_Lines_Skipped__c, SLO_Auto_Accepted__c
            FROM SLO_Sellout_Report__c WHERE SLO_Account__c = :parentAccount.Id
        ];
        System.assertEquals(1, reports.size());
        System.assertEquals(1, reports[0].SLO_Lines_Processed__c);
        System.assertEquals(1, reports[0].SLO_Lines_Skipped__c);
        System.assertEquals(true, reports[0].SLO_Auto_Accepted__c);

        Invoice__c invoice = [SELECT SLO_Sellout_Reviewed__c FROM Invoice__c WHERE Name = 'DAILY-1'];
        System.assertEquals(true, invoice.SLO_Sellout_Reviewed__c, 'Invoice is flagged once the file is saved');
        System.assertEquals(1, [
            SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :reports[0].Id
        ]);

        Database.executeBatch(new SLO_SelloutDailyAutoBatch(), SLO_SelloutDailyAutoBatch.SCOPE_SIZE);
        System.assertEquals(1, [
            SELECT COUNT() FROM SLO_Sellout_Report__c WHERE SLO_Account__c = :parentAccount.Id
        ], 'A second run does not duplicate the report');
    }

    private static Account makeChild(Account parentAccount, String name, String status) {
        Account child = new Account(
            Name = name, ParentId = parentAccount.Id, Status__c = status,
            BillingStreet = '1 Rue Test', BillingCity = 'Paris',
            BillingCountryCode = 'FR', BillingPostalCode = '75001'
        );
        // Same-name accounts are intentional in tests, so bypass the duplicate rules
        Database.DMLOptions dmlOptions = new Database.DMLOptions();
        dmlOptions.DuplicateRuleHeader.allowSave = true;
        Database.insert(child, dmlOptions);
        return child;
    }

    private static Order makeOrderOnInvoice(Account parentAccount, String customerName, Integer lineNo) {
        Order ord = new Order(
            AccountId = parentAccount.Id, Status = orderStatus(), EffectiveDate = Date.today(),
            Customer_name_Description__c = customerName
        );
        insert ord;
        insert new Invoice_Line_Item__c(
            Invoice_Number__c = [SELECT Id FROM Invoice__c WHERE Name = 'DAILY-1'].Id, Order__c = ord.Id,
            Product_Name__c = 'SKU-X' + lineNo, Quantity__c = 1, Valid__c = true
        );
        return ord;
    }

    private static Id childOf(Order ord) {
        return [SELECT Child_Account_Non_SBO__c FROM Order WHERE Id = :ord.Id].Child_Account_Non_SBO__c;
    }

    @isTest
    static void orderChildAccountPrefersActiveAndMatchesInvoiceAccount() {
        Account parentAccount = parent();
        // The inactive account is created first, so an org-wide name query would return it first
        Account inactive = makeChild(parentAccount, 'NORD NEGOCE', 'Y');
        Account active = makeChild(parentAccount, 'NORD NEGOCE', 'N');
        Order ord = makeOrderOnInvoice(parentAccount, ' NORD NEGOCE ', 1);

        Test.startTest();
        Database.executeBatch(new SLO_SelloutDailyAutoBatch(), SLO_SelloutDailyAutoBatch.SCOPE_SIZE);
        Test.stopTest();

        Id written = childOf(ord);
        System.assertEquals(active.Id, written, 'The active account wins over the inactive one');
        System.assertNotEquals(inactive.Id, written);
        System.assertEquals(
            SLO_SelloutAccountMatcher.resolve(parentAccount.Id, new Set<String>{ 'NORD NEGOCE' })
                .get(SLO_SelloutImportController.nameKey('NORD NEGOCE')).accountId,
            written, 'Order and invoice lines use the same account'
        );
    }

    @isTest
    static void orderChildAccountUsesInactiveWhenOnlyInactiveExists() {
        Account parentAccount = parent();
        Account inactive = makeChild(parentAccount, 'Old Customer', 'Inactive');
        Order ord = makeOrderOnInvoice(parentAccount, 'Old Customer', 1);

        Test.startTest();
        Database.executeBatch(new SLO_SelloutDailyAutoBatch(), SLO_SelloutDailyAutoBatch.SCOPE_SIZE);
        Test.stopTest();

        System.assertEquals(inactive.Id, childOf(ord));
    }

    @isTest
    static void orderChildAccountCreatedWhenNoMatch() {
        Account parentAccount = parent();
        Order ord = makeOrderOnInvoice(parentAccount, 'Brand New Customer', 1);

        Test.startTest();
        Database.executeBatch(new SLO_SelloutDailyAutoBatch(), SLO_SelloutDailyAutoBatch.SCOPE_SIZE);
        Test.stopTest();

        Id written = childOf(ord);
        System.assertNotEquals(null, written);
        Account created = [SELECT Name, ParentId FROM Account WHERE Id = :written];
        System.assertEquals(
            SLO_SelloutImportController.buildSelloutAccountName('Brand New Customer', parentAccount.Name),
            created.Name
        );
        System.assertEquals(parentAccount.Id, created.ParentId);
    }

    @isTest
    static void orderChildAccountUnchangedForDistributorCustomerAndWhenAlreadySet() {
        Account parentAccount = parent();
        Account existing = makeChild(parentAccount, 'Preset Customer', 'Active');
        Order distributorOrder = makeOrderOnInvoice(parentAccount, '  daily PARENT ', 1);
        Order presetOrder = makeOrderOnInvoice(parentAccount, 'Preset Customer', 2);
        Account other = makeChild(parentAccount, 'Other Child', 'Active');
        presetOrder.Child_Account_Non_SBO__c = other.Id;
        update presetOrder;

        Test.startTest();
        Database.executeBatch(new SLO_SelloutDailyAutoBatch(), SLO_SelloutDailyAutoBatch.SCOPE_SIZE);
        Test.stopTest();

        System.assertEquals(null, childOf(distributorOrder), 'Distributor-as-customer leaves the Order unchanged');
        System.assertEquals(0, [SELECT COUNT() FROM Account WHERE Name LIKE 'daily PARENT%Sellout%'],
            'No account is created for the distributor itself');
        System.assertEquals(other.Id, childOf(presetOrder), 'A filled Order field is never overwritten');
        System.assertNotEquals(null, existing.Id);
    }

    @isTest
    static void batchSkipsAccountWithWrongMethodAndSendsNoEmail() {
        Account parentAccount = parent();
        parentAccount.SLO_Automatic_Sellout__c = false;
        parentAccount.SLO_Sellout_Method__c = null;
        update parentAccount;

        Test.startTest();
        Database.executeBatch(new SLO_SelloutDailyAutoBatch(), SLO_SelloutDailyAutoBatch.SCOPE_SIZE);
        Integer emails = Limits.getEmailInvocations();
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM SLO_Sellout_Report__c WHERE SLO_Account__c = :parentAccount.Id]);
        System.assertEquals(false, [SELECT SLO_Sellout_Reviewed__c FROM Invoice__c WHERE Name = 'DAILY-1'].SLO_Sellout_Reviewed__c);
        System.assertEquals(0, emails, 'No failure email when nothing failed');
    }

    @isTest
    static void batchDoesNothingWhenNoUnreviewedInvoices() {
        Account parentAccount = parent();
        update new Invoice__c(
            Id = [SELECT Id FROM Invoice__c WHERE Name = 'DAILY-1'].Id, SLO_Sellout_Reviewed__c = true
        );

        Test.startTest();
        Database.executeBatch(new SLO_SelloutDailyAutoBatch(), SLO_SelloutDailyAutoBatch.SCOPE_SIZE);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM SLO_Sellout_Report__c WHERE SLO_Account__c = :parentAccount.Id]);
    }
}