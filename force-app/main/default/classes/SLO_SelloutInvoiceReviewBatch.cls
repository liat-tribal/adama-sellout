/**
 * @description Batch Apex class that reviews SAP invoices for automated sellout processing.
 * Queries invoices where Transaction_type__c NOT IN ('Internal Sellout','Internal Sellout N')
 * AND SLO_Sellout_Reviewed__c = false within a configurable date range, restricted to accounts
 * that opted in via Account.SLO_Automatic_Sellout__c - the process is activated per account.
 * Optionally filters by Usage_Company__c when provided.
 *
 * For each invoice, checks line items for Order__c lookup, traverses to Order's Buyer Group
 * Information field (Customer_name_Description__c), derives child account
 * name from customer name only, matches or creates child accounts under the invoice's account
 * (created accounts follow the shared sellout naming convention -
 * "<name>_Sellout_<PARENT>", Status Active - so both sellout processes find them again),
 * groups line items by child account + date, creates positive invoices for child accounts with
 * Transaction_type__c = 'Internal Sellout', copies the source line financials so the invoice
 * totals roll up, numbers the invoice from the source invoice number, populates
 * Child_Account_Non_SBO__c on the Order and - only when the resolved account differs from the
 * source invoice's own account - on the Invoice, and marks the source invoice as reviewed.
 *
 * Usage:
 * - Historical backfill (all countries): Database.executeBatch(new SLO_SelloutInvoiceReviewBatch(Date.newInstance(2025,1,1), Date.newInstance(2025,1,31)), 200);
 * - Historical backfill (specific country): Database.executeBatch(new SLO_SelloutInvoiceReviewBatch(Date.newInstance(2025,1,1), Date.newInstance(2025,1,31), 'FR'), 200);
 * - Weekly schedule: System.schedule('SLO Weekly Invoice Review', '0 0 22 ? * FRI', new SLO_SelloutInvoiceReviewScheduler());
 */
public class SLO_SelloutInvoiceReviewBatch implements Database.Batchable<sObject>, Database.Stateful {

    // Scope sizes used as the job retries; each retry processes fewer invoices per transaction
    private static final List<Integer> RETRY_SCOPE_SIZES = new List<Integer>{ 200, 100, 50 };
    private static final Integer MAX_ATTEMPTS = 3;

    // Developer names the "Distributor / Dealer (non-SBO)" account record type is known by
    private static final List<String> NON_SBO_RECORD_TYPE_DEVELOPER_NAMES = new List<String>{
        'Distributor_Dealer_non_SBO', 'Distributor_Dealer_Non_SBO', 'Distributor_non_SBO'
    };
    private static Id nonSboRecordTypeIdCache;
    private static Boolean nonSboRecordTypeResolved = false;

    // Suffix appended to the source invoice number to name the generated sellout invoice
    private static final String SELLOUT_INVOICE_SUFFIX = '-SO';

    private Date startDate;
    private Date endDate;
    private String usageCompany;

    // Attempt number of this run; a failed run re-queues itself with a smaller scope and no email
    private Integer attempt;
    private String notificationEmail;

    // Cross-chunk totals for the single summary email
    private Integer invoicesReviewed = 0;
    private Integer childAccountsCreated = 0;
    private Integer selloutInvoicesCreated = 0;
    private Integer lineItemsCreated = 0;
    private Integer lineItemsSkippedNoProduct = 0;
    // Groups whose derived end customer resolved to the source invoice's own account - a sign the
    // Buyer Group field on the Order carries the distributor's own name rather than an end buyer
    private Integer selfResolvedGroups = 0;
    private Integer ordersUpdated = 0;
    private Integer chunksFailed = 0;
    private Integer recordErrors = 0;
    private Integer silentRetries = 0;
    private List<String> errorSamples = new List<String>();

    // Totals from earlier attempts, so a retry's email covers the whole run rather than the last pass
    private ReviewTotals carriedTotals;

    /**
     * @description Totals carried from one attempt to the next so the single summary email reports
     * everything the run achieved, including work done before a retry
     */
    public class ReviewTotals {
        public Integer invoicesReviewed = 0;
        public Integer childAccountsCreated = 0;
        public Integer selloutInvoicesCreated = 0;
        public Integer lineItemsCreated = 0;
        public Integer lineItemsSkippedNoProduct = 0;
        public Integer selfResolvedGroups = 0;
        public Integer ordersUpdated = 0;
        public Integer recordErrors = 0;
        public List<String> errorSamples = new List<String>();
    }

