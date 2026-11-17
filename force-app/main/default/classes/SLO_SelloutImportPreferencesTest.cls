/**
 * @description Tests for remembering each user's sellout import settings
 * (SLO_SelloutImportController.getImportSettings / saveImportSettings)
 */
@IsTest
private class SLO_SelloutImportPreferencesTest {

    private static final String MAPPING =
        '{"itemDate":"PERIODE DE VENTES jj/mm/aa","productCode":"EAN PRODUIT",'
        + '"quantity":"QTY FACTUREE","customerAccountName":"NOM CLIENT"}';

    // A distributor with a usage company and an active price book offered for it
    private static Account makeDistributor(String name) {
        Account acc = new Account(
            Name = name,
            BillingCountry = 'France',
            BillingStreet = 'Rue de Test 1',
            BillingCity = 'Paris',
            BillingPostalCode = '75001',
            Status__c = 'N',
            Account_Usage_Company__c =
                Account.Account_Usage_Company__c.getDescribe().getPicklistValues()[0].getValue()
        );
        insert acc;
        return [SELECT Id, Account_Usage_Company__c FROM Account WHERE Id = :acc.Id];
    }

    private static Pricebook2 makePriceBook(String name, String usageCompany, Boolean active) {
        Pricebook2 pb = new Pricebook2(Name = name, IsActive = active, Usage_Company__c = usageCompany);
        insert pb;
        return pb;
    }

    @IsTest
    static void userWithNothingSavedGetsTodaysDefaults() {
        Account distributor = makeDistributor('Distributor A');

        Test.startTest();
        SLO_SelloutImportController.ImportPreferences prefs =
            SLO_SelloutImportController.getImportSettings(distributor.Id);
        Test.stopTest();

        Assert.areEqual('Customer_Price_List', prefs.priceMethod);
        Assert.isNull(prefs.priceBookId);
        Assert.isFalse(prefs.autoAccept);
        Assert.isTrue(prefs.skipDuplicates);
        Assert.isNull(prefs.columnMapping);
        Assert.areEqual(Date.newInstance(2026, 1, 1), prefs.startDate);
    }

    @IsTest
    static void savedSettingsArePreFilledOnAnotherAccount() {
        Account dha = makeDistributor('Distributor DHA');
        Account inoxa = makeDistributor('Distributor INOXA');
        Pricebook2 book = makePriceBook('Test Actura Book', dha.Account_Usage_Company__c, true);

        Test.startTest();
        SLO_SelloutImportController.saveImportSettings(
            Date.newInstance(2026, 3, 1), ';', MAPPING, 'Dedicated_Price_Book', book.Id, true, false
        );
        SLO_SelloutImportController.ImportPreferences prefs =
            SLO_SelloutImportController.getImportSettings(inoxa.Id);
        Test.stopTest();

        Assert.areEqual(Date.newInstance(2026, 3, 1), prefs.startDate);
        Assert.areEqual('Dedicated_Price_Book', prefs.priceMethod);
        Assert.areEqual(String.valueOf(book.Id), prefs.priceBookId);
        Assert.isTrue(prefs.autoAccept);
        Assert.isFalse(prefs.skipDuplicates);
        Assert.areEqual(MAPPING, prefs.columnMapping);
        SLO_Import_Preferences__c stored = SLO_Import_Preferences__c.getValues(UserInfo.getUserId());
        Assert.areEqual(';', stored.SLO_CSV_Delimiter__c);
    }

    @IsTest
    static void inactivePriceBookIsLeftEmptyAndMethodKept() {
        Account dha = makeDistributor('Distributor DHA');
        Pricebook2 book = makePriceBook('Test Actura Book', dha.Account_Usage_Company__c, true);
        SLO_SelloutImportController.saveImportSettings(
            null, ',', MAPPING, 'Dedicated_Price_Book', book.Id, false, true
        );
        book.IsActive = false;
        update book;

        Test.startTest();
        SLO_SelloutImportController.ImportPreferences prefs =
            SLO_SelloutImportController.getImportSettings(dha.Id);
        Test.stopTest();

        Assert.areEqual('Dedicated_Price_Book', prefs.priceMethod, 'The saved price method is kept');
        Assert.isNull(prefs.priceBookId, 'An inactive price book is not pre-filled');
    }

