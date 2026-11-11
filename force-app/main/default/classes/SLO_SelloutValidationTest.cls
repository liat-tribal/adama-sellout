/**
 * @description Tests for review-time validation: the shared item validator (duplicates, unknown
 * product codes, quantity conflicts), the re-validation run by updateSelloutItems after an inline
 * edit, and the import batch flagging rows as it stores them.
 */
@IsTest
private class SLO_SelloutValidationTest {

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

    private static Account makeParentAccount() {
        Account parent = new Account(
            Name = 'Parent Wholesaler',
            BillingCountry = 'France',
            BillingStreet = 'Rue de Test 1',
            BillingCity = 'Paris',
            BillingPostalCode = '75001',
            Status__c = 'Active'
        );
        insert parent;
        return parent;
    }

    private static Account makeChildAccount(Id parentId, String name) {
        Account child = new Account(
            Name = name,
            ParentId = parentId,
            BillingCountry = 'France',
            BillingStreet = 'Rue de Test 1',
            BillingCity = 'Paris',
            BillingPostalCode = '75001',
            Status__c = 'Active'
        );
        insert child;
        return child;
    }

    private static Product2 makeProduct(String barcode) {
        Product2 product = new Product2(
            Name = 'Product ' + barcode,
            Barcode__c = barcode,
            IsActive = true
        );
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

    @IsTest
    static void validatorFlagsDuplicateConflictAndBadProduct() {
        Account parent = makeParentAccount();
        makeProduct('123456');

        SLO_Sellout_Report__c oldReport = makeReport(parent.Id, 'Completed');
        insert new List<SLO_Sellout_Item__c>{
            // Recorded line the new rows are compared against
            makeItem(oldReport.Id, 'Shop A', '123456', ITEM_DATE, 5, 'Invoice_Created'),
            // A line the user skipped is not "recorded" and must not raise conflicts
            makeItem(oldReport.Id, 'Shop B', '123456', ITEM_DATE, 3, 'Skipped')
        };

        SLO_Sellout_Report__c newReport = makeReport(parent.Id, 'New');
        SLO_Sellout_Item__c exactDuplicate =
            makeItem(newReport.Id, 'Shop A', '123456', ITEM_DATE, 5, 'Pending');
        SLO_Sellout_Item__c quantityConflict =
            makeItem(newReport.Id, 'Shop A', '123456', ITEM_DATE, 7, 'Pending');
        SLO_Sellout_Item__c badProduct =
            makeItem(newReport.Id, 'Shop A', '999999', ITEM_DATE, 3, 'Pending');
        SLO_Sellout_Item__c cleanRow =
            makeItem(newReport.Id, 'Shop A', '123456', ITEM_DATE.addDays(1), 4, 'Pending');
        SLO_Sellout_Item__c vsSkippedRow =
            makeItem(newReport.Id, 'Shop B', '123456', ITEM_DATE, 8, 'Pending');

        Test.startTest();
        SLO_SelloutImportController.ValidationCounts counts =
            SLO_SelloutImportController.validateItemsForAccount(
                new List<SLO_Sellout_Item__c>{
                    exactDuplicate, quantityConflict, badProduct, cleanRow, vsSkippedRow
                },
                parent.Id,
                null
            );
        Test.stopTest();

        Assert.areEqual(1, counts.duplicates, 'The exact duplicate should be counted');
        Assert.areEqual(1, counts.productErrors, 'The unknown product code should be counted');
        Assert.areEqual(1, counts.quantityConflicts, 'The quantity conflict should be counted');

        Assert.areEqual('Skipped', exactDuplicate.SLO_Processing_Status__c);
        Assert.isTrue(
            exactDuplicate.SLO_Processing_Notes__c.startsWith(SLO_SelloutImportController.NOTE_DUPLICATE),
            'The duplicate note names the earlier report: ' + exactDuplicate.SLO_Processing_Notes__c
        );
        Assert.isTrue(exactDuplicate.SLO_Processing_Notes__c.contains('report '),
            'A cross-report duplicate says where the line was recorded');

        Assert.areEqual('Error', quantityConflict.SLO_Processing_Status__c);
        Assert.isTrue(
            quantityConflict.SLO_Processing_Notes__c.startsWith(
                SLO_SelloutImportController.NOTE_QUANTITY_CONFLICT_PREFIX + '5'
            ),
            'The conflict note should carry the recorded quantity: ' + quantityConflict.SLO_Processing_Notes__c
        );

        Assert.areEqual('Error', badProduct.SLO_Processing_Status__c);
        Assert.areEqual(SLO_SelloutImportController.NOTE_PRODUCT_NOT_FOUND, badProduct.SLO_Processing_Notes__c);

        Assert.areEqual('Pending', cleanRow.SLO_Processing_Status__c, 'A clean row keeps its status');
        Assert.areEqual('Pending', vsSkippedRow.SLO_Processing_Status__c,
            'A skipped line must not block a different quantity from loading');
    }

    @IsTest
    static void validatorTreatsInFileLinesAsOrdersNotConflicts() {
        Account parent = makeParentAccount();
        makeProduct('123456');
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'New');

        // Sellout statistics are per order line: two orders of the same product by the same
        // customer on the same day are two lines with different quantities, not a conflict
        SLO_Sellout_Item__c firstOrder = makeItem(report.Id, 'Shop C', '123456', ITEM_DATE, 500, 'Pending');
        SLO_Sellout_Item__c secondOrder = makeItem(report.Id, 'Shop C', '123456', ITEM_DATE, 100, 'Pending');
        SLO_Sellout_Item__c inFileDuplicate = makeItem(report.Id, 'Shop C', '123456', ITEM_DATE, 500, 'Pending');

        SLO_SelloutImportController.ValidationCounts counts =
            SLO_SelloutImportController.validateItemsForAccount(
                new List<SLO_Sellout_Item__c>{ firstOrder, secondOrder, inFileDuplicate },
                parent.Id,
                null
            );

        Assert.areEqual('Pending', firstOrder.SLO_Processing_Status__c, 'The first order stays clean');
        Assert.areEqual('Pending', secondOrder.SLO_Processing_Status__c,
            'A second order the same day with another quantity is another order, not a conflict');
        Assert.areEqual('Skipped', inFileDuplicate.SLO_Processing_Status__c,
            'An identical line within the file is still a duplicate');
        Assert.areEqual(SLO_SelloutImportController.NOTE_DUPLICATE, inFileDuplicate.SLO_Processing_Notes__c,
            'An in-file repeat needs no pointer to another report');
        Assert.areEqual(1, counts.duplicates);
        Assert.areEqual(0, counts.quantityConflicts);
    }