    /**
     * @description Constructor with configurable date range for flexible historical backfill
     * @param startDate Start date for invoice query range
     * @param endDate End date for invoice query range
     */
    public SLO_SelloutInvoiceReviewBatch(Date startDate, Date endDate) {
        this(startDate, endDate, null, 1, 0, null);
    }

    /**
     * @description Constructor with configurable date range and optional usage company filter
     * @param startDate Start date for invoice query range
     * @param endDate End date for invoice query range
     * @param usageCompany Optional usage company code to filter invoices (e.g., 'FR', 'US')
     */
    public SLO_SelloutInvoiceReviewBatch(Date startDate, Date endDate, String usageCompany) {
        this(startDate, endDate, usageCompany, 1, 0, null);
    }

    /**
     * @description Constructor used when the job re-queues itself after a failed attempt
     * @param startDate Start date for invoice query range
     * @param endDate End date for invoice query range
     * @param usageCompany Optional usage company code to filter invoices
     * @param attempt 1-based attempt number, which sets the scope size
     * @param priorRetries Number of silent retries already performed, carried into the summary
     * @param priorTotals Totals achieved by earlier attempts, or null on the first attempt
     */
    public SLO_SelloutInvoiceReviewBatch(Date startDate, Date endDate, String usageCompany,
                                        Integer attempt, Integer priorRetries, ReviewTotals priorTotals) {
        this.startDate = startDate;
        this.endDate = endDate;
        this.usageCompany = usageCompany;
        this.attempt = (attempt == null || attempt < 1) ? 1 : attempt;
        this.silentRetries = priorRetries == null ? 0 : priorRetries;
        this.carriedTotals = priorTotals;
        this.notificationEmail = UserInfo.getUserEmail();
    }

    /**
     * @description Scope size for a given attempt, shrinking on each silent retry
     * @param attempt 1-based attempt number
     * @return Invoices per execute() call
     */
    public static Integer scopeSizeForAttempt(Integer attempt) {
        Integer index = (attempt == null ? 1 : attempt) - 1;
        if (index < 0) {
            index = 0;
        }
        if (index >= RETRY_SCOPE_SIZES.size()) {
            index = RETRY_SCOPE_SIZES.size() - 1;
        }
        return RETRY_SCOPE_SIZES[index];
    }

    /**
     * @description Start method - queries invoices to review within date range
     * @param bc BatchableContext
     * @return Database.QueryLocator for invoices to process
     */
    public Database.QueryLocator start(Database.BatchableContext bc) {
        // Query invoices that need review: not already Internal Sellout, not yet reviewed, and
        // belonging to an account that has the automated sellout switched on - the process is
        // activated per account, so everyone else's invoices are left alone
        String query = 'SELECT Id, Name, Account_Name__c, Invoice_Date__c, Usage_Company__c, ' +
                       'Child_Account_Non_SBO__c, Transaction_type__c, ' +
                       '(SELECT Id, Name, Order__c, Product_Name__c, Product_SKU__c, SKU_Code__c, ' +
                       'Quantity__c, Invoice_Number__c,' +
                       'Net_Price__c, Gross_Value__c, Gross_Price__c, Total_After_Discount__c, ' +
                       'Unit_Price__c, VAT_In_Original_Price__c, VAT_In_Dollars__c, YearAfter2022__c ' +
                       'FROM Invoice_Line_Items__r WHERE Order__c != null) ' +
                       'FROM Invoice__c ' +
                       'WHERE Transaction_type__c NOT IN (\'Internal Sellout\', \'Internal Sellout N\') ' +
                       'AND SLO_Sellout_Reviewed__c = false ' +
                       'AND Status__c = \'Closed\' ' +
                       'AND Account_Name__r.SLO_Automatic_Sellout__c = true ' +
                       'AND Invoice_Date__c >= :startDate ' +
                       'AND Invoice_Date__c <= :endDate';

        // Add optional usage company filter
        if (String.isNotBlank(usageCompany)) {
            query += ' AND Usage_Company__c = :usageCompany';
        }

        return Database.getQueryLocator(query);
    }

    /**
     * @description Execute method - processes each batch of invoices
     * @param bc BatchableContext
     * @param scope List of Invoice__c records to process
     */
    public void execute(Database.BatchableContext bc, List<Invoice__c> scope) {
        // One bad chunk must not abort the whole review - record it and carry on with the next
        try {
            processScope(scope);
        } catch (Exception e) {
            chunksFailed++;
            addError(e.getMessage());
        }
    }

