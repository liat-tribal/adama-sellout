/**
 * @description Test class for SLO_SelloutInvoiceReviewBatch and SLO_SelloutInvoiceReviewScheduler
 * Provides comprehensive test coverage for batch processing, account matching/creation,
 * invoice creation, child account naming convention, and scheduler execution.
 */
@isTest
private class SLO_SelloutInvoiceReviewBatchTest {

    private static final String SELLOUT_TYPE = 'Internal Sellout';

    /**
     * @description Resolves an active Transaction_type__c value for source invoices.
     * The picklist is restricted in the org, so hard-coded values fail on insert.
     */
    private static String sourceTransactionType(Integer index) {
        List<String> vals = new List<String>();
        for (Schema.PicklistEntry entry : Invoice__c.Transaction_type__c.getDescribe().getPicklistValues()) {
            if (entry.isActive() && !entry.getValue().startsWith(SELLOUT_TYPE)) {
                vals.add(entry.getValue());
            }
        }
        if (vals.isEmpty()) {
            return null;
        }
        return vals[Math.min(index, vals.size() - 1)];
    }

    /**
     * @description True when the org still exposes Internal Sellout as an active picklist value
     */
    private static Boolean isSelloutTypeActive() {
        for (Schema.PicklistEntry entry : Invoice__c.Transaction_type__c.getDescribe().getPicklistValues()) {
            if (entry.isActive() && SELLOUT_TYPE.equals(entry.getValue())) {
                return true;
            }
        }
        return false;
    }

    /**
     * @description Resolves an active Order.Status value, preferring Draft when available
     */
    private static String defaultOrderStatus() {
        List<Schema.PicklistEntry> entries = Order.Status.getDescribe().getPicklistValues();
        for (Schema.PicklistEntry entry : entries) {
            if (entry.isActive() && 'Draft'.equals(entry.getValue())) {
                return entry.getValue();
            }
        }
        for (Schema.PicklistEntry entry : entries) {
            if (entry.isActive()) {
                return entry.getValue();
            }
        }
        return null;
    }