    @IsTest
    static void editRematchesRowToHierarchyAccount() {
        Account parent = makeParentAccount();
        Account child = makeChildAccount(parent.Id, 'Shop A');
        makeProduct('123456');

        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c item =
            makeItem(report.Id, 'Unknown Shop', '123456', ITEM_DATE, 5, 'Pending_Decision');
        item.SLO_Processing_Notes__c = SLO_SelloutImportController.NOTE_ACCOUNT_NOT_FOUND;
        insert item;

        Test.startTest();
        List<SLO_Sellout_Item__c> revalidated = SLO_SelloutImportController.updateSelloutItems(
            new List<SLO_Sellout_Item__c>{
                new SLO_Sellout_Item__c(Id = item.Id, SLO_Customer_Account_Name__c = 'Shop A')
            }
        );
        Test.stopTest();

        Assert.areEqual(1, revalidated.size(), 'The edited row should be returned re-validated');
        Assert.areEqual('Matched', revalidated[0].SLO_Processing_Status__c,
            'Fixing the name to an existing account should resolve the row');
        Assert.areEqual(SLO_SelloutImportController.NOTE_READY, revalidated[0].SLO_Processing_Notes__c);
        Assert.areEqual(child.Id, revalidated[0].SLO_Matched_Account__c);
    }

    @IsTest
    static void correctingProductCodeMakesRowReady() {
        Account parent = makeParentAccount();
        Account child = makeChildAccount(parent.Id, 'Shop A');
        makeProduct('123456');

        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        // The row the user is looking at: its account is already resolved, only the code is wrong
        SLO_Sellout_Item__c item = makeItem(report.Id, 'Shop A', '999999', ITEM_DATE, 5, 'Error');
        item.SLO_Processing_Notes__c = SLO_SelloutImportController.NOTE_PRODUCT_NOT_FOUND;
        item.SLO_Matched_Account__c = child.Id;
        insert item;

        Test.startTest();
        List<SLO_Sellout_Item__c> revalidated = SLO_SelloutImportController.updateSelloutItems(
            new List<SLO_Sellout_Item__c>{
                new SLO_Sellout_Item__c(Id = item.Id, SLO_Product_Code_EAN__c = '123456')
            }
        );
        Test.stopTest();

        Assert.areEqual(1, revalidated.size(), 'The edited row should be returned re-validated');
        Assert.areEqual('Matched', revalidated[0].SLO_Processing_Status__c,
            'Correcting the code to a real product should make the row ready');
        Assert.areEqual(SLO_SelloutImportController.NOTE_READY,
            revalidated[0].SLO_Processing_Notes__c,
            'A ready row reads as ready rather than keeping its old error note');

        Map<String, Integer> counts =
            SLO_SelloutImportController.getItemStatusCounts(report.Id);
        Assert.areEqual(1, counts.get('Matched'),
            'The ready count should include the corrected line');
        Assert.areEqual(0, counts.get('Error'),
            'The corrected line should no longer be counted as needing a fix');
    }

    @IsTest
    static void editingNameReleasesSkippedAccountRow() {
        Account parent = makeParentAccount();
        Account child = makeChildAccount(parent.Id, 'Shop A');
        makeProduct('123456');

        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        // A line the user chose to leave out on the accounts step
        SLO_Sellout_Item__c item =
            makeItem(report.Id, 'Unknown Shop', '123456', ITEM_DATE, 5, 'Skipped');
        item.SLO_Processing_Notes__c = SLO_SelloutImportController.NOTE_ACCOUNT_DECLINED;
        insert item;

        Test.startTest();
        List<SLO_Sellout_Item__c> revalidated = SLO_SelloutImportController.updateSelloutItems(
            new List<SLO_Sellout_Item__c>{
                new SLO_Sellout_Item__c(Id = item.Id, SLO_Customer_Account_Name__c = 'Shop A')
            }
        );
        Test.stopTest();

        Assert.areEqual(1, revalidated.size(),
            'A line set aside on the accounts step should still be re-validated when edited');
        Assert.areEqual('Matched', revalidated[0].SLO_Processing_Status__c,
            'Correcting the customer name should take the line out of Skipped');
        Assert.areEqual(child.Id, revalidated[0].SLO_Matched_Account__c,
            'The line should be mapped to the account its corrected name names');

        Map<String, Integer> counts =
            SLO_SelloutImportController.getItemStatusCounts(report.Id);
        Assert.areEqual(1, counts.get('Matched'), 'The released line should count as ready');
        Assert.areEqual(0, counts.get('Skipped'), 'Nothing should remain set aside');
    }

    @IsTest
    static void editOntoSiblingDateIsNotAConflict() {
        Account parent = makeParentAccount();
        makeChildAccount(parent.Id, 'Shop A');
        makeProduct('123456');

        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c keptRow = makeItem(report.Id, 'Shop A', '123456', ITEM_DATE, 5, 'Matched');
        SLO_Sellout_Item__c editedRow =
            makeItem(report.Id, 'Shop A', '123456', ITEM_DATE.addDays(1), 7, 'Matched');
        insert new List<SLO_Sellout_Item__c>{ keptRow, editedRow };

        // Moving the second row onto the first row's date makes two orders of the same product
        // by the same customer on one day - both stay ready, the same as two lines in the file
        Test.startTest();
        List<SLO_Sellout_Item__c> revalidated = SLO_SelloutImportController.updateSelloutItems(
            new List<SLO_Sellout_Item__c>{
                new SLO_Sellout_Item__c(Id = editedRow.Id, SLO_Item_Date__c = ITEM_DATE)
            }
        );
        Test.stopTest();

        Assert.areEqual(2, revalidated.size(),
            'The edited row and its same-name sibling should both be re-validated');

        Map<Id, SLO_Sellout_Item__c> byId = new Map<Id, SLO_Sellout_Item__c>(revalidated);
        Assert.areEqual('Matched', byId.get(keptRow.Id).SLO_Processing_Status__c,
            'The earlier row keeps its place');
        Assert.areEqual('Matched', byId.get(editedRow.Id).SLO_Processing_Status__c,
            'A second order the same day within the same report is not a conflict');
    }

