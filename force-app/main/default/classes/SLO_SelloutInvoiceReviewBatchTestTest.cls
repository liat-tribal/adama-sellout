/**
 * @description Additional test class for SLO_SelloutInvoiceReviewBatch
 * Provides extended test coverage for edge cases and specific scenarios
 */
@isTest
private class SLO_SelloutInvoiceReviewBatchTestTest {

    private static final String SELLOUT_TYPE = 'Internal Sellout';

    /**
     * @description Resolves an active Transaction_type__c value for source invoices.
     * The picklist is restricted in the org, so hard-coded values fail on insert.
     */
    private static String sourceTransactionType() {
        for (Schema.PicklistEntry entry : Invoice__c.Transaction_type__c.getDescribe().getPicklistValues()) {
            if (entry.isActive() && !entry.getValue().startsWith(SELLOUT_TYPE)) {
                return entry.getValue();
            }
        }
        return null;
    }

    /**
     * @description Test batch execution with null date parameters
     */
    @isTest
    static void testBatchWithNullDates() {
        // Create test account, opted in to the automated sellout
        Account testAccount = new Account(Name = 'Test Account', SLO_Automatic_Sellout__c = true, SLO_Sellout_Method__c = 'By_linked_order_details');
        insert testAccount;

        // Create invoice with today's date
        Invoice__c testInvoice = new Invoice__c(
            Account_Name__c = testAccount.Id,
            Invoice_Date__c = Date.today(),
            Transaction_type__c = sourceTransactionType(),
            Status__c = 'Closed',
            Delivered_VN__c = false,
            Manual_Creation__c = false,
            Valid__c = true,
            SLO_Sellout_Reviewed__c = false
        );
        insert testInvoice;

        Test.startTest();

        // Execute batch with today's date range
        SLO_SelloutInvoiceReviewBatch batch = new SLO_SelloutInvoiceReviewBatch(Date.today(), Date.today());
        Database.executeBatch(batch, 200);

        Test.stopTest();

        // Verify batch executed without errors
        List<Invoice__c> processedInvoices = [
            SELECT Id, SLO_Sellout_Reviewed__c
            FROM Invoice__c
            WHERE Id = :testInvoice.Id
        ];
        System.assertEquals(1, processedInvoices.size(), 'Invoice should exist after batch execution');
    }

    /**
     * @description Test batch with invoices that have no line items
     */
    @isTest
    static void testBatchWithInvoicesWithoutLineItems() {
        // Create test account, opted in to the automated sellout
        Account testAccount = new Account(Name = 'Test Account No Items', SLO_Automatic_Sellout__c = true, SLO_Sellout_Method__c = 'By_linked_order_details');
        insert testAccount;

        // Create invoice without line items
        Invoice__c testInvoice = new Invoice__c(
            Account_Name__c = testAccount.Id,
            Invoice_Date__c = Date.today(),
            Transaction_type__c = sourceTransactionType(),
            Status__c = 'Closed',
            Delivered_VN__c = false,
            Manual_Creation__c = false,
            Valid__c = true,
            SLO_Sellout_Reviewed__c = false
        );
        insert testInvoice;

        Test.startTest();

        // Execute batch
        SLO_SelloutInvoiceReviewBatch batch = new SLO_SelloutInvoiceReviewBatch(Date.today(), Date.today());
        Database.executeBatch(batch, 200);

        Test.stopTest();

        // Verify invoice is marked as reviewed even without line items
        Invoice__c processedInvoice = [
            SELECT Id, SLO_Sellout_Reviewed__c
            FROM Invoice__c
            WHERE Id = :testInvoice.Id
        ];
        System.assertEquals(true, processedInvoice.SLO_Sellout_Reviewed__c, 'Invoice should be marked as reviewed');
    }