    /**
     * @description Process one chunk of invoices: match or create child accounts, create sellout
     * invoices and line items, then mark the source invoices as reviewed
     * @param scope List of Invoice__c records to process
     */
    private void processScope(List<Invoice__c> scope) {
        // Group line items by: parent account + child account name + invoice date
        Map<String, InvoiceGroupKey> invoiceGroups = new Map<String, InvoiceGroupKey>();

        // Track orders and invoices to update with Child_Account_Non_SBO__c
        Map<Id, Id> orderToChildAccountMap = new Map<Id, Id>();
        Set<Id> processedInvoiceIds = new Set<Id>();

        // Process each invoice in the batch
        for (Invoice__c invoice : scope) {
            Id parentAccountId = invoice.Account_Name__c;
            if (parentAccountId == null) {
                // No account to hang a child account off - leave unreviewed so the data can be fixed
                continue;
            }

            // The invoice has been reviewed once we have looked at it, even when there is nothing
            // to create. Without this it would be re-queried by every subsequent run.
            processedInvoiceIds.add(invoice.Id);

            if (invoice.Invoice_Line_Items__r.isEmpty()) {
                continue;
            }

            // Process each line item
            for (Invoice_Line_Item__c lineItem : invoice.Invoice_Line_Items__r) {
                if (lineItem.Order__c == null) {
                    continue;
                }

                // A sellout line must identify a product. A source line with no product
                // reference is skipped rather than copied into a line item with an empty product.
                if (String.isBlank(lineItem.Product_Name__c)) {
                    lineItemsSkippedNoProduct++;
                    continue;
                }

                // Store line item for later processing
                String groupKey = parentAccountId + '_' + lineItem.Order__c + '_' + invoice.Invoice_Date__c;

                if (!invoiceGroups.containsKey(groupKey)) {
                    InvoiceGroupKey groupInfo = new InvoiceGroupKey();
                    groupInfo.parentAccountId = parentAccountId;
                    groupInfo.orderId = lineItem.Order__c;
                    groupInfo.invoiceDate = invoice.Invoice_Date__c;
                    groupInfo.usageCompany = invoice.Usage_Company__c;
                    groupInfo.sourceInvoiceId = invoice.Id;
                    groupInfo.sourceInvoiceName = invoice.Name;
                    groupInfo.lineItems = new List<Invoice_Line_Item__c>();
                    invoiceGroups.put(groupKey, groupInfo);
                }

                invoiceGroups.get(groupKey).lineItems.add(lineItem);
            }

            processedInvoiceIds.add(invoice.Id);
        }

        // Query Order records to get Buyer Group Information
        Set<Id> orderIds = new Set<Id>();
        for (InvoiceGroupKey groupInfo : invoiceGroups.values()) {
            orderIds.add(groupInfo.orderId);
        }

        Map<Id, Order> orderMap = new Map<Id, Order>([
            SELECT Id, AccountId, Customer_name_Description__c, Customer_City__c,
                   Customer_EAI_Code__c, Child_Account_Non_SBO__c,
                   Account.Buying_Group__c
            FROM Order
            WHERE Id IN :orderIds
        ]);

        // Derive child account names
        for (String groupKey : invoiceGroups.keySet()) {
            InvoiceGroupKey groupInfo = invoiceGroups.get(groupKey);
            Order ord = orderMap.get(groupInfo.orderId);

            if (ord == null) {
                continue;
            }

            // Derive child account name from Customer_name_Description__c only
            String childAccountName = deriveChildAccountName(
                ord.Customer_name_Description__c
            );

            if (String.isNotBlank(childAccountName)) {
                groupInfo.childAccountName = childAccountName;
            }
        }

        // Query parent accounts first - the sellout-created account names carry a marker derived
        // from the parent's name, so matching needs the parents before it can build candidates
        Set<Id> parentAccountIds = new Set<Id>();
        for (InvoiceGroupKey groupInfo : invoiceGroups.values()) {
            if (groupInfo.parentAccountId != null) {
                parentAccountIds.add(groupInfo.parentAccountId);
            }
        }

        Map<Id, Account> parentAccountMap = new Map<Id, Account>();
        if (!parentAccountIds.isEmpty()) {
            List<Account> parentAccounts = [
                SELECT Id, Name, CurrencyIsoCode, BillingStreet, BillingCity,
                       BillingCountryCode, BillingPostalCode
                FROM Account
                WHERE Id IN :parentAccountIds
            ];

            for (Account parentAcc : parentAccounts) {
                parentAccountMap.put(parentAcc.Id, parentAcc);
            }
        }

        // Look for existing accounts under every name a customer could already be stored as: its
        // exact name (an account that predates the sellout process), the current
        // "<name>_Sellout_<PARENT>" convention, or the legacy "<name>_Sellout" one
        Set<String> candidateNames = new Set<String>();
        for (InvoiceGroupKey groupInfo : invoiceGroups.values()) {
            if (String.isBlank(groupInfo.childAccountName)) {
                continue;
            }
            Account parentAccount = parentAccountMap.get(groupInfo.parentAccountId);
            candidateNames.add(groupInfo.childAccountName);
            candidateNames.add(groupInfo.childAccountName + SLO_SelloutImportController.SELLOUT_ACCOUNT_SUFFIX);
            if (parentAccount != null) {
                candidateNames.add(SLO_SelloutImportController.buildSelloutAccountName(
                    groupInfo.childAccountName, parentAccount.Name
                ));
            }
        }
        candidateNames.remove(null);

        Map<String, Id> accountIdByLowerName = new Map<String, Id>();
        if (!candidateNames.isEmpty()) {
            for (Account acc : [SELECT Id, Name FROM Account WHERE Name IN :candidateNames]) {
                String lowerName = acc.Name.toLowerCase();
                if (!accountIdByLowerName.containsKey(lowerName)) {
                    accountIdByLowerName.put(lowerName, acc.Id);
                }
            }
        }

        // Resolve each group - exact name first, then the marked sellout name, then the legacy
        // one - and line up an account to create for the customers that have none, one per parent
        // and name however many orders mention them
        Map<String, Account> accountsToCreateByKey = new Map<String, Account>();
        Map<String, List<InvoiceGroupKey>> createKeyToGroups = new Map<String, List<InvoiceGroupKey>>();

        for (InvoiceGroupKey groupInfo : invoiceGroups.values()) {
            if (String.isBlank(groupInfo.childAccountName)) {
                continue;
            }
            Account parentAccount = parentAccountMap.get(groupInfo.parentAccountId);
            String markedName = parentAccount != null
                ? SLO_SelloutImportController.buildSelloutAccountName(
                    groupInfo.childAccountName, parentAccount.Name)
                : null;
            String legacyName = groupInfo.childAccountName +
                SLO_SelloutImportController.SELLOUT_ACCOUNT_SUFFIX;

            for (String candidate : new List<String>{ groupInfo.childAccountName, markedName, legacyName }) {
                if (candidate != null && accountIdByLowerName.containsKey(candidate.toLowerCase())) {
                    groupInfo.childAccountId = accountIdByLowerName.get(candidate.toLowerCase());
                    break;
                }
            }

            if (groupInfo.childAccountId == null && parentAccount != null && markedName != null) {
                // Created accounts follow the shared sellout naming convention and are active, the
                // same as accounts the import wizard creates, so both processes find them again
                String createKey = groupInfo.parentAccountId + '|' + markedName.toLowerCase();
                if (!accountsToCreateByKey.containsKey(createKey)) {
                    Account childAccount = new Account(
                        Name = markedName,
                        ParentId = groupInfo.parentAccountId,
                        Status__c = 'Active',
                        CurrencyIsoCode = parentAccount.CurrencyIsoCode,
                        BillingStreet = parentAccount.BillingStreet,
                        BillingCity = parentAccount.BillingCity,
                        BillingCountryCode = parentAccount.BillingCountryCode,
                        BillingPostalCode = parentAccount.BillingPostalCode
                    );
                    // Same record type the manual Apply Sellout path stamps, so both paths produce
                    // identical accounts. Resolved by developer name rather than a hardcoded Id.
                    Id childRecordTypeId = nonSboRecordTypeId();
                    if (childRecordTypeId != null) {
                        childAccount.RecordTypeId = childRecordTypeId;
                    }
                    accountsToCreateByKey.put(createKey, childAccount);
                    createKeyToGroups.put(createKey, new List<InvoiceGroupKey>());
                }
                createKeyToGroups.get(createKey).add(groupInfo);
            }
        }

        // Insert new accounts with duplicate rule bypass
        if (!accountsToCreateByKey.isEmpty()) {
            List<String> orderedCreateKeys = new List<String>(accountsToCreateByKey.keySet());
            List<Account> newAccounts = new List<Account>();
            for (String createKey : orderedCreateKeys) {
                newAccounts.add(accountsToCreateByKey.get(createKey));
            }

            Database.DMLOptions dml = new Database.DMLOptions();
            dml.optAllOrNone = false;
            dml.DuplicateRuleHeader.allowSave = true;
            dml.DuplicateRuleHeader.runAsCurrentUser = true;
            for (Database.SaveResult saveResult : Database.insert(newAccounts, dml)) {
                if (!saveResult.isSuccess() && !saveResult.getErrors().isEmpty()) {
                    recordErrors++;
                    addError(saveResult.getErrors()[0].getMessage());
                }
            }

            // Point the groups at their created account, skipping any the platform rejected
            for (Integer i = 0; i < newAccounts.size(); i++) {
                if (newAccounts[i].Id == null) {
                    continue;
                }
                childAccountsCreated++;
                for (InvoiceGroupKey groupInfo : createKeyToGroups.get(orderedCreateKeys[i])) {
                    groupInfo.childAccountId = newAccounts[i].Id;
                }
            }
        }

        // Create new invoices and line items grouped by child account
        List<Invoice__c> newInvoices = new List<Invoice__c>();
        Map<String, Id> groupKeyToNewInvoiceId = new Map<String, Id>();
        // Explicit ordered key list so each inserted invoice is paired with the exact group it came
        // from - map key order is not guaranteed and would attach line items to the wrong invoice
        List<String> orderedGroupKeys = new List<String>();
        // How many sellout invoices each source invoice has already produced in this chunk, so a
        // source invoice split across several child accounts gets distinct, repeatable numbers
        Map<Id, Integer> selloutNameSequence = new Map<Id, Integer>();

        // Sorted so the numbering a group receives does not depend on map iteration order
        List<String> sortedGroupKeys = new List<String>(invoiceGroups.keySet());
        sortedGroupKeys.sort();

        for (String groupKey : sortedGroupKeys) {
            InvoiceGroupKey groupInfo = invoiceGroups.get(groupKey);

            if (String.isBlank(groupInfo.childAccountName)) {
                continue;
            }

            Id childAccountId = groupInfo.childAccountId;
            if (childAccountId == null) {
                continue;
            }

            // Create new invoice for child account with Transaction_type__c = 'Internal Sellout'
            Invoice__c newInvoice = new Invoice__c(
                Account_Name__c = childAccountId,
                Invoice_Date__c = groupInfo.invoiceDate,
                Transaction_type__c = 'Internal Sellout',
                Status__c = 'New',
                Delivered_VN__c = false,
                Manual_Creation__c = false,
                Valid__c = true,
                Usage_Company__c = groupInfo.usageCompany,
                Name = buildSelloutInvoiceName(groupInfo, selloutNameSequence)
            );

            // Child_Account_Non_SBO__c means "a distinct non-SBO child was identified". When the
            // derived customer name resolves back to the source invoice's own account there is no
            // such child, so the field stays empty instead of echoing the account.
            if (childAccountId != groupInfo.parentAccountId) {
                newInvoice.Child_Account_Non_SBO__c = childAccountId;
            } else {
                selfResolvedGroups++;
            }
            newInvoices.add(newInvoice);
            orderedGroupKeys.add(groupKey);

            // Track Order to Child Account mapping
            Order ord = orderMap.get(groupInfo.orderId);
            if (ord != null && ord.Child_Account_Non_SBO__c == null) {
                orderToChildAccountMap.put(ord.Id, childAccountId);
            }
        }

        // Insert new invoices with partial success so one rejected invoice does not lose the rest
        if (!newInvoices.isEmpty()) {
            List<Database.SaveResult> invoiceResults = Database.insert(newInvoices, false);

            for (Integer i = 0; i < invoiceResults.size(); i++) {
                if (invoiceResults[i].isSuccess()) {
                    groupKeyToNewInvoiceId.put(orderedGroupKeys[i], invoiceResults[i].getId());
                    selloutInvoicesCreated++;
                } else {
                    recordErrors++;
                    if (!invoiceResults[i].getErrors().isEmpty()) {
                        addError(invoiceResults[i].getErrors()[0].getMessage());
                    }
                }
            }
        }

        // Create invoice line items for new invoices
        List<Invoice_Line_Item__c> newLineItems = new List<Invoice_Line_Item__c>();

        for (String groupKey : invoiceGroups.keySet()) {
            Id newInvoiceId = groupKeyToNewInvoiceId.get(groupKey);
            if (newInvoiceId == null) {
                continue;
            }

            InvoiceGroupKey groupInfo = invoiceGroups.get(groupKey);

            for (Invoice_Line_Item__c lineItem : groupInfo.lineItems) {
                // Financials are copied straight from the source line so the sellout invoice carries
                // the same values and the platform roll-ups on the parent invoice add up. Invoice
                // Value and the parent totals are calculated fields and must never be written.
                Invoice_Line_Item__c newLineItem = new Invoice_Line_Item__c(
                    Invoice_Number__c = newInvoiceId,
                    Name = lineItem.Name,
                    Product_Name__c = lineItem.Product_Name__c,
                    Product_SKU__c = lineItem.Product_SKU__c,
                    SKU_Code__c = lineItem.SKU_Code__c,
                    Quantity__c = lineItem.Quantity__c,
                    Status__c = 'Closed',
                    Valid__c = true,
                    Net_Price__c = lineItem.Net_Price__c,
                    Gross_Value__c = lineItem.Gross_Value__c,
                    Gross_Price__c = lineItem.Gross_Price__c,
                    Total_After_Discount__c = lineItem.Total_After_Discount__c,
                    Unit_Price__c = lineItem.Unit_Price__c,
                    VAT_In_Original_Price__c = lineItem.VAT_In_Original_Price__c,
                    VAT_In_Dollars__c = lineItem.VAT_In_Dollars__c,
                    YearAfter2022__c = lineItem.YearAfter2022__c
                );
                newLineItems.add(newLineItem);
            }
        }

        // Insert new line items with partial success
        if (!newLineItems.isEmpty()) {
            for (Database.SaveResult saveResult : Database.insert(newLineItems, false)) {
                if (saveResult.isSuccess()) {
                    lineItemsCreated++;
                } else {
                    recordErrors++;
                    if (!saveResult.getErrors().isEmpty()) {
                        addError(saveResult.getErrors()[0].getMessage());
                    }
                }
            }
        }

        // Update Orders with Child_Account_Non_SBO__c
        List<Order> ordersToUpdate = new List<Order>();
        for (Id orderId : orderToChildAccountMap.keySet()) {
            Order ord = new Order(
                Id = orderId,
                Child_Account_Non_SBO__c = orderToChildAccountMap.get(orderId)
            );
            ordersToUpdate.add(ord);
        }

        if (!ordersToUpdate.isEmpty()) {
            for (Database.SaveResult saveResult : Database.update(ordersToUpdate, false)) {
                if (saveResult.isSuccess()) {
                    ordersUpdated++;
                } else {
                    recordErrors++;
                    if (!saveResult.getErrors().isEmpty()) {
                        addError(saveResult.getErrors()[0].getMessage());
                    }
                }
            }
        }

        // Mark source invoices as reviewed
        List<Invoice__c> invoicesToUpdate = new List<Invoice__c>();
        for (Id invoiceId : processedInvoiceIds) {
            Invoice__c inv = new Invoice__c(
                Id = invoiceId,
                SLO_Sellout_Reviewed__c = true
            );
            invoicesToUpdate.add(inv);
        }

        if (!invoicesToUpdate.isEmpty()) {
            for (Database.SaveResult saveResult : Database.update(invoicesToUpdate, false)) {
                if (saveResult.isSuccess()) {
                    invoicesReviewed++;
                } else {
                    recordErrors++;
                    if (!saveResult.getErrors().isEmpty()) {
                        addError(saveResult.getErrors()[0].getMessage());
                    }
                }
            }
        }
    }