    /**
     * @description Setup test data for all test methods
     */
    @TestSetup
    static void setupTestData() {
        // Create parent account with billing address, opted in to the automated sellout - the
        // batch only reviews invoices of accounts carrying this flag
        Account parentAccount = new Account(
            Name = 'Test Parent Account',
            BillingStreet = '123 Test Street',
            BillingCity = 'Test City',
            BillingCountryCode = 'FR',
            BillingPostalCode = '75001',
            SLO_Automatic_Sellout__c = true,
            SLO_Sellout_Method__c = 'By_linked_order_details'
        );
        insert parentAccount;

        // Create an existing child account for matching scenario
        Account existingChildAccount = new Account(
            Name = 'AGORA',
            ParentId = parentAccount.Id
        );
        insert existingChildAccount;

        // Create Orders with Buyer Group Information
        Order order1 = new Order(
            AccountId = parentAccount.Id,
            Status = defaultOrderStatus(),
            EffectiveDate = Date.today(),
            Customer_name_Description__c = 'AGORA',
            Customer_City__c = 'PARIS',
            Customer_EAI_Code__c = 'EAI123'
        );

        Order order2 = new Order(
            AccountId = parentAccount.Id,
            Status = defaultOrderStatus(),
            EffectiveDate = Date.today(),
            Customer_name_Description__c = 'METRO',
            Customer_City__c = 'LYON',
            Customer_EAI_Code__c = 'EAI456'
        );

        insert new List<Order>{order1, order2};

        // A catalogue product for tests that need one; source lines carry the product name as text
        Product2 product = new Product2(Name = 'Test Sellout Product', IsActive = true);
        insert product;

        // Create source invoices (not Internal Sellout)
        Invoice__c invoice1 = new Invoice__c(
            Name = 'INV-1001',
            Account_Name__c = parentAccount.Id,
            Invoice_Date__c = Date.today(),
            Transaction_type__c = sourceTransactionType(0),
            Status__c = 'Closed',
            Delivered_VN__c = false,
            Manual_Creation__c = false,
            Valid__c = true,
            Usage_Company__c = 'TEST_CO',
            SLO_Sellout_Reviewed__c = false
        );

        Invoice__c invoice2 = new Invoice__c(
            Name = 'INV-1002',
            Account_Name__c = parentAccount.Id,
            Invoice_Date__c = Date.today(),
            Transaction_type__c = sourceTransactionType(1),
            Status__c = 'Closed',
            Delivered_VN__c = false,
            Manual_Creation__c = false,
            Valid__c = true,
            Usage_Company__c = 'TEST_CO',
            SLO_Sellout_Reviewed__c = false
        );

        List<Invoice__c> sourceInvoices = new List<Invoice__c>{invoice1, invoice2};

        // Create invoice that should be skipped (already Internal Sellout).
        // Only possible when the org keeps that restricted picklist value active.
        if (isSelloutTypeActive()) {
            sourceInvoices.add(new Invoice__c(
                Account_Name__c = parentAccount.Id,
                Invoice_Date__c = Date.today(),
                Transaction_type__c = SELLOUT_TYPE,
                Status__c = 'Closed',
                Delivered_VN__c = false,
                Manual_Creation__c = false,
                Valid__c = true,
                Usage_Company__c = 'TEST_CO',
                SLO_Sellout_Reviewed__c = false
            ));
        }

        insert sourceInvoices;

        // Create invoice line items with Order lookups
        Invoice_Line_Item__c lineItem1 = new Invoice_Line_Item__c(
            Invoice_Number__c = invoice1.Id,
            Order__c = order1.Id,
            Product_Name__c = 'Product A',
            Quantity__c = 10,
            Valid__c = true,
            Net_Price__c = 100,
            Gross_Value__c = 120,
            Gross_Price__c = 12,
            Total_After_Discount__c = 110,
            Unit_Price__c = 10,
            VAT_In_Original_Price__c = 20,
            VAT_In_Dollars__c = 22
        );

        Invoice_Line_Item__c lineItem2 = new Invoice_Line_Item__c(
            Invoice_Number__c = invoice1.Id,
            Order__c = order1.Id,
            Product_Name__c = 'Product B',
            Quantity__c = 5,
            Valid__c = true,
            Net_Price__c = 50,
            Gross_Value__c = 60,
            Gross_Price__c = 12,
            Total_After_Discount__c = 55,
            Unit_Price__c = 10,
            VAT_In_Original_Price__c = 10,
            VAT_In_Dollars__c = 11
        );

        Invoice_Line_Item__c lineItem3 = new Invoice_Line_Item__c(
            Invoice_Number__c = invoice2.Id,
            Order__c = order2.Id,
            Product_Name__c = 'Product C',
            Quantity__c = 20,
            Valid__c = true,
            Net_Price__c = 200,
            Gross_Value__c = 240,
            Gross_Price__c = 12,
            Total_After_Discount__c = 220,
            Unit_Price__c = 10,
            VAT_In_Original_Price__c = 40,
            VAT_In_Dollars__c = 44
        );

        // Line item without Order (should be skipped)
        Invoice_Line_Item__c lineItem4 = new Invoice_Line_Item__c(
            Invoice_Number__c = invoice2.Id,
            Product_Name__c = 'Product D',
            Quantity__c = 15,
            Valid__c = true
        );

        insert new List<Invoice_Line_Item__c>{lineItem1, lineItem2, lineItem3, lineItem4};
    }

