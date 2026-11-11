/**
 * @description Daily automated sellout. For every account with SLO_Automatic_Sellout__c set, builds
 * a CSV from its unreviewed invoices, creates the Sellout Report, stores the CSV as a file on the
 * report and flags the source invoices as reviewed. When all accounts are prepared, finish starts
 * the existing import batch per report with Auto Accept on; the import batch then chains into the
 * existing Apply Sellout batch. A failure on one account is recorded on its report and does not
 * stop the others.
 */
public with sharing class SLO_SelloutDailyAutoBatch
        implements Database.Batchable<SObject>, Database.Stateful {

    // One account per transaction keeps file and DML work well inside limits
    public static final Integer SCOPE_SIZE = 1;
    private static final String IMPORT_LOCALE = 'en_US';
    public static final String REQUIRED_METHOD = 'By_linked_order_details';

    private class PreparedReport {
        Id accountId;
        Id reportId;
        Id contentVersionId;
        List<Id> invoiceIds;
    }

    private List<PreparedReport> prepared = new List<PreparedReport>();
    private List<String> errors = new List<String>();
    private List<String> failures = new List<String>();

    private Id singleAccountId;

    public SLO_SelloutDailyAutoBatch() {}

    // Manual run for one account from the Account page
    public SLO_SelloutDailyAutoBatch(Id accountId) {
        this.singleAccountId = accountId;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        if (singleAccountId != null) {
            return Database.getQueryLocator([
                SELECT Id, Name, SLO_Automatic_Sellout__c, SLO_Sellout_Method__c
                FROM Account
                WHERE Id = :singleAccountId AND SLO_Automatic_Sellout__c = true
            ]);
        }
        return Database.getQueryLocator([
            SELECT Id, Name, SLO_Automatic_Sellout__c, SLO_Sellout_Method__c
            FROM Account
            WHERE SLO_Automatic_Sellout__c = true
            ORDER BY Id
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Account> scope) {
        for (Account account : scope) {
            processAccount(account);
        }
    }

    public void finish(Database.BatchableContext bc) {
        for (PreparedReport item : prepared) {
            try {
                SLO_SelloutImportController.ImportMappingConfig config =
                    new SLO_SelloutImportController.ImportMappingConfig();
                config.customerAccountIndex = SLO_SelloutDailyCsvBuilder.COLUMN_CUSTOMER;
                config.itemDateIndex = SLO_SelloutDailyCsvBuilder.COLUMN_DATE;
                config.productCodeIndex = SLO_SelloutDailyCsvBuilder.COLUMN_SKU;
                config.quantityIndex = SLO_SelloutDailyCsvBuilder.COLUMN_QUANTITY;
                config.sourceLineIndex = SLO_SelloutDailyCsvBuilder.COLUMN_SOURCE_LINE;
                config.csvDelimiter = SLO_SelloutDailyCsvBuilder.DELIMITER;
                config.autoAccept = true;

                Database.executeBatch(
                    new SLO_SelloutItemImportBatch(
                        item.accountId, item.reportId, item.contentVersionId, config, IMPORT_LOCALE, true
                    ),
                    200
                );
            } catch (Exception e) {
                markFailed(item.reportId, 'Could not start the import: ' + e.getMessage());
                failures.add(item.accountId + ': Could not start the import: ' + e.getMessage());
                releaseInvoices(item.invoiceIds);
            }
        }
        sendFailureEmail();
        if (!errors.isEmpty()) {
            System.debug(LoggingLevel.ERROR, 'Daily automated sellout errors: ' + String.join(errors, '; '));
        }
    }

    private void processAccount(Account account) {
        Id reportId;
        try {
            if (account.SLO_Automatic_Sellout__c != true) {
                System.debug('Daily sellout skipped for ' + account.Id + ': Automated Sellout is not enabled');
                return;
            }
            if (account.SLO_Sellout_Method__c != REQUIRED_METHOD) {
                String reason = 'Daily sellout skipped for ' + account.Id + ': Sellout Method is '
                    + (String.isBlank(account.SLO_Sellout_Method__c) ? 'empty' : account.SLO_Sellout_Method__c)
                    + ', expected ' + REQUIRED_METHOD;
                System.debug(LoggingLevel.WARN, reason);
                errors.add(reason);
                return;
            }

            Date today = Date.today();
            List<SLO_Sellout_Report__c> existing = [
                SELECT Id FROM SLO_Sellout_Report__c
                WHERE SLO_Account__c = :account.Id AND SLO_Report_Date__c = :today
                LIMIT 1
            ];
            if (singleAccountId == null && !existing.isEmpty()) {
                System.debug('Daily sellout skipped for ' + account.Id + ': a report already exists for today');
                return;
            }

            SLO_SelloutDailyCsvBuilder.BuildResult built = SLO_SelloutDailyCsvBuilder.build(account.Id);
            if (built.rowCount == 0) {
                errors.add(account.Id + ': No eligible invoice lines found (unreviewed invoices with an Order and customer name)');
                return;
            }

            populateOrderChildAccounts(account, built.invoiceIds);

            SLO_Sellout_Report__c report = new SLO_Sellout_Report__c(
                SLO_Account__c = account.Id,
                SLO_Report_Date__c = today,
                SLO_Status__c = 'New',
                SLO_Auto_Accepted__c = true,
                SLO_Accounts_Created__c = 0,
                SLO_Lines_Processed__c = built.rowCount,
                SLO_Lines_Skipped__c = built.skippedLines,
                SLO_Lines_Need_Fix__c = 0
            );
            insert report;
            reportId = report.Id;

            ContentVersion version = new ContentVersion(
                Title = 'AUTO - Daily Sellout ' + String.valueOf(today),
                PathOnClient = 'daily_sellout_' + String.valueOf(today) + '.csv',
                VersionData = Blob.valueOf(built.csv)
            );
            insert version;

            Id documentId = [
                SELECT ContentDocumentId FROM ContentVersion WHERE Id = :version.Id
            ].ContentDocumentId;
            insert new ContentDocumentLink(
                ContentDocumentId = documentId,
                LinkedEntityId = reportId,
                ShareType = 'V'
            );

            List<Invoice__c> toFlag = new List<Invoice__c>();
            for (Id invoiceId : built.invoiceIds) {
                toFlag.add(new Invoice__c(Id = invoiceId, SLO_Sellout_Reviewed__c = true));
            }
            update toFlag;

            PreparedReport item = new PreparedReport();
            item.accountId = account.Id;
            item.reportId = reportId;
            item.contentVersionId = version.Id;
            item.invoiceIds = built.invoiceIds;
            prepared.add(item);
        } catch (Exception e) {
            errors.add(account.Id + ': ' + e.getMessage());
            failures.add(account.Name + ' (' + account.Id + '): ' + e.getMessage());
            if (reportId != null) {
                markFailed(reportId, e.getMessage());
            }
        }
    }

    // Same matching and creation rules as SLO_SelloutInvoiceReviewBatch; only empty Order fields are filled
    private void populateOrderChildAccounts(Account parent, List<Id> invoiceIds) {
        Set<Id> orderIds = new Set<Id>();
        for (Invoice_Line_Item__c line : [
            SELECT Order__c FROM Invoice_Line_Item__c
            WHERE Invoice_Number__c IN :invoiceIds AND Order__c != null
        ]) {
            orderIds.add(line.Order__c);
        }
        if (orderIds.isEmpty()) {
            return;
        }

        List<Order> orders = [
            SELECT Id, Customer_name_Description__c
            FROM Order
            WHERE Id IN :orderIds AND Child_Account_Non_SBO__c = null
              AND Customer_name_Description__c != null
        ];
        Set<String> candidateNames = new Set<String>();
        for (Order ord : orders) {
            String name = ord.Customer_name_Description__c.trim();
            if (String.isBlank(name)) {
                continue;
            }
            candidateNames.add(name);
            candidateNames.add(name + SLO_SelloutImportController.SELLOUT_ACCOUNT_SUFFIX);
            candidateNames.add(SLO_SelloutImportController.buildSelloutAccountName(name, parent.Name));
        }
        if (candidateNames.isEmpty()) {
            return;
        }

        Map<String, Id> idByLowerName = new Map<String, Id>();
        for (Account acc : [SELECT Id, Name FROM Account WHERE Name IN :candidateNames]) {
            String key = acc.Name.toLowerCase();
            if (!idByLowerName.containsKey(key)) {
                idByLowerName.put(key, acc.Id);
            }
        }

        Account parentFull = [
            SELECT Id, CurrencyIsoCode, BillingStreet, BillingCity, BillingCountryCode, BillingPostalCode
            FROM Account WHERE Id = :parent.Id
        ];
        Map<String, Account> toCreate = new Map<String, Account>();
        Map<Id, String> orderToName = new Map<Id, String>();
        for (Order ord : orders) {
            String name = ord.Customer_name_Description__c.trim();
            if (String.isBlank(name)) {
                continue;
            }
            String marked = SLO_SelloutImportController.buildSelloutAccountName(name, parent.Name);
            Boolean found = false;
            for (String candidate : new List<String>{
                name, marked, name + SLO_SelloutImportController.SELLOUT_ACCOUNT_SUFFIX
            }) {
                if (idByLowerName.containsKey(candidate.toLowerCase())) {
                    found = true;
                    break;
                }
            }
            if (!found && !toCreate.containsKey(marked.toLowerCase())) {
                Account child = new Account(
                    Name = marked,
                    ParentId = parent.Id,
                    Status__c = 'Active',
                    CurrencyIsoCode = parentFull.CurrencyIsoCode,
                    BillingStreet = parentFull.BillingStreet,
                    BillingCity = parentFull.BillingCity,
                    BillingCountryCode = parentFull.BillingCountryCode,
                    BillingPostalCode = parentFull.BillingPostalCode
                );
                Id recordTypeId = SLO_SelloutInvoiceReviewBatch.nonSboRecordTypeId();
                if (recordTypeId != null) {
                    child.RecordTypeId = recordTypeId;
                }
                toCreate.put(marked.toLowerCase(), child);
            }
            orderToName.put(ord.Id, name);
        }

        if (!toCreate.isEmpty()) {
            Database.DMLOptions dml = new Database.DMLOptions();
            dml.optAllOrNone = false;
            dml.DuplicateRuleHeader.allowSave = true;
            dml.DuplicateRuleHeader.runAsCurrentUser = true;
            List<Account> created = toCreate.values();
            List<Database.SaveResult> results = Database.insert(created, dml);
            for (Integer i = 0; i < created.size(); i++) {
                if (results[i].isSuccess()) {
                    idByLowerName.put(created[i].Name.toLowerCase(), created[i].Id);
                } else if (!results[i].getErrors().isEmpty()) {
                    errors.add(parent.Id + ': ' + results[i].getErrors()[0].getMessage());
                }
            }
        }

        List<Order> toUpdate = new List<Order>();
        for (Order ord : orders) {
            String name = orderToName.get(ord.Id);
            if (name == null) {
                continue;
            }
            Id childId = null;
            for (String candidate : new List<String>{
                name,
                SLO_SelloutImportController.buildSelloutAccountName(name, parent.Name),
                name + SLO_SelloutImportController.SELLOUT_ACCOUNT_SUFFIX
            }) {
                if (idByLowerName.containsKey(candidate.toLowerCase())) {
                    childId = idByLowerName.get(candidate.toLowerCase());
                    break;
                }
            }
            if (childId != null) {
                toUpdate.add(new Order(Id = ord.Id, Child_Account_Non_SBO__c = childId));
            }
        }
        if (!toUpdate.isEmpty()) {
            for (Database.SaveResult r : Database.update(toUpdate, false)) {
                if (!r.isSuccess() && !r.getErrors().isEmpty()) {
                    errors.add(parent.Id + ': ' + r.getErrors()[0].getMessage());
                }
            }
        }
    }

    // One email per job run, to the user who scheduled it; nothing is sent when no account failed
    private void sendFailureEmail() {
        if (failures.isEmpty()) {
            return;
        }
        try {
            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setTargetObjectId(UserInfo.getUserId());
            mail.setSaveAsActivity(false);
            mail.setSubject('Daily automated sellout: ' + failures.size() + ' account(s) failed');
            mail.setPlainTextBody(
                'The daily automated sellout could not process the following accounts:\n\n'
                + String.join(failures, '\n')
                + '\n\nThe related Sellout Reports are set to Error. Other accounts were processed normally.'
            );
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
        } catch (Exception e) {
            errors.add('Could not send failure email: ' + e.getMessage());
        }
    }

    private void markFailed(Id reportId, String message) {
        try {
            update new SLO_Sellout_Report__c(
                Id = reportId,
                SLO_Status__c = 'Error',
                SLO_Error_Message__c = String.isBlank(message) ? null : message.abbreviate(32000)
            );
        } catch (Exception e) {
            errors.add(reportId + ': ' + e.getMessage());
        }
    }

    private void releaseInvoices(List<Id> invoiceIds) {
        try {
            List<Invoice__c> toRelease = new List<Invoice__c>();
            for (Id invoiceId : invoiceIds) {
                toRelease.add(new Invoice__c(Id = invoiceId, SLO_Sellout_Reviewed__c = false));
            }
            update toRelease;
        } catch (Exception e) {
            errors.add('Could not release invoices: ' + e.getMessage());
        }
    }
}