    /**
     * @description Record type Id for the "Distributor / Dealer (non-SBO)" account record type,
     * resolved from the Account describe by developer name and cached for the transaction.
     * Returns null when the record type is not available in this org, so account creation can
     * carry on without a record type rather than failing the whole chunk.
     * @return Record type Id, or null when it cannot be resolved
     */
    public static Id nonSboRecordTypeId() {
        if (!nonSboRecordTypeResolved) {
            nonSboRecordTypeResolved = true;
            Map<String, Schema.RecordTypeInfo> infosByDeveloperName =
                Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName();

            for (String developerName : NON_SBO_RECORD_TYPE_DEVELOPER_NAMES) {
                Schema.RecordTypeInfo info = infosByDeveloperName.get(developerName);
                if (info != null && info.isAvailable()) {
                    nonSboRecordTypeIdCache = info.getRecordTypeId();
                    return nonSboRecordTypeIdCache;
                }
            }

            // Developer names vary between orgs; fall back to the record type whose label is the
            // non-SBO distributor one rather than silently stamping nothing
            for (Schema.RecordTypeInfo info : infosByDeveloperName.values()) {
                String label = info.getName();
                if (info.isAvailable() && label != null &&
                    label.toLowerCase().contains('non-sbo')) {
                    nonSboRecordTypeIdCache = info.getRecordTypeId();
                    return nonSboRecordTypeIdCache;
                }
            }
        }
        return nonSboRecordTypeIdCache;
    }