    /**
     * @description Test batch processing with existing child account match
     */
    @isTest
    static void testBatchWithExistingChildAccount() {
        // Get test data
        Account parentAccount = [SELECT Id FROM Account WHERE Name = 'Test Parent Account' LIMIT 1];
        Account existingChildAccount = [SELECT Id FROM Account WHERE Name = 'AGORA' LIMIT 1];

        Test.startTest();

        // Execute batch for today's date range
        SLO_SelloutInvoiceReviewBatch batch = new SLO_SelloutInvoiceReviewBatch(Date.today(), Date.today());
        Database.executeBatch(batch, 200);

        Test.stopTest();

        // Verify source invoices marked as reviewed (excluding Internal Sellout)
        List<Invoice__c> reviewedInvoices = [
            SELECT Id, SLO_Sellout_Reviewed__c, Transaction_type__c
            FROM Invoice__c
            WHERE SLO_Sellout_Reviewed__c = true
        ];
        System.assertEquals(2, reviewedInvoices.size(), 'Two invoices should be marked as reviewed');

        // Verify new Internal Sellout invoices created. The batch writes that restricted
        // picklist value, so it can only succeed while the value is active in the org.
        if (isSelloutTypeActive()) {
            List<Invoice__c> newInvoices = [
                SELECT Id, Account_Name__c, Transaction_type__c, Child_Account_Non_SBO__c, Usage_Company__c
                FROM Invoice__c
                WHERE Transaction_type__c = :SELLOUT_TYPE
                AND Account_Name__c = :existingChildAccount.Id
            ];
            System.assert(newInvoices.size() >= 1, 'At least one Internal Sellout invoice should be created for existing child account');
            System.assertEquals('TEST_CO', newInvoices[0].Usage_Company__c, 'Usage Company should be copied from source invoice');

            // Verify new invoice line items created
            List<Invoice_Line_Item__c> newLineItems = [
                SELECT Id, Invoice_Number__c, Product_Name__c, Quantity__c
                FROM Invoice_Line_Item__c
                WHERE Invoice_Number__c IN (SELECT Id FROM Invoice__c WHERE Transaction_type__c = :SELLOUT_TYPE)
            ];
            System.assert(newLineItems.size() >= 2, 'Line items should be created for new invoices');
        }

        // Verify Orders updated with Child_Account_Non_SBO__c
        List<Order> updatedOrders = [
            SELECT Id, Child_Account_Non_SBO__c, Customer_name_Description__c, Customer_City__c
            FROM Order
            WHERE Customer_name_Description__c = 'AGORA'
            AND Customer_City__c = 'PARIS'
        ];
        System.assertEquals(1, updatedOrders.size(), 'Order should be found');
        System.assertEquals(existingChildAccount.Id, updatedOrders[0].Child_Account_Non_SBO__c, 'Order should be linked to child account');
    }

    /**
     * @description Test batch processing with new child account creation
     */
    @isTest
    static void testBatchWithNewChildAccountCreation() {
        // Get test data
        Account parentAccount = [SELECT Id FROM Account WHERE Name = 'Test Parent Account' LIMIT 1];

        Test.startTest();

        // Execute batch for today's date range
        SLO_SelloutInvoiceReviewBatch batch = new SLO_SelloutInvoiceReviewBatch(Date.today(), Date.today());
        Database.executeBatch(batch, 200);

        Test.stopTest();

        // Verify new child account created for METRO under the shared sellout naming convention
        String expectedName = SLO_SelloutImportController.buildSelloutAccountName(
            'METRO', 'Test Parent Account'
        );
        List<Account> newChildAccounts = [
            SELECT Id, Name, ParentId, Status__c, BillingStreet, BillingCity,
                   BillingCountryCode, BillingPostalCode
            FROM Account
            WHERE Name = :expectedName
        ];
        System.assertEquals(1, newChildAccounts.size(),
            'New child account ' + expectedName + ' should be created');
        System.assertEquals(parentAccount.Id, newChildAccounts[0].ParentId, 'New child account should be under parent account');
        System.assertEquals('Active', newChildAccounts[0].Status__c,
            'Sellout-created accounts are active, the same as the import wizard creates them');

        // Verify billing address copied from parent
        Account parentAcct = [SELECT BillingStreet, BillingCity, BillingCountryCode, BillingPostalCode
                              FROM Account WHERE Id = :parentAccount.Id];
        System.assertEquals(parentAcct.BillingStreet, newChildAccounts[0].BillingStreet, 'BillingStreet should be copied from parent');
        System.assertEquals(parentAcct.BillingCity, newChildAccounts[0].BillingCity, 'BillingCity should be copied from parent');
        System.assertEquals(parentAcct.BillingCountryCode, newChildAccounts[0].BillingCountryCode, 'BillingCountryCode should be copied from parent');
        System.assertEquals(parentAcct.BillingPostalCode, newChildAccounts[0].BillingPostalCode, 'BillingPostalCode should be copied from parent');

        // Verify new Internal Sellout invoice created for new child account
        if (isSelloutTypeActive()) {
            List<Invoice__c> newInvoices = [
                SELECT Id, Account_Name__c, Transaction_type__c, Child_Account_Non_SBO__c
                FROM Invoice__c
                WHERE Transaction_type__c = :SELLOUT_TYPE
                AND Account_Name__c = :newChildAccounts[0].Id
            ];
            System.assertEquals(1, newInvoices.size(), 'Internal Sellout invoice should be created for new child account');
            System.assertEquals(newChildAccounts[0].Id, newInvoices[0].Child_Account_Non_SBO__c, 'Child_Account_Non_SBO__c should be populated');
        }
    }