    /**
     * @description Test batch with line items that have null Order__c
     */
    @isTest
    static void testBatchWithLineItemsWithoutOrders() {
        // Create test account, opted in to the automated sellout
        Account testAccount = new Account(Name = 'Test Account No Orders', SLO_Automatic_Sellout__c = true, SLO_Sellout_Method__c = 'By_linked_order_details');
        insert testAccount;

        // Create invoice
        Invoice__c testInvoice = new Invoice__c(
            Account_Name__c = testAccount.Id,
            Invoice_Date__c = Date.today(),
            Transaction_type__c = sourceTransactionType(),
            Status__c = 'Closed',
            Delivered_VN__c = false,
            Manual_Creation__c = false,
            Valid__c = true,
            SLO_Sellout_Reviewed__c = false
        );
        insert testInvoice;

        // Create line item without Order__c
        Invoice_Line_Item__c lineItem = new Invoice_Line_Item__c(
            Invoice_Number__c = testInvoice.Id,
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

        // Verify no new Internal Sellout invoices created (since line items have no orders)
        List<Invoice__c> newInvoices = [
            SELECT Id
            FROM Invoice__c
            WHERE Transaction_type__c = :SELLOUT_TYPE
            AND CreatedDate = TODAY
        ];
        System.assertEquals(0, newInvoices.size(), 'No Internal Sellout invoices should be created without orders');

        // Verify source invoice is still marked as reviewed
        Invoice__c processedInvoice = [
            SELECT Id, SLO_Sellout_Reviewed__c
            FROM Invoice__c
            WHERE Id = :testInvoice.Id
        ];
        System.assertEquals(true, processedInvoice.SLO_Sellout_Reviewed__c, 'Invoice should be marked as reviewed');
    }

    /**
     * @description Test batch with past date range
     */
    @isTest
    static void testBatchWithPastDateRange() {
        // Create test account, opted in to the automated sellout
        Account testAccount = new Account(Name = 'Test Account Past', SLO_Automatic_Sellout__c = true, SLO_Sellout_Method__c = 'By_linked_order_details');
        insert testAccount;

        // Create invoice with past date
        Invoice__c testInvoice = new Invoice__c(
            Account_Name__c = testAccount.Id,
            Invoice_Date__c = Date.today().addDays(-30),
            Transaction_type__c = sourceTransactionType(),
            Status__c = 'Closed',
            Delivered_VN__c = false,
            Manual_Creation__c = false,
            Valid__c = true,
            SLO_Sellout_Reviewed__c = false
        );
        insert testInvoice;

        Test.startTest();

        // Execute batch with past date range
        Date pastStart = Date.today().addDays(-35);
        Date pastEnd = Date.today().addDays(-25);
        SLO_SelloutInvoiceReviewBatch batch = new SLO_SelloutInvoiceReviewBatch(pastStart, pastEnd);
        Database.executeBatch(batch, 200);

        Test.stopTest();

        // Verify invoice in range is processed
        Invoice__c processedInvoice = [
            SELECT Id, SLO_Sellout_Reviewed__c
            FROM Invoice__c
            WHERE Id = :testInvoice.Id
        ];
        System.assertEquals(true, processedInvoice.SLO_Sellout_Reviewed__c, 'Past invoice should be marked as reviewed');
    }

    @isTest
    static void dailyCsvBuilderHelpersAndEmptyBuild() {
        Account acc = new Account(Name = 'Daily Account', SLO_Automatic_Sellout__c = true, SLO_Sellout_Method__c = 'By_linked_order_details');
        insert acc;

        SLO_SelloutDailyCsvBuilder.BuildResult built = SLO_SelloutDailyCsvBuilder.build(acc.Id);
        System.assertEquals(0, built.rowCount, 'No invoices means no rows');
        System.assertEquals(null, built.csv);

        System.assertEquals('"a,b"', SLO_SelloutDailyCsvBuilder.escape('a,b'));
        System.assertEquals('"say ""hi"""', SLO_SelloutDailyCsvBuilder.escape('say "hi"'));
        System.assertEquals('', SLO_SelloutDailyCsvBuilder.escape(null));
        System.assertEquals('plain', SLO_SelloutDailyCsvBuilder.escape('plain'));
        System.assertEquals('3', SLO_SelloutDailyCsvBuilder.formatQuantity(3.000));
        System.assertEquals('2.5', SLO_SelloutDailyCsvBuilder.formatQuantity(2.50));
    }

    @isTest
    static void dailyAutoBatchRunsWithoutInvoices() {
        Account acc = new Account(Name = 'Daily Account', SLO_Automatic_Sellout__c = true, SLO_Sellout_Method__c = 'By_linked_order_details');
        insert acc;

        Test.startTest();
        Database.executeBatch(new SLO_SelloutDailyAutoBatch(), SLO_SelloutDailyAutoBatch.SCOPE_SIZE);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM SLO_Sellout_Report__c WHERE SLO_Account__c = :acc.Id],
            'An account with nothing to send gets no report');
    }

    private static Order makeOrder(Id accountId, String customerName) {
        String status;
        for (Schema.PicklistEntry entry : Order.Status.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                status = entry.getValue();
                if ('Draft'.equals(status)) {
                    break;
                }
            }
        }
        Order ord = new Order(
            AccountId = accountId,
            Status = status,
            EffectiveDate = Date.today(),
            Customer_name_Description__c = customerName
        );
        insert ord;
        return ord;
    }

    private static Invoice__c makeSourceInvoice(Id accountId) {
        Invoice__c invoice = new Invoice__c(
            Account_Name__c = accountId,
            Invoice_Date__c = Date.today(),
            Transaction_type__c = sourceTransactionType(),
            Status__c = 'Closed',
            Valid__c = true,
            SLO_Sellout_Reviewed__c = false
        );
        insert invoice;
        return invoice;
    }

    @isTest
    static void dailyCsvBuilderBuildsRowsFromOrderCustomers() {
        Account acc = new Account(Name = 'Daily Account', SLO_Automatic_Sellout__c = true, SLO_Sellout_Method__c = 'By_linked_order_details');
        insert acc;
        Order ord = makeOrder(acc.Id, 'Shop, "One"');
        Invoice__c usable = makeSourceInvoice(acc.Id);
        Invoice__c unusable = makeSourceInvoice(acc.Id);

        insert new List<Invoice_Line_Item__c>{
            new Invoice_Line_Item__c(Invoice_Number__c = usable.Id, Order__c = ord.Id,
                Central_Item_Code__c = ' 111111 ', Product_Name__c = 'ignored', Quantity__c = 2.50, Valid__c = true),
            new Invoice_Line_Item__c(Invoice_Number__c = usable.Id, Order__c = ord.Id,
                Product_Name__c = '222222', Quantity__c = 3, Valid__c = true),
            new Invoice_Line_Item__c(Invoice_Number__c = usable.Id, Order__c = ord.Id,
                Product_Name__c = null, Quantity__c = 3, Valid__c = true),
            new Invoice_Line_Item__c(Invoice_Number__c = unusable.Id, Order__c = ord.Id,
                Product_Name__c = '333333', Quantity__c = null, Valid__c = true)
        };

        SLO_SelloutDailyCsvBuilder.BuildResult built = SLO_SelloutDailyCsvBuilder.build(acc.Id);

        System.assertEquals(2, built.rowCount, 'Two lines have customer, SKU and quantity');
        System.assertEquals(2, built.skippedLines, 'A line without SKU and one without quantity are skipped');
        System.assertEquals(1, built.invoiceIds.size(), 'Only the invoice that contributed rows is returned');
        System.assertEquals(usable.Id, built.invoiceIds[0]);
        List<String> lines = built.csv.split('\n');
        System.assertEquals(SLO_SelloutDailyCsvBuilder.HEADER, lines[0]);
        Set<String> rows = new Set<String>(lines);
        Date d = Date.today();
        String formatted = String.valueOf(d.day()).leftPad(2, '0') + '/' + String.valueOf(d.month()).leftPad(2, '0')
            + '/' + String.valueOf(Math.mod(d.year(), 100)).leftPad(2, '0');
        System.assertEquals(3, lines.size(), 'Header plus two rows');
        Boolean hasCentral = false;
        Boolean hasFallback = false;
        for (String row : lines) {
            hasCentral = hasCentral || row.startsWith(formatted + ',111111,2.5,"Shop, ""One""",');
            hasFallback = hasFallback || row.startsWith(formatted + ',222222,3,"Shop, ""One""",');
        }
        System.assert(hasCentral, 'Central item code wins and the quantity is trimmed');
        System.assert(hasFallback, 'Product name is the SKU fallback');
    }

    // Database.executeBatch is not allowed from a future method, so finish() hits its failure path
    @future
    private static void runDailyBatchFromFuture(Id accountId) {
        List<Account> scope = [
            SELECT Id, Name, SLO_Automatic_Sellout__c, SLO_Sellout_Method__c FROM Account WHERE Id = :accountId
        ];
        SLO_SelloutDailyAutoBatch batch = new SLO_SelloutDailyAutoBatch();
        batch.execute(null, scope);
        batch.finish(null);
    }

    @isTest
    static void dailyAutoBatchFinishHandlesImportStartFailure() {
        Account acc = new Account(Name = 'Daily Account', SLO_Automatic_Sellout__c = true, SLO_Sellout_Method__c = 'By_linked_order_details');
        insert acc;
        Order ord = makeOrder(acc.Id, 'Shop One');
        Invoice__c invoice = makeSourceInvoice(acc.Id);
        insert new Invoice_Line_Item__c(Invoice_Number__c = invoice.Id, Order__c = ord.Id,
            Product_Name__c = '111111', Quantity__c = 4, Valid__c = true);

        Test.startTest();
        runDailyBatchFromFuture(acc.Id);
        Test.stopTest();

        List<SLO_Sellout_Report__c> reports = [
            SELECT SLO_Status__c, SLO_Error_Message__c FROM SLO_Sellout_Report__c WHERE SLO_Account__c = :acc.Id
        ];
        System.assertEquals(1, reports.size(), 'The report was prepared before the import failed to start');
        System.assertEquals('Error', reports[0].SLO_Status__c, 'The report records the failure');
        System.assert(reports[0].SLO_Error_Message__c.startsWith('Could not start the import'),
            'The error message says what failed');
        System.assertEquals(false,
            [SELECT SLO_Sellout_Reviewed__c FROM Invoice__c WHERE Id = :invoice.Id].SLO_Sellout_Reviewed__c,
            'The invoice is released so the next run can pick it up again');
    }

    @isTest
    static void dailyAutoBatchPreparesReportAndFlagsInvoices() {
        Account acc = new Account(Name = 'Daily Account', SLO_Automatic_Sellout__c = true, SLO_Sellout_Method__c = 'By_linked_order_details');
        insert acc;
        Order ord = makeOrder(acc.Id, 'Shop One');
        Invoice__c invoice = makeSourceInvoice(acc.Id);
        insert new Invoice_Line_Item__c(Invoice_Number__c = invoice.Id, Order__c = ord.Id,
            Product_Name__c = '111111', Quantity__c = 4, Valid__c = true);

        Test.startTest();
        Database.executeBatch(new SLO_SelloutDailyAutoBatch(), SLO_SelloutDailyAutoBatch.SCOPE_SIZE);
        Test.stopTest();

        List<SLO_Sellout_Report__c> reports = [
            SELECT Id, SLO_Report_Date__c FROM SLO_Sellout_Report__c WHERE SLO_Account__c = :acc.Id
        ];
        System.assertEquals(1, reports.size(), 'One report is created for the opted-in account');
        System.assertEquals(Date.today(), reports[0].SLO_Report_Date__c);
        System.assertEquals(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :reports[0].Id],
            'The CSV is stored as a file on the report');
        System.assertEquals(true,
            [SELECT SLO_Sellout_Reviewed__c FROM Invoice__c WHERE Id = :invoice.Id].SLO_Sellout_Reviewed__c,
            'The source invoice is flagged as reviewed');
    }

    @isTest
    static void dailyAutoBatchSkipsAccountWithReportForToday() {
        Account acc = new Account(Name = 'Daily Account', SLO_Automatic_Sellout__c = true, SLO_Sellout_Method__c = 'By_linked_order_details');
        insert acc;
        insert new SLO_Sellout_Report__c(SLO_Account__c = acc.Id, SLO_Report_Date__c = Date.today(), SLO_Status__c = 'New');
        Order ord = makeOrder(acc.Id, 'Shop One');
        Invoice__c invoice = makeSourceInvoice(acc.Id);
        insert new Invoice_Line_Item__c(Invoice_Number__c = invoice.Id, Order__c = ord.Id,
            Product_Name__c = '111111', Quantity__c = 4, Valid__c = true);

        Test.startTest();
        Database.executeBatch(new SLO_SelloutDailyAutoBatch(), SLO_SelloutDailyAutoBatch.SCOPE_SIZE);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM SLO_Sellout_Report__c WHERE SLO_Account__c = :acc.Id],
            'No second report is created for the same day');
        System.assertEquals(false,
            [SELECT SLO_Sellout_Reviewed__c FROM Invoice__c WHERE Id = :invoice.Id].SLO_Sellout_Reviewed__c);
    }

    @isTest
    static void dailyAutoBatchSendsNothingForAccountsWithoutOptIn() {
        Account acc = new Account(Name = 'Not Opted In');
        insert acc;

        Test.startTest();
        Database.executeBatch(new SLO_SelloutDailyAutoBatch(), SLO_SelloutDailyAutoBatch.SCOPE_SIZE);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM SLO_Sellout_Report__c WHERE SLO_Account__c = :acc.Id]);
    }

    @isTest
    static void dailyAutoSchedulerStartsBatch() {
        Test.startTest();
        Id jobId = System.schedule('SLO Daily Auto Test', SLO_SelloutDailyAutoScheduler.CRON_DAILY_0200,
            new SLO_SelloutDailyAutoScheduler());
        Test.stopTest();

        System.assertNotEquals(null, jobId);
        System.assertEquals(1, [SELECT COUNT() FROM CronTrigger WHERE Id = :jobId]);
    }

    @isTest
    static void fixOffsetVatNegatesOnlyPositiveVatOnOffsetInvoices() {
        Account acc = new Account(Name = 'Offset Account');
        insert acc;

        Invoice__c offsetInvoice = new Invoice__c(
            Name = 'OFFSET-N', Account_Name__c = acc.Id, Invoice_Date__c = Date.today(),
            Transaction_type__c = 'Internal Sellout N', Status__c = 'Closed', Valid__c = true
        );
        Invoice__c regularInvoice = new Invoice__c(
            Name = 'REGULAR', Account_Name__c = acc.Id, Invoice_Date__c = Date.today(),
            Transaction_type__c = sourceTransactionType(), Status__c = 'Closed', Valid__c = true
        );
        insert new List<Invoice__c>{ offsetInvoice, regularInvoice };

        Invoice_Line_Item__c bothPositive = new Invoice_Line_Item__c(
            Invoice_Number__c = offsetInvoice.Id, Product_Name__c = 'A', Quantity__c = 1, Valid__c = true,
            VAT_In_Original_Price__c = 5, VAT_In_Dollars__c = 7
        );
        Invoice_Line_Item__c onlyOriginalPositive = new Invoice_Line_Item__c(
            Invoice_Number__c = offsetInvoice.Id, Product_Name__c = 'B', Quantity__c = 1, Valid__c = true,
            VAT_In_Original_Price__c = 3, VAT_In_Dollars__c = -2
        );
        Invoice_Line_Item__c alreadyNegative = new Invoice_Line_Item__c(
            Invoice_Number__c = offsetInvoice.Id, Product_Name__c = 'C', Quantity__c = 1, Valid__c = true,
            VAT_In_Original_Price__c = -4, VAT_In_Dollars__c = 1
        );
        Invoice_Line_Item__c regularLine = new Invoice_Line_Item__c(
            Invoice_Number__c = regularInvoice.Id, Product_Name__c = 'D', Quantity__c = 1, Valid__c = true,
            VAT_In_Original_Price__c = 9, VAT_In_Dollars__c = 9
        );
        insert new List<Invoice_Line_Item__c>{ bothPositive, onlyOriginalPositive, alreadyNegative, regularLine };

        Test.startTest();
        Database.executeBatch(new SLO_SelloutFixOffsetVat(), 200);
        Test.stopTest();

        Map<Id, Invoice_Line_Item__c> after = new Map<Id, Invoice_Line_Item__c>([
            SELECT Id, VAT_In_Original_Price__c, VAT_In_Dollars__c FROM Invoice_Line_Item__c
        ]);
        System.assertEquals(-5, after.get(bothPositive.Id).VAT_In_Original_Price__c);
        System.assertEquals(-7, after.get(bothPositive.Id).VAT_In_Dollars__c);
        System.assertEquals(-3, after.get(onlyOriginalPositive.Id).VAT_In_Original_Price__c);
        System.assertEquals(-2, after.get(onlyOriginalPositive.Id).VAT_In_Dollars__c, 'Negative values are left as they are');
        System.assertEquals(-4, after.get(alreadyNegative.Id).VAT_In_Original_Price__c);
        System.assertEquals(-1, after.get(alreadyNegative.Id).VAT_In_Dollars__c);
        System.assertEquals(9, after.get(regularLine.Id).VAT_In_Original_Price__c, 'Regular invoices are untouched');
        System.assertEquals(9, after.get(regularLine.Id).VAT_In_Dollars__c, 'Regular invoices are untouched');
    }

    @isTest
    static void fixOffsetVatExecuteSkipsLinesWithNothingToFix() {
        SLO_SelloutFixOffsetVat batch = new SLO_SelloutFixOffsetVat();
        Invoice_Line_Item__c untouched = new Invoice_Line_Item__c(
            VAT_In_Original_Price__c = -1, VAT_In_Dollars__c = null
        );

        Test.startTest();
        batch.execute(null, new List<Invoice_Line_Item__c>{ untouched });
        Test.stopTest();

        System.assertEquals(-1, untouched.VAT_In_Original_Price__c, 'Negative VAT is not flipped');
        System.assertEquals(null, untouched.VAT_In_Dollars__c, 'Empty VAT is not changed');
    }
}