    /**
     * @description Record an error sample, keeping only the first few to bound heap usage
     * @param message Error text to record
     */
    private void addError(String message) {
        if (errorSamples.size() < 10 && String.isNotBlank(message)) {
            errorSamples.add(message);
        }
    }

    /**
     * @description Finish method - executed after all batches complete
     * @param bc BatchableContext
     */
    public void finish(Database.BatchableContext bc) {
        // Chunks that failed outright are usually transient limit or lock errors. Re-run with a
        // smaller scope and no email; invoices already marked reviewed are skipped by the query,
        // so the retry only picks up what was left behind.
        if (chunksFailed > 0 && attempt < MAX_ATTEMPTS && !Test.isRunningTest()) {
            try {
                Database.executeBatch(
                    new SLO_SelloutInvoiceReviewBatch(
                        startDate, endDate, usageCompany, attempt + 1, silentRetries + 1, buildTotals()
                    ),
                    scopeSizeForAttempt(attempt + 1)
                );
                return;
            } catch (Exception e) {
                addError(e.getMessage());
            }
        }

        sendSummaryEmail();
    }

    /**
     * @description Snapshot this attempt's totals, merged with any carried in, for the next attempt
     * @return Combined totals to hand to the retry
     */
    private ReviewTotals buildTotals() {
        ReviewTotals totals = new ReviewTotals();
        totals.invoicesReviewed = totalInvoicesReviewed();
        totals.childAccountsCreated = totalChildAccountsCreated();
        totals.selloutInvoicesCreated = totalSelloutInvoicesCreated();
        totals.lineItemsCreated = totalLineItemsCreated();
        totals.lineItemsSkippedNoProduct = totalLineItemsSkippedNoProduct();
        totals.selfResolvedGroups = totalSelfResolvedGroups();
        totals.ordersUpdated = totalOrdersUpdated();
        totals.recordErrors = totalRecordErrors();
        totals.errorSamples = allErrorSamples();
        return totals;
    }