    @IsTest
    static void reviewPageHonoursStatusFilter() {
        Account parent = makeParentAccount();
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        insert new List<SLO_Sellout_Item__c>{
            makeItem(report.Id, 'Shop A', '123456', ITEM_DATE, 5, 'Matched'),
            makeItem(report.Id, 'Shop A', '123456', ITEM_DATE.addDays(1), 6, 'Matched'),
            makeItem(report.Id, 'Shop B', '999999', ITEM_DATE, 3, 'Error'),
            makeItem(report.Id, 'Shop C', '123456', ITEM_DATE, 2, 'Pending_Decision')
        };

        // The Ready view holds the completed, valid lines and nothing else - no error line and no
        // line awaiting an account decision reaches it
        SLO_SelloutImportController.SelloutItemPage readyOnly =
            SLO_SelloutImportController.getSelloutItemPage(report.Id, 50, 0, false, 'Ready');
        Assert.areEqual(2, readyOnly.totalCount, 'The Ready view counts only the valid lines');
        Assert.areEqual(2, readyOnly.items.size(), 'The Ready view lists only the valid lines');
        for (SLO_Sellout_Item__c row : readyOnly.items) {
            Assert.areEqual('Matched', row.SLO_Processing_Status__c,
                'The Ready view excludes errors and account decisions');
        }

        // The Needs a fix view holds the technical data errors alone
        SLO_SelloutImportController.SelloutItemPage needsFix =
            SLO_SelloutImportController.getSelloutItemPage(report.Id, 50, 0, false, 'Error');
        Assert.areEqual(1, needsFix.totalCount, 'The Needs a fix view counts only the error lines');
        Assert.areEqual('Error', needsFix.items[0].SLO_Processing_Status__c,
            'The Needs a fix view lists only the error lines');

        // The Account decision view holds the lines awaiting a decision alone
        SLO_SelloutImportController.SelloutItemPage decisions =
            SLO_SelloutImportController.getSelloutItemPage(report.Id, 50, 0, false, 'Pending_Decision');
        Assert.areEqual(1, decisions.totalCount,
            'The Account decision view counts only the lines awaiting a decision');
        Assert.areEqual('Pending_Decision', decisions.items[0].SLO_Processing_Status__c,
            'The Account decision view lists only the lines awaiting a decision');

        SLO_SelloutImportController.SelloutItemPage errorsChunk =
            SLO_SelloutImportController.getActionableItemsAfter(report.Id, null, false, 'Error');
        Assert.areEqual(1, errorsChunk.items.size(), 'Load All honours the same filter');
        Assert.areEqual('Error', errorsChunk.items[0].SLO_Processing_Status__c,
            'Load All returns only the error lines for the Needs a fix view');

        SLO_SelloutImportController.SelloutItemPage readyChunk =
            SLO_SelloutImportController.getActionableItemsAfter(report.Id, null, false, 'Ready');
        Assert.areEqual(2, readyChunk.items.size(),
            'Load All on the Ready view returns only the valid lines');
    }

    @IsTest
    static void parseCsvRowCleansHiddenSpaces() {
        // Exported files carry non-breaking spaces inside names and padding around numbers
        List<String> fields = SLO_SelloutImportController.parseCsvRow(
            'ARMBRUSTER  GRANDES CULTURES  SAS,3700249121548,  1 920 ,', ','
        );

        Assert.areEqual('ARMBRUSTER GRANDES CULTURES SAS', fields[0],
            'Non-breaking spaces become spaces and runs of spaces collapse');
        Assert.areEqual('3700249121548', fields[1]);
        Assert.areEqual('1 920', fields[2], 'Inner spacing is normalised, ends are trimmed');
        Assert.areEqual('', fields[3], 'An empty last field stays empty');
    }

    @IsTest
    static void stripBomRemovesLeadingMarkerOnlyOnce() {
        String bom = String.fromCharArray(new List<Integer>{ 65279 });

        Assert.areEqual('DATE FICHIER,EAN',
            SLO_SelloutImportController.stripBom(bom + 'DATE FICHIER,EAN'),
            'The byte order mark is removed from the start of the content');
        Assert.areEqual('DATE FICHIER,EAN',
            SLO_SelloutImportController.stripBom('DATE FICHIER,EAN'),
            'Content without a marker is unchanged');

        // The preview parser sees the same clean header the import batch will read
        String csv = bom + 'DATE FICHIER,PERIODE DE VENTES,QTY\n09/03/2026,29/04/2022,1920\n';
        SLO_SelloutImportController.ParseResult parsed = SLO_SelloutImportController.parseFile(
            EncodingUtil.base64Encode(Blob.valueOf(csv)), 'statistiques.csv', false, ','
        );
        Assert.isNull(parsed.errorMessage, 'The file should parse: ' + parsed.errorMessage);
        Assert.areEqual('DATE FICHIER', parsed.columnHeaders[0],
            'The first header is exactly what the user sees, so a saved mapping matches it');
    }

    @IsTest
    static void accountNamesMatchAcrossHiddenSpaces() {
        Account withHiddenSpaces = new Account(
            Name = 'ARMBRUSTER  GRANDES CULTURES  SAS',
            Status__c = 'Active',
            BillingCountry = 'France',
            BillingStreet = 'Rue de Test 1',
            BillingCity = 'Paris',
            BillingPostalCode = '75001'
        );
        insert withHiddenSpaces;

        Map<String, Id> nameToId = new Map<String, Id>();
        Map<String, String> nameToStatus = new Map<String, String>();
        SLO_SelloutImportController.buildAccountNameMaps(
            new List<Account>{ withHiddenSpaces }, nameToId, nameToStatus
        );

        Assert.areEqual(withHiddenSpaces.Id,
            nameToId.get(SLO_SelloutImportController.nameKey('ARMBRUSTER GRANDES CULTURES SAS')),
            'A clean file name finds an account whose name carries hidden spaces');
    }

    @IsTest
    static void importBatchFlagsRowsAsItStoresThem() {
        Account parent = makeParentAccount();
        makeProduct('123456');

        // A line recorded by an earlier report, so the new file overlaps it
        SLO_Sellout_Report__c oldReport = makeReport(parent.Id, 'Completed');
        insert makeItem(oldReport.Id, 'Shop A', '123456', ITEM_DATE, 5, 'Invoice_Created');

        SLO_Sellout_Report__c report = makeReport(parent.Id, 'New');

        SLO_SelloutImportController.ImportMappingConfig config =
            new SLO_SelloutImportController.ImportMappingConfig();
        config.itemDateIndex = 0;
        config.productCodeIndex = 1;
        config.quantityIndex = 2;
        config.customerAccountIndex = 3;
        config.csvDelimiter = ',';

        List<String> lines = new List<String>{
            '2026-01-15,123456,5,Shop A',   // exact duplicate of the recorded line -> Skipped
            '2026-01-15,999999,3,Shop A',   // unknown product code -> Error
            '2026-01-15,123456,9,Shop A',   // different quantity for a recorded line -> Error
            '2026-01-15,123456,5,Shop A',   // exact duplicate within the file -> not stored at all
            '2026-01-16,123456,4,Shop B'    // clean row -> Pending
        };

        SLO_SelloutItemImportBatch batch = new SLO_SelloutItemImportBatch(
            parent.Id, report.Id, null, config, 'en_US', true
        );

        Test.startTest();
        batch.execute(null, lines);
        batch.finish(null);
        Test.stopTest();

        List<SLO_Sellout_Item__c> stored = [
            SELECT SLO_Quantity__c, SLO_Product_Code_EAN__c, SLO_Processing_Status__c,
                   SLO_Processing_Notes__c
            FROM SLO_Sellout_Item__c
            WHERE SLO_Sellout_Report__c = :report.Id
            ORDER BY Id ASC
        ];
        Assert.areEqual(4, stored.size(), 'The in-file duplicate collapses; every other row is stored');

        Assert.areEqual('Skipped', stored[0].SLO_Processing_Status__c);
        Assert.isTrue(
            stored[0].SLO_Processing_Notes__c.startsWith(SLO_SelloutImportController.NOTE_DUPLICATE),
            'The duplicate note names the earlier report: ' + stored[0].SLO_Processing_Notes__c
        );

        Assert.areEqual('Error', stored[1].SLO_Processing_Status__c);
        Assert.areEqual(SLO_SelloutImportController.NOTE_PRODUCT_NOT_FOUND, stored[1].SLO_Processing_Notes__c);

        Assert.areEqual('Error', stored[2].SLO_Processing_Status__c);
        Assert.isTrue(
            stored[2].SLO_Processing_Notes__c.startsWith(
                SLO_SelloutImportController.NOTE_QUANTITY_CONFLICT_PREFIX + '5'
            ),
            'The conflict note should carry the recorded quantity: ' + stored[2].SLO_Processing_Notes__c
        );

        Assert.areEqual('Pending', stored[3].SLO_Processing_Status__c,
            'A clean row is left for the matching pass');

        SLO_Sellout_Report__c finished = [
            SELECT SLO_Status__c, SLO_Total_Items__c
            FROM SLO_Sellout_Report__c
            WHERE Id = :report.Id
        ];
        Assert.areEqual('Draft', finished.SLO_Status__c, 'The report pauses in Draft for review');
        Assert.areEqual(5, finished.SLO_Total_Items__c.intValue(),
            'The total counts every data row read from the file');
    }