    /**
     * @description Test scheduler execution
     */
    @isTest
    static void testScheduler() {
        Test.startTest();

        // Schedule the job
        String cronExp = '0 0 22 ? * FRI';
        String jobId = System.schedule('Test SLO Invoice Review', cronExp, new SLO_SelloutInvoiceReviewScheduler());

        Test.stopTest();

        // Verify scheduled job exists
        List<CronTrigger> scheduledJobs = [
            SELECT Id, CronExpression, TimesTriggered, NextFireTime
            FROM CronTrigger
            WHERE Id = :jobId
        ];
        System.assertEquals(1, scheduledJobs.size(), 'Scheduled job should exist');
        System.assertEquals(cronExp, scheduledJobs[0].CronExpression, 'Cron expression should match');
    }

    /**
     * @description Test batch with invoices already reviewed
     */
    @isTest
    static void testBatchWithReviewedInvoices() {
        // Mark all invoices as reviewed
        List<Invoice__c> invoices = [SELECT Id FROM Invoice__c];
        for (Invoice__c inv : invoices) {
            inv.SLO_Sellout_Reviewed__c = true;
        }
        update invoices;

        Test.startTest();

        // Execute batch
        SLO_SelloutInvoiceReviewBatch batch = new SLO_SelloutInvoiceReviewBatch(Date.today(), Date.today());
        Database.executeBatch(batch, 200);

        Test.stopTest();

        // Verify no new Internal Sellout invoices created. Only the one seeded in setup
        // may exist, and setup only seeds it when the picklist value is active.
        List<Invoice__c> newInvoices = [
            SELECT Id
            FROM Invoice__c
            WHERE Transaction_type__c = :SELLOUT_TYPE
        ];
        Integer expectedSelloutInvoices = isSelloutTypeActive() ? 1 : 0;
        System.assertEquals(expectedSelloutInvoices, newInvoices.size(), 'Only the existing Internal Sellout invoice should exist (no new ones)');
    }

    /**
     * @description Test batch with empty date range
     */
    @isTest
    static void testBatchWithEmptyDateRange() {
        Test.startTest();

        // Execute batch with future date range (no invoices)
        Date futureDate = Date.today().addDays(30);
        SLO_SelloutInvoiceReviewBatch batch = new SLO_SelloutInvoiceReviewBatch(futureDate, futureDate.addDays(7));
        Database.executeBatch(batch, 200);

        Test.stopTest();

        // Verify no new Internal Sellout invoices created. Setup already seeds one such invoice
        // today when the picklist value is active, so that one is expected and nothing more.
        List<Invoice__c> newInvoices = [
            SELECT Id
            FROM Invoice__c
            WHERE Transaction_type__c = :SELLOUT_TYPE
            AND CreatedDate = TODAY
        ];
        Integer expectedSelloutInvoices = isSelloutTypeActive() ? 1 : 0;
        System.assertEquals(expectedSelloutInvoices, newInvoices.size(), 'No new invoices should be created for future date range');
    }

