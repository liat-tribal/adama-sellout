/**
 * @description Handles account matching logic for sellout items with case-insensitive comparison,
 * whitespace trimming, and account hierarchy traversal (main, child, grandchild accounts)
 */
public with sharing class SLO_SelloutAccountMatcher {

    /**
     * @description Wrapper class for account matching result
     */
    public class MatchResult {
        @AuraEnabled public String accountId { get; set; }
        @AuraEnabled public String matchType { get; set; } // 'main', 'child', 'grandchild', 'none'
        @AuraEnabled public String accountName { get; set; }

        public MatchResult() {
            this.accountId = null;
            this.matchType = 'none';
            this.accountName = null;
        }
    }

    /**
     * @description Match customer account name to existing accounts in hierarchy using case-insensitive comparison.
     * Matching is restricted to the main account, its children and its grandchildren - there is no
     * org-wide name lookup, so a same-named account under another parent is never matched.
     * @param mainAccountId The ID of the main account (current account record)
     * @param customerAccountName The customer account name from the sellout item
     * @return MatchResult containing matched account ID, match type, and account name
     */
    @AuraEnabled(cacheable=false)
    public static MatchResult matchAccount(String mainAccountId, String customerAccountName) {
        MatchResult result = new MatchResult();

        // Validate inputs
        if (String.isBlank(mainAccountId) || String.isBlank(customerAccountName)) {
            return result;
        }

        // Trim and normalize the customer account name for comparison
        String normalizedCustomerName = customerAccountName.trim();

        // Step 1: Check main account match
        List<Account> mainAccounts = [
            SELECT Id, Name
            FROM Account
            WHERE Id = :mainAccountId
            LIMIT 1
        ];

        if (!mainAccounts.isEmpty() &&
            mainAccounts[0].Name.trim().equalsIgnoreCase(normalizedCustomerName)) {
            result.accountId = mainAccounts[0].Id;
            result.matchType = 'main';
            result.accountName = mainAccounts[0].Name;
            return result;
        }

        // Step 2: Check child accounts (ParentId = main account)
        List<Account> childAccounts = [
            SELECT Id, Name
            FROM Account
            WHERE ParentId = :mainAccountId
        ];

        for (Account child : childAccounts) {
            if (child.Name.trim().equalsIgnoreCase(normalizedCustomerName)) {
                result.accountId = child.Id;
                result.matchType = 'child';
                result.accountName = child.Name;
                return result;
            }
        }

        // Step 3: Check grandchild accounts (ParentId IN child account IDs)
        if (!childAccounts.isEmpty()) {
            Set<Id> childAccountIds = new Set<Id>();
            for (Account child : childAccounts) {
                childAccountIds.add(child.Id);
            }

            List<Account> grandchildAccounts = [
                SELECT Id, Name
                FROM Account
                WHERE ParentId IN :childAccountIds
            ];

            for (Account grandchild : grandchildAccounts) {
                if (grandchild.Name.trim().equalsIgnoreCase(normalizedCustomerName)) {
                    result.accountId = grandchild.Id;
                    result.matchType = 'grandchild';
                    result.accountName = grandchild.Name;
                    return result;
                }
            }
        }

        // No match found
        return result;
    }

    /**
     * @description Create a new child account under the main account
     * @param mainAccountId The ID of the main account (parent)
     * @param accountName The name for the new child account
     * @return ID of the newly created account
     */
    @AuraEnabled(cacheable=false)
    public static String createChildAccount(String mainAccountId, String accountName) {
        if (String.isBlank(mainAccountId) || String.isBlank(accountName)) {
            throw buildAuraException(
                'Missing required fields: main account ID and account name are both required'
            );
        }

        try {
            // Query parent account to get its owner
            List<Account> parentAccounts = [
                SELECT Id, OwnerId
                FROM Account
                WHERE Id = :mainAccountId
                LIMIT 1
            ];

            if (parentAccounts.isEmpty()) {
                throw buildAuraException('Parent account not found');
            }

            Account parentAccount = parentAccounts[0];

            // Create new account with owner matching parent account owner
            Account newAccount = new Account(
                Name = accountName.trim(),
                ParentId = mainAccountId,
                OwnerId = parentAccount.OwnerId,
                RecordTypeId = '012j0000000emJYAAY'  // Distributor / Dealer (non-SBO)
            );

            insert newAccount;
            return newAccount.Id;
        } catch (AuraHandledException e) {
            // Already carries a caller-facing message - do not re-wrap
            throw e;
        } catch (Exception e) {
            throw buildAuraException('Error creating child account: ' + e.getMessage());
        }
    }

    /**
     * @description Build an AuraHandledException whose getMessage() returns the supplied text.
     * Setting the message explicitly is required - otherwise getMessage() returns
     * 'Script-thrown exception' and the caller loses the reason for the failure.
     * @param message The caller-facing error message
     * @return AuraHandledException carrying the message
     */
    private static AuraHandledException buildAuraException(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }

    /**
     * @description Batch match multiple sellout items to accounts
     * @param mainAccountId The ID of the main account
     * @param selloutItemIds List of sellout item IDs to match
     * @return Map of sellout item ID to MatchResult
     */
    @AuraEnabled(cacheable=false)
    public static Map<String, MatchResult> batchMatchAccounts(String mainAccountId, List<String> selloutItemIds) {
        Map<String, MatchResult> results = new Map<String, MatchResult>();

        if (String.isBlank(mainAccountId) || selloutItemIds == null || selloutItemIds.isEmpty()) {
            return results;
        }

        // Query sellout items
        List<SLO_Sellout_Item__c> items = [
            SELECT Id, SLO_Customer_Account_Name__c
            FROM SLO_Sellout_Item__c
            WHERE Id IN :selloutItemIds
        ];

        // Match each item
        for (SLO_Sellout_Item__c item : items) {
            if (String.isNotBlank(item.SLO_Customer_Account_Name__c)) {
                MatchResult result = matchAccount(mainAccountId, item.SLO_Customer_Account_Name__c);
                results.put(item.Id, result);
            }
        }

        return results;
    }
}