    @IsTest
    static void bulkReassignRenamesLinesAndRevalidates() {
        Account parent = makeParentAccount();
        Account child = makeChildAccount(parent.Id, 'Agora_DM');
        makeProduct('123456');

        // A line already recorded for the target account, so a renamed line can collide with it
        SLO_Sellout_Report__c oldReport = makeReport(parent.Id, 'Completed');
        insert makeItem(oldReport.Id, 'Agora_DM', '123456', ITEM_DATE, 5, 'Invoice_Created');

        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c conflictRow =
            makeItem(report.Id, 'Agora', '123456', ITEM_DATE, 9, 'Pending_Decision');
        SLO_Sellout_Item__c cleanRow =
            makeItem(report.Id, 'Agora', '123456', ITEM_DATE.addDays(1), 4, 'Pending_Decision');
        SLO_Sellout_Item__c duplicateRow =
            makeItem(report.Id, 'Agora', '123456', ITEM_DATE, 5, 'Pending_Decision');
        insert new List<SLO_Sellout_Item__c>{ conflictRow, cleanRow, duplicateRow };

        SLO_SelloutImportController.UnmatchedDecision decision =
            new SLO_SelloutImportController.UnmatchedDecision();
        decision.customerAccountName = 'Agora';
        decision.action = 'reassign';
        decision.existingAccountId = child.Id;

        Test.startTest();
        SLO_SelloutImportController.BulkResolveResult result =
            SLO_SelloutImportController.bulkResolveUnmatched(
                report.Id,
                parent.Id,
                new List<SLO_SelloutImportController.UnmatchedDecision>{ decision },
                false
            );
        Test.stopTest();

        Assert.isTrue(result.success, 'The reassign run should succeed: ' + result.errorMessage);
        Assert.areEqual(3, result.itemsReassigned, 'Every line carrying the name is reassigned');
        Assert.areEqual(1, result.itemsMatched, 'Only the clean line stays matched');
        Assert.areEqual(1, result.itemsFlagged, 'The quantity conflict is flagged');
        Assert.isNull(result.jobId, 'The review wizard must not start invoicing');
        Assert.isNotNull(result.warningMessage, 'The flagged and duplicate lines are reported');

        Map<Id, SLO_Sellout_Item__c> byId = new Map<Id, SLO_Sellout_Item__c>([
            SELECT Id, SLO_Customer_Account_Name__c, SLO_Matched_Account__c,
                   SLO_Processing_Status__c, SLO_Processing_Notes__c
            FROM SLO_Sellout_Item__c
            WHERE SLO_Sellout_Report__c = :report.Id
        ]);

        for (SLO_Sellout_Item__c row : byId.values()) {
            Assert.areEqual('Agora_DM', row.SLO_Customer_Account_Name__c,
                'Every reassigned line carries the account\'s name');
        }

        Assert.areEqual('Error', byId.get(conflictRow.Id).SLO_Processing_Status__c,
            'Under its new name this line conflicts on quantity with the recorded line');
        Assert.isTrue(
            byId.get(conflictRow.Id).SLO_Processing_Notes__c.startsWith(
                SLO_SelloutImportController.NOTE_QUANTITY_CONFLICT_PREFIX + '5'
            ),
            'The conflict note should carry the recorded quantity: ' +
                byId.get(conflictRow.Id).SLO_Processing_Notes__c
        );

        Assert.areEqual('Matched', byId.get(cleanRow.Id).SLO_Processing_Status__c);
        Assert.areEqual(child.Id, byId.get(cleanRow.Id).SLO_Matched_Account__c);
        Assert.areEqual(SLO_SelloutImportController.NOTE_READY,
            byId.get(cleanRow.Id).SLO_Processing_Notes__c);

        Assert.areEqual('Skipped', byId.get(duplicateRow.Id).SLO_Processing_Status__c,
            'Under its new name this line duplicates the recorded line exactly');
        Assert.isTrue(
            byId.get(duplicateRow.Id).SLO_Processing_Notes__c.startsWith(
                SLO_SelloutImportController.NOTE_DUPLICATE
            ),
            'The duplicate note names the earlier report: ' +
                byId.get(duplicateRow.Id).SLO_Processing_Notes__c
        );
    }

    @IsTest
    static void hierarchyAccountOptionsExcludeInactiveAndSort() {
        Account parent = makeParentAccount();
        makeChildAccount(parent.Id, 'Beta Shop');
        makeChildAccount(parent.Id, 'Alpha Shop');
        insert new Account(
            Name = 'Gamma Shop',
            ParentId = parent.Id,
            BillingCountry = 'France',
            BillingStreet = 'Rue de Test 1',
            BillingCity = 'Paris',
            BillingPostalCode = '75001',
            Status__c = 'N'
        );

        List<SLO_SelloutImportController.PicklistOption> options =
            SLO_SelloutImportController.getHierarchyAccountOptions(parent.Id);

        Assert.areEqual(3, options.size(), 'The inactive account is left out');
        Assert.areEqual('Alpha Shop', options[0].label);
        Assert.areEqual('Beta Shop', options[1].label);
        Assert.areEqual('Parent Wholesaler', options[2].label);
    }