    /**
     * @description Total source invoices reviewed across every attempt
     * @return Combined count
     */
    private Integer totalInvoicesReviewed() {
        return invoicesReviewed + (carriedTotals == null ? 0 : carriedTotals.invoicesReviewed);
    }

    /**
     * @description Total child accounts created across every attempt
     * @return Combined count
     */
    private Integer totalChildAccountsCreated() {
        return childAccountsCreated + (carriedTotals == null ? 0 : carriedTotals.childAccountsCreated);
    }

    /**
     * @description Total sellout invoices created across every attempt
     * @return Combined count
     */
    private Integer totalSelloutInvoicesCreated() {
        return selloutInvoicesCreated + (carriedTotals == null ? 0 : carriedTotals.selloutInvoicesCreated);
    }

    /**
     * @description Total line items created across every attempt
     * @return Combined count
     */
    private Integer totalLineItemsCreated() {
        return lineItemsCreated + (carriedTotals == null ? 0 : carriedTotals.lineItemsCreated);
    }

    /**
     * @description Total source lines skipped for having no product reference, across every attempt
     * @return Combined count
     */
    private Integer totalLineItemsSkippedNoProduct() {
        return lineItemsSkippedNoProduct +
            (carriedTotals == null ? 0 : carriedTotals.lineItemsSkippedNoProduct);
    }

