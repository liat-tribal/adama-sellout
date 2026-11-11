/**
 * @description Tests for SLO_SelloutImportController: the synchronous import, matching and invoicing
 * paths, the review-list queries, the account decisions and the small screen helpers.
 */
@IsTest
private class SLO_SelloutImportControllerTest {

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
        return new Account(
            Name = name,
            ParentId = parentId,
            BillingCountry = 'France',
            BillingStreet = 'Rue de Test 1',
            BillingCity = 'Paris',
            BillingPostalCode = '75001',
            Status__c = status
        );
    }

    private static Account makeParentAccount() {
        Account parent = makeAccount('Parent Wholesaler', null, 'Active');
        insert parent;
        return parent;
    }

    private static Account makeChildAccount(Id parentId, String name, String status) {
        Account child = makeAccount(name, parentId, status);
        insert child;
        return child;
    }

    private static Product2 makeProduct(String barcode) {
        Product2 product = new Product2(Name = 'Product ' + barcode, Barcode__c = barcode, IsActive = true);
        insert product;
        insert new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(), Product2Id = product.Id, UnitPrice = 10, IsActive = true
        );
        return product;
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
        Id reportId, String customer, String productCode, Date itemDate, Decimal quantity, String status
    ) {
        return new SLO_Sellout_Item__c(
            SLO_Sellout_Report__c = reportId,
            SLO_Customer_Account_Name__c = customer,
            SLO_Product_Code_EAN__c = productCode,
            SLO_Item_Date__c = itemDate,
            SLO_Quantity__c = quantity,
            SLO_Processing_Status__c = status
        );
    }

    private static SLO_Sellout_Item__c makeMatchedItem(
        Id reportId, Id accountId, String productCode, Date itemDate, Decimal quantity
    ) {
        SLO_Sellout_Item__c item = makeItem(reportId, 'Known Shop', productCode, itemDate, quantity, 'Matched');
        item.SLO_Matched_Account__c = accountId;
        return item;
    }

    private static SLO_SelloutImportController.SelloutItemData makeRow(
        String itemDate, String productCode, String quantity, String customer
    ) {
        SLO_SelloutImportController.SelloutItemData row = new SLO_SelloutImportController.SelloutItemData();
        row.itemDate = itemDate;
        row.productCode = productCode;
        row.quantity = quantity;
        row.customerAccountName = customer;
        return row;
    }

    private static String statusOf(Id itemId) {
        return [SELECT SLO_Processing_Status__c FROM SLO_Sellout_Item__c WHERE Id = :itemId].SLO_Processing_Status__c;
    }

    private static String reportStatusOf(Id reportId) {
        return [SELECT SLO_Status__c FROM SLO_Sellout_Report__c WHERE Id = :reportId].SLO_Status__c;
    }

    // ---------------------------------------------------------------------------------------------
    // Locale parsing
    // ---------------------------------------------------------------------------------------------

    @IsTest
    static void parsesDatesForEachLocaleFamily() {
        Assert.areEqual(ITEM_DATE, SLO_SelloutImportController.parseDateForLocale('2026-01-15', 'fr_FR'));
        Assert.areEqual(ITEM_DATE, SLO_SelloutImportController.parseDateForLocale('01/15/2026', 'en_US'));
        Assert.areEqual(ITEM_DATE, SLO_SelloutImportController.parseDateForLocale('15.01.2026', 'de_DE'));
        Assert.areEqual(ITEM_DATE, SLO_SelloutImportController.parseDateForLocale('15-01-26', 'fr_FR'),
            'A two-digit year below 50 is read as 20xx');
        Assert.areEqual(Date.newInstance(1999, 1, 15),
            SLO_SelloutImportController.parseDateForLocale('15/01/99', 'en_GB'),
            'A two-digit year of 50 or more is read as 19xx');

        for (String bad : new List<String>{ '', '2026/01', '15/13/2026', '32/01/2026', '15/01/2200', 'aa/bb/cccc' }) {
            Boolean failed = false;
            try {
                SLO_SelloutImportController.parseDateForLocale(bad, 'fr_FR');
            } catch (IllegalArgumentException e) {
                failed = true;
            }
            Assert.isTrue(failed, 'An invalid date must be rejected: ' + bad);
        }
    }

    @IsTest
    static void parsesNumbersForDecimalCommaAndPoint() {
        Assert.areEqual(1234.5, SLO_SelloutImportController.parseNumberForLocale('1.234,5', 'fr_FR'));
        Assert.areEqual(1234.5, SLO_SelloutImportController.parseNumberForLocale('1,234.5', 'en_US'));
        Assert.areEqual(0, SLO_SelloutImportController.parseNumberForLocale('  ', 'en_US'));

        Boolean failed = false;
        try {
            SLO_SelloutImportController.parseNumberForLocale('abc', 'en_US');
        } catch (IllegalArgumentException e) {
            failed = true;
        }
        Assert.isTrue(failed, 'A non-numeric quantity is rejected');
    }

    // ---------------------------------------------------------------------------------------------
    // File parsing and synchronous import
    // ---------------------------------------------------------------------------------------------

    @IsTest
    static void parseFileRejectsBadInputAndReadsDataUrls() {
        Assert.isNotNull(SLO_SelloutImportController.parseFile('', 'file.xlsx', false, ',').errorMessage,
            'A non-CSV file is refused');
        Assert.areEqual('File is empty',
            SLO_SelloutImportController.parseFile('', 'file.csv', false, null).errorMessage);

        String csv = 'A;B\n1;2\n\n3;4\n';
        SLO_SelloutImportController.ParseResult parsed = SLO_SelloutImportController.parseFile(
            'data:text/csv;base64,' + EncodingUtil.base64Encode(Blob.valueOf(csv)), 'file.csv', true, ';'
        );
        Assert.isNull(parsed.errorMessage);
        Assert.areEqual(2, parsed.columnHeaders.size());
        Assert.areEqual(2, parsed.previewRows.size(), 'Blank lines are not rows');
    }

    @IsTest
    static void importSelloutItemsStoresRowsAndMarksDuplicates() {
        Account parent = makeParentAccount();
        SLO_Sellout_Report__c oldReport = makeReport(parent.Id, 'Completed');
        insert makeItem(oldReport.Id, 'Shop A', '123456', ITEM_DATE, 5, 'Invoice_Created');

        Test.startTest();
        SLO_SelloutImportController.ImportResult result = SLO_SelloutImportController.importSelloutItems(
            parent.Id,
            '2026-01-31',
            new List<SLO_SelloutImportController.SelloutItemData>{
                makeRow('2026-01-15', '123456', '5', 'Shop A'),
                makeRow('2026-01-16', '123456', '3', 'Shop B'),
                makeRow('2026-01-17', '123456', '', 'Shop C')
            }
        );
        Test.stopTest();

        Assert.isTrue(result.success, 'Unexpected error: ' + result.errorMessage);
        Assert.areEqual(1, result.duplicatesRemoved);
        Assert.areEqual(2, result.itemsImported, 'The duplicate is stored but not counted as new');
        Assert.areEqual('Draft', reportStatusOf(result.selloutReportId));
        Assert.areEqual(1, [
            SELECT COUNT() FROM SLO_Sellout_Item__c
            WHERE SLO_Sellout_Report__c = :result.selloutReportId AND SLO_Processing_Status__c = 'Skipped'
        ]);
    }

    @IsTest
    static void importSelloutItemsRejectsBadInput() {
        Account parent = makeParentAccount();

        Assert.areEqual('Invalid input parameters',
            SLO_SelloutImportController.importSelloutItems(parent.Id, '2026-01-31', null).errorMessage);

        SLO_SelloutImportController.ImportResult badReportDate = SLO_SelloutImportController.importSelloutItems(
            parent.Id, 'not a date',
            new List<SLO_SelloutImportController.SelloutItemData>{ makeRow('2026-01-15', '1', '1', 'A') }
        );
        Assert.isFalse(badReportDate.success);
        Assert.isTrue(badReportDate.errorMessage.startsWith('Invalid report date format'));

        SLO_SelloutImportController.ImportResult badRow = SLO_SelloutImportController.importSelloutItems(
            parent.Id, '2026-01-31',
            new List<SLO_SelloutImportController.SelloutItemData>{ makeRow('garbage', '1', '1', 'A') }
        );
        Assert.isFalse(badRow.success);
        Assert.isNotNull(badRow.selloutReportId, 'The report is created before the row fails');
        Assert.areEqual('Error', reportStatusOf(badRow.selloutReportId), 'A failed import marks the report');
    }

    // ---------------------------------------------------------------------------------------------
    // Synchronous Apply Sellout
    // ---------------------------------------------------------------------------------------------

    @IsTest
    static void applySelloutFlagsUnmatchedInactiveAndZeroRows() {
        Account parent = makeParentAccount();
        Account active = makeChildAccount(parent.Id, 'Known Shop', 'Active');
        makeChildAccount(parent.Id, 'Old Shop', 'N');
        Account grandchild = makeChildAccount(active.Id, 'Grand Shop', 'Active');

        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c zero = makeItem(report.Id, 'Known Shop', '1', ITEM_DATE, 0, 'Pending');
        SLO_Sellout_Item__c matched = makeItem(report.Id, 'Grand Shop', '1', ITEM_DATE, 2, 'Pending');
        SLO_Sellout_Item__c inactive1 = makeItem(report.Id, 'Old Shop', '1', ITEM_DATE, 2, 'Pending');
        SLO_Sellout_Item__c inactive2 = makeItem(report.Id, 'Old Shop', '2', ITEM_DATE, 2, 'Pending');
        SLO_Sellout_Item__c unknown1 = makeItem(report.Id, 'Nobody', '1', ITEM_DATE, 2, 'Pending');
        SLO_Sellout_Item__c unknown2 = makeItem(report.Id, 'Nobody', '2', ITEM_DATE, 2, 'Pending');
        insert new List<SLO_Sellout_Item__c>{ zero, matched, inactive1, inactive2, unknown1, unknown2 };

        Test.startTest();
        SLO_SelloutImportController.ApplySelloutResult result =
            SLO_SelloutImportController.applySellout(report.Id, parent.Id);
        Test.stopTest();

        Assert.isTrue(result.success, 'Unexpected error: ' + result.errorMessage);
        Assert.areEqual(1, result.itemsSkipped);
        Assert.areEqual(1, result.itemsMatched);
        Assert.areEqual(2, result.unmatchedItems.size(), 'One entry per inactive and per unknown name');
        Assert.areEqual('Skipped', statusOf(zero.Id));
        Assert.areEqual('Matched', statusOf(matched.Id));
        Assert.areEqual(grandchild.Id,
            [SELECT SLO_Matched_Account__c FROM SLO_Sellout_Item__c WHERE Id = :matched.Id].SLO_Matched_Account__c);
        Assert.areEqual('Pending_Decision', statusOf(inactive2.Id));
        Assert.areEqual('Pending_Decision', statusOf(unknown2.Id));
    }

    @IsTest
    static void applySelloutInvoicesWhenEverythingMatches() {
        if (!selloutTypeActive()) {
            return;
        }
        Account parent = makeParentAccount();
        makeChildAccount(parent.Id, 'Known Shop', 'Active');
        makeProduct('123456');

        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c item = makeItem(report.Id, 'Known Shop', '123456', ITEM_DATE, 4, 'Pending');
        insert item;

        Test.startTest();
        SLO_SelloutImportController.ApplySelloutResult result =
            SLO_SelloutImportController.applySellout(report.Id, parent.Id);
        Test.stopTest();

        Assert.isTrue(result.success, 'Unexpected error: ' + result.errorMessage);
        Assert.areEqual(1, result.positiveInvoicesCreated);
        Assert.areEqual(1, result.negativeInvoicesCreated);
        Assert.areEqual('Invoice_Created', statusOf(item.Id));
        Assert.areEqual('Completed', reportStatusOf(report.Id));
    }

    @IsTest
    static void applySelloutReportsEmptyAndFailedRuns() {
        Account parent = makeParentAccount();
        SLO_Sellout_Report__c empty = makeReport(parent.Id, 'Draft');
        Assert.areEqual('No sellout items found for this report',
            SLO_SelloutImportController.applySellout(empty.Id, parent.Id).errorMessage);

        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        insert makeItem(report.Id, 'Shop', '1', ITEM_DATE, 1, 'Pending');

        // The report Id is not an account, so the account lookup fails and the report is marked Error
        SLO_SelloutImportController.ApplySelloutResult failed =
            SLO_SelloutImportController.applySellout(report.Id, report.Id);
        Assert.isFalse(failed.success);
        Assert.areEqual('Error', reportStatusOf(report.Id));
    }

    // ---------------------------------------------------------------------------------------------
    // Invoice creation
    // ---------------------------------------------------------------------------------------------

    @IsTest
    static void invoicePassReconcilesAgainstExistingInvoices() {
        if (!selloutTypeActive()) {
            return;
        }
        Account parent = makeAccount('Parent Wholesaler', null, 'Active');
        String usageCompany =
            Account.Account_Usage_Company__c.getDescribe().getPicklistValues()[0].getValue();
        parent.Account_Usage_Company__c = usageCompany;
        insert parent;
        // Read back what was saved, in case automation rewrites the usage company on insert
        usageCompany = [SELECT Account_Usage_Company__c FROM Account WHERE Id = :parent.Id].Account_Usage_Company__c;
        Assert.isNotNull(usageCompany, 'The parent needs a usage company for the pricebook lookup');
        Account child = makeChildAccount(parent.Id, 'Known Shop', 'Active');

        makeProduct('111111');
        makeProduct('222222');
        Product2 priced = makeProduct('333333');
        // Found only through the ProductCode fallback, and only once the leading zero is dropped
        Product2 codeOnly = new Product2(Name = 'Code only', ProductCode = '444444', IsActive = true);
        insert codeOnly;

        Id pricebookId = Test.getStandardPricebookId();
        insert new PricebookEntry(
            Pricebook2Id = pricebookId, Product2Id = codeOnly.Id, UnitPrice = 10, IsActive = true
        );
        insert new ARF_CountrySettings__c(
            ARF_CountryCode__c = usageCompany,
            ARF_CountryName__c = 'Test Country',
            ARF_IsActive__c = true,
            ARF_UserPricebookOverrides__c = JSON.serialize(new List<Object>{
                new Map<String, Object>{ 'userId' => UserInfo.getUserId(), 'pricebookId' => pricebookId }
            })
        );

        // What the customer already has for ITEM_DATE, and the parent's offsetting invoice that day
        Invoice__c existing = new Invoice__c(
            Name = 'EXIST-1', Account_Name__c = child.Id, Invoice_Date__c = ITEM_DATE,
            Transaction_type__c = 'Internal Sellout', Status__c = 'New', Valid__c = true
        );
        Invoice__c existingNegative = new Invoice__c(
            Name = 'EXIST-1-N', Account_Name__c = parent.Id, Invoice_Date__c = ITEM_DATE,
            Transaction_type__c = 'Internal Sellout N', Status__c = 'New', Valid__c = true
        );
        insert new List<Invoice__c>{ existing, existingNegative };
        insert new List<Invoice_Line_Item__c>{
            new Invoice_Line_Item__c(Invoice_Number__c = existing.Id, Product_Name__c = '111111', Quantity__c = 5, Valid__c = true),
            new Invoice_Line_Item__c(Invoice_Number__c = existing.Id, Product_Name__c = '222222', Quantity__c = 3, Valid__c = true),
            new Invoice_Line_Item__c(Invoice_Number__c = existing.Id, Product_Name__c = null, Quantity__c = 1, Valid__c = true)
        };

        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c duplicate = makeMatchedItem(report.Id, child.Id, '111111', ITEM_DATE, 5);
        SLO_Sellout_Item__c mismatch = makeMatchedItem(report.Id, child.Id, '222222', ITEM_DATE, 7);
        SLO_Sellout_Item__c appended = makeMatchedItem(report.Id, child.Id, '333333', ITEM_DATE, 2);
        SLO_Sellout_Item__c byCode = makeMatchedItem(report.Id, child.Id, '0444444', ITEM_DATE.addDays(1), 1);
        SLO_Sellout_Item__c unknown = makeMatchedItem(report.Id, child.Id, '999999', ITEM_DATE.addDays(1), 1);
        SLO_Sellout_Item__c unknownOnly = makeMatchedItem(report.Id, child.Id, '888888', ITEM_DATE.addDays(2), 1);
        insert new List<SLO_Sellout_Item__c>{ duplicate, mismatch, appended, byCode, unknown, unknownOnly };

        Test.startTest();
        SLO_SelloutImportController.ApplySelloutResult result =
            SLO_SelloutImportController.createInvoicesForReport(report.Id);
        Test.stopTest();

        Assert.isTrue(result.success, 'Unexpected error: ' + result.errorMessage);
        Assert.areEqual('Skipped', statusOf(duplicate.Id), 'Same product and quantity is a duplicate');
        Assert.areEqual('Enforced_Skipped', statusOf(mismatch.Id), 'Same product, other quantity is set aside');
        Assert.areEqual(1, result.itemsQuantityMismatch);
        Assert.areEqual('Invoice_Created', statusOf(appended.Id));
        Assert.areEqual(1, result.lineItemsAddedToExistingInvoices, 'A new product joins the existing invoice');
        Assert.areEqual('Invoice_Created', statusOf(byCode.Id), 'The ProductCode fallback resolves the code');
        Assert.areEqual('Error', statusOf(unknown.Id));
        Assert.areEqual('Error', statusOf(unknownOnly.Id));
        Assert.areEqual(1, result.positiveInvoicesCreated, 'Only the new date needs a new customer invoice');
        Assert.areEqual(1, result.negativeInvoicesCreated, 'The existing offsetting invoice is reused');
        Assert.areEqual(10, [
            SELECT Unit_Price__c FROM Invoice_Line_Item__c
            WHERE Invoice_Number__c = :existing.Id AND Product_SKU__c = :priced.Id
        ].Unit_Price__c, 'The user override pricebook supplies the price');
        Assert.areEqual('Completed', reportStatusOf(report.Id));
    }

    @IsTest
    static void invoicePassSkipsGroupsThatAreFullyInvoiced() {
        if (!selloutTypeActive()) {
            return;
        }
        Account parent = makeParentAccount();
        Account child = makeChildAccount(parent.Id, 'Known Shop', 'Active');
        makeProduct('111111');

        Invoice__c existing = new Invoice__c(
            Account_Name__c = child.Id, Invoice_Date__c = ITEM_DATE,
            Transaction_type__c = 'Internal Sellout', Status__c = 'New', Valid__c = true
        );
        insert existing;
        insert new Invoice_Line_Item__c(
            Invoice_Number__c = existing.Id, Product_Name__c = '111111', Quantity__c = 5, Valid__c = true
        );

        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c duplicate = makeMatchedItem(report.Id, child.Id, '111111', ITEM_DATE, 5);
        insert duplicate;

        SLO_SelloutImportController.ApplySelloutResult result =
            SLO_SelloutImportController.createInvoicesForReport(report.Id);

        Assert.isTrue(result.success, 'Unexpected error: ' + result.errorMessage);
        Assert.areEqual(0, result.invoicesCreated);
        Assert.areEqual(1, result.duplicateGroupsSkipped);
        Assert.areEqual('Skipped', statusOf(duplicate.Id));
    }

    @IsTest
    static void invoicePassExplainsWhyNothingWasInvoiced() {
        Account parent = makeParentAccount();
        Account child = makeChildAccount(parent.Id, 'Known Shop', 'Active');

        SLO_Sellout_Report__c empty = makeReport(parent.Id, 'Draft');
        Assert.isTrue(SLO_SelloutImportController.createInvoicesForReport(empty.Id)
            .errorMessage.contains('no items'));

        SLO_Sellout_Report__c unmatched = makeReport(parent.Id, 'Draft');
        insert makeItem(unmatched.Id, 'Shop', '1', ITEM_DATE, 1, 'Pending');
        Assert.isTrue(SLO_SelloutImportController.createInvoicesForReport(unmatched.Id)
            .errorMessage.contains('Account matching has not been completed'));

        SLO_Sellout_Report__c errored = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c errorRow = makeMatchedItem(errored.Id, child.Id, '1', ITEM_DATE, 1);
        errorRow.SLO_Processing_Status__c = 'Error';
        insert errorRow;
        Assert.isTrue(SLO_SelloutImportController.createInvoicesForReport(errored.Id)
            .errorMessage.contains('items have errors'));

        SLO_Sellout_Report__c skipped = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c skippedRow = makeMatchedItem(skipped.Id, child.Id, '1', ITEM_DATE, 1);
        skippedRow.SLO_Processing_Status__c = 'Skipped';
        insert skippedRow;
        Assert.isTrue(SLO_SelloutImportController.createInvoicesForReport(skipped.Id)
            .errorMessage.contains('status "Matched"'));
    }

    @IsTest
    static void invoicePassClosesFinishedReportsAndHonoursCursor() {
        Account parent = makeParentAccount();
        Account child = makeChildAccount(parent.Id, 'Known Shop', 'Active');

        SLO_Sellout_Report__c invoiced = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c done = makeMatchedItem(invoiced.Id, child.Id, '1', ITEM_DATE, 1);
        done.SLO_Processing_Status__c = 'Invoice_Created';
        insert done;
        Assert.isTrue(SLO_SelloutImportController.createInvoicesForReport(invoiced.Id).success);
        Assert.areEqual('Completed', reportStatusOf(invoiced.Id));

        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c waiting = makeMatchedItem(report.Id, child.Id, '1', ITEM_DATE, 1);
        insert waiting;
        SLO_SelloutImportController.ApplySelloutResult atEnd =
            SLO_SelloutImportController.createInvoicePass(report.Id, waiting.Id);
        Assert.isTrue(atEnd.success);
        Assert.isNull(atEnd.lastItemIdExamined, 'A cursor past the end rewinds');
        Assert.areEqual(1, atEnd.matchedItemsRemaining);

        SLO_SelloutImportController.ApplySelloutResult broken =
            SLO_SelloutImportController.createInvoicePass('not-an-id', null);
        Assert.isFalse(broken.success);
    }

    // ---------------------------------------------------------------------------------------------
    // Review list and summaries
    // ---------------------------------------------------------------------------------------------

    @IsTest
    static void accountDecisionViewListsSetAsideNamesAfterOpenOnes() {
        Account parent = makeParentAccount();
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c declined = makeItem(report.Id, 'Left Out', '1', ITEM_DATE, 1, 'Skipped');
        declined.SLO_Processing_Notes__c = SLO_SelloutImportController.NOTE_ACCOUNT_DECLINED;
        SLO_Sellout_Item__c duplicate = makeItem(report.Id, 'Dup', '1', ITEM_DATE, 1, 'Skipped');
        duplicate.SLO_Processing_Notes__c = SLO_SelloutImportController.NOTE_DUPLICATE;
        insert new List<SLO_Sellout_Item__c>{
            makeItem(report.Id, 'Nobody A', '1', ITEM_DATE, 1, 'Pending_Decision'),
            makeItem(report.Id, 'Nobody B', '1', ITEM_DATE, 1, 'Pending_Decision'),
            declined,
            duplicate
        };

        SLO_SelloutImportController.SelloutItemPage first =
            SLO_SelloutImportController.getSelloutItemPage(report.Id, 1, 0, false, 'Pending_Decision');
        Assert.areEqual(3, first.totalCount, 'Two awaiting plus one set aside; the duplicate is not listed');
        Assert.isTrue(first.hasMore);

        SLO_SelloutImportController.SelloutItemPage last =
            SLO_SelloutImportController.getSelloutItemPage(report.Id, 5, 2, false, 'Pending_Decision');
        Assert.areEqual(declined.Id, last.items[0].Id, 'The set-aside line follows the open ones');

        Assert.isTrue(SLO_SelloutImportController.getSelloutItemPage(report.Id, 5, 10, false, 'Pending_Decision')
            .items.isEmpty());

        SLO_SelloutImportController.SelloutItemPage loadAll =
            SLO_SelloutImportController.getActionableItemsAfter(report.Id, null, false, 'Pending_Decision');
        Assert.areEqual(3, loadAll.items.size());
        Assert.areEqual(3, loadAll.totalCount);

        Map<String, Integer> counts = SLO_SelloutImportController.getItemStatusCounts(report.Id);
        Assert.areEqual(1, counts.get('Skipped_Accounts'));
    }

    @IsTest
    static void mixedReviewViewPutsErrorsFirst() {
        Account parent = makeParentAccount();
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        insert new List<SLO_Sellout_Item__c>{
            makeItem(report.Id, 'Shop', '1', ITEM_DATE, 1, 'Matched'),
            makeItem(report.Id, 'Shop', '2', ITEM_DATE, 1, 'Pending'),
            makeItem(report.Id, 'Shop', '3', ITEM_DATE, 1, 'Error')
        };

        SLO_SelloutImportController.SelloutItemPage page =
            SLO_SelloutImportController.getSelloutItemPage(report.Id, null, null, false, 'all');
        Assert.areEqual(3, page.totalCount);
        Assert.areEqual('Error', page.items[0].SLO_Processing_Status__c);
        Assert.isFalse(page.hasMore);

        Assert.areEqual(1, SLO_SelloutImportController.getSelloutItemPage(report.Id, 5, 0, true, null).totalCount,
            'The legacy errors-only flag still filters');
        Assert.isTrue(SLO_SelloutImportController.getSelloutItemPage(report.Id, 5, 50, false, 'all').items.isEmpty());
        Assert.areEqual(0, SLO_SelloutImportController.getSelloutItemPage(null, 5, 0, false, 'all').totalCount);

        SLO_SelloutImportController.SelloutItemPage firstChunk =
            SLO_SelloutImportController.getActionableItemsAfter(report.Id, null, false, null);
        SLO_SelloutImportController.SelloutItemPage afterFirst = SLO_SelloutImportController.getActionableItemsAfter(
            report.Id, firstChunk.items[0].Id, false, null
        );
        Assert.areEqual(2, afterFirst.items.size(), 'The cursor skips what was already loaded');
        Assert.areEqual(0, SLO_SelloutImportController.getActionableItemsAfter(null, null, false, null).totalCount);

        Assert.areEqual(3, SLO_SelloutImportController.getSelloutItems(report.Id).size());
        Assert.areEqual(3, SLO_SelloutImportController.getFilteredSelloutItems(report.Id, true).size());
        Assert.areEqual(3, SLO_SelloutImportController.getFilteredSelloutItems(report.Id, false).size());
        Assert.isTrue(SLO_SelloutImportController.getSelloutItems(null).isEmpty());
        Assert.isTrue(SLO_SelloutImportController.getFilteredSelloutItems(null, false).isEmpty());
        Assert.areEqual(1, SLO_SelloutImportController.getSelloutReports(parent.Id).size());
        Assert.isTrue(SLO_SelloutImportController.getSelloutReports(null).isEmpty());
        Assert.isFalse(SLO_SelloutImportController.getProcessingStatusValues().isEmpty());
    }

    @IsTest
    static void reportSummaryCountsEveryOutcome() {
        if (!selloutTypeActive()) {
            return;
        }
        Account parent = makeParentAccount();
        Account child = makeChildAccount(parent.Id, 'Known Shop', 'Active');
        makeProduct('111111');
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        insert new List<SLO_Sellout_Item__c>{
            makeMatchedItem(report.Id, child.Id, '111111', ITEM_DATE, 2),
            makeItem(report.Id, 'Shop', '1', ITEM_DATE, 1, 'Skipped'),
            makeItem(report.Id, 'Shop', '2', ITEM_DATE, 1, 'Enforced_Skipped'),
            makeItem(report.Id, 'Shop', '3', ITEM_DATE, 1, 'Error')
        };
        SLO_SelloutImportController.createInvoicesForReport(report.Id);
        // Two more rows were read from the file than were stored - older imports dropped duplicates
        update new SLO_Sellout_Report__c(Id = report.Id, SLO_Total_Items__c = 6);

        SLO_SelloutImportController.SelloutSummary summary = SLO_SelloutImportController.getReportSummary(report.Id);

        Assert.areEqual(1, summary.linesInvoiced);
        Assert.areEqual(3, summary.duplicatesSkipped);
        Assert.areEqual(1, summary.enforcedSkipped);
        Assert.areEqual(1, summary.errors);
        Assert.areEqual(1, summary.invoicesCreated);
        Assert.areEqual(0, SLO_SelloutImportController.getReportSummary(null).totalItems);

        Boolean failed = false;
        try {
            SLO_SelloutImportController.getReportSummary(child.Id);
        } catch (AuraHandledException e) {
            failed = true;
        }
        Assert.isTrue(failed, 'An unknown report is reported to the screen');
    }

    @IsTest
    static void reportStatusFlagsStuckReportsAndReconcileRepairsThem() {
        Account parent = makeParentAccount();
        Account child = makeChildAccount(parent.Id, 'Known Shop', 'Active');

        SLO_Sellout_Report__c completed = makeReport(parent.Id, 'Completed');
        insert new List<SLO_Sellout_Item__c>{
            makeMatchedItem(completed.Id, child.Id, '1', ITEM_DATE, 1),
            makeItem(completed.Id, 'Shop', '1', ITEM_DATE, 1, 'Pending_Decision'),
            makeItem(completed.Id, 'Shop', '2', ITEM_DATE, 1, 'Error'),
            makeItem(completed.Id, 'Shop', '3', ITEM_DATE, 1, 'Skipped'),
            makeItem(completed.Id, 'Shop', '4', ITEM_DATE, 1, 'Pending'),
            makeItem(completed.Id, 'Shop', '5', ITEM_DATE, 1, 'Invoice_Created')
        };
        SLO_SelloutImportController.ReportStatus stuck = SLO_SelloutImportController.getReportStatus(completed.Id);
        Assert.isTrue(stuck.isStuck, 'Completed with matched items left is stuck');
        Assert.areEqual(1, stuck.matchedCount);
        Assert.areEqual(1, stuck.pendingDecisionCount);
        Assert.areEqual('Draft', SLO_SelloutImportController.reconcileReportStatus(completed.Id).status);

        SLO_Sellout_Report__c errored = makeReport(parent.Id, 'Error');
        Assert.isTrue(SLO_SelloutImportController.getReportStatus(errored.Id).isStuck);
        Assert.areEqual('Completed', SLO_SelloutImportController.reconcileReportStatus(errored.Id).status);

        SLO_Sellout_Report__c emptyImport = makeReport(parent.Id, 'New');
        Assert.isTrue(SLO_SelloutImportController.getReportStatus(emptyImport.Id).isStuck);
        Assert.isNull(SLO_SelloutImportController.getReportStatus(null).status);

        SLO_SelloutImportController.resetReportStatus(errored.Id);
        Assert.areEqual('Draft', reportStatusOf(errored.Id));

        Boolean failed = false;
        try {
            SLO_SelloutImportController.reconcileReportStatus(child.Id);
        } catch (AuraHandledException e) {
            failed = true;
        }
        Assert.isTrue(failed);
    }

    // ---------------------------------------------------------------------------------------------
    // Account decisions
    // ---------------------------------------------------------------------------------------------

    @IsTest
    static void singleAccountActionsLinkTheirLines() {
        Account parent = makeParentAccount();
        Account inactive = makeChildAccount(parent.Id, 'Old Shop', 'N');
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c a = makeItem(report.Id, 'New Shop', '1', ITEM_DATE, 1, 'Pending_Decision');
        SLO_Sellout_Item__c b = makeItem(report.Id, 'Other Shop', '1', ITEM_DATE, 1, 'Pending_Decision');
        SLO_Sellout_Item__c c = makeItem(report.Id, 'Old Shop', '1', ITEM_DATE, 1, 'Pending_Decision');
        SLO_Sellout_Item__c d = makeItem(report.Id, 'Skip Shop', '1', ITEM_DATE, 1, 'Pending_Decision');
        insert new List<SLO_Sellout_Item__c>{ a, b, c, d };

        Test.startTest();
        Id createdId = SLO_SelloutImportController.createChildAccount(parent.Id, 'New Shop', new List<String>{ a.Id });
        Id suffixedId = SLO_SelloutImportController.createChildAccountWithSuffix(
            parent.Id, 'Other Shop', new List<String>{ b.Id }
        );
        Assert.areEqual('Success', SLO_SelloutImportController.activateAccount(inactive.Id, new List<String>{ c.Id }));
        SLO_SelloutImportController.skipMatchingForItem(new List<String>{ d.Id });
        Test.stopTest();

        Assert.areEqual(createdId,
            [SELECT SLO_Matched_Account__c FROM SLO_Sellout_Item__c WHERE Id = :a.Id].SLO_Matched_Account__c);
        Assert.areEqual(suffixedId,
            [SELECT SLO_Matched_Account__c FROM SLO_Sellout_Item__c WHERE Id = :b.Id].SLO_Matched_Account__c);
        Assert.areEqual('Active', [SELECT Status__c FROM Account WHERE Id = :inactive.Id].Status__c);
        Assert.areEqual('Matched', statusOf(c.Id));
        Assert.areEqual('Skipped', statusOf(d.Id));

        Integer failures = 0;
        try { SLO_SelloutImportController.createChildAccount(report.Id, 'X', new List<String>()); } catch (AuraHandledException e) { failures++; }
        try { SLO_SelloutImportController.createChildAccountWithSuffix(report.Id, 'X', new List<String>()); } catch (AuraHandledException e) { failures++; }
        try { SLO_SelloutImportController.activateAccount(report.Id, new List<String>()); } catch (AuraHandledException e) { failures++; }
        try { SLO_SelloutImportController.skipMatchingForItem(new List<String>{ parent.Id }); } catch (AuraHandledException e) { failures++; }
        try { SLO_SelloutImportController.resetReportStatus(parent.Id); } catch (AuraHandledException e) { failures++; }
        Assert.areEqual(5, failures, 'Every failure reaches the screen as an AuraHandledException');
    }

    @IsTest
    static void bulkDecisionsActivateSkipAndQueueInvoicing() {
        Account parent = makeParentAccount();
        Account inactive = makeChildAccount(parent.Id, 'Old Shop', 'N');
        makeProduct('123456');
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c toActivate = makeItem(report.Id, 'Old Shop', '123456', ITEM_DATE, 2, 'Pending_Decision');
        SLO_Sellout_Item__c zero = makeItem(report.Id, 'Old Shop', '123456', ITEM_DATE, 0, 'Pending_Decision');
        SLO_Sellout_Item__c toSkip = makeItem(report.Id, 'Skip Shop', '123456', ITEM_DATE, 1, 'Pending_Decision');
        SLO_Sellout_Item__c undecided = makeItem(report.Id, 'Later Shop', '123456', ITEM_DATE, 1, 'Pending_Decision');
        insert new List<SLO_Sellout_Item__c>{ toActivate, zero, toSkip, undecided };

        SLO_SelloutImportController.UnmatchedDecision activateDecision = new SLO_SelloutImportController.UnmatchedDecision();
        activateDecision.customerAccountName = 'Old Shop';
        activateDecision.action = 'activate';
        activateDecision.existingAccountId = inactive.Id;
        SLO_SelloutImportController.UnmatchedDecision skip = new SLO_SelloutImportController.UnmatchedDecision();
        skip.customerAccountName = 'Skip Shop';
        SLO_SelloutImportController.UnmatchedDecision reassignNowhere = new SLO_SelloutImportController.UnmatchedDecision();
        reassignNowhere.customerAccountName = 'Later Shop';
        reassignNowhere.action = 'reassign';

        Test.startTest();
        SLO_SelloutImportController.BulkResolveResult result = SLO_SelloutImportController.bulkResolveUnmatched(
            report.Id, parent.Id,
            new List<SLO_SelloutImportController.UnmatchedDecision>{ activateDecision, skip, reassignNowhere, null },
            true
        );
        Test.stopTest();

        Assert.isTrue(result.success, 'Unexpected error: ' + result.errorMessage);
        Assert.areEqual(1, result.accountsActivated);
        Assert.areEqual(1, result.itemsSkipped);
        Assert.isNotNull(result.jobId, 'Invoicing is queued once lines are matched');
        Assert.areEqual('Skipped', statusOf(zero.Id), 'A zero-quantity line is set aside by the decision');
        Assert.areEqual('Pending_Decision', statusOf(undecided.Id), 'A reassign with no target leaves the line');

        Assert.areEqual('Invalid input parameters', SLO_SelloutImportController.bulkResolveUnmatched(
            report.Id, parent.Id, new List<SLO_SelloutImportController.UnmatchedDecision>(), false
        ).errorMessage);
        Assert.isFalse(SLO_SelloutImportController.bulkResolveUnmatched(
            report.Id, report.Id, new List<SLO_SelloutImportController.UnmatchedDecision>{ skip }, false
        ).success, 'An unknown parent account fails the run');
    }

    @IsTest
    static void bulkDecideCustomerNamesValidatesAndApplies() {
        Account parent = makeParentAccount();
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c row = makeItem(report.Id, 'Skip Shop', '1', ITEM_DATE, 1, 'Pending_Decision');
        insert row;

        Assert.isNotNull(SLO_SelloutImportController.bulkDecideCustomerNames(
            report.Id, parent.Id, null, 'skip', null).errorMessage);
        Assert.isTrue(SLO_SelloutImportController.bulkDecideCustomerNames(
            report.Id, parent.Id, new List<String>{ 'A' }, 'explode', null).errorMessage.startsWith('Unsupported'));
        Assert.isNotNull(SLO_SelloutImportController.bulkDecideCustomerNames(
            report.Id, parent.Id, new List<String>{ 'A' }, 'reassign', null).errorMessage);
        Assert.isNotNull(SLO_SelloutImportController.bulkDecideCustomerNames(
            report.Id, parent.Id, new List<String>{ ' ', null }, 'skip', null).errorMessage);

        SLO_SelloutImportController.BulkResolveResult result = SLO_SelloutImportController.bulkDecideCustomerNames(
            report.Id, parent.Id, new List<String>{ 'Skip Shop', 'skip shop' }, 'SKIP', null
        );
        Assert.isTrue(result.success, 'Unexpected error: ' + result.errorMessage);
        Assert.areEqual(1, result.itemsSkipped, 'A name ticked twice is decided once');

        SLO_SelloutImportController.BulkResolveResult single = SLO_SelloutImportController.resolveUnmatchedRow(
            report.Id, parent.Id, 'Skip Shop', 'skip', null
        );
        Assert.isTrue(single.success, 'A set-aside line can be decided again');
    }

    @IsTest
    static void bulkEditCorrectsProductCodeAndCustomerName() {
        Account parent = makeParentAccount();
        Account child = makeChildAccount(parent.Id, 'Known Shop', 'Active');
        makeProduct('123456');
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c badCode1 = makeMatchedItem(report.Id, child.Id, '999999', ITEM_DATE, 1);
        SLO_Sellout_Item__c badCode2 = makeMatchedItem(report.Id, child.Id, '999999', ITEM_DATE.addDays(1), 2);
        badCode1.SLO_Processing_Status__c = 'Error';
        badCode2.SLO_Processing_Status__c = 'Error';
        SLO_Sellout_Item__c badName = makeItem(report.Id, 'Typo', '123456', ITEM_DATE, 3, 'Error');
        insert new List<SLO_Sellout_Item__c>{ badCode1, badCode2, badName };

        List<String> block = SLO_SelloutImportController.getItemIdsByProductCode(report.Id, ' 999999 ');
        Assert.areEqual(2, block.size());
        Assert.isTrue(SLO_SelloutImportController.getItemIdsByProductCode(null, '1').isEmpty());

        Test.startTest();
        SLO_SelloutImportController.BulkEditResult codeFix =
            SLO_SelloutImportController.bulkEditItemField(block, 'productCode', '123456');
        SLO_SelloutImportController.BulkEditResult nameFix = SLO_SelloutImportController.bulkEditItemField(
            new List<String>{ badName.Id, badName.Id, '' }, 'customerAccountName', 'Known Shop'
        );
        Test.stopTest();

        Assert.isTrue(codeFix.success, 'Unexpected error: ' + codeFix.errorMessage);
        Assert.areEqual(2, codeFix.rowsUpdated);
        Assert.areEqual(2, codeFix.nowReady);
        Assert.isFalse(codeFix.reportCounts.isEmpty(), 'The badges are read back from the report');
        Assert.isTrue(nameFix.success, 'Unexpected error: ' + nameFix.errorMessage);
        Assert.areEqual(1, nameFix.rowsUpdated, 'A line ticked twice is written once');

        Assert.isNotNull(SLO_SelloutImportController.bulkEditItemField(null, 'productCode', '1').errorMessage);
        Assert.isNotNull(SLO_SelloutImportController.bulkEditItemField(block, 'quantity', '1').errorMessage);
        Assert.isNotNull(SLO_SelloutImportController.bulkEditItemField(block, 'productCode', ' ').errorMessage);
        Assert.isNotNull(SLO_SelloutImportController.bulkEditItemField(block, 'customerAccountName', '').errorMessage);
    }

    // ---------------------------------------------------------------------------------------------
    // Async starters and small helpers
    // ---------------------------------------------------------------------------------------------

    @IsTest
    static void asyncStartersValidateAndQueue() {
        Account parent = makeParentAccount();
        Account child = makeChildAccount(parent.Id, 'Known Shop', 'Active');
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');

        Assert.areEqual('Invalid input parameters',
            SLO_SelloutImportController.startAsyncApplySellout(null, parent.Id).errorMessage);
        Assert.areEqual('Invalid input parameters',
            SLO_SelloutImportController.resumeInvoiceCreation(report.Id, null).errorMessage);
        Assert.areEqual('Invalid input parameters',
            SLO_SelloutImportController.startAsyncImport(parent.Id, '2026-01-31', null, null).errorMessage);
        Assert.isFalse(SLO_SelloutImportController.startAsyncImport(
            parent.Id, 'bad date', 'x', new SLO_SelloutImportController.ImportMappingConfig()
        ).success);
        Assert.isNotNull(SLO_SelloutImportController.resumeInvoiceCreation(report.Id, parent.Id).errorMessage,
            'Nothing waits to be invoiced yet');

        insert makeMatchedItem(report.Id, child.Id, '1', ITEM_DATE, 1);

        Test.startTest();
        Assert.isTrue(SLO_SelloutImportController.resumeInvoiceCreation(report.Id, parent.Id).success);
        Assert.isTrue(SLO_SelloutImportController.startAsyncApplySellout(report.Id, parent.Id).success);
        Test.stopTest();
    }

    @IsTest
    static void smallHelpersBehave() {
        Account parent = makeParentAccount();

        Assert.isTrue(SLO_SelloutImportController.getAsyncRowThreshold() > 0);
        Assert.isNotNull(SLO_SelloutImportController.canDeleteReports());

        Assert.isNull(SLO_SelloutImportController.getSavedColumnMapping(null));
        SLO_SelloutImportController.saveColumnMapping(parent.Id, '{"itemDateIndex":0}');
        SLO_SelloutImportController.saveColumnMapping(parent.Id, null);
        Assert.areEqual('{"itemDateIndex":0}', SLO_SelloutImportController.getSavedColumnMapping(parent.Id));
        Assert.isNull(SLO_SelloutImportController.getSavedColumnMapping('001000000000000AAA'),
            'An unknown account has no mapping');

        Id versionId = SLO_SelloutImportController.saveCsvFile(
            'sellout.csv', EncodingUtil.base64Encode(Blob.valueOf('a,b\n1,2'))
        );
        Assert.isNotNull(versionId);
        Integer failures = 0;
        try { SLO_SelloutImportController.saveCsvFile('sellout.xlsx', 'abc'); } catch (AuraHandledException e) { failures++; }
        try { SLO_SelloutImportController.saveCsvFile('sellout.csv', ''); } catch (AuraHandledException e) { failures++; }
        try { SLO_SelloutImportController.saveColumnMapping('001000000000000AAA', '{}'); } catch (AuraHandledException e) { failures++; }
        Assert.areEqual(3, failures);

        Assert.areEqual(0, SLO_SelloutImportController.skipUncorrectedErrorItems(null));
        Assert.areEqual(0, SLO_SelloutImportController.enforceSkipItems(null));
        Assert.isTrue(SLO_SelloutImportController.getUnmatchedAccounts(null).isEmpty());
        Assert.isTrue(SLO_SelloutImportController.getHierarchyAccountOptions(null).isEmpty());

        SLO_SelloutImportController.sendCompletionEmail(null, 'subject', 'body');
        SLO_SelloutImportController.sendCompletionEmail('someone@example.com', 'subject', 'body');
    }

    @IsTest
    static void accountMatcherMatchesOnlyInsideHierarchy() {
        Account parent = makeParentAccount();
        Account child = makeChildAccount(parent.Id, 'Child Store', 'Active');
        Account grandchild = makeChildAccount(child.Id, 'Grandchild Store', 'Active');
        Account other = makeAccount('Other Distributor', null, 'Active');
        insert other;
        makeChildAccount(other.Id, 'Foreign Store', 'Active');

        SLO_SelloutAccountMatcher.MatchResult main =
            SLO_SelloutAccountMatcher.matchAccount(parent.Id, ' parent wholesaler ');
        Assert.areEqual('main', main.matchType);
        Assert.areEqual(parent.Id, main.accountId);

        SLO_SelloutAccountMatcher.MatchResult childResult =
            SLO_SelloutAccountMatcher.matchAccount(parent.Id, 'CHILD STORE');
        Assert.areEqual('child', childResult.matchType);
        Assert.areEqual(child.Id, childResult.accountId);

        SLO_SelloutAccountMatcher.MatchResult grandResult =
            SLO_SelloutAccountMatcher.matchAccount(parent.Id, 'Grandchild Store');
        Assert.areEqual('grandchild', grandResult.matchType);
        Assert.areEqual(grandchild.Id, grandResult.accountId);

        Assert.areEqual('none', SLO_SelloutAccountMatcher.matchAccount(parent.Id, 'Foreign Store').matchType,
            'An account under another distributor must not match');
        Assert.areEqual('none', SLO_SelloutAccountMatcher.matchAccount(null, 'Child Store').matchType);
        Assert.areEqual('none', SLO_SelloutAccountMatcher.matchAccount(parent.Id, '').matchType);

        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c item = makeItem(report.Id, 'Child Store', '123', ITEM_DATE, 1, 'Pending');
        insert item;
        Map<String, SLO_SelloutAccountMatcher.MatchResult> batch =
            SLO_SelloutAccountMatcher.batchMatchAccounts(parent.Id, new List<String>{ item.Id });
        Assert.areEqual(child.Id, batch.get(item.Id).accountId);
        Assert.isTrue(SLO_SelloutAccountMatcher.batchMatchAccounts(parent.Id, null).isEmpty());

        Assert.areEqual('failed', failMessage(null, 'X'), 'Blank parent is rejected');
        Assert.areEqual('failed', failMessage('001000000000000AAA', 'X'), 'Unknown parent is rejected');

        String createdId = SLO_SelloutAccountMatcher.createChildAccount(parent.Id, 'Brand New Store');
        Assert.areEqual(parent.Id, [SELECT ParentId FROM Account WHERE Id = :createdId].ParentId);
    }

    private static String failMessage(String parentId, String name) {
        try {
            SLO_SelloutAccountMatcher.createChildAccount(parentId, name);
        } catch (AuraHandledException e) {
            return 'failed';
        }
        return 'none';
    }
}