    @IsTest
    static void selloutAccountNamesCarryParentMarker() {
        Assert.areEqual('PAREN',
            SLO_SelloutImportController.buildParentMarker('Parent Wholesaler'),
            'The marker is the first alphanumeric characters of the parent name, uppercased');
        Assert.areEqual('',
            SLO_SelloutImportController.buildParentMarker('  '),
            'A blank parent name yields no marker');

        Assert.areEqual('Agora_Sellout_PAREN',
            SLO_SelloutImportController.buildSelloutAccountName('Agora', 'Parent Wholesaler'),
            'Created names carry the suffix and the parent marker');
        Assert.areEqual('Agora_Sellout',
            SLO_SelloutImportController.buildSelloutAccountName('Agora', null),
            'Without a parent the plain legacy suffix is used');

        Assert.areEqual('Agora_Sellout',
            SLO_SelloutImportController.buildSelloutAccountName('Agora_Sellout', 'Parent Wholesaler'),
            'A name already carrying the legacy suffix is never suffixed again');
        Assert.areEqual('Agora_Sellout_XYZ',
            SLO_SelloutImportController.buildSelloutAccountName('Agora_Sellout_XYZ', 'Parent Wholesaler'),
            'A name already carrying the marked suffix is never suffixed again');

        String longName = 'A'.repeat(300);
        String built = SLO_SelloutImportController.buildSelloutAccountName(longName, 'Parent Wholesaler');
        Assert.isTrue(built.length() <= 255, 'The built name must fit Account.Name');
        Assert.isTrue(built.endsWith('_Sellout_PAREN'),
            'The customer part is truncated, never the suffix: ' + built);
    }

    @IsTest
    static void accountNameMapsMatchBothSuffixGenerations() {
        Account exactName = new Account(Name = 'Agora', Status__c = 'Active', BillingCountry = 'France', BillingStreet = 'Rue de Test 1', BillingCity = 'Paris', BillingPostalCode = '75001');
        Account legacySuffix = new Account(Name = 'Agora_Sellout', Status__c = 'Active', BillingCountry = 'France', BillingStreet = 'Rue de Test 1', BillingCity = 'Paris', BillingPostalCode = '75001');
        Account markedSuffix = new Account(Name = 'Copa_Sellout_PAREN', Status__c = 'Active', BillingCountry = 'France', BillingStreet = 'Rue de Test 1', BillingCity = 'Paris', BillingPostalCode = '75001');
        Account legacyMetro = new Account(Name = 'Metro_Sellout', Status__c = 'Active', BillingCountry = 'France', BillingStreet = 'Rue de Test 1', BillingCity = 'Paris', BillingPostalCode = '75001');
        insert new List<Account>{ exactName, legacySuffix, markedSuffix, legacyMetro };

        Map<String, Id> nameToId = new Map<String, Id>();
        Map<String, String> nameToStatus = new Map<String, String>();
        SLO_SelloutImportController.buildAccountNameMaps(
            new List<Account>{ exactName, legacySuffix, markedSuffix, legacyMetro },
            nameToId,
            nameToStatus
        );

        Assert.areEqual(exactName.Id, nameToId.get('agora'),
            'An account genuinely carrying the name always beats the suffixed variant');
        Assert.areEqual(legacySuffix.Id, nameToId.get('agora_sellout'),
            'The suffixed account still answers to its own full name');
        Assert.areEqual(markedSuffix.Id, nameToId.get('copa'),
            'The marked suffix strips back to the customer name');
        Assert.areEqual(legacyMetro.Id, nameToId.get('metro'),
            'The legacy suffix keeps stripping back to the customer name');
    }

    @IsTest
    static void createDecisionUsesMarkedAccountName() {
        Account parent = makeParentAccount();
        makeProduct('123456');

        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c item =
            makeItem(report.Id, 'NewShop', '123456', ITEM_DATE, 5, 'Pending_Decision');
        insert item;

        SLO_SelloutImportController.UnmatchedDecision decision =
            new SLO_SelloutImportController.UnmatchedDecision();
        decision.customerAccountName = 'NewShop';
        decision.action = 'create';

        Test.startTest();
        SLO_SelloutImportController.BulkResolveResult result =
            SLO_SelloutImportController.bulkResolveUnmatched(
                report.Id,
                parent.Id,
                new List<SLO_SelloutImportController.UnmatchedDecision>{ decision },
                false
            );
        Test.stopTest();

        Assert.isTrue(result.success, 'The create run should succeed: ' + result.errorMessage);
        Assert.areEqual(1, result.accountsCreated);

        List<Account> created = [
            SELECT Id, Name, ParentId, Status__c
            FROM Account
            WHERE Name = 'NewShop_Sellout_PAREN'
        ];
        Assert.areEqual(1, created.size(),
            'The created account carries the sellout suffix and the parent marker');
        Assert.areEqual(parent.Id, created[0].ParentId);
        Assert.areEqual('Active', created[0].Status__c);

        SLO_Sellout_Item__c resolved = [
            SELECT SLO_Matched_Account__c, SLO_Processing_Status__c
            FROM SLO_Sellout_Item__c
            WHERE Id = :item.Id
        ];
        Assert.areEqual('Matched', resolved.SLO_Processing_Status__c);
        Assert.areEqual(created[0].Id, resolved.SLO_Matched_Account__c);
    }

    @IsTest
    static void abandonedUploadsDoNotBlockReimport() {
        Account parent = makeParentAccount();
        makeProduct('123456');

        // An earlier upload that never got processed: an errored row, an undecided row, and one
        // row that genuinely was accepted for invoicing
        SLO_Sellout_Report__c abandoned = makeReport(parent.Id, 'Draft');
        insert new List<SLO_Sellout_Item__c>{
            makeItem(abandoned.Id, 'Shop A', '123456', ITEM_DATE, 5, 'Error'),
            makeItem(abandoned.Id, 'Shop B', '123456', ITEM_DATE, 3, 'Pending_Decision'),
            makeItem(abandoned.Id, 'Shop C', '123456', ITEM_DATE, 7, 'Invoice_Created')
        };

        SLO_Sellout_Report__c report = makeReport(parent.Id, 'New');
        SLO_Sellout_Item__c sameAsErrored =
            makeItem(report.Id, 'Shop A', '123456', ITEM_DATE, 5, 'Pending');
        SLO_Sellout_Item__c sameAsUndecided =
            makeItem(report.Id, 'Shop B', '123456', ITEM_DATE, 3, 'Pending');
        SLO_Sellout_Item__c sameAsRecorded =
            makeItem(report.Id, 'Shop C', '123456', ITEM_DATE, 7, 'Pending');
        SLO_Sellout_Item__c conflictsWithRecorded =
            makeItem(report.Id, 'Shop C', '123456', ITEM_DATE, 9, 'Pending');

        SLO_SelloutImportController.validateItemsForAccount(
            new List<SLO_Sellout_Item__c>{
                sameAsErrored, sameAsUndecided, sameAsRecorded, conflictsWithRecorded
            },
            parent.Id,
            null
        );

        Assert.areEqual('Pending', sameAsErrored.SLO_Processing_Status__c,
            'An errored row of an abandoned upload was never recorded and must not block');
        Assert.areEqual('Pending', sameAsUndecided.SLO_Processing_Status__c,
            'An undecided row of an abandoned upload was never recorded and must not block');
        Assert.areEqual('Skipped', sameAsRecorded.SLO_Processing_Status__c,
            'A row genuinely accepted for invoicing still counts as recorded');
        Assert.areEqual('Error', conflictsWithRecorded.SLO_Processing_Status__c,
            'A different quantity against a genuinely recorded row is still a conflict');
    }

