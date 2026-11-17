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

        Map<String, MatchResult> resolved = resolve(mainAccountId, new Set<String>{ customerAccountName });
        MatchResult found = resolved.get(SLO_SelloutImportController.nameKey(customerAccountName));
        return found != null ? found : result;
    }

    /**
     * @description Whether an Account.Status__c value means inactive. Stored values 'Y' and
     * 'Inactive' are inactive; 'N', 'Active', 'Actif', blank and anything else are active.
     * @param status Stored Status__c value
     * @return True when the account is inactive
     */
    public static Boolean isInactive(String status) {
        if (String.isBlank(status)) {
            return false;
        }
        String trimmed = status.trim();
        return trimmed.equalsIgnoreCase('Y') || trimmed.equalsIgnoreCase('Inactive');
    }

    /**
     * @description The single matching rule: resolve customer names to accounts inside the hierarchy
     * of the main account (itself, children, grandchildren with the same billing country). Active
     * accounts are searched first, inactive ones only when no active account answers; at each level an
     * exact name beats a _Sellout suffix name, and ties go to the oldest account (CreatedDate, Id).
     * @param mainAccountId The main account whose hierarchy is searched
     * @param customerNames Customer names to resolve
     * @return Name key (SLO_SelloutImportController.nameKey) to MatchResult; unmatched names are absent
     */
    public static Map<String, MatchResult> resolve(Id mainAccountId, Set<String> customerNames) {
        Map<String, MatchResult> results = new Map<String, MatchResult>();
        if (mainAccountId == null || customerNames == null || customerNames.isEmpty()) {
            return results;
        }

        List<Account> hierarchy = SLO_SelloutImportController.getHierarchyAccounts(mainAccountId);
        Map<Id, Account> accountsById = new Map<Id, Account>(hierarchy);
        Map<String, Id> nameToId = new Map<String, Id>();
        Map<String, String> nameToStatus = new Map<String, String>();
        SLO_SelloutImportController.buildAccountNameMaps(hierarchy, nameToId, nameToStatus);

        for (String customerName : customerNames) {
            String key = SLO_SelloutImportController.nameKey(customerName);
            Id accountId = nameToId.get(key);
            if (String.isBlank(key) || accountId == null) {
                continue;
            }
            Account matched = accountsById.get(accountId);
            MatchResult result = new MatchResult();
            result.accountId = matched.Id;
            result.accountName = matched.Name;
            result.matchType = matched.Id == mainAccountId ? 'main'
                : (matched.ParentId == mainAccountId ? 'child' : 'grandchild');
            results.put(key, result);
        }
        return results;
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