    @IsTest
    static void priceBookNotOfferedForTheAccountIsLeftEmpty() {
        Pricebook2 other = makePriceBook('Other Country Book', 'XX', true);
        // Org automation may stamp a new price book's usage company; put the account in a different
        // usage company so this active book is not offered for it
        String bookCompany = [SELECT Usage_Company__c FROM Pricebook2 WHERE Id = :other.Id].Usage_Company__c;
        Account dha = makeDistributor('Distributor DHA');
        for (Schema.PicklistEntry entry : Account.Account_Usage_Company__c.getDescribe().getPicklistValues()) {
            String value = entry.getValue();
            if (entry.isActive() && String.isNotBlank(bookCompany) && !bookCompany.containsIgnoreCase(value)) {
                dha.Account_Usage_Company__c = value;
                break;
            }
        }
        update dha;
        String accountCompany = [SELECT Account_Usage_Company__c FROM Account WHERE Id = :dha.Id].Account_Usage_Company__c;
        if (String.isBlank(accountCompany) || String.isBlank(bookCompany) || bookCompany.containsIgnoreCase(accountCompany)) {
            return; // No usage company that keeps the book out of the offered list in this org
        }
        SLO_SelloutImportController.saveImportSettings(
            null, ',', MAPPING, 'Dedicated_Price_Book', other.Id, false, true
        );

        Test.startTest();
        SLO_SelloutImportController.ImportPreferences prefs =
            SLO_SelloutImportController.getImportSettings(dha.Id);
        Test.stopTest();

        Assert.areEqual('Dedicated_Price_Book', prefs.priceMethod);
        Assert.isNull(prefs.priceBookId);
    }

    @IsTest
    static void mappingTooLongKeepsThePreviousOne() {
        Account dha = makeDistributor('Distributor DHA');
        SLO_SelloutImportController.saveImportSettings(
            null, ',', MAPPING, 'Customer_Price_List', null, false, true
        );
        String tooLong = '{"itemDate":"' + 'X'.repeat(SLO_SelloutImportController.MAX_SAVED_MAPPING_LENGTH) + '"}';

        Test.startTest();
        SLO_SelloutImportController.saveImportSettings(
            null, ',', tooLong, 'Customer_Price_List', null, false, true
        );
        Test.stopTest();

        Assert.areEqual(MAPPING, SLO_SelloutImportController.getImportSettings(dha.Id).columnMapping);
    }

    @IsTest
    static void unknownMethodFallsBackAndBookIsOnlyKeptForDedicated() {
        Account dha = makeDistributor('Distributor DHA');
        Pricebook2 book = makePriceBook('Test Actura Book', dha.Account_Usage_Company__c, true);

        Test.startTest();
        SLO_SelloutImportController.saveImportSettings(null, ',', null, 'Last_Item_Price', book.Id, false, true);
        SLO_Import_Preferences__c afterLastItem = SLO_Import_Preferences__c.getValues(UserInfo.getUserId());
        SLO_SelloutImportController.saveImportSettings(null, ',', null, 'Not_A_Method', null, false, true);
        SLO_Import_Preferences__c afterUnknown = SLO_Import_Preferences__c.getValues(UserInfo.getUserId());
        Test.stopTest();

        Assert.areEqual('Last_Item_Price', afterLastItem.SLO_Price_Method__c);
        Assert.isNull(afterLastItem.SLO_Price_Book_Id__c, 'A price book is only kept for Dedicated Price Book');
        Assert.areEqual('Customer_Price_List', afterUnknown.SLO_Price_Method__c);
    }

    @IsTest
    static void oneUsersSettingsDoNotAffectAnother() {
        Account dha = makeDistributor('Distributor DHA');
        SLO_SelloutImportController.saveImportSettings(
            null, ';', MAPPING, 'Last_Item_Price', null, true, false
        );
        User other = [
            SELECT Id FROM User
            WHERE IsActive = true AND Id != :UserInfo.getUserId() AND Profile.Name = 'System Administrator'
            LIMIT 1
        ];

        SLO_SelloutImportController.ImportPreferences prefs;
        Test.startTest();
        System.runAs(other) {
            prefs = SLO_SelloutImportController.getImportSettings(dha.Id);
        }
        Test.stopTest();

        Assert.areEqual('Customer_Price_List', prefs.priceMethod);
        Assert.isFalse(prefs.autoAccept);
        Assert.isTrue(prefs.skipDuplicates);
        Assert.isNull(prefs.columnMapping);
    }
}