    @IsTest
    static void unmatchedAccountsComputedFromLiveMatching() {
        Account parent = makeParentAccount();
        Account activeChild = makeChildAccount(parent.Id, 'Shop A');
        Account inactiveChild = new Account(
            Name = 'Old Shop',
            ParentId = parent.Id,
            BillingCountry = 'France',
            BillingStreet = 'Rue de Test 1',
            BillingCity = 'Paris',
            BillingPostalCode = '75001',
            Status__c = 'N'
        );
        insert inactiveChild;

        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c erroredNewName =
            makeItem(report.Id, 'NewShop', '999999', ITEM_DATE, 5, 'Error');
        erroredNewName.SLO_Processing_Notes__c = SLO_SelloutImportController.NOTE_PRODUCT_NOT_FOUND;
        insert new List<SLO_Sellout_Item__c>{
            erroredNewName,
            // Matched rows are settled and never appear on the accounts step
            makeItem(report.Id, 'Shop A', '123456', ITEM_DATE, 4, 'Matched'),
            // A pending row whose name an active account answers to needs no decision
            makeItem(report.Id, 'Shop A', '123456', ITEM_DATE.addDays(1), 2, 'Pending'),
            makeItem(report.Id, 'Old Shop', '123456', ITEM_DATE, 3, 'Pending_Decision')
        };

        List<SLO_SelloutImportController.AccountMatchResult> unmatched =
            SLO_SelloutImportController.getUnmatchedAccounts(report.Id);

        Assert.areEqual(2, unmatched.size(),
            'Only the unresolved names are listed, whatever status their rows carry');
        Assert.areEqual('NewShop', unmatched[0].customerAccountName,
            'An errored row still needs its account resolved');
        Assert.isFalse(unmatched[0].isInactive);
        Assert.areEqual('Old Shop', unmatched[1].customerAccountName);
        Assert.isTrue(unmatched[1].isInactive, 'A name matching an inactive account offers Activate');
        Assert.areEqual(inactiveChild.Id, unmatched[1].accountId);
        Assert.isNotNull(activeChild.Id);
    }

    @IsTest
    static void createDecisionKeepsProductErrorVisible() {
        Account parent = makeParentAccount();
        // No product exists for this code, so the row's product error must survive the decision

        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c item =
            makeItem(report.Id, 'NewShop', '999999', ITEM_DATE, 5, 'Error');
        item.SLO_Processing_Notes__c = SLO_SelloutImportController.NOTE_PRODUCT_NOT_FOUND;
        insert item;

        SLO_SelloutImportController.UnmatchedDecision decision =
            new SLO_SelloutImportController.UnmatchedDecision();
        decision.customerAccountName = 'NewShop';
        decision.action = 'create';

        Test.startTest();
        SLO_SelloutImportController.BulkResolveResult result =
            SLO_SelloutImportController.bulkResolveUnmatched(
                report.Id,
                parent.Id,
                new List<SLO_SelloutImportController.UnmatchedDecision>{ decision },
                false
            );
        Test.stopTest();

        Assert.isTrue(result.success, 'The decision should apply: ' + result.errorMessage);
        Assert.areEqual(1, result.accountsCreated, 'The account is still created');
        Assert.areEqual(0, result.itemsMatched, 'A row with a bad product is not ready');
        Assert.areEqual(1, result.itemsFlagged, 'The product error is re-flagged after the decision');

        SLO_Sellout_Item__c after = [
            SELECT SLO_Matched_Account__c, SLO_Processing_Status__c, SLO_Processing_Notes__c
            FROM SLO_Sellout_Item__c
            WHERE Id = :item.Id
        ];
        Assert.areEqual('Error', after.SLO_Processing_Status__c,
            'The decision resolves the account, not the data');
        Assert.areEqual(SLO_SelloutImportController.NOTE_PRODUCT_NOT_FOUND, after.SLO_Processing_Notes__c);
        Assert.isNotNull(after.SLO_Matched_Account__c,
            'The created account is remembered on the row for when the product is fixed');
    }

    @IsTest
    static void secondUploadForSameDateWarns() {
        Account parent = makeParentAccount();

        ContentVersion csvFile = new ContentVersion(
            Title = 'sellout.csv',
            PathOnClient = 'sellout.csv',
            VersionData = Blob.valueOf('Date,Code,Qty,Customer\n2026-01-15,123456,5,Shop A')
        );
        insert csvFile;

        SLO_SelloutImportController.ImportMappingConfig config =
            new SLO_SelloutImportController.ImportMappingConfig();
        config.itemDateIndex = 0;
        config.productCodeIndex = 1;
        config.quantityIndex = 2;
        config.customerAccountIndex = 3;
        config.csvDelimiter = ',';

        Test.startTest();
        SLO_SelloutImportController.AsyncStartResult first =
            SLO_SelloutImportController.startAsyncImport(
                parent.Id, '2026-01-31', csvFile.Id, config
            );
        SLO_SelloutImportController.AsyncStartResult second =
            SLO_SelloutImportController.startAsyncImport(
                parent.Id, '2026-01-31', csvFile.Id, config
            );
        Test.stopTest();

        Assert.isTrue(first.success, 'The first upload should start: ' + first.errorMessage);
        Assert.isNull(first.warningMessage, 'Nothing overlaps the first upload');
        Assert.isTrue(second.success, 'The second upload still starts - overlap is not a block');
        Assert.isNotNull(second.warningMessage,
            'The second upload warns that an earlier report exists for the same date');
    }

    @IsTest
    static void enforceSkipTouchesOnlyErrorLines() {
        Account parent = makeParentAccount();
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c errorRow = makeItem(report.Id, 'Shop A', '999999', ITEM_DATE, 3, 'Error');
        SLO_Sellout_Item__c readyRow = makeItem(report.Id, 'Shop A', '123456', ITEM_DATE, 3, 'Pending');
        insert new List<SLO_Sellout_Item__c>{ errorRow, readyRow };

        Test.startTest();
        Integer skipped = SLO_SelloutImportController.enforceSkipItems(
            new List<String>{ errorRow.Id, readyRow.Id }
        );
        Test.stopTest();

        Assert.areEqual(1, skipped, 'Only the line in error is set aside');
        Assert.areEqual('Enforced_Skipped',
            [SELECT SLO_Processing_Status__c FROM SLO_Sellout_Item__c WHERE Id = :errorRow.Id].SLO_Processing_Status__c);
        Assert.areEqual('Pending',
            [SELECT SLO_Processing_Status__c FROM SLO_Sellout_Item__c WHERE Id = :readyRow.Id].SLO_Processing_Status__c);
        Assert.areEqual(1, SLO_SelloutImportController.getItemStatusCounts(report.Id).get('Enforced_Skipped'));
    }