    /**
     * @description Test batch with usage company filter
     */
    @isTest
    static void testBatchWithUsageCompanyFilter() {
        // Get test data
        Account parentAccount = [SELECT Id FROM Account WHERE Name = 'Test Parent Account' LIMIT 1];

        // Create invoices with different usage companies
        Invoice__c invoiceFR = new Invoice__c(
            Account_Name__c = parentAccount.Id,
            Invoice_Date__c = Date.today(),
            Transaction_type__c = sourceTransactionType(0),
            Status__c = 'Closed',
            Delivered_VN__c = false,
            Manual_Creation__c = false,
            Valid__c = true,
            Usage_Company__c = 'FR',
            SLO_Sellout_Reviewed__c = false
        );

        Invoice__c invoiceUS = new Invoice__c(
            Account_Name__c = parentAccount.Id,
            Invoice_Date__c = Date.today(),
            Transaction_type__c = sourceTransactionType(0),
            Status__c = 'Closed',
            Delivered_VN__c = false,
            Manual_Creation__c = false,
            Valid__c = true,
            Usage_Company__c = 'US',
            SLO_Sellout_Reviewed__c = false
        );

        insert new List<Invoice__c>{invoiceFR, invoiceUS};

        // Create orders for line items
        Order orderFR = new Order(
            AccountId = parentAccount.Id,
            Status = defaultOrderStatus(),
            EffectiveDate = Date.today(),
            Customer_name_Description__c = 'FRANCE_CUSTOMER',
            Customer_City__c = 'PARIS'
        );
        insert orderFR;

        // Create line items
        Invoice_Line_Item__c lineItemFR = new Invoice_Line_Item__c(
            Invoice_Number__c = invoiceFR.Id,
            Order__c = orderFR.Id,
            Product_Name__c = 'Product FR',
            Quantity__c = 10,
            Valid__c = true
        );
        insert lineItemFR;

        Test.startTest();

        // Execute batch with France filter only
        SLO_SelloutInvoiceReviewBatch batch = new SLO_SelloutInvoiceReviewBatch(Date.today(), Date.today(), 'FR');
        Database.executeBatch(batch, 200);

        Test.stopTest();

        // Verify only France invoice was reviewed
        Invoice__c frInvoiceAfter = [SELECT Id, SLO_Sellout_Reviewed__c FROM Invoice__c WHERE Id = :invoiceFR.Id];
        Invoice__c usInvoiceAfter = [SELECT Id, SLO_Sellout_Reviewed__c FROM Invoice__c WHERE Id = :invoiceUS.Id];

        System.assertEquals(true, frInvoiceAfter.SLO_Sellout_Reviewed__c, 'France invoice should be marked as reviewed');
        System.assertEquals(false, usInvoiceAfter.SLO_Sellout_Reviewed__c, 'US invoice should not be reviewed when filtering by FR');

        // Verify Internal Sellout invoice created for France customer
        if (isSelloutTypeActive()) {
            List<Invoice__c> newInvoices = [
                SELECT Id, Account_Name__c, Transaction_type__c, Usage_Company__c
                FROM Invoice__c
                WHERE Transaction_type__c = :SELLOUT_TYPE
                AND Usage_Company__c = 'FR'
            ];
            System.assert(newInvoices.size() >= 1, 'Internal Sellout invoice should be created for France customer');
        }
    }

    /**
     * @description Test child account name derivation with only customer name
     */
    @isTest
    static void testChildAccountNameDerivationWithNameOnly() {
        // Create order with only customer name (no city)
        Account parentAccount = [SELECT Id FROM Account WHERE Name = 'Test Parent Account' LIMIT 1];

        Order order = new Order(
            AccountId = parentAccount.Id,
            Status = defaultOrderStatus(),
            EffectiveDate = Date.today(),
            Customer_name_Description__c = 'SOLO_NAME',
            Customer_City__c = null
        );
        insert order;

        Invoice__c invoice = new Invoice__c(
            Account_Name__c = parentAccount.Id,
            Invoice_Date__c = Date.today(),
            Transaction_type__c = sourceTransactionType(0),
            Status__c = 'Closed',
            Delivered_VN__c = false,
            Manual_Creation__c = false,
            Valid__c = true,
            SLO_Sellout_Reviewed__c = false
        );
        insert invoice;

        Invoice_Line_Item__c lineItem = new Invoice_Line_Item__c(
            Invoice_Number__c = invoice.Id,
            Order__c = order.Id,
            Product_Name__c = 'Product X',
            Quantity__c = 10,
            Valid__c = true
        );
        insert lineItem;

        Test.startTest();

        // Execute batch
        SLO_SelloutInvoiceReviewBatch batch = new SLO_SelloutInvoiceReviewBatch(Date.today(), Date.today());
        Database.executeBatch(batch, 200);

        Test.stopTest();

        // Verify child account created with name only, under the shared sellout naming convention
        String expectedName = SLO_SelloutImportController.buildSelloutAccountName(
            'SOLO_NAME', 'Test Parent Account'
        );
        List<Account> childAccounts = [
            SELECT Id, Name
            FROM Account
            WHERE Name = :expectedName
        ];
        System.assertEquals(1, childAccounts.size(), 'Child account should be created with name only');
    }