    /**
     * @description Total groups whose end customer resolved to the invoice's own account
     * @return Combined count
     */
    private Integer totalSelfResolvedGroups() {
        return selfResolvedGroups + (carriedTotals == null ? 0 : carriedTotals.selfResolvedGroups);
    }

    /**
     * @description Total orders linked to a child account across every attempt
     * @return Combined count
     */
    private Integer totalOrdersUpdated() {
        return ordersUpdated + (carriedTotals == null ? 0 : carriedTotals.ordersUpdated);
    }

    /**
     * @description Total record-level save failures across every attempt
     * @return Combined count
     */
    private Integer totalRecordErrors() {
        return recordErrors + (carriedTotals == null ? 0 : carriedTotals.recordErrors);
    }

    /**
     * @description Error samples from every attempt, capped so the email stays readable
     * @return Combined samples
     */
    private List<String> allErrorSamples() {
        List<String> combined = new List<String>();
        if (carriedTotals != null) {
            combined.addAll(carriedTotals.errorSamples);
        }
        for (String sample : errorSamples) {
            if (combined.size() >= 10) {
                break;
            }
            combined.add(sample);
        }
        return combined;
    }

    /**
     * @description Send the one summary email for the whole review run, including any retries
     */
    private void sendSummaryEmail() {
        String range = startDate + ' to ' + endDate +
            (String.isNotBlank(usageCompany) ? ' (usage company ' + usageCompany + ')' : '');

        Integer invoicesCreatedTotal = totalSelloutInvoicesCreated();
        Integer recordErrorsTotal = totalRecordErrors();
        List<String> samples = allErrorSamples();

        String subject = (chunksFailed > 0 || recordErrorsTotal > 0)
            ? 'Sellout invoice review finished with issues - ' + invoicesCreatedTotal + ' invoices created'
            : 'Sellout invoice review complete - ' + invoicesCreatedTotal + ' invoices created';

        String body = 'The automated sellout invoice review has finished.\n\n' +
            'Period reviewed: ' + range + '\n\n' +
            'Results\n' +
            '  Source invoices reviewed: ' + totalInvoicesReviewed() + '\n' +
            '  Child accounts created: ' + totalChildAccountsCreated() + '\n' +
            '  Sellout invoices created: ' + invoicesCreatedTotal + '\n' +
            '  Line items created: ' + totalLineItemsCreated() + '\n' +
            '  Orders linked to a child account: ' + totalOrdersUpdated();

        Integer skippedNoProduct = totalLineItemsSkippedNoProduct();
        if (skippedNoProduct > 0) {
            body += '\n  Lines skipped - product not found: ' + skippedNoProduct;
        }

        Integer selfResolvedTotal = totalSelfResolvedGroups();
        if (selfResolvedTotal > 0) {
            body += '\n  Lines whose end customer matched the invoice account itself: ' +
                selfResolvedTotal +
                '\n    (the end customer recorded on the order is the distributor itself, so no ' +
                'separate child customer could be identified for those lines)';
        }

        if (chunksFailed > 0 || recordErrorsTotal > 0) {
            body += '\n\nPlease note\n' +
                '  Records that could not be saved: ' + recordErrorsTotal + '\n' +
                '  Groups of invoices that could not be processed: ' + chunksFailed + '\n' +
                '  Those invoices are still unreviewed, so the next scheduled run will pick them up again.';
        }

        if (!samples.isEmpty()) {
            body += '\n\nFirst errors:\n  ' + String.join(samples, '\n  ');
        }

        SLO_SelloutImportController.sendCompletionEmail(notificationEmail, subject, body);
    }

    /**
     * @description Builds the invoice number for a generated sellout invoice from the source
     * invoice number, adding a sequence when one source invoice feeds several child accounts
     * @param groupInfo Group the sellout invoice is being created for
     * @param sequenceBySourceInvoice Running count of invoices already named per source invoice
     * @return Invoice number, or null when the source invoice has no number to derive from
     */
    private String buildSelloutInvoiceName(InvoiceGroupKey groupInfo,
                                           Map<Id, Integer> sequenceBySourceInvoice) {
        if (String.isBlank(groupInfo.sourceInvoiceName)) {
            return null;
        }

        Integer used = sequenceBySourceInvoice.containsKey(groupInfo.sourceInvoiceId)
            ? sequenceBySourceInvoice.get(groupInfo.sourceInvoiceId)
            : 0;
        sequenceBySourceInvoice.put(groupInfo.sourceInvoiceId, used + 1);

        return deriveSelloutInvoiceName(groupInfo.sourceInvoiceName, used);
    }

    /**
     * @description Derived sellout invoice number shared by the weekly and daily paths
     * @param sourceInvoiceName Number of the source invoice
     * @param alreadyUsed How many sellout invoices were already named from this source invoice
     * @return Source number plus the sellout suffix (with a sequence after the first), or null
     */
    public static String deriveSelloutInvoiceName(String sourceInvoiceName, Integer alreadyUsed) {
        if (String.isBlank(sourceInvoiceName)) {
            return null;
        }
        Integer used = alreadyUsed == null ? 0 : alreadyUsed;
        String suffix = SELLOUT_INVOICE_SUFFIX + (used == 0 ? '' : '-' + String.valueOf(used + 1));

        // Invoice Number is an 80 character text field; keep room for the suffix
        String base = sourceInvoiceName.trim();
        Integer maxBaseLength = 80 - suffix.length();
        if (base.length() > maxBaseLength) {
            base = base.substring(0, maxBaseLength);
        }

        return base + suffix;
    }

    /**
     * @description Derives child account name from Customer Name only
     * @param customerName Customer name from Order.Customer_name_Description__c
     * @return String Child account name or null if input is blank
     */
    private String deriveChildAccountName(String customerName) {
        if (String.isBlank(customerName)) {
            return null;
        }

        return customerName.trim();
    }

    /**
     * @description Wrapper class to group invoice line items by account and date
     */
    private class InvoiceGroupKey {
        public Id parentAccountId;
        public Id orderId;
        public Date invoiceDate;
        public String usageCompany;
        public String childAccountName;
        // The account this group's sellout invoice is created for - matched or newly created
        public Id childAccountId;
        // Source invoice this group's lines came from, used to derive the sellout invoice number
        public Id sourceInvoiceId;
        public String sourceInvoiceName;
        public List<Invoice_Line_Item__c> lineItems;
    }
}