    @IsTest
    static void uncorrectedSweepWritesEnforcedSkipped() {
        Account parent = makeParentAccount();
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        insert makeItem(report.Id, 'Shop A', '999999', ITEM_DATE, 3, 'Error');

        Test.startTest();
        SLO_SelloutImportController.skipUncorrectedErrorItems(report.Id);
        Test.stopTest();

        Assert.areEqual('Enforced_Skipped',
            [SELECT SLO_Processing_Status__c FROM SLO_Sellout_Item__c WHERE SLO_Sellout_Report__c = :report.Id].SLO_Processing_Status__c);
    }

    @IsTest
    static void startMarksReportInProcess() {
        Account parent = makeParentAccount();
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');

        Test.startTest();
        new SLO_SelloutApplyBatch(report.Id, parent.Id, SLO_SelloutApplyBatch.MODE_MATCH).start(null);
        Test.stopTest();

        Assert.areEqual('In_Process',
            [SELECT SLO_Status__c FROM SLO_Sellout_Report__c WHERE Id = :report.Id].SLO_Status__c,
            'start() marks the report busy so the screen will not open it mid-run');
    }

    @IsTest
    static void chainEndWithPendingDecisionsReleasesInProcessToDraft() {
        Account parent = makeParentAccount();
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        // No account by this name exists, so the row waits for a decision and the match link ends
        // the chain without setting a status itself
        insert makeItem(report.Id, 'Nobody Known', '123456', ITEM_DATE, 3, 'Pending');

        Test.startTest();
        Database.executeBatch(
            new SLO_SelloutApplyBatch(report.Id, parent.Id, SLO_SelloutApplyBatch.MODE_MATCH), 200
        );
        Test.stopTest();

        Assert.areEqual('Pending_Decision',
            [SELECT SLO_Processing_Status__c FROM SLO_Sellout_Item__c WHERE SLO_Sellout_Report__c = :report.Id]
                .SLO_Processing_Status__c);
        Assert.areEqual('Draft',
            [SELECT SLO_Status__c FROM SLO_Sellout_Report__c WHERE Id = :report.Id].SLO_Status__c,
            'The chain ends with the report released from In Process');
    }

    @IsTest
    static void chainEndKeepsCompletedStatusUntouched() {
        Account parent = makeParentAccount();
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Completed');

        Test.startTest();
        new SLO_SelloutApplyBatch(report.Id, parent.Id, SLO_SelloutApplyBatch.MODE_INVOICE).finish(null);
        Test.stopTest();

        Assert.areEqual('Completed',
            [SELECT SLO_Status__c FROM SLO_Sellout_Report__c WHERE Id = :report.Id].SLO_Status__c,
            'Only an In Process report is released; a final status is left alone');
    }

    @IsTest
    static void deleteGuardRejectsInProcessReport() {
        Account parent = makeParentAccount();
        SLO_Sellout_Report__c idle = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Report__c busy = makeReport(parent.Id, 'In_Process');

        Test.startTest();
        // The same caller can delete an idle report, so the refusal below is down to the status
        Assert.isTrue(SLO_SelloutImportController.deleteSelloutReport(idle.Id).finished,
            'A Draft report is deleted');
        Boolean refused = false;
        try {
            SLO_SelloutImportController.deleteSelloutReport(busy.Id);
        } catch (AuraHandledException e) {
            refused = true;
        }
        Test.stopTest();

        Assert.isTrue(refused, 'The delete is refused');
        Assert.areEqual(1, [SELECT COUNT() FROM SLO_Sellout_Report__c WHERE Id = :busy.Id],
            'An In Process report is never deleted');
    }

    @IsTest
    static void staleInProcessIsStuckAndReconcileReleasesIt() {
        Account parent = makeParentAccount();
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'In_Process');

        Test.startTest();
        SLO_SelloutImportController.ReportStatus before = SLO_SelloutImportController.getReportStatus(report.Id);
        SLO_SelloutImportController.ReportStatus after = SLO_SelloutImportController.reconcileReportStatus(report.Id);
        Test.stopTest();