    /**
     * @description Test that accounts without the automated sellout flag are left alone
     */
    @isTest
    static void testBatchSkipsAccountsWithoutAutomationFlag() {
        // An account that has not opted in to the automated sellout
        Account optedOutAccount = new Account(
            Name = 'Opted Out Account',
            BillingCountryCode = 'FR',
            SLO_Automatic_Sellout__c = false
        );
        insert optedOutAccount;

        Invoice__c optedOutInvoice = new Invoice__c(
            Account_Name__c = optedOutAccount.Id,
            Invoice_Date__c = Date.today(),
            Transaction_type__c = sourceTransactionType(0),
            Status__c = 'Closed',
            Delivered_VN__c = false,
            Manual_Creation__c = false,
            Valid__c = true,
            SLO_Sellout_Reviewed__c = false
        );
        insert optedOutInvoice;

        Test.startTest();
        SLO_SelloutInvoiceReviewBatch batch = new SLO_SelloutInvoiceReviewBatch(Date.today(), Date.today());
        Database.executeBatch(batch, 200);
        Test.stopTest();

        Invoice__c untouched = [
            SELECT Id, SLO_Sellout_Reviewed__c
            FROM Invoice__c
            WHERE Id = :optedOutInvoice.Id
        ];
        System.assertEquals(false, untouched.SLO_Sellout_Reviewed__c,
            'An invoice of an account without the flag must not be reviewed');
    }

    /**
     * @description Record type Id of the non-SBO distributor/dealer account record type, or null
     * when the org does not expose it
     */
    private static Id nonSboAccountRecordTypeId() {
        for (Schema.RecordTypeInfo info :
                Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().values()) {
            if (info.isAvailable() && info.getName() != null &&
                info.getName().toLowerCase().contains('non-sbo')) {
                return info.getRecordTypeId();
            }
        }
        return null;
    }

    /**
     * @description A created child account carries the same record type the manual Apply Sellout
     * path stamps, so both routes produce identical accounts
     */
    @isTest
    static void testCreatedChildAccountUsesNonSboRecordType() {
        Test.startTest();
        Database.executeBatch(new SLO_SelloutInvoiceReviewBatch(Date.today(), Date.today()), 200);
        Test.stopTest();

        String expectedName = SLO_SelloutImportController.buildSelloutAccountName(
            'METRO', 'Test Parent Account'
        );
        Account created = [
            SELECT Id, RecordTypeId, Status__c
            FROM Account
            WHERE Name = :expectedName
            LIMIT 1
        ];
        System.assertEquals('Active', created.Status__c, 'Created child accounts are active');

        Id expectedRecordTypeId = nonSboAccountRecordTypeId();
        if (expectedRecordTypeId != null) {
            System.assertEquals(expectedRecordTypeId, created.RecordTypeId,
                'Created child account should carry the non-SBO distributor record type');
        }
    }

    /**
     * @description Line-level financials are copied from the source lines, the parent totals are
     * then calculated by the platform, and the invoice carries a derived invoice number
     */
    @isTest
    static void testFinancialsCopiedAndInvoiceNumbered() {
        if (!isSelloutTypeActive()) {
            return;
        }

        Test.startTest();
        Database.executeBatch(new SLO_SelloutInvoiceReviewBatch(Date.today(), Date.today()), 200);
        Test.stopTest();

        List<Invoice__c> created = [
            SELECT Id, Name, Total_Invoice_Value__c, Total_Gross_Value__c, Total_VAT__c, Net_Price__c
            FROM Invoice__c
            WHERE Transaction_type__c = :SELLOUT_TYPE
            AND Name LIKE 'INV-100%'
        ];
        System.assertEquals(2, created.size(),
            'One sellout invoice per source invoice should be created and numbered');

        Set<String> names = new Set<String>();
        for (Invoice__c inv : created) {
            names.add(inv.Name);
        }
        System.assert(names.contains('INV-1001-SO'),
            'Invoice number should be derived from the source invoice number');
        System.assert(names.contains('INV-1002-SO'),
            'Invoice number should be derived from the source invoice number');

        List<Invoice_Line_Item__c> lines = [
            SELECT Id, Net_Price__c, Gross_Value__c, Gross_Price__c, Total_After_Discount__c,
                   Unit_Price__c, VAT_In_Original_Price__c, VAT_In_Dollars__c
            FROM Invoice_Line_Item__c
            WHERE Invoice_Number__c IN :created
        ];
        System.assertEquals(3, lines.size(), 'Every source line with a product should be copied');

        Decimal netTotal = 0;
        for (Invoice_Line_Item__c line : lines) {
            System.assertNotEquals(null, line.Net_Price__c, 'Net value should be copied');
            System.assertNotEquals(null, line.Gross_Value__c, 'Gross value should be copied');
            System.assertNotEquals(null, line.Gross_Price__c, 'Gross price should be copied');
            System.assertNotEquals(null, line.Total_After_Discount__c,
                'Total after discount should be copied');
            System.assertNotEquals(null, line.Unit_Price__c, 'Invoice price should be copied');
            System.assertNotEquals(null, line.VAT_In_Original_Price__c, 'VAT should be copied');
            System.assertNotEquals(null, line.VAT_In_Dollars__c, 'VAT in dollars should be copied');
            netTotal += line.Net_Price__c;
        }
        System.assertEquals(350, netTotal, 'Copied net values should match the source lines');

        // The parent totals are platform roll-ups, so they are only populated once the child lines
        // exist - re-query to confirm they are no longer zero
        Decimal rolledUpNet = 0;
        for (Invoice__c inv : [
            SELECT Id, Net_Price__c FROM Invoice__c WHERE Id IN :created
        ]) {
            rolledUpNet += inv.Net_Price__c == null ? 0 : inv.Net_Price__c;
        }
        System.assertEquals(350, rolledUpNet,
            'Invoice totals should roll up from the copied line values');
    }

