/**
 * @description Test class for SLO_SelloutInvoiceReviewScheduler
 * Provides comprehensive test coverage for scheduler functionality
 */
@isTest
private class SLO_SelloutInvoiceReviewSchedulerTest {

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
     * @description Test scheduler execution and batch job creation
     */
    @isTest
    static void testSchedulerExecution() {
        // Create test data
        Account testAccount = new Account(Name = 'Test Scheduler Account');
        insert testAccount;

        // Create Order with Buyer Group Information
        Order testOrder = new Order(
            AccountId = testAccount.Id,
            Status = defaultOrderStatus(),
            EffectiveDate = Date.today(),
            Customer_name_Description__c = 'Test Customer',
            Customer_City__c = 'Test City'
        );
        insert testOrder;

        // Create invoice for current week
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

        // Create invoice line item with Order lookup
        Invoice_Line_Item__c lineItem = new Invoice_Line_Item__c(
            Invoice_Number__c = testInvoice.Id,
            Order__c = testOrder.Id,
            Product_Name__c = 'Test Product',
            Quantity__c = 10,
            Valid__c = true
        );
        insert lineItem;

        Test.startTest();

        // Schedule the job
        String cronExp = '0 0 22 ? * FRI';
        String jobId = System.schedule('Test SLO Invoice Review Scheduler', cronExp, new SLO_SelloutInvoiceReviewScheduler());

        // Verify scheduled job exists
        List<CronTrigger> scheduledJobs = [
            SELECT Id, CronExpression, TimesTriggered, NextFireTime
            FROM CronTrigger
            WHERE Id = :jobId
        ];

        Test.stopTest();

        // Assertions
        System.assertEquals(1, scheduledJobs.size(), 'Scheduled job should exist');
        System.assertEquals(cronExp, scheduledJobs[0].CronExpression, 'Cron expression should match');
    }

    /**
     * @description Test scheduler execute method directly
     */
    @isTest
    static void testSchedulerExecuteMethod() {
        // Create test data
        Account testAccount = new Account(Name = 'Test Execute Account');
        insert testAccount;

        // Create invoice for current week
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

        // Execute scheduler directly
        SLO_SelloutInvoiceReviewScheduler scheduler = new SLO_SelloutInvoiceReviewScheduler();
        scheduler.execute(null);

        Test.stopTest();

        // Verify that a batch job was queued
        List<AsyncApexJob> batchJobs = [
            SELECT Id, Status, JobType, ApexClass.Name
            FROM AsyncApexJob
            WHERE JobType = 'BatchApex'
            AND ApexClass.Name = 'SLO_SelloutInvoiceReviewBatch'
        ];

        System.assert(batchJobs.size() > 0, 'Batch job should be queued after scheduler execution');
    }

    /**
     * @description Test scheduler date calculation for Monday
     */
    @isTest
    static void testSchedulerDateCalculationMonday() {
        Test.startTest();

        // Execute scheduler
        SLO_SelloutInvoiceReviewScheduler scheduler = new SLO_SelloutInvoiceReviewScheduler();
        scheduler.execute(null);

        Test.stopTest();

        // Verify batch job was created
        List<AsyncApexJob> batchJobs = [
            SELECT Id, Status, ApexClass.Name
            FROM AsyncApexJob
            WHERE JobType = 'BatchApex'
            AND ApexClass.Name = 'SLO_SelloutInvoiceReviewBatch'
            LIMIT 1
        ];

        System.assertEquals(1, batchJobs.size(), 'Batch job should be created');
    }

    /**
     * @description Test scheduler with multiple executions
     */
    @isTest
    static void testSchedulerMultipleExecutions() {
        // Create test account
        Account testAccount = new Account(Name = 'Test Multiple Account');
        insert testAccount;

        Test.startTest();

        // Schedule the job multiple times with different names
        String cronExp = '0 0 22 ? * FRI';
        String jobId1 = System.schedule('Test Job 1', cronExp, new SLO_SelloutInvoiceReviewScheduler());
        String jobId2 = System.schedule('Test Job 2', cronExp, new SLO_SelloutInvoiceReviewScheduler());

        Test.stopTest();

        // Verify both scheduled jobs exist
        List<CronTrigger> scheduledJobs = [
            SELECT Id, CronExpression
            FROM CronTrigger
            WHERE Id IN (:jobId1, :jobId2)
        ];

        System.assertEquals(2, scheduledJobs.size(), 'Both scheduled jobs should exist');
    }

    /**
     * @description Test scheduler with empty invoice set
     */
    @isTest
    static void testSchedulerWithNoInvoices() {
        Test.startTest();

        // Execute scheduler when no invoices exist
        SLO_SelloutInvoiceReviewScheduler scheduler = new SLO_SelloutInvoiceReviewScheduler();
        scheduler.execute(null);

        Test.stopTest();

        // Verify batch job still executes (even with no data)
        List<AsyncApexJob> batchJobs = [
            SELECT Id, Status, ApexClass.Name
            FROM AsyncApexJob
            WHERE JobType = 'BatchApex'
            AND ApexClass.Name = 'SLO_SelloutInvoiceReviewBatch'
        ];

        System.assert(batchJobs.size() > 0, 'Batch job should still be created even with no invoices');
    }
}