        Assert.isTrue(before.isStuck, 'In Process with no job running is stuck');
        Assert.areEqual('Draft', after.status, 'Check Status releases a stale In Process report');
    }

    @IsTest
    static void importBatchDropsRowsBeforeStartDate() {
        Account parent = makeParentAccount();
        makeProduct('123456');
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'New');

        SLO_SelloutImportController.ImportMappingConfig config =
            new SLO_SelloutImportController.ImportMappingConfig();
        config.itemDateIndex = 0;
        config.productCodeIndex = 1;
        config.quantityIndex = 2;
        config.customerAccountIndex = 3;
        config.csvDelimiter = ',';
        config.startDate = Date.newInstance(2026, 1, 1);

        SLO_SelloutItemImportBatch batch = new SLO_SelloutItemImportBatch(
            parent.Id, report.Id, null, config, 'en_US', true
        );

        Test.startTest();
        batch.execute(null, new List<String>{
            '2022-06-01,123456,5,Shop A',   // before the start date -> ignored
            '2022-06-02,123456,abc,Shop A', // before the start date with a bad quantity -> ignored, not an error
            '2026-01-01,123456,3,Shop B',   // exactly the start date -> kept
            '2026-01-15,123456,4,Shop A'    // kept
        });
        batch.finish(null);
        Test.stopTest();

        Assert.areEqual(2, [SELECT COUNT() FROM SLO_Sellout_Item__c WHERE SLO_Sellout_Report__c = :report.Id]);
        Assert.areEqual(2,
            [SELECT SLO_Total_Items__c FROM SLO_Sellout_Report__c WHERE Id = :report.Id].SLO_Total_Items__c.intValue(),
            'Ignored rows are not part of the report total');
    }

    @IsTest
    static void importBatchKeepsEveryRowWithoutStartDate() {
        Account parent = makeParentAccount();
        makeProduct('123456');
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'New');

        SLO_SelloutImportController.ImportMappingConfig config =
            new SLO_SelloutImportController.ImportMappingConfig();
        config.itemDateIndex = 0;
        config.productCodeIndex = 1;
        config.quantityIndex = 2;
        config.customerAccountIndex = 3;
        config.csvDelimiter = ',';
        config.startDate = null;

        SLO_SelloutItemImportBatch batch = new SLO_SelloutItemImportBatch(
            parent.Id, report.Id, null, config, 'en_US', true
        );

        Test.startTest();
        batch.execute(null, new List<String>{
            '2022-06-01,123456,5,Shop A',
            '2026-01-15,123456,4,Shop A'
        });
        batch.finish(null);
        Test.stopTest();

        Assert.areEqual(2, [SELECT COUNT() FROM SLO_Sellout_Item__c WHERE SLO_Sellout_Report__c = :report.Id],
            'A null start date keeps every row');
    }

    @IsTest
    static void importPreferencesDefaultThenSave() {
        SLO_SelloutImportController.ImportPreferences defaults = SLO_SelloutImportController.getImportPreferences();
        Assert.areEqual(Date.newInstance(2026, 1, 1), defaults.startDate);
        Assert.areEqual(',', defaults.csvDelimiter);

        Test.startTest();
        SLO_SelloutImportController.saveImportPreferences(Date.newInstance(2026, 3, 1), ';');
        Test.stopTest();

        SLO_SelloutImportController.ImportPreferences saved = SLO_SelloutImportController.getImportPreferences();
        Assert.areEqual(Date.newInstance(2026, 3, 1), saved.startDate);
        Assert.areEqual(';', saved.csvDelimiter);
    }

    @IsTest
    static void autoAcceptSkipsErrorsAndCreatesAccounts() {
        if (!selloutTypeActive()) {
            return;
        }
        Account parent = makeParentAccount();
        makeProduct('123456');
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c newCustomer = makeItem(report.Id, 'Brand New Shop', '123456', ITEM_DATE, 3, 'Pending');
        SLO_Sellout_Item__c needsFix = makeItem(report.Id, 'Brand New Shop', '999999', ITEM_DATE, 2, 'Error');
        insert new List<SLO_Sellout_Item__c>{ newCustomer, needsFix };

        SLO_SelloutApplyBatch.RunContext context = new SLO_SelloutApplyBatch.RunContext();
        context.autoAccept = true;

        Test.startTest();
        Database.executeBatch(
            new SLO_SelloutApplyBatch(report.Id, parent.Id, SLO_SelloutApplyBatch.MODE_MATCH, context), 200
        );
        Test.stopTest();

        Assert.isFalse(String.valueOf(SLO_SelloutApplyBatch.lastSummarySubject).contains('needs your decision'),
            'Decisions were applied, so the summary must not ask for one: ' + SLO_SelloutApplyBatch.lastSummarySubject);

        SLO_Sellout_Item__c fixedRow = [
            SELECT SLO_Processing_Status__c FROM SLO_Sellout_Item__c WHERE Id = :needsFix.Id
        ];
        Assert.areEqual('Enforced_Skipped', fixedRow.SLO_Processing_Status__c,
            'Auto Accept sets lines needing a fix aside');

        SLO_Sellout_Item__c acceptedRow = [
            SELECT SLO_Processing_Status__c, SLO_Matched_Account__c FROM SLO_Sellout_Item__c WHERE Id = :newCustomer.Id
        ];
        Assert.isNotNull(acceptedRow.SLO_Matched_Account__c, 'Auto Accept creates the missing account');
        Assert.areEqual('Invoice_Created', acceptedRow.SLO_Processing_Status__c,
            'The decision job runs on into invoicing');
        Assert.areNotEqual('In_Process',
            [SELECT SLO_Status__c FROM SLO_Sellout_Report__c WHERE Id = :report.Id].SLO_Status__c,
            'The finished chain releases the report from In Process');
    }

    @IsTest
    static void withoutAutoAcceptLinesNeedingAFixAreKept() {
        Account parent = makeParentAccount();
        makeProduct('123456');
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c newCustomer = makeItem(report.Id, 'Brand New Shop', '123456', ITEM_DATE, 3, 'Pending');
        SLO_Sellout_Item__c needsFix = makeItem(report.Id, 'Brand New Shop', '999999', ITEM_DATE, 2, 'Error');
        insert new List<SLO_Sellout_Item__c>{ newCustomer, needsFix };

        SLO_SelloutApplyBatch.RunContext context = new SLO_SelloutApplyBatch.RunContext();
        context.autoAccept = false;

        Test.startTest();
        Database.executeBatch(
            new SLO_SelloutApplyBatch(report.Id, parent.Id, SLO_SelloutApplyBatch.MODE_MATCH, context), 200
        );
        Test.stopTest();

        Assert.areEqual('Error',
            [SELECT SLO_Processing_Status__c FROM SLO_Sellout_Item__c WHERE Id = :needsFix.Id].SLO_Processing_Status__c,
            'Without Auto Accept the line needing a fix is not set aside');
        Assert.areEqual('Draft',
            [SELECT SLO_Status__c FROM SLO_Sellout_Report__c WHERE Id = :report.Id].SLO_Status__c,
            'Without Auto Accept the report waits in Draft, released from In Process');
        Assert.areNotEqual('Invoice_Created',
            [SELECT SLO_Processing_Status__c FROM SLO_Sellout_Item__c WHERE Id = :newCustomer.Id].SLO_Processing_Status__c,
            'Without Auto Accept nothing is invoiced');
    }

    @IsTest
    static void autoAcceptInvoicesMatchedRowsWhenNoDecisionsAreNeeded() {
        if (!selloutTypeActive()) {
            return;
        }
        Account parent = makeParentAccount();
        makeChildAccount(parent.Id, 'Known Shop');
        makeProduct('123456');
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'Draft');
        SLO_Sellout_Item__c known = makeItem(report.Id, 'Known Shop', '123456', ITEM_DATE, 3, 'Pending');
        insert known;

        SLO_SelloutApplyBatch.RunContext context = new SLO_SelloutApplyBatch.RunContext();
        context.autoAccept = true;

        Test.startTest();
        Database.executeBatch(
            new SLO_SelloutApplyBatch(report.Id, parent.Id, SLO_SelloutApplyBatch.MODE_MATCH, context), 200
        );
        Test.stopTest();

        Assert.areEqual('Invoice_Created',
            [SELECT SLO_Processing_Status__c FROM SLO_Sellout_Item__c WHERE Id = :known.Id].SLO_Processing_Status__c,
            'Matched rows are invoiced even though no account decision was needed');
        Assert.areNotEqual('In_Process',
            [SELECT SLO_Status__c FROM SLO_Sellout_Report__c WHERE Id = :report.Id].SLO_Status__c,
            'The report is released from In Process');
    }

    @IsTest
    static void autoAcceptImportWithNoRowsReleasesReport() {
        Account parent = makeParentAccount();
        SLO_Sellout_Report__c report = makeReport(parent.Id, 'In_Process');

        SLO_SelloutImportController.ImportMappingConfig config =
            new SLO_SelloutImportController.ImportMappingConfig();
        config.itemDateIndex = 0;
        config.productCodeIndex = 1;
        config.quantityIndex = 2;
        config.customerAccountIndex = 3;
        config.csvDelimiter = ',';
        config.autoAccept = true;

        SLO_SelloutItemImportBatch batch = new SLO_SelloutItemImportBatch(
            parent.Id, report.Id, null, config, 'en_US', true
        );

        Test.startTest();
        batch.finish(null);
        Test.stopTest();

        Assert.areNotEqual('In_Process',
            [SELECT SLO_Status__c FROM SLO_Sellout_Report__c WHERE Id = :report.Id].SLO_Status__c,
            'An empty Auto Accept import leaves the report openable');
    }
}