    /**
     * @description When the end customer on the order is the invoice's own account there is no
     * distinct child customer, so Child_Account_Non_SBO__c is left empty rather than echoing it
     */
    @isTest
    static void testSelfResolvingCustomerLeavesChildAccountEmpty() {
        if (!isSelloutTypeActive()) {
            return;
        }

        Account parentAccount = [SELECT Id, Name FROM Account WHERE Name = 'Test Parent Account' LIMIT 1];

        // The order records the distributor's own name as the end customer
        Order selfOrder = new Order(
            AccountId = parentAccount.Id,
            Status = defaultOrderStatus(),
            EffectiveDate = Date.today(),
            Customer_name_Description__c = parentAccount.Name
        );
        insert selfOrder;

        Invoice__c sourceInvoice = new Invoice__c(
            Name = 'INV-2001',
            Account_Name__c = parentAccount.Id,
            Invoice_Date__c = Date.today(),
            Transaction_type__c = sourceTransactionType(0),
            Status__c = 'Closed',
            Delivered_VN__c = false,
            Manual_Creation__c = false,
            Valid__c = true,
            SLO_Sellout_Reviewed__c = false
        );
        insert sourceInvoice;

        insert new Invoice_Line_Item__c(
            Invoice_Number__c = sourceInvoice.Id,
            Order__c = selfOrder.Id,
            Product_Name__c = 'Product Self',
            Quantity__c = 4,
            Valid__c = true,
            Net_Price__c = 40
        );

        Test.startTest();
        Database.executeBatch(new SLO_SelloutInvoiceReviewBatch(Date.today(), Date.today()), 200);
        Test.stopTest();

        List<Invoice__c> selfInvoices = [
            SELECT Id, Account_Name__c, Child_Account_Non_SBO__c
            FROM Invoice__c
            WHERE Name = 'INV-2001-SO'
        ];
        System.assertEquals(1, selfInvoices.size(), 'A sellout invoice should still be created');
        System.assertEquals(parentAccount.Id, selfInvoices[0].Account_Name__c,
            'The invoice is assigned to the resolved account');
        System.assertEquals(null, selfInvoices[0].Child_Account_Non_SBO__c,
            'No distinct child customer was identified, so the field stays empty');
    }

    /**
     * @description A genuinely distinct child customer is assigned to both the invoice account and
     * the non-SBO child account field, and an existing account is reused rather than duplicated
     */
    @isTest
    static void testDistinctChildAccountIsAssignedAndReused() {
        if (!isSelloutTypeActive()) {
            return;
        }

        Account existingChildAccount = [SELECT Id FROM Account WHERE Name = 'AGORA' LIMIT 1];

        Test.startTest();
        Database.executeBatch(new SLO_SelloutInvoiceReviewBatch(Date.today(), Date.today()), 200);
        Test.stopTest();

        List<Invoice__c> agoraInvoices = [
            SELECT Id, Account_Name__c, Child_Account_Non_SBO__c
            FROM Invoice__c
            WHERE Transaction_type__c = :SELLOUT_TYPE
            AND Account_Name__c = :existingChildAccount.Id
        ];
        System.assertEquals(1, agoraInvoices.size(),
            'The existing customer account should be reused for its sellout invoice');
        System.assertEquals(existingChildAccount.Id, agoraInvoices[0].Child_Account_Non_SBO__c,
            'A distinct child customer should be recorded on the invoice');

        System.assertEquals(1, [SELECT COUNT() FROM Account WHERE Name = 'AGORA'],
            'No duplicate account should be created for a customer that already exists');
    }
}