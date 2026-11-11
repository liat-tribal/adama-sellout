/**
 * @description Controller for sellout import LWC providing methods for file parsing,
 * batch import with duplicate prevention, and sellout item management
 */
public with sharing class SLO_SelloutImportController {

    private static final Integer BATCH_SIZE = 200;

    // Row counts at or above this threshold are processed asynchronously with an email notification
    @TestVisible
    private static final Integer ASYNC_ROW_THRESHOLD = 500;

    // Maximum sellout items invoiced in a single transaction. Each item costs three DML rows
    // (positive line item, offsetting line item, item update), so this keeps a pass well inside
    // the 10,000 DML row limit. Larger reports are invoiced across several chained passes.
    // Kept small because record triggers on invoices and line items run once per 200-row DML chunk,
    // each chunk spending SOQL queries; a pass of 1500 items hit the 100-query limit.
    public static final Integer INVOICE_ITEMS_PER_PASS = 150;

    // Hard ceiling on the items a single pass may invoice once partial account/date groups have been
    // completed. A pass reads INVOICE_ITEMS_PER_PASS items by Id, then pulls in the rest of every
    // group it touched; this cap stops that completion step from growing the pass without bound.
    private static final Integer INVOICE_ITEMS_PASS_CEILING = 300;

    // Accounts this process creates are named "<customer name>_Sellout_<PARENT>" so they are
    // recognisable as sellout-created, and the same suffix is searched for when matching. The
    // marker after the suffix is derived from the parent account's name, so two customers with the
    // same name under different parents never produce the same account name - identical names trip
    // duplicate blocking and would fail the process. Exact name still wins when matching, so
    // accounts created before this convention (plain "_Sellout", or unsuffixed) keep matching.
    public static final String SELLOUT_ACCOUNT_SUFFIX = '_Sellout';

    // Length of the parent marker: enough of the parent name to tell parents apart, short enough
    // to keep the created account names readable
    private static final Integer PARENT_MARKER_LENGTH = 5;

    // Account.Name holds at most this many characters; a long customer name is truncated so the
    // suffix always survives whole
    private static final Integer ACCOUNT_NAME_MAX_LENGTH = 255;

    // Processing notes the review screen shows verbatim. They are written as a plain statement of
    // what the row needs, because this text is the only explanation the user gets on the row.
    public static final String NOTE_READY = 'Ready for creation';
    public static final String NOTE_ACCOUNT_NOT_FOUND =
        'Account not found - choose whether to create it';
    public static final String NOTE_ACCOUNT_INACTIVE =
        'Account found but inactive - choose whether to activate it or create a new one';
    public static final String NOTE_ACCOUNT_DECLINED =
        'Skipped - not included in this sellout';
    // Set when the user was shown how many lines still need a fix and chose to apply the sellout
    // anyway, so the row records the decision rather than looking like an unexplained skip
    public static final String NOTE_LEFT_UNCORRECTED =
        'Skipped - the product code still needed a fix when the sellout was applied';
    public static final String NOTE_ENFORCED_SKIP =
        'Enforced skipped - set aside from the needs-a-fix list without a correction';
    // A line that still needed a fix and was set aside on purpose - by the user from the needs-a-fix
    // view, by the "skip them and continue" sweep, or by Auto Accept. Kept apart from Skipped
    // (duplicates, declined accounts) so the screen can show it differently.
    public static final String STATUS_ENFORCED_SKIPPED = 'Enforced_Skipped';
    public static final String NOTE_ZERO_QUANTITY =
        'Skipped - the quantity is zero, so there is nothing to invoice';
    // Duplicate rows are kept as Skipped items rather than discarded, so the review screen can show
    // how many rows of the file were already recorded instead of silently opening on an empty list
    public static final String NOTE_DUPLICATE =
        'Skipped - an identical line (customer, product, date and quantity) is already recorded';
    // A row whose product code resolves to no product can never be invoiced, so it is flagged at
    // review time rather than failing later during invoice creation
    public static final String NOTE_PRODUCT_NOT_FOUND =
        'Product code not found - correct the code or untick the line to leave it out';
    // Prefix of the note the apply run writes when a line's code resolves to no product. Recognised
    // by the re-check, so correcting the code clears it exactly as it clears the review-time note.
    public static final String NOTE_APPLY_PRODUCT_NOT_FOUND_PREFIX = 'Product not found for EAN';
    // Prefix of the note set when the same customer, product and date are already recorded with a
    // DIFFERENT quantity; the full note names the recorded quantity so the user can decide which
    // of the two figures is right
    public static final String NOTE_QUANTITY_CONFLICT_PREFIX = 'Already recorded with quantity ';

    // Source label for lines recorded earlier in the same file, as opposed to an earlier report
    private static final String SOURCE_THIS_FILE = 'this file';

    // Rows the bulk account decisions can be applied to inside the user's own request. Applying a
    // decision touches every row carrying the name - a large file has tens of thousands - and the
    // platform allows 10,000 records per transaction, so above this the work moves to a background
    // job. The ceiling is set well below the limit because the same transaction also re-validates
    // the rows, which reads and writes more of them.
    private static final Integer MAX_SYNC_DECISION_ROWS = 4000;

    /**
     * @description Build the note for a row whose customer, product and date are already recorded
     * with a different quantity
     * @param recordedQuantity Quantity already recorded for that customer, product and date
     * @param source Where the recorded line lives - an earlier report's name, or this same file -
     *        so the user can reconcile the two figures; blank leaves the note without a source
     * @return The full processing note, carrying the recorded quantity and its source
     */
    public static String buildQuantityConflictNote(Decimal recordedQuantity, String source) {
        String quantityText = recordedQuantity == null
            ? '0'
            : recordedQuantity.stripTrailingZeros().toPlainString();
        return NOTE_QUANTITY_CONFLICT_PREFIX + quantityText +
            (String.isBlank(source) ? '' : ' in ' + source) +
            ' for this customer, product and date - change the date or quantity, or untick the line to leave it out';
    }

    /**
     * @description Build the name a newly created sellout account is given, without a parent
     * marker. Kept for callers with no parent at hand; account creation passes the parent name.
     * @param customerName Customer account name as it appears on the sellout item
     * @return The customer name with the sellout suffix appended, or null when the name is blank
     */
    public static String buildSelloutAccountName(String customerName) {
        return buildSelloutAccountName(customerName, null);
    }

    /**
     * @description Build the name a newly created sellout account is given:
     * "<customer name>_Sellout_<PARENT>", where the marker makes the name unique per parent
     * @param customerName Customer account name as it appears on the sellout item
     * @param parentName Name of the parent account the new account is created under; blank
     *        produces the plain "_Sellout" suffix
     * @return The suffixed name, or null when the customer name is blank. A name already carrying
     *         the sellout suffix (either generation) is returned unchanged.
     */
    public static String buildSelloutAccountName(String customerName, String parentName) {
        if (String.isBlank(customerName)) {
            return null;
        }
        String trimmed = customerName.trim();
        // Never double up the suffix when a name already carries it
        if (carriesSelloutSuffix(trimmed)) {
            return trimmed;
        }

        String marker = buildParentMarker(parentName);
        String suffix = String.isBlank(marker)
            ? SELLOUT_ACCOUNT_SUFFIX
            : SELLOUT_ACCOUNT_SUFFIX + '_' + marker;

        // Truncate the customer part rather than the suffix, so the name always parses back
        Integer maxBaseLength = ACCOUNT_NAME_MAX_LENGTH - suffix.length();
        if (trimmed.length() > maxBaseLength) {
            trimmed = trimmed.substring(0, maxBaseLength).trim();
        }
        return trimmed + suffix;
    }

    /**
     * @description Derive the short parent marker appended after the sellout suffix
     * @param parentName Name of the parent account
     * @return The first alphanumeric characters of the parent name, uppercased; empty when the
     *         name is blank or holds no alphanumeric characters
     */
    public static String buildParentMarker(String parentName) {
        if (String.isBlank(parentName)) {
            return '';
        }
        String alphanumeric = parentName.replaceAll('[^a-zA-Z0-9]', '').toUpperCase();
        return alphanumeric.length() > PARENT_MARKER_LENGTH
            ? alphanumeric.substring(0, PARENT_MARKER_LENGTH)
            : alphanumeric;
    }

    /**
     * @description True when a name already carries the sellout suffix - the legacy "_Sellout"
     * ending or the marked "_Sellout_<PARENT>" form
     * @param name Account or customer name to inspect
     * @return True when the name is already a sellout-created name
     */
    private static Boolean carriesSelloutSuffix(String name) {
        String lower = name.toLowerCase();
        String suffixKey = SELLOUT_ACCOUNT_SUFFIX.toLowerCase();
        return lower.endsWith(suffixKey) || lower.contains(suffixKey + '_');
    }

    // The UTF-8 byte order mark Excel writes at the start of a CSV. Left in place it becomes an
    // invisible first character of the first column header, so that header never equals what the
    // user sees on screen.
    private static final String UTF8_BOM = String.fromCharArray(new List<Integer>{ 65279 });

    // The non-breaking space exported systems put inside names. Neither trim() nor
    // normalizeSpace() treats it as white space, so it has to be replaced explicitly.
    private static final String NON_BREAKING_SPACE = String.fromCharArray(new List<Integer>{ 160 });

    /**
     * @description Remove a leading UTF-8 byte order mark from file content
     * @param content Decoded file content
     * @return The content without the marker; unchanged when there is none
     */
    public static String stripBom(String content) {
        if (content != null && content.startsWith(UTF8_BOM)) {
            return content.substring(UTF8_BOM.length());
        }
        return content;
    }

    /**
     * @description Normalise one cell value: non-breaking spaces become spaces, runs of white
     * space collapse, and the ends are trimmed - so "ARMBRUSTER  GRANDES CULTURES  SAS" with
     * hidden characters is the same customer as the account of that name
     * @param value Raw cell value
     * @return Cleaned value, or null when the input is null
     */
    public static String cleanCellValue(String value) {
        if (value == null) {
            return null;
        }
        return value.replace(NON_BREAKING_SPACE, ' ').normalizeSpace();
    }

    /**
     * @description The case-insensitive key two names are compared on - cleaned of hidden spaces
     * and lowercased - so a file name and an account name match however they were typed
     * @param name Customer or account name
     * @return The comparison key; empty for a blank name
     */
    public static String nameKey(String name) {
        if (String.isBlank(name)) {
            return '';
        }
        return cleanCellValue(name).toLowerCase();
    }

    /**
     * @description Build the case-insensitive name lookups used to match a sellout row to an account.
     * Two passes, and the order is what makes "exact name first, then the suffixed name" work: every
     * account is registered under its own name, and only then does an account called
     * "AGORA_Sellout" or "AGORA_Sellout_PAREN" also answer to "AGORA". An account genuinely named
     * "AGORA" therefore always wins, while a row reading "AGORA" still finds the suffixed account a
     * previous import created - whichever suffix generation it carries.
     * @param accounts Accounts in the hierarchy, in match-precedence order
     * @param nameToId Name key to account Id, populated in place
     * @param nameToStatus Name key to account status, populated in place
     */
    public static void buildAccountNameMaps(
        List<Account> accounts,
        Map<String, Id> nameToId,
        Map<String, String> nameToStatus
    ) {
        // Pass one: exact names
        for (Account account : accounts) {
            if (String.isBlank(account.Name)) {
                continue;
            }
            String key = nameKey(account.Name);
            if (!nameToId.containsKey(key)) {
                nameToId.put(key, account.Id);
                nameToStatus.put(key, account.Status__c);
            }
        }

        // Pass two: the suffixed accounts also answer to their base name, where nothing claims it
        for (Account account : accounts) {
            if (String.isBlank(account.Name)) {
                continue;
            }
            String baseKey = stripSelloutSuffix(nameKey(account.Name));
            if (baseKey == null || nameToId.containsKey(baseKey)) {
                continue;
            }
            nameToId.put(baseKey, account.Id);
            nameToStatus.put(baseKey, account.Status__c);
        }
    }

    /**
     * @description The customer name a sellout-created account name was built from - the part
     * before "_Sellout" (legacy) or "_Sellout_<PARENT>" (current)
     * @param key Lowercased, trimmed account name
     * @return The base name, or null when the name carries no sellout suffix
     */
    private static String stripSelloutSuffix(String key) {
        String suffixKey = SELLOUT_ACCOUNT_SUFFIX.toLowerCase();
        if (key.endsWith(suffixKey) && key.length() > suffixKey.length()) {
            return key.substring(0, key.length() - suffixKey.length());
        }
        Integer markerIndex = key.lastIndexOf(suffixKey + '_');
        if (markerIndex > 0) {
            return key.substring(0, markerIndex);
        }
        return null;
    }

    /**
     * @description Get the current user's locale setting
     * @return String LocaleSidKey of the running user (e.g., 'en_US', 'en_GB', 'de_DE')
     */
    private static String getUserLocale() {
        User currentUser = [SELECT LocaleSidKey FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        return currentUser.LocaleSidKey;
    }

    /**
     * @description Determine date format pattern based on locale
     * @param locale The user's LocaleSidKey
     * @return String representing date format: 'DD/MM/YYYY', 'MM/DD/YYYY', or 'DD.MM.YYYY'
     */
    private static String getDateFormatForLocale(String locale) {
        // US locales use MM/DD/YYYY
        if (locale.startsWith('en_US') || locale.startsWith('en_CA')) {
            return 'MM/DD/YYYY';
        }
        // German and some other European locales use DD.MM.YYYY with dots
        else if (locale.startsWith('de_') || locale.startsWith('fi_') || locale.startsWith('no_') ||
                 locale.startsWith('sv_') || locale.startsWith('da_')) {
            return 'DD.MM.YYYY';
        }
        // Most other locales use DD/MM/YYYY (UK, FR, ES, IT, PT, etc.)
        else {
            return 'DD/MM/YYYY';
        }
    }

    /**
     * @description Determine if locale uses decimal comma instead of decimal point
     * @param locale The user's LocaleSidKey
     * @return Boolean true if locale uses comma as decimal separator
     */
    private static Boolean usesDecimalComma(String locale) {
        // European locales generally use comma as decimal separator
        // US, UK, and some Asian locales use decimal point
        Set<String> decimalPointLocales = new Set<String>{
            'en_US', 'en_GB', 'en_CA', 'en_AU', 'en_NZ', 'en_IE',
            'zh_CN', 'zh_TW', 'ja_JP', 'ko_KR', 'th_TH'
        };

        return !decimalPointLocales.contains(locale);
    }

    /**
     * @description Parse date string according to user's locale
     * @param dateStr Date string from CSV (e.g., '24/05/2022', '05/24/2022', '24.05.2022')
     * @param locale The user's LocaleSidKey
     * @return Date parsed date in Salesforce format
     * @throws Exception if date cannot be parsed
     */
    private static Date parseDateByLocale(String dateStr, String locale) {
        if (String.isBlank(dateStr)) {
            throw new IllegalArgumentException('Date string cannot be blank');
        }

        // Remove any whitespace
        dateStr = dateStr.trim();

        // Check if date is already in ISO format (YYYY-MM-DD)
        // Pattern: 4 digits, dash, 2 digits, dash, 2 digits
        Pattern isoPattern = Pattern.compile('^\\d{4}-\\d{2}-\\d{2}$');
        if (isoPattern.matcher(dateStr).matches()) {
            // Already in Salesforce format, parse directly
            try {
                return Date.valueOf(dateStr);
            } catch (Exception e) {
                throw new IllegalArgumentException('Invalid ISO date format: ' + dateStr + '. Error: ' + e.getMessage());
            }
        }

        // Get expected format for locale
        String dateFormat = getDateFormatForLocale(locale);

        // Determine separator (could be /, -, or .)
        String separator = '/';
        if (dateStr.contains('.')) {
            separator = '.';
        } else if (dateStr.contains('-')) {
            separator = '-';
        }

        // Split date string into parts
        List<String> parts = dateStr.split('\\' + separator);
        if (parts.size() != 3) {
            throw new IllegalArgumentException('Invalid date format: ' + dateStr + '. Expected format: ' + dateFormat);
        }

        Integer day, month, year;

        try {
            // Parse based on locale format
            if (dateFormat == 'MM/DD/YYYY') {
                // US format: Month/Day/Year
                month = Integer.valueOf(parts[0]);
                day = Integer.valueOf(parts[1]);
                year = Integer.valueOf(parts[2]);
            } else {
                // DD/MM/YYYY or DD.MM.YYYY format: Day/Month/Year
                day = Integer.valueOf(parts[0]);
                month = Integer.valueOf(parts[1]);
                year = Integer.valueOf(parts[2]);
            }

            // Handle 2-digit years
            if (year < 100) {
                if (year < 50) {
                    year += 2000;
                } else {
                    year += 1900;
                }
            }

            // Validate ranges
            if (month < 1 || month > 12) {
                throw new IllegalArgumentException('Invalid month: ' + month);
            }
            if (day < 1 || day > 31) {
                throw new IllegalArgumentException('Invalid day: ' + day);
            }
            if (year < 1900 || year > 2100) {
                throw new IllegalArgumentException('Invalid year: ' + year);
            }

            // Construct Salesforce date format YYYY-MM-DD
            String salesforceDateStr = String.valueOf(year) + '-' +
                                       String.valueOf(month).leftPad(2, '0') + '-' +
                                       String.valueOf(day).leftPad(2, '0');

            return Date.valueOf(salesforceDateStr);

        } catch (Exception e) {
            throw new IllegalArgumentException('Error parsing date "' + dateStr + '" with format ' +
                                             dateFormat + ': ' + e.getMessage());
        }
    }

    /**
     * @description Parse number string according to user's locale
     * @param numStr Number string from CSV (e.g., '1234.56' or '1234,56')
     * @param locale The user's LocaleSidKey
     * @return Decimal parsed number
     * @throws Exception if number cannot be parsed
     */
    private static Decimal parseNumberByLocale(String numStr, String locale) {
        if (String.isBlank(numStr)) {
            return 0;
        }

        // Remove whitespace
        numStr = numStr.trim();

        try {
            if (usesDecimalComma(locale)) {
                // European format: comma as decimal separator, dot/space as thousands separator
                // Remove thousands separators (dots or spaces)
                numStr = numStr.replace('.', '');
                numStr = numStr.replace(' ', '');
                // Replace comma with dot for Salesforce decimal parsing
                numStr = numStr.replace(',', '.');
            } else {
                // US/UK format: dot as decimal separator, comma as thousands separator
                // Remove thousands separators (commas)
                numStr = numStr.replace(',', '');
            }

            return Decimal.valueOf(numStr);

        } catch (Exception e) {
            throw new IllegalArgumentException('Error parsing number "' + numStr + '" for locale ' +
                                             locale + ': ' + e.getMessage());
        }
    }

    /**
     * @description Wrapper class for file parsing result
     */
    public class ParseResult {
        @AuraEnabled public List<String> columnHeaders { get; set; }
        @AuraEnabled public List<List<String>> previewRows { get; set; }
        @AuraEnabled public Integer totalRows { get; set; }
        @AuraEnabled public String errorMessage { get; set; }

        public ParseResult() {
            this.columnHeaders = new List<String>();
            this.previewRows = new List<List<String>>();
            this.totalRows = 0;
            this.errorMessage = null;
        }
    }

    /**
     * @description Wrapper class for import result
     */
    public class ImportResult {
        @AuraEnabled public String selloutReportId { get; set; }
        @AuraEnabled public Integer itemsImported { get; set; }
        @AuraEnabled public Boolean success { get; set; }
        @AuraEnabled public String errorMessage { get; set; }
        @AuraEnabled public Integer duplicatesRemoved { get; set; }

        public ImportResult() {
            this.selloutReportId = null;
            this.itemsImported = 0;
            this.success = false;
            this.errorMessage = null;
            this.duplicatesRemoved = 0;
        }
    }

    /**
     * @description Wrapper class for sellout item data
     */
    public class SelloutItemData {
        @AuraEnabled public String itemDate { get; set; }
        @AuraEnabled public String productCode { get; set; }
        @AuraEnabled public String quantity { get; set; } // Changed to String for locale-aware parsing
        @AuraEnabled public String customerAccountName { get; set; }
    }

    /**
     * @description Parse CSV file content and return column headers and preview rows
     * @param fileContent Base64 encoded file content
     * @param fileName Name of the uploaded file
     * @param parseAllRows If true, return all rows; if false, return only first 20 rows for preview
     * @param csvDelimiter The delimiter character to use (comma, semicolon, or tab). Defaults to comma if null.
     * @return ParseResult with column headers, preview rows, and total row count
     */
    @AuraEnabled(cacheable=false)
    public static ParseResult parseFile(String fileContent, String fileName, Boolean parseAllRows, String csvDelimiter) {
        ParseResult result = new ParseResult();

        try {
            // Default to comma if delimiter is null or blank
            if (String.isBlank(csvDelimiter)) {
                csvDelimiter = ',';
            }

            // Validate file extension - only allow CSV files
            if (String.isBlank(fileName) || !fileName.toLowerCase().endsWith('.csv')) {
                result.errorMessage = 'Only CSV files are supported. Please export your Excel file as CSV before uploading.';
                return result;
            }

            // Decode base64 content
            String csvContent = fileContent;
            if (fileContent.startsWith('data:')) {
                // Remove data URL prefix if present
                Integer commaIndex = fileContent.indexOf(',');
                if (commaIndex > 0) {
                    csvContent = fileContent.substring(commaIndex + 1);
                }
            }

            String decodedContent = stripBom(EncodingUtil.base64Decode(csvContent).toString());

            // Count the total number of lines without materialising them - large files must never
            // be run through a regex based split, which fails with "Regex too complicated".
            Integer totalLines = countLines(decodedContent);
            if (totalLines == 0) {
                result.errorMessage = 'File is empty';
                return result;
            }

            // Only materialise the lines we actually need: everything for a full parse, the header
            // plus 20 data rows for a preview.
            Integer linesToRead = (parseAllRows != null && parseAllRows) ? null : 21;
            List<String> lines = splitLines(decodedContent, linesToRead);

            if (lines.isEmpty()) {
                result.errorMessage = 'File is empty';
                return result;
            }

            // Parse headers with specified delimiter
            String headerLine = lines[0].trim();
            result.columnHeaders = parseCSVLine(headerLine, csvDelimiter);

            for (Integer i = 1; i < lines.size(); i++) {
                String line = lines[i].trim();
                if (String.isNotBlank(line)) {
                    List<String> row = parseCSVLine(line, csvDelimiter);
                    if (row.size() > 0) {
                        result.previewRows.add(row);
                    }
                }
            }

            // Count total data rows
            result.totalRows = Math.max(0, totalLines - 1);

        } catch (Exception e) {
            result.errorMessage = 'Error parsing file: ' + e.getMessage();
        }

        return result;
    }

    /**
     * @description Import sellout items from parsed data
     * @param accountId ID of the account this sellout report belongs to
     * @param reportDate Date of the sellout report
     * @param items List of sellout item data to import
     * @return ImportResult with report ID and import status
     */
    @AuraEnabled(cacheable=false)
    public static ImportResult importSelloutItems(String accountId, String reportDate, List<SelloutItemData> items) {
        ImportResult result = new ImportResult();

        try {
            // Validate inputs
            if (String.isBlank(accountId) || String.isBlank(reportDate) || items == null || items.isEmpty()) {
                result.errorMessage = 'Invalid input parameters';
                return result;
            }

            // Get user's locale for date and number parsing
            String userLocale = getUserLocale();

            // Parse report date using locale-aware parser
            Date reportDateParsed;
            try {
                reportDateParsed = parseDateByLocale(reportDate, userLocale);
            } catch (Exception e) {
                result.errorMessage = 'Invalid report date format. Expected format for your locale (' + userLocale + '): ' +
                                     getDateFormatForLocale(userLocale) + '. Error: ' + e.getMessage();
                return result;
            }

            // Auto-cleanse duplicate logic now runs for every parent account, not only French ones.
            // The comparison set stays scoped to this account's own reports, which is what "the same
            // country as the account the sellout is performed on" means in practice - a parent account
            // has one usage company, so its own history is already country-scoped.
            List<SelloutItemData> filteredItems;
            Integer duplicatesRemoved = 0;
            // Duplicate rows are still imported, marked Skipped, so the report holds a complete record
            // of the file and the review screen can show how many rows were already recorded
            Set<String> duplicateKeys = new Set<String>();

            {
                // === 4-field auto-cleanse duplicate checking ===
                // Check for duplicate items (Customer + Product + Date + Quantity combination)
                // First, parse all items to build composite keys
                Set<String> newItemKeys = new Set<String>();
                Map<String, Integer> keyToRowNumber = new Map<String, Integer>();
                Map<String, SelloutItemData> keyToItemData = new Map<String, SelloutItemData>();

                Integer rowNumber = 1;
                for (SelloutItemData itemData : items) {
                    try {
                        // Parse item date using locale-aware parser
                        Date itemDateParsed = parseDateByLocale(itemData.itemDate, userLocale);

                        // Parse quantity for consistent formatting (10 == 10.00 == 10.0)
                        Decimal quantityParsed = parseNumberByLocale(itemData.quantity, userLocale);
                        String quantityKey = quantityParsed != null ? quantityParsed.stripTrailingZeros().toPlainString() : '0';

                        // Build composite key: customerName|productCode|itemDate|quantity
                        String compositeKey = (itemData.customerAccountName != null ? itemData.customerAccountName.toLowerCase().trim() : '') +
                                            '|' +
                                            (itemData.productCode != null ? itemData.productCode.trim() : '') +
                                            '|' +
                                            String.valueOf(itemDateParsed) +
                                            '|' +
                                            quantityKey;

                        newItemKeys.add(compositeKey);
                        keyToRowNumber.put(compositeKey, rowNumber);
                        keyToItemData.put(compositeKey, itemData);
                    } catch (Exception e) {
                        // Date parsing error will be caught in the main processing loop
                        // Log for debugging but continue to allow main processing to handle it
                        System.debug('Unable to parse date for duplicate checking on row ' + rowNumber + ': ' + e.getMessage());
                    }
                    rowNumber++;
                }

                // Query existing sellout items for this account
                List<SLO_Sellout_Item__c> existingItems = [
                    SELECT Id, SLO_Customer_Account_Name__c, SLO_Product_Code_EAN__c, SLO_Item_Date__c, SLO_Quantity__c
                    FROM SLO_Sellout_Item__c
                    WHERE SLO_Sellout_Report__c IN (
                        SELECT Id FROM SLO_Sellout_Report__c WHERE SLO_Account__c = :accountId
                    )
                ];

                // Build map of existing item keys
                Set<String> existingItemKeys = new Set<String>();
                for (SLO_Sellout_Item__c existingItem : existingItems) {
                    // Normalize quantity for consistent key matching
                    String quantityKey = existingItem.SLO_Quantity__c != null ?
                        existingItem.SLO_Quantity__c.stripTrailingZeros().toPlainString() : '0';

                    String existingKey = (existingItem.SLO_Customer_Account_Name__c != null ? existingItem.SLO_Customer_Account_Name__c.toLowerCase().trim() : '') +
                                       '|' +
                                       (existingItem.SLO_Product_Code_EAN__c != null ? existingItem.SLO_Product_Code_EAN__c.trim() : '') +
                                       '|' +
                                       String.valueOf(existingItem.SLO_Item_Date__c) +
                                       '|' +
                                       quantityKey;
                    existingItemKeys.add(existingKey);
                }

                // Every row is imported; the ones already recorded are noted here and stored as Skipped
                filteredItems = new List<SelloutItemData>();

                for (SelloutItemData itemData : items) {
                    try {
                        // Parse item date and quantity for key construction
                        Date itemDateParsed = parseDateByLocale(itemData.itemDate, userLocale);
                        Decimal quantityParsed = parseNumberByLocale(itemData.quantity, userLocale);
                        String quantityKey = quantityParsed != null ? quantityParsed.stripTrailingZeros().toPlainString() : '0';

                        // Rebuild composite key for this item
                        String compositeKey = (itemData.customerAccountName != null ? itemData.customerAccountName.toLowerCase().trim() : '') +
                                            '|' +
                                            (itemData.productCode != null ? itemData.productCode.trim() : '') +
                                            '|' +
                                            String.valueOf(itemDateParsed) +
                                            '|' +
                                            quantityKey;

                        // Check if this key exists in existing items
                        if (existingItemKeys.contains(compositeKey)) {
                            duplicatesRemoved++;
                            duplicateKeys.add(compositeKey);
                        }
                        filteredItems.add(itemData);
                    } catch (Exception e) {
                        // If we can't parse the item for duplicate checking, import it anyway.
                        // The main processing loop will handle the error
                        filteredItems.add(itemData);
                    }
                }
            }

            result.duplicatesRemoved = duplicatesRemoved;

            // Create sellout report
            SLO_Sellout_Report__c report = new SLO_Sellout_Report__c(
                SLO_Account__c = accountId,
                SLO_Report_Date__c = reportDateParsed,
                SLO_Status__c = 'New'
            );
            insert report;
            result.selloutReportId = report.Id;

            // Process filtered items in batches with locale-aware parsing
            List<SLO_Sellout_Item__c> allItems = new List<SLO_Sellout_Item__c>();
            Integer processRowNumber = 1; // Track row number for error reporting
            for (SelloutItemData itemData : filteredItems) {
                try {
                    // Parse item date using locale-aware parser
                    Date itemDateParsed = parseDateByLocale(itemData.itemDate, userLocale);

                    // Parse quantity using locale-aware parser
                    Decimal quantityParsed = parseNumberByLocale(itemData.quantity, userLocale);

                    SLO_Sellout_Item__c item = new SLO_Sellout_Item__c(
                        SLO_Sellout_Report__c = report.Id,
                        SLO_Item_Date__c = itemDateParsed,
                        SLO_Product_Code_EAN__c = itemData.productCode,
                        SLO_Quantity__c = quantityParsed,
                        SLO_Customer_Account_Name__c = itemData.customerAccountName,
                        SLO_Processing_Status__c = 'Pending'
                    );

                    // A row already recorded for this account is stored as Skipped so it is counted
                    // and explained rather than disappearing from the report
                    String quantityKey = quantityParsed != null
                        ? quantityParsed.stripTrailingZeros().toPlainString()
                        : '0';
                    String itemKey = (itemData.customerAccountName != null
                            ? itemData.customerAccountName.toLowerCase().trim() : '') +
                        '|' + (itemData.productCode != null ? itemData.productCode.trim() : '') +
                        '|' + String.valueOf(itemDateParsed) +
                        '|' + quantityKey;
                    if (duplicateKeys.contains(itemKey)) {
                        item.SLO_Processing_Status__c = 'Skipped';
                        item.SLO_Processing_Notes__c = NOTE_DUPLICATE;
                    }

                    allItems.add(item);
                } catch (Exception e) {
                    throw new IllegalArgumentException('Error on row ' + processRowNumber + ': ' + e.getMessage());
                }
                processRowNumber++;
            }

            // Insert in batches
            Integer itemsInserted = 0;
            for (Integer i = 0; i < allItems.size(); i += BATCH_SIZE) {
                Integer endIndex = Math.min(i + BATCH_SIZE, allItems.size());
                List<SLO_Sellout_Item__c> batch = new List<SLO_Sellout_Item__c>();
                for (Integer j = i; j < endIndex; j++) {
                    batch.add(allItems[j]);
                }
                insert batch;
                itemsInserted += batch.size();
            }

            // Import finished. Every report - small or large - pauses in Draft for review before
            // invoices are created, so the small-file path must not jump straight to Completed.
            report.SLO_Status__c = 'Draft';
            report.SLO_Import_Date__c = DateTime.now();
            // Every row of the file is counted, new or already recorded, so the number shown for the
            // report matches what the user uploaded
            report.SLO_Total_Items__c = Math.max(itemsInserted, filteredItems.size());
            update report;

            // The duplicates are stored but are not new lines, so they are reported separately
            result.itemsImported = itemsInserted - duplicatesRemoved;
            if (result.itemsImported < 0) {
                result.itemsImported = 0;
            }
            result.success = true;

        } catch (Exception e) {
            if (result.selloutReportId != null) {
                // Update report with error status
                try {
                    SLO_Sellout_Report__c report = [SELECT Id FROM SLO_Sellout_Report__c WHERE Id = :result.selloutReportId];
                    report.SLO_Status__c = 'Error';
                    report.SLO_Error_Message__c = e.getMessage();
                    update report;
                } catch (Exception updateEx) {
                    System.debug('Error updating report status: ' + updateEx.getMessage());
                }
            }
            result.errorMessage = 'Error importing sellout items: ' + e.getMessage();
            result.success = false;
        }

        return result;
    }

    /**
     * @description Get sellout reports for an account
     * @param accountId ID of the account
     * @return List of sellout reports ordered by import date descending
     */
    public static final String LOCKED_MESSAGE =
        'This report was applied with Auto Accept and is locked. It can be reviewed but not changed.';

    /**
     * @description Reject changes to a report applied by the daily Auto Accept job
     * @param reportId Sellout report Id
     */
    public static void assertReportEditable(String reportId) {
        if (String.isBlank(reportId)) {
            return;
        }
        Integer locked = [
            SELECT COUNT() FROM SLO_Sellout_Report__c
            WHERE Id = :reportId AND SLO_Auto_Accepted__c = true
        ];
        if (locked > 0) {
            throw new AuraHandledException(LOCKED_MESSAGE);
        }
    }

    /**
     * @description Reject changes to lines that belong to an Auto Accepted report
     * @param itemIds Sellout item Ids about to be changed
     */
    public static void assertItemsEditable(List<String> itemIds) {
        if (itemIds == null || itemIds.isEmpty()) {
            return;
        }
        Integer locked = [
            SELECT COUNT() FROM SLO_Sellout_Item__c
            WHERE Id IN :itemIds AND SLO_Sellout_Report__r.SLO_Auto_Accepted__c = true
        ];
        if (locked > 0) {
            throw new AuraHandledException(LOCKED_MESSAGE);
        }
    }

    /**
     * @description Add to the report's count of newly created accounts. Never fails the caller.
     * @param reportId Sellout report Id
     * @param created Number of accounts just inserted
     */
    private static void addAccountsCreated(String reportId, Integer created) {
        if (String.isBlank(reportId) || created == null || created <= 0) {
            return;
        }
        try {
            SLO_Sellout_Report__c report = [
                SELECT Id, SLO_Accounts_Created__c FROM SLO_Sellout_Report__c
                WHERE Id = :reportId LIMIT 1 FOR UPDATE
            ];
            report.SLO_Accounts_Created__c =
                (report.SLO_Accounts_Created__c != null ? report.SLO_Accounts_Created__c : 0) + created;
            update report;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Could not record accounts created: ' + e.getMessage());
        }
    }

    private static void addAccountsCreatedForItems(List<String> itemIds, Integer created) {
        if (itemIds == null || itemIds.isEmpty()) {
            return;
        }
        List<SLO_Sellout_Item__c> first = [
            SELECT SLO_Sellout_Report__c FROM SLO_Sellout_Item__c WHERE Id = :itemIds[0] LIMIT 1
        ];
        if (!first.isEmpty()) {
            addAccountsCreated(first[0].SLO_Sellout_Report__c, created);
        }
    }

    @AuraEnabled(cacheable=false)
    public static List<SLO_Sellout_Report__c> getSelloutReports(String accountId) {
        if (String.isBlank(accountId)) {
            return new List<SLO_Sellout_Report__c>();
        }

        return [
            SELECT Id, Name, SLO_Report_Date__c, SLO_Status__c,
                   SLO_Accounts_Created__c, SLO_Auto_Accepted__c,
                   SLO_Total_Items__c, SLO_Import_Date__c, SLO_Error_Message__c
            FROM SLO_Sellout_Report__c
            WHERE SLO_Account__c = :accountId
            ORDER BY SLO_Import_Date__c DESC NULLS LAST, CreatedDate DESC
        ];
    }

    /**
     * @description Get sellout items for a report
     * @param reportId ID of the sellout report
     * @return List of sellout items
     */
    @AuraEnabled(cacheable=false)
    public static List<SLO_Sellout_Item__c> getSelloutItems(String reportId) {
        if (String.isBlank(reportId)) {
            return new List<SLO_Sellout_Item__c>();
        }

        return [
            SELECT Id, Name, SLO_Item_Date__c, SLO_Product_Code_EAN__c,
                   SLO_Quantity__c, SLO_Customer_Account_Name__c,
                   SLO_Matched_Account__c, SLO_Processing_Status__c,
                   SLO_Processing_Notes__c, SLO_Invoice_Line_Item__c
            FROM SLO_Sellout_Item__c
            WHERE SLO_Sellout_Report__c = :reportId
            ORDER BY CreatedDate ASC
        ];
    }

    /**
     * @description Get sellout items for a report, optionally hiding the items that were skipped as
     * duplicates. A large file is mostly rows that already exist, so the review screen defaults to
     * the items that actually need attention rather than every row that was imported.
     * @param reportId ID of the sellout report
     * @param showSkipped True to return every item, false or null to hide items at status Skipped
     * @return List of sellout items
     */
    @AuraEnabled(cacheable=false)
    public static List<SLO_Sellout_Item__c> getFilteredSelloutItems(String reportId, Boolean showSkipped) {
        if (String.isBlank(reportId)) {
            return new List<SLO_Sellout_Item__c>();
        }

        if (showSkipped == true) {
            return getSelloutItems(reportId);
        }

        return [
            SELECT Id, Name, SLO_Item_Date__c, SLO_Product_Code_EAN__c,
                   SLO_Quantity__c, SLO_Customer_Account_Name__c,
                   SLO_Matched_Account__c, SLO_Processing_Status__c,
                   SLO_Processing_Notes__c, SLO_Invoice_Line_Item__c
            FROM SLO_Sellout_Item__c
            WHERE SLO_Sellout_Report__c = :reportId
            AND SLO_Processing_Status__c != 'Skipped'
            ORDER BY CreatedDate ASC
        ];
    }

    // Ceiling on the older unpaged item queries. Without it a large report can breach the query row
    // limit and fail outright instead of returning what it can; the paged review list is the route
    // the UI now uses.
    private static final Integer LEGACY_ITEM_QUERY_LIMIT = 2000;

    /**
     * @description Wrapper for one page of review items, so the client can render a page without
     * knowing how many items the report holds in total
     */
    public class SelloutItemPage {
        @AuraEnabled public List<SLO_Sellout_Item__c> items { get; set; }
        @AuraEnabled public Integer totalCount { get; set; }
        @AuraEnabled public Boolean hasMore { get; set; }

        public SelloutItemPage() {
            this.items = new List<SLO_Sellout_Item__c>();
            this.totalCount = 0;
            this.hasMore = false;
        }
    }

    // One page of review items. Small enough that the first page paints immediately however large
    // the imported file was.
    private static final Integer REVIEW_PAGE_SIZE = 50;

    // SOQL will not accept an OFFSET beyond 2000 rows. The review list is meant for correcting a
    // handful of rows, so paging stops there rather than failing the query.
    private static final Integer MAX_REVIEW_OFFSET = 2000;

    // The review list only ever shows rows someone can act on: rows that failed, rows awaiting a
    // decision, and the new rows that are ready to be invoiced. Duplicates and rows already invoiced
    // are counted in the summary instead of being listed.
    private static final Set<String> REVIEW_STATUSES = new Set<String>{
        'Error', 'Pending', 'Pending_Decision', 'Matched', 'Duplicate'
    };

    // Every status a row can sit in while it is still waiting on an account decision. Error rows
    // count as open because a row can carry a data error AND an unresolved account name. Shared with
    // the apply batch so the deferred decision pass and the synchronous pass select the same rows.
    public static final Set<String> DECISION_OPEN_STATUSES = new Set<String>{
        'Pending', 'Pending_Decision', 'Error'
    };

    // Every status an account decision can still be taken on. This adds the rows already set aside
    // on the accounts step: leaving a customer out is the one reversible decision on that view, and
    // the view deliberately lists those names for review, so they must be actionable again. A
    // Skipped row only qualifies when it was skipped by an account decision - a duplicate or a
    // zero-quantity row is skipped for its own reasons and no account decision revives it.
    public static final Set<String> DECISION_DECIDABLE_STATUSES = new Set<String>{
        'Pending', 'Pending_Decision', 'Error', 'Skipped'
    };

    /**
     * @description Whether an account decision may still be applied to a row: every open row, plus
     * the rows set aside by an earlier account decision, and no other skipped row
     * @param item Review row carrying its status and processing notes
     * @return True when a bulk account decision may write to this row
     */
    public static Boolean isDecidableRow(SLO_Sellout_Item__c item) {
        if (item == null) {
            return false;
        }
        String status = item.SLO_Processing_Status__c;
        if (status == 'Skipped') {
            return item.SLO_Processing_Notes__c == NOTE_ACCOUNT_DECLINED;
        }
        return DECISION_OPEN_STATUSES.contains(status);
    }

    // The review screen offers three views, each with a single purpose, so a line appears in exactly
    // one of them and the count beside a view is always work of that one kind.
    //
    // The view that owns the account decisions. The names the user chose to leave out are Skipped
    // rather than actionable, so they are listed here alongside the names still awaiting a decision -
    // one place holding every account decision, taken or not.
    private static final String ACCOUNT_DECISION_FILTER = 'Pending_Decision';

    // The view that owns the technical data errors - an unknown product code, a quantity that
    // contradicts a line already recorded. Nothing else reaches it.
    private static final String NEEDS_FIX_FILTER = 'Error';

    // The view that owns the finished lines: valid, with no decision and no error outstanding, so
    // they need nothing from the user. A line never checked is valid as far as the data goes, so it
    // belongs with the ready lines rather than in a view of its own.
    private static final String READY_FILTER = 'Ready';
    private static final Set<String> READY_STATUSES = new Set<String>{ 'Pending', 'Matched' };

    /**
     * @description The statuses a review view lists: the ready block for the ready view, one status
     * when the filter names it, the error block alone for the older errors-only flag, otherwise
     * every actionable status
     * @param errorsOnly Legacy flag restricting the view to rows that failed
     * @param statusFilter The view to show, or 'all' / blank for every actionable status
     * @return The statuses to query
     */
    private static Set<String> resolveReviewStatuses(Boolean errorsOnly, String statusFilter) {
        if (statusFilter == READY_FILTER) {
            return new Set<String>(READY_STATUSES);
        }
        if (String.isNotBlank(statusFilter) && statusFilter != 'all'
                && REVIEW_STATUSES.contains(statusFilter)) {
            return new Set<String>{ statusFilter };
        }
        if (errorsOnly == true) {
            return new Set<String>{ NEEDS_FIX_FILTER };
        }
        return REVIEW_STATUSES;
    }

    /**
     * @description Get one page of a report's actionable review items - the rows in error and the
     * new rows still awaiting processing - with errors first so corrections are on the first page
     * @param reportId ID of the sellout report
     * @param pageSize Rows to return; null, zero or negative falls back to the default page size
     * @param rowOffset Rows to skip before this page; null or negative is treated as zero
     * @param errorsOnly True to restrict the page to rows that failed (older clients)
     * @param statusFilter The view to list - 'Pending_Decision', 'Error' or 'Ready' - or 'all' /
     *        null for every actionable status (older clients)
     * @return SelloutItemPage holding the page's items, the total count for the view and whether
     *         further pages exist
     */
    @AuraEnabled(cacheable=false)
    public static SelloutItemPage getSelloutItemPage(
        String reportId,
        Integer pageSize,
        Integer rowOffset,
        Boolean errorsOnly,
        String statusFilter
    ) {
        SelloutItemPage result = new SelloutItemPage();

        if (String.isBlank(reportId)) {
            return result;
        }

        Integer limitSize = (pageSize == null || pageSize <= 0) ? REVIEW_PAGE_SIZE : pageSize;
        Integer skip = (rowOffset == null || rowOffset < 0) ? 0 : rowOffset;

        // The account-decision view lists the names still awaiting a decision first, then the names
        // already left out, so a decision taken is as visible as one still to take
        if (statusFilter == ACCOUNT_DECISION_FILTER) {
            try {
                Set<String> decisionStatuses = new Set<String>{ 'Pending_Decision' };
                Integer awaitingTotal = [
                    SELECT COUNT()
                    FROM SLO_Sellout_Item__c
                    WHERE SLO_Sellout_Report__c = :reportId
                    AND SLO_Processing_Status__c IN :decisionStatuses
                ];
                List<SLO_Sellout_Item__c> setAside = readSkippedAccountItems(reportId);
                result.totalCount = awaitingTotal + setAside.size();

                if (skip >= result.totalCount) {
                    return result;
                }

                if (skip < awaitingTotal && skip < MAX_REVIEW_OFFSET) {
                    result.items.addAll(
                        queryReviewItems(reportId, decisionStatuses, limitSize, skip)
                    );
                }

                // A page that runs past the rows awaiting a decision is topped up with the names
                // already left out, so the two blocks read as one list
                if (result.items.size() < limitSize) {
                    Integer setAsideSkip = skip > awaitingTotal ? skip - awaitingTotal : 0;
                    for (Integer i = setAsideSkip;
                            i < setAside.size() && result.items.size() < limitSize; i++) {
                        result.items.add(setAside[i]);
                    }
                }

                result.hasMore = (skip + result.items.size()) < result.totalCount
                    && !result.items.isEmpty();
            } catch (Exception e) {
                throw new AuraHandledException(
                    'Unable to load the account decisions: ' + e.getMessage()
                );
            }
            return result;
        }

        Set<String> statuses = resolveReviewStatuses(errorsOnly, statusFilter);
        // Only a view that mixes error rows with others needs the error block read first. A view of
        // one status, or the ready view - which holds no error rows at all - is read as one block.
        Boolean singleBlock = !(statuses.contains('Error') && statuses.size() > 1);

        try {
            result.totalCount = [
                SELECT COUNT()
                FROM SLO_Sellout_Item__c
                WHERE SLO_Sellout_Report__c = :reportId
                AND SLO_Processing_Status__c IN :statuses
            ];

            if (skip >= result.totalCount || skip >= MAX_REVIEW_OFFSET) {
                return result;
            }

            // Errors are read as their own block first, because a picklist orders by its own value
            // order rather than putting Error at the top
            Integer errorTotal = singleBlock
                ? result.totalCount
                : [
                    SELECT COUNT()
                    FROM SLO_Sellout_Item__c
                    WHERE SLO_Sellout_Report__c = :reportId
                    AND SLO_Processing_Status__c = 'Error'
                ];

            List<SLO_Sellout_Item__c> page = new List<SLO_Sellout_Item__c>();

            if (skip < errorTotal) {
                page.addAll(queryReviewItems(
                    reportId,
                    singleBlock ? statuses : new Set<String>{ 'Error' },
                    limitSize,
                    skip
                ));
            }

            // A page that starts inside the error block but runs past its end is topped up with the
            // pending rows that follow, so the user never sees a short page mid-list
            if (page.size() < limitSize && !singleBlock) {
                Integer pendingSkip = skip > errorTotal ? skip - errorTotal : 0;
                Integer pendingLimit = limitSize - page.size();
                if (pendingSkip < MAX_REVIEW_OFFSET) {
                    page.addAll(queryReviewItems(
                        reportId,
                        new Set<String>{ 'Pending', 'Pending_Decision', 'Matched' },
                        pendingLimit,
                        pendingSkip
                    ));
                }
            }

            result.items = page;
            result.hasMore = (skip + page.size()) < result.totalCount
                && (skip + page.size()) < MAX_REVIEW_OFFSET
                && !page.isEmpty();
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load the review items: ' + e.getMessage());
        }

        return result;
    }

    // A "load all" chunk. Bigger than a display page because the user has asked for everything, but
    // still bounded so one call cannot blow the query row limit.
    private static final Integer LOAD_ALL_CHUNK_SIZE = 1000;

    /**
     * @description Read the next chunk of every actionable row in a report, walking forward on Id.
     * OFFSET cannot go past 2000 rows, so "Load All" pages on the last Id it saw instead, letting the
     * client pull an entire large file in a few calls.
     * @param reportId ID of the sellout report
     * @param lastItemId Id of the last row already loaded; blank to start from the beginning
     * @param errorsOnly True to restrict the chunk to rows that failed (older clients)
     * @param statusFilter The view to list - 'Pending_Decision', 'Error' or 'Ready' - or 'all' /
     *        null for every actionable status (older clients)
     * @return SelloutItemPage holding this chunk, the total count for the view and whether more remain
     */
    @AuraEnabled(cacheable=false)
    public static SelloutItemPage getActionableItemsAfter(
        String reportId,
        String lastItemId,
        Boolean errorsOnly,
        String statusFilter
    ) {
        SelloutItemPage result = new SelloutItemPage();

        if (String.isBlank(reportId)) {
            return result;
        }

        Set<String> statuses = resolveReviewStatuses(errorsOnly, statusFilter);

        try {
            result.totalCount = [
                SELECT COUNT()
                FROM SLO_Sellout_Item__c
                WHERE SLO_Sellout_Report__c = :reportId
                AND SLO_Processing_Status__c IN :statuses
            ];

            // An empty cursor starts before every possible Id, so the same query serves both the
            // first call and every continuation
            Id cursor = String.isBlank(lastItemId) ? null : (Id) lastItemId;

            List<SLO_Sellout_Item__c> chunk = cursor == null
                ? [
                    SELECT Id, Name, SLO_Item_Date__c, SLO_Product_Code_EAN__c,
                           SLO_Quantity__c, SLO_Customer_Account_Name__c,
                           SLO_Processing_Status__c, SLO_Processing_Notes__c
                    FROM SLO_Sellout_Item__c
                    WHERE SLO_Sellout_Report__c = :reportId
                    AND SLO_Processing_Status__c IN :statuses
                    ORDER BY Id ASC
                    LIMIT :LOAD_ALL_CHUNK_SIZE
                ]
                : [
                    SELECT Id, Name, SLO_Item_Date__c, SLO_Product_Code_EAN__c,
                           SLO_Quantity__c, SLO_Customer_Account_Name__c,
                           SLO_Processing_Status__c, SLO_Processing_Notes__c
                    FROM SLO_Sellout_Item__c
                    WHERE SLO_Sellout_Report__c = :reportId
                    AND SLO_Processing_Status__c IN :statuses
                    AND Id > :cursor
                    ORDER BY Id ASC
                    LIMIT :LOAD_ALL_CHUNK_SIZE
                ];

            result.items = chunk;
            result.hasMore = (chunk.size() == LOAD_ALL_CHUNK_SIZE);

            // The account-decision view also holds the names already left out. They are Skipped, so
            // the cursor above never reaches them - they are appended once its rows run out, keeping
            // every account decision in the one list.
            if (statusFilter == ACCOUNT_DECISION_FILTER && !result.hasMore) {
                List<SLO_Sellout_Item__c> setAside = readSkippedAccountItems(reportId);
                result.items.addAll(setAside);
                result.totalCount += setAside.size();
            } else if (statusFilter == ACCOUNT_DECISION_FILTER) {
                result.totalCount += countSkippedAccountItems(reportId);
            }
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load the remaining items: ' + e.getMessage());
        }

        return result;
    }

    /**
     * @description Counts-only summary of what a finished report actually did, so a completed report
     * opens as a read-only result rather than an editable list that could be applied twice
     * @param reportId ID of the sellout report
     * @return SelloutSummary holding the invoice, line, duplicate and error totals
     */
    @AuraEnabled(cacheable=false)
    public static SelloutSummary getReportSummary(String reportId) {
        SelloutSummary summary = new SelloutSummary();

        if (String.isBlank(reportId)) {
            return summary;
        }

        try {
            SLO_Sellout_Report__c report = [
                SELECT Id, Name, SLO_Status__c, SLO_Total_Items__c, SLO_Import_Date__c,
                       SLO_Accounts_Created__c, SLO_Auto_Accepted__c
                FROM SLO_Sellout_Report__c
                WHERE Id = :reportId
                LIMIT 1
            ];

            summary.accountsCreated = report.SLO_Accounts_Created__c != null
                ? report.SLO_Accounts_Created__c.intValue()
                : 0;
            summary.autoAccepted = report.SLO_Auto_Accepted__c == true;
            summary.reportName = report.Name;
            summary.status = report.SLO_Status__c;
            summary.importDate = report.SLO_Import_Date__c;
            summary.totalItems = report.SLO_Total_Items__c != null
                ? report.SLO_Total_Items__c.intValue()
                : 0;

            Integer storedItems = 0;
            for (AggregateResult ar : [
                SELECT SLO_Processing_Status__c itemStatus, COUNT(Id) itemCount
                FROM SLO_Sellout_Item__c
                WHERE SLO_Sellout_Report__c = :reportId
                GROUP BY SLO_Processing_Status__c
            ]) {
                String itemStatus = (String) ar.get('itemStatus');
                Integer itemCount = ((Decimal) ar.get('itemCount')).intValue();
                storedItems += itemCount;

                if (itemStatus == 'Invoice_Created') {
                    summary.linesInvoiced = itemCount;
                } else if (itemStatus == 'Skipped') {
                    summary.duplicatesSkipped = itemCount;
                } else if (itemStatus == STATUS_ENFORCED_SKIPPED) {
                    summary.enforcedSkipped = itemCount;
                } else if (itemStatus == 'Error') {
                    summary.errors = itemCount;
                }
            }

            if (summary.errors > 0) {
                for (SLO_Sellout_Item__c errItem : [
                    SELECT Id, SLO_Customer_Account_Name__c, SLO_Product_Code_EAN__c, SLO_Processing_Notes__c
                    FROM SLO_Sellout_Item__c
                    WHERE SLO_Sellout_Report__c = :reportId
                    AND SLO_Processing_Status__c = 'Error'
                    ORDER BY CreatedDate
                    LIMIT 100
                ]) {
                    SelloutErrorDetail detail = new SelloutErrorDetail();
                    detail.itemId = errItem.Id;
                    detail.customerName = errItem.SLO_Customer_Account_Name__c;
                    detail.productCode = errItem.SLO_Product_Code_EAN__c;
                    detail.message = String.isBlank(errItem.SLO_Processing_Notes__c)
                        ? 'No error message was recorded for this row.'
                        : errItem.SLO_Processing_Notes__c;
                    summary.errorDetails.add(detail);
                }
            }

            // A report imported before duplicates were kept has rows in its total that produced no
            // item at all. Those rows were duplicates, so they are counted as skipped rather than
            // quietly disappearing from the summary.
            if (summary.totalItems > storedItems) {
                summary.duplicatesSkipped += summary.totalItems - storedItems;
            }

            // Distinct invoices, since several lines of the same customer share one invoice
            for (AggregateResult ar : [
                SELECT COUNT_DISTINCT(Invoice_Number__c) invoiceTotal
                FROM Invoice_Line_Item__c
                WHERE Invoice_Number__c != null
                AND Id IN (
                    SELECT SLO_Invoice_Line_Item__c
                    FROM SLO_Sellout_Item__c
                    WHERE SLO_Sellout_Report__c = :reportId
                    AND SLO_Invoice_Line_Item__c != null
                )
            ]) {
                String invoiceTotal = String.valueOf(ar.get('invoiceTotal'));
                summary.invoicesCreated = String.isBlank(invoiceTotal) ? 0 : Integer.valueOf(invoiceTotal);
            }
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load the report summary: ' + e.getMessage());
        }

        return summary;
    }

    /**
     * @description Resolve one unmatched row on the spot - create the account, activate the existing
     * one, or skip the row - so the user can decide row by row inside the review list
     * @param reportId ID of the sellout report the row belongs to
     * @param parentAccountId ID of the account the sellout is being applied to
     * @param customerAccountName Customer name on the row being resolved
     * @param action 'create', 'activate' or 'skip'
     * @param existingAccountId Account to activate; only read when the action is 'activate'
     * @return BulkResolveResult describing what the single decision did
     */
    @AuraEnabled(cacheable=false)
    public static BulkResolveResult resolveUnmatchedRow(
        String reportId,
        String parentAccountId,
        String customerAccountName,
        String action,
        String existingAccountId
    ) {
        assertReportEditable(reportId);
        // One decision is just a bulk run of size one, so the create/activate/skip rules and the
        // duplicate-rule handling stay in a single place
        UnmatchedDecision decision = new UnmatchedDecision();
        decision.customerAccountName = customerAccountName;
        decision.action = action;
        decision.existingAccountId = existingAccountId;

        // Invoicing is deliberately not started here - the user is mid-review and applies the whole
        // list once with Apply Sellout
        return applyUnmatchedDecisions(
            reportId,
            parentAccountId,
            new List<UnmatchedDecision>{ decision },
            false
        );
    }

    /**
     * @description Read one bounded slice of a report's items at the given statuses, selecting only
     * the fields the review list displays. Rows are ordered by product code so every line carrying
     * the same code sits together in the list, which is how the review screen is worked: one code is
     * corrected and its whole block follows.
     * @param reportId ID of the sellout report
     * @param statuses Processing statuses to include
     * @param limitSize Maximum rows to return
     * @param skip Rows to skip before the slice
     * @return List of sellout items
     */
    private static List<SLO_Sellout_Item__c> queryReviewItems(
        String reportId,
        Set<String> statuses,
        Integer limitSize,
        Integer skip
    ) {
        return [
            SELECT Id, Name, SLO_Item_Date__c, SLO_Product_Code_EAN__c,
                   SLO_Quantity__c, SLO_Customer_Account_Name__c,
                   SLO_Processing_Status__c, SLO_Processing_Notes__c
            FROM SLO_Sellout_Item__c
            WHERE SLO_Sellout_Report__c = :reportId
            AND SLO_Processing_Status__c IN :statuses
            ORDER BY SLO_Product_Code_EAN__c ASC NULLS LAST, CreatedDate ASC, Id ASC
            LIMIT :limitSize
            OFFSET :skip
        ];
    }

    // How many skipped rows are scanned when picking out the ones set aside on the accounts step. The
    // reason lives in the note, and a long text area cannot be filtered in SOQL, so the rows are read
    // and sifted in Apex. The scan has to be able to reach past the whole duplicate block: on a file
    // where nearly every line was already recorded, a handful of set-aside names sit among thousands
    // of skipped duplicates, and a scan that stops short of them reports none and leaves the badge
    // reading zero while the view lists them. The query reads two fields and iterates in batches, so
    // a bound this size costs query rows rather than heap.
    private static final Integer SKIPPED_SCAN_LIMIT = 20000;

    // How many set-aside lines the account-decision view will list. The names left out are meant to
    // be read back, not paged through in their thousands, so the list stops here.
    private static final Integer SKIPPED_DISPLAY_LIMIT = 2000;

    /**
     * @description Find the report's lines set aside on the accounts step: skipped rows whose note
     * records an account decision, so duplicates, zero-quantity rows and lines left uncorrected are
     * left out. Scans at most SKIPPED_SCAN_LIMIT skipped rows, reading only what the sift needs.
     * @param reportId ID of the sellout report
     * @return Ids of the skipped account-decision lines
     */
    private static List<Id> findSkippedAccountItemIds(String reportId) {
        List<Id> setAsideIds = new List<Id>();

        if (String.isBlank(reportId)) {
            return setAsideIds;
        }

        // One request can want both the count and the rows - the badge and the list are refreshed
        // together - and this scan reaches across the whole skipped block, so it is run once per
        // report per transaction rather than once per caller
        if (skippedAccountIdCache.containsKey(reportId)) {
            return skippedAccountIdCache.get(reportId);
        }

        for (SLO_Sellout_Item__c item : [
            SELECT Id, SLO_Processing_Notes__c
            FROM SLO_Sellout_Item__c
            WHERE SLO_Sellout_Report__c = :reportId
            AND SLO_Processing_Status__c = 'Skipped'
            ORDER BY Id ASC
            LIMIT :SKIPPED_SCAN_LIMIT
        ]) {
            if (item.SLO_Processing_Notes__c == NOTE_ACCOUNT_DECLINED) {
                setAsideIds.add(item.Id);
            }
        }

        skippedAccountIdCache.put(reportId, setAsideIds);
        return setAsideIds;
    }

    // Per-transaction memo of the scan above, keyed on report Id. Only ever holds Ids, and a single
    // request only touches one report, so it stays small.
    private static Map<String, List<Id>> skippedAccountIdCache = new Map<String, List<Id>>();

    /**
     * @description Read the report's lines set aside on the accounts step, in full, for listing on
     * the account-decision view alongside the names still awaiting a decision
     * @param reportId ID of the sellout report
     * @return The skipped account-decision lines, ordered by customer name
     */
    private static List<SLO_Sellout_Item__c> readSkippedAccountItems(String reportId) {
        List<Id> setAsideIds = findSkippedAccountItemIds(reportId);

        if (setAsideIds.isEmpty()) {
            return new List<SLO_Sellout_Item__c>();
        }

        return [
            SELECT Id, Name, SLO_Item_Date__c, SLO_Product_Code_EAN__c,
                   SLO_Quantity__c, SLO_Customer_Account_Name__c,
                   SLO_Processing_Status__c, SLO_Processing_Notes__c
            FROM SLO_Sellout_Item__c
            WHERE Id IN :setAsideIds
            ORDER BY SLO_Customer_Account_Name__c ASC, Id ASC
            LIMIT :SKIPPED_DISPLAY_LIMIT
        ];
    }

    /**
     * @description Count the report's lines set aside on the accounts step, for the badge and the
     * view picker. Counted from the light scan, so the number matches the rows the view lists.
     * @param reportId ID of the sellout report
     * @return Number of lines skipped by an account decision
     */
    public static Integer countSkippedAccountItems(String reportId) {
        return findSkippedAccountItemIds(reportId).size();
    }


    /**
     * @description Count a report's items by processing status, so the review screen can show how
     * many items are ready, in error or skipped without loading the items themselves
     * @param reportId ID of the sellout report
     * @return Map of processing status to item count, plus Rows_Loaded holding the number of rows
     *         read from the imported file; the statuses shown in the UI are always present,
     *         defaulting to zero
     */
    @AuraEnabled(cacheable=false)
    public static Map<String, Integer> getItemStatusCounts(String reportId) {
        // Seeded so the summary bar always has a number to show for each status it displays
        Map<String, Integer> counts = new Map<String, Integer>{
            'Pending' => 0,
            'Pending_Decision' => 0,
            'Matched' => 0,
            'Invoice_Created' => 0,
            'Error' => 0,
            'Skipped' => 0,
            'Enforced_Skipped' => 0,
            'Duplicate' => 0,
            // The share of Skipped rows the user set aside on the accounts step, counted separately
            // so its own view can carry a badge
            'Skipped_Accounts' => 0,
            // Recorded on the report itself, so the screen can still say how much of the file was
            // read even when the import produced no items at all
            'Rows_Loaded' => 0
        };

        if (String.isBlank(reportId)) {
            return counts;
        }

        for (SLO_Sellout_Report__c report : [
            SELECT SLO_Total_Items__c
            FROM SLO_Sellout_Report__c
            WHERE Id = :reportId
            LIMIT 1
        ]) {
            if (report.SLO_Total_Items__c != null) {
                counts.put('Rows_Loaded', report.SLO_Total_Items__c.intValue());
            }
        }

        for (AggregateResult ar : [
            SELECT SLO_Processing_Status__c itemStatus, COUNT(Id) itemCount
            FROM SLO_Sellout_Item__c
            WHERE SLO_Sellout_Report__c = :reportId
            GROUP BY SLO_Processing_Status__c
        ]) {
            String itemStatus = (String) ar.get('itemStatus');
            Integer itemCount = ((Decimal) ar.get('itemCount')).intValue();

            // An item with no status set yet is still awaiting processing
            String key = String.isBlank(itemStatus) ? 'Pending' : itemStatus;
            counts.put(key, counts.containsKey(key) ? counts.get(key) + itemCount : itemCount);
        }

        // Only worth a second query when something was skipped at all
        if (counts.get('Skipped') > 0) {
            counts.put('Skipped_Accounts', countSkippedAccountItems(reportId));
        }

        return counts;
    }

    /**
     * @description Save inline edits and immediately re-validate what the edits touched, so each
     * row's status and note reflect its new values without waiting for the next processing run.
     * The report's other actionable rows sharing the edited customer names are re-checked too,
     * because an edit can create or clear a duplicate or a quantity conflict with a sibling row.
     * @param items Sellout items carrying the edited field values
     * @return The re-validated rows - the edited ones and any affected siblings - with their new
     *         status and notes, so the client can refresh them in place
     */
    @AuraEnabled(cacheable=false)
    public static List<SLO_Sellout_Item__c> updateSelloutItems(List<SLO_Sellout_Item__c> items) {
        if (items == null || items.isEmpty()) {
            return new List<SLO_Sellout_Item__c>();
        }

        List<String> editedIds = new List<String>();
        for (SLO_Sellout_Item__c edited : items) {
            if (edited.Id != null) {
                editedIds.add(edited.Id);
            }
        }
        assertItemsEditable(editedIds);

        update items;

        try {
            return revalidateEditedItems(new Map<Id, SLO_Sellout_Item__c>(items).keySet());
        } catch (Exception e) {
            // The save itself succeeded, so never fail the request over the re-check - return the
            // edited rows as they now stand and let the next full validation catch up
            System.debug(LoggingLevel.ERROR, 'Re-validation after edit failed: ' + e.getMessage());
            return [
                SELECT Id, Name, SLO_Item_Date__c, SLO_Product_Code_EAN__c, SLO_Quantity__c,
                       SLO_Customer_Account_Name__c, SLO_Matched_Account__c,
                       SLO_Processing_Status__c, SLO_Processing_Notes__c
                FROM SLO_Sellout_Item__c
                WHERE Id IN :new Map<Id, SLO_Sellout_Item__c>(items).keySet()
            ];
        }
    }

    // Statuses a re-validation may rewrite on a row the user did NOT edit. A Skipped sibling carries
    // a decision of its own and an Invoice_Created one a finished result, so neither is reopened by
    // an edit to some other row.
    private static final Set<String> REVALIDATABLE_STATUSES = new Set<String>{
        'Pending', 'Pending_Decision', 'Matched', 'Error', 'Duplicate'
    };

    // A row the user edited is always re-checked, whatever status it was sitting at - a line set
    // aside on the accounts step must be able to come back once its customer name is corrected,
    // rather than staying Skipped for good. Only an invoiced line is untouchable, because its
    // figures have already been written to an invoice.
    private static final String STATUS_INVOICED = 'Invoice_Created';

    // How many same-name sibling rows one edit re-checks alongside the row the user changed. Bounded
    // so a customer name carrying thousands of rows cannot make a single cell edit exceed the
    // transaction limits - the edited row itself is always re-checked regardless.
    private static final Integer REVALIDATE_SIBLING_LIMIT = 200;

    /**
     * @description Re-run account matching and data validation for the edited rows and the
     * same-report rows sharing their customer names
     * @param editedIds Ids of the rows the user edited
     * @return Every row that was re-validated, with its new status and notes
     */
    private static List<SLO_Sellout_Item__c> revalidateEditedItems(Set<Id> editedIds) {
        return revalidateEditedItems(editedIds, true);
    }

    /**
     * @description Re-run account matching and data validation for the edited rows, optionally
     * widening to the same-report rows sharing their customer names
     * @param editedIds Ids of the rows the user edited
     * @param includeSiblings True for a single cell edit, where an edit can create or clear a
     *        duplicate on a row the user did not touch. False for a bulk correction: the rows the
     *        user ticked are already the whole block that shared the problem, and pulling in up to
     *        200 extra rows per pass is what pushed a large correction past the transaction's
     *        query-row ceiling and failed the whole action.
     * @return Every row that was re-validated, with its new status and notes
     */
    private static List<SLO_Sellout_Item__c> revalidateEditedItems(
        Set<Id> editedIds,
        Boolean includeSiblings
    ) {
        List<SLO_Sellout_Item__c> revalidated = new List<SLO_Sellout_Item__c>();

        // Establish which reports the edited rows belong to (a save is normally one report) and
        // which customer names the edits now carry
        Map<Id, Id> reportToAccount = new Map<Id, Id>();
        Map<Id, Set<String>> reportToNames = new Map<Id, Set<String>>();
        for (SLO_Sellout_Item__c item : [
            SELECT Id, SLO_Customer_Account_Name__c, SLO_Sellout_Report__c,
                   SLO_Sellout_Report__r.SLO_Account__c
            FROM SLO_Sellout_Item__c
            WHERE Id IN :editedIds
        ]) {
            reportToAccount.put(item.SLO_Sellout_Report__c, item.SLO_Sellout_Report__r.SLO_Account__c);
            if (!reportToNames.containsKey(item.SLO_Sellout_Report__c)) {
                reportToNames.put(item.SLO_Sellout_Report__c, new Set<String>());
            }
            if (String.isNotBlank(item.SLO_Customer_Account_Name__c)) {
                reportToNames.get(item.SLO_Sellout_Report__c)
                    .add(item.SLO_Customer_Account_Name__c.trim());
            }
        }

        for (Id reportId : reportToAccount.keySet()) {
            Id accountId = reportToAccount.get(reportId);
            Set<String> names = reportToNames.get(reportId);

            // The affected set: the edited rows first - they must always be re-checked, whatever
            // else the report holds - then the report's other actionable rows carrying the same
            // customer names, which is where a new duplicate or quantity conflict can land.
            // Rows that shared an edited row's OLD name keep their state until they are edited
            // themselves; their note still says what to check.
            // An edited row is re-checked from ANY status but Invoice_Created, so a line set aside
            // on the accounts step is released the moment its customer name is corrected instead of
            // staying Skipped for good.
            Map<Id, SLO_Sellout_Item__c> affectedById = new Map<Id, SLO_Sellout_Item__c>([
                SELECT Id, Name, SLO_Item_Date__c, SLO_Product_Code_EAN__c, SLO_Quantity__c,
                       SLO_Customer_Account_Name__c, SLO_Matched_Account__c,
                       SLO_Processing_Status__c, SLO_Processing_Notes__c, SLO_Sellout_Report__c
                FROM SLO_Sellout_Item__c
                WHERE SLO_Sellout_Report__c = :reportId
                AND SLO_Processing_Status__c != :STATUS_INVOICED
                AND Id IN :editedIds
            ]);

            // Siblings are bounded: on a large file one customer name can carry thousands of rows,
            // and an unbounded re-check would breach the transaction limits and leave the edit
            // looking as though it had not saved at all. The rest are re-checked by the next run.
            if (includeSiblings == true && names != null && !names.isEmpty()) {
                for (SLO_Sellout_Item__c sibling : [
                    SELECT Id, Name, SLO_Item_Date__c, SLO_Product_Code_EAN__c, SLO_Quantity__c,
                           SLO_Customer_Account_Name__c, SLO_Matched_Account__c,
                           SLO_Processing_Status__c, SLO_Processing_Notes__c, SLO_Sellout_Report__c
                    FROM SLO_Sellout_Item__c
                    WHERE SLO_Sellout_Report__c = :reportId
                    AND SLO_Processing_Status__c IN :REVALIDATABLE_STATUSES
                    AND SLO_Customer_Account_Name__c IN :names
                    AND Id NOT IN :editedIds
                    ORDER BY Id ASC
                    LIMIT :REVALIDATE_SIBLING_LIMIT
                ]) {
                    affectedById.put(sibling.Id, sibling);
                }
            }

            if (affectedById.isEmpty()) {
                continue;
            }

            List<SLO_Sellout_Item__c> affected = affectedById.values();

            // Matching first: give every affected row the status its account name earns...
            Map<String, Id> nameToId = new Map<String, Id>();
            Map<String, String> nameToStatus = new Map<String, String>();
            buildAccountNameMaps(getHierarchyAccounts(accountId), nameToId, nameToStatus);
            // ...including the accounts these rows are already pointed at. An account chosen or
            // created by an earlier decision can sit outside the hierarchy the maps were built from
            // (a child recorded under another billing country, for instance), and without it a line
            // that is genuinely ready would be sent back to "account decision" every time another
            // cell on it was corrected - which is why a fixed product code left the Ready count at
            // zero. Registered under the name the row carries, and only where the hierarchy has
            // nothing better, so a real hierarchy match always wins.
            registerMatchedAccounts(affectedById.values(), accountId, nameToId, nameToStatus);

            for (SLO_Sellout_Item__c item : affected) {
                rematchItem(item, nameToId, nameToStatus);
            }

            // ...then validation, which overrides with Skipped (exact duplicate) or Error (unknown
            // product code, quantity conflict) where the data itself is the problem. The affected
            // rows' own Ids are excluded from the comparison so no row is compared against itself.
            validateItemsForAccount(
                affected, accountId, new Map<Id, SLO_Sellout_Item__c>(affected).keySet()
            );

            update affected;
            revalidated.addAll(affected);
        }

        return revalidated;
    }

    /**
     * @description Give one row the status its account name earns: Skipped for a zero quantity,
     * Matched with the account set for an active match, Pending_Decision otherwise. Mirrors the
     * matching pass, so an edited row lands in the same state a fresh import would give it.
     * @param item Row to rematch; status, notes and matched account are set in place
     * @param nameToId Case-insensitive account name key to account Id
     * @param nameToStatus Case-insensitive account name key to account status
     */
    private static void rematchItem(
        SLO_Sellout_Item__c item,
        Map<String, Id> nameToId,
        Map<String, String> nameToStatus
    ) {
        if (item.SLO_Quantity__c == null || item.SLO_Quantity__c == 0) {
            item.SLO_Processing_Status__c = 'Skipped';
            item.SLO_Processing_Notes__c = NOTE_ZERO_QUANTITY;
            return;
        }

        String key = nameKey(item.SLO_Customer_Account_Name__c);

        if (nameToId.containsKey(key) && nameToStatus.get(key) != 'N') {
            item.SLO_Matched_Account__c = nameToId.get(key);
            item.SLO_Processing_Status__c = 'Matched';
            item.SLO_Processing_Notes__c = NOTE_READY;
            return;
        }

        // No usable match - an inactive account, or no account at all: the user decides
        item.SLO_Matched_Account__c = null;
        item.SLO_Processing_Status__c = 'Pending_Decision';
        item.SLO_Processing_Notes__c = nameToId.containsKey(key)
            ? NOTE_ACCOUNT_INACTIVE
            : NOTE_ACCOUNT_NOT_FOUND;
    }

    /**
     * @description Add the accounts the rows are already pointed at to the name maps, so a row whose
     * customer name was matched or created earlier still resolves when it is re-checked. Only names
     * the hierarchy does not already answer for are added, and only active accounts, so a live
     * hierarchy match always takes precedence and a deactivated account still sends its rows back
     * for a decision.
     * Accounts outside the report account's own hierarchy (the account, its children and
     * grandchildren) are never registered, so a stale match to another distributor's account is
     * not carried forward.
     * @param items Rows about to be rematched
     * @param accountId Report account whose hierarchy bounds the registered accounts
     * @param nameToId Name key to account Id, added to in place
     * @param nameToStatus Name key to account status, added to in place
     */
    private static void registerMatchedAccounts(
        List<SLO_Sellout_Item__c> items,
        Id accountId,
        Map<String, Id> nameToId,
        Map<String, String> nameToStatus
    ) {
        Map<Id, String> nameKeyByAccountId = new Map<Id, String>();
        for (SLO_Sellout_Item__c item : items) {
            String key = nameKey(item.SLO_Customer_Account_Name__c);
            if (item.SLO_Matched_Account__c == null
                    || String.isBlank(key)
                    || nameToId.containsKey(key)) {
                continue;
            }
            nameKeyByAccountId.put(item.SLO_Matched_Account__c, key);
        }

        if (nameKeyByAccountId.isEmpty()) {
            return;
        }

        for (Account account : [
            SELECT Id, Status__c
            FROM Account
            WHERE Id IN :nameKeyByAccountId.keySet()
            AND (Id = :accountId OR ParentId = :accountId OR Parent.ParentId = :accountId)
        ]) {
            String key = nameKeyByAccountId.get(account.Id);
            if (nameToId.containsKey(key)) {
                continue;
            }
            nameToId.put(key, account.Id);
            nameToStatus.put(key, account.Status__c);
        }
    }

    /**
     * @description Read the accounts a sellout row may match, in match-precedence order: the main
     * account, then its children, then grandchildren, with children and grandchildren filtered to
     * the main account's billing country. Shared by the matching batch and re-validation so both
     * see the same hierarchy.
     * @param accountId Main account Id
     * @return Accounts carrying the fields the name maps need
     */
    public static List<Account> getHierarchyAccounts(Id accountId) {
        Account current = [
            SELECT Id, Name, BillingCountry, Status__c
            FROM Account
            WHERE Id = :accountId
            LIMIT 1
        ];
        String billingCountry = current.BillingCountry;

        List<Account> hierarchy = new List<Account>{ current };

        List<Account> children = [
            SELECT Id, Name, Status__c
            FROM Account
            WHERE ParentId = :accountId
            AND BillingCountry = :billingCountry
        ];
        hierarchy.addAll(children);

        Set<Id> childIds = new Map<Id, Account>(children).keySet();
        if (!childIds.isEmpty()) {
            hierarchy.addAll([
                SELECT Id, Name, Status__c
                FROM Account
                WHERE ParentId IN :childIds
                AND BillingCountry = :billingCountry
            ]);
        }

        return hierarchy;
    }

    /**
     * @description Counts of the rows each validation check flagged
     */
    public class ValidationCounts {
        public Integer duplicates = 0;
        public Integer productErrors = 0;
        public Integer quantityConflicts = 0;
    }

    /**
     * @description Validate rows against the account's recorded history and the product catalogue,
     * so data problems surface in the review list instead of failing later during invoice creation.
     * The comparison set is what was genuinely recorded for the account - other reports' rows at
     * Matched or Invoice_Created, plus this report's own non-skipped rows - never the leftovers of
     * an abandoned or errored earlier upload. Three checks, in order of precedence per row:
     *  - an exact duplicate (same customer, product, date and quantity) is Skipped with the
     *    duplicate note - already recorded, nothing to fix;
     *  - a product code that resolves to no product is an Error - the code needs correcting;
     *  - a row whose customer, product and date an EARLIER REPORT recorded with a DIFFERENT
     *    quantity is an Error - one of the two figures is wrong and the user has to decide which.
     *    Within one file, two lines for the same customer, product and date with different
     *    quantities are two orders, not a conflict - sellout statistics are per order line.
     * Rows already Skipped or Invoice_Created are never touched, and a clean row keeps whatever
     * status it arrived with, so the caller decides what a valid row becomes. Rows earlier in the
     * list count as recorded for the duplicate check on the rows after them, so a file that
     * repeats a line is caught before anything is saved.
     * @param items Rows to validate; status and notes are set in place
     * @param accountId Parent account whose recorded items are the comparison set
     * @param excludeItemIds Stored item Ids to leave out of the comparison set - pass the items'
     *        own Ids when re-validating stored rows, so a row is never compared against itself
     * @return ValidationCounts with the number of rows each check flagged
     */
    public static ValidationCounts validateItemsForAccount(
        List<SLO_Sellout_Item__c> items,
        Id accountId,
        Set<Id> excludeItemIds
    ) {
        return validateItemsForAccount(items, accountId, excludeItemIds, null);
    }

    // How an exact duplicate is treated: set aside as Skipped (default), diverted to the Duplicates
    // section for a decision, or processed like any other line
    public static final String DUP_MODE_SKIP = 'skip';
    public static final String DUP_MODE_SECTION = 'section';
    public static final String DUP_MODE_PROCESS = 'process';
    public static final String STATUS_DUPLICATE = 'Duplicate';
    public static final String NOTE_DUPLICATE_REVIEW =
        'Duplicate - an identical line is already recorded; enforce skip or edit it to process it';

    /**
     * @description Same validation with an explicit duplicate treatment
     * @param duplicateMode skip, section or process; null detects section when the report already
     *        holds Duplicate rows and otherwise skips
     */
    public static ValidationCounts validateItemsForAccount(
        List<SLO_Sellout_Item__c> items,
        Id accountId,
        Set<Id> excludeItemIds,
        String duplicateMode
    ) {
        ValidationCounts counts = new ValidationCounts();

        if (items == null || items.isEmpty()) {
            return counts;
        }

        Set<Id> excluded = excludeItemIds == null ? new Set<Id>() : excludeItemIds;

        Set<String> productCodes = new Set<String>();
        // The customer names the rows carry, which is all the comparison set can usefully hold: a
        // duplicate or a quantity conflict only ever involves a row with the SAME customer name.
        // Narrowing the comparison query on this is what keeps a single cell edit on a file of
        // thousands of lines inside the transaction's query-row limit - without it the re-check
        // reads every line of every report for the account, fails, and the edited row is left
        // reading as broken however many times it is corrected.
        Set<String> comparisonNames = new Set<String>();
        // The product codes the rows carry, in both their raw and trimmed form. A duplicate or a
        // quantity conflict also requires the SAME product, so narrowing the comparison query on
        // this as well as on the customer name is what keeps a correction of hundreds of lines
        // inside the transaction's query-row ceiling - without it a bulk correction read every line
        // recorded for every one of the selected customers and failed with "Too many query rows".
        Set<String> comparisonCodes = new Set<String>();
        // A row with no product code at all can only ever duplicate another row with no product
        // code, which the code filter cannot express - such a row falls back to the wider query
        Boolean anyBlankCode = false;
        Id currentReportId = null;
        for (SLO_Sellout_Item__c item : items) {
            if (String.isNotBlank(item.SLO_Product_Code_EAN__c)) {
                productCodes.add(item.SLO_Product_Code_EAN__c);
                comparisonCodes.add(item.SLO_Product_Code_EAN__c);
                comparisonCodes.add(item.SLO_Product_Code_EAN__c.trim());
            } else {
                anyBlankCode = true;
            }
            if (String.isNotBlank(item.SLO_Customer_Account_Name__c)) {
                // Both the raw and the trimmed form, so a stored value carrying stray spaces is
                // still read into the comparison set
                comparisonNames.add(item.SLO_Customer_Account_Name__c);
                comparisonNames.add(item.SLO_Customer_Account_Name__c.trim());
            }
            // isSet guards against a caller that queried its rows without the report field -
            // reading an unqueried field throws, and a missed report just widens the comparison
            if (currentReportId == null
                    && item.isSet('SLO_Sellout_Report__c')
                    && item.SLO_Sellout_Report__c != null) {
                currentReportId = item.SLO_Sellout_Report__c;
            }
        }

        String mode = duplicateMode;
        if (mode == null) {
            mode = DUP_MODE_SKIP;
            if (currentReportId != null && [
                SELECT COUNT() FROM SLO_Sellout_Item__c
                WHERE SLO_Sellout_Report__c = :currentReportId
                AND SLO_Processing_Status__c = :STATUS_DUPLICATE
                LIMIT 1
            ] > 0) {
                mode = DUP_MODE_SECTION;
            }
        }

        // "Already recorded" means genuinely recorded, not merely uploaded once: rows of OTHER
        // reports only count once they are Invoice_Created (Ready lines never invoiced stay pending
        // and are picked up by this file) -
        // an abandoned draft, an errored row or a skipped line from an earlier upload must never
        // block this file's rows. Rows of THIS report count at any status except Skipped, so a
        // file that repeats its own lines is still caught whole. Each recorded key remembers its
        // source - the earlier report's name, or this same file - so the notes say where the
        // recorded line lives and overlaps reconcile themselves on the row.
        Set<String> recordedStatuses = new Set<String>{ 'Invoice_Created' };
        Map<String, String> duplicateKeySource = new Map<String, String>();
        Map<String, Decimal> recordedQuantityByGroup = new Map<String, Decimal>();
        Map<String, String> recordedGroupSource = new Map<String, String>();

        // The recorded rows worth comparing against: same account, same customer names and - unless
        // one of the rows has no product code to narrow on - the same product codes
        List<SLO_Sellout_Item__c> comparisonRows;
        if (anyBlankCode || comparisonCodes.isEmpty()) {
            comparisonRows = [
                SELECT Id, SLO_Customer_Account_Name__c, SLO_Product_Code_EAN__c,
                       SLO_Item_Date__c, SLO_Quantity__c, SLO_Processing_Status__c,
                       SLO_Sellout_Report__c, SLO_Sellout_Report__r.Name
                FROM SLO_Sellout_Item__c
                WHERE SLO_Sellout_Report__c IN (
                    SELECT Id FROM SLO_Sellout_Report__c WHERE SLO_Account__c = :accountId
                )
                AND SLO_Customer_Account_Name__c != null
                AND SLO_Customer_Account_Name__c IN :comparisonNames
                AND Id NOT IN :excluded
                AND (
                    SLO_Sellout_Report__c = :currentReportId
                    OR SLO_Processing_Status__c IN :recordedStatuses
                )
            ];
        } else {
            comparisonRows = [
                SELECT Id, SLO_Customer_Account_Name__c, SLO_Product_Code_EAN__c,
                       SLO_Item_Date__c, SLO_Quantity__c, SLO_Processing_Status__c,
                       SLO_Sellout_Report__c, SLO_Sellout_Report__r.Name
                FROM SLO_Sellout_Item__c
                WHERE SLO_Sellout_Report__c IN (
                    SELECT Id FROM SLO_Sellout_Report__c WHERE SLO_Account__c = :accountId
                )
                AND SLO_Customer_Account_Name__c != null
                AND SLO_Customer_Account_Name__c IN :comparisonNames
                AND SLO_Product_Code_EAN__c IN :comparisonCodes
                AND Id NOT IN :excluded
                AND (
                    SLO_Sellout_Report__c = :currentReportId
                    OR SLO_Processing_Status__c IN :recordedStatuses
                )
            ];
        }

        for (SLO_Sellout_Item__c existing : comparisonRows) {
            Boolean sameReport = (existing.SLO_Sellout_Report__c == currentReportId);
            if (sameReport && (existing.SLO_Processing_Status__c == 'Skipped'
                    || existing.SLO_Processing_Status__c == STATUS_DUPLICATE
                    || existing.SLO_Processing_Status__c == STATUS_ENFORCED_SKIPPED)) {
                continue;
            }
            String source = sameReport
                ? SOURCE_THIS_FILE
                : 'report ' + existing.SLO_Sellout_Report__r.Name;
            String existingDuplicateKey = buildDuplicateKey(existing);
            if (!duplicateKeySource.containsKey(existingDuplicateKey)) {
                duplicateKeySource.put(existingDuplicateKey, source);
            }
            // Only an earlier report's figure can conflict: this file's own lines for the same
            // customer, product and date are separate orders
            if (sameReport) {
                continue;
            }
            String existingGroupKey = buildGroupKey(existing);
            if (!recordedQuantityByGroup.containsKey(existingGroupKey)) {
                recordedQuantityByGroup.put(existingGroupKey, existing.SLO_Quantity__c);
                recordedGroupSource.put(existingGroupKey, source);
            }
        }

        Map<String, Id> productIdByCode = resolveProductIdsByEan(productCodes);

        // Re-keyed on the normalized code. The resolver answers on the raw value it was given, so a
        // row whose stored code differs from the resolved one only by padding or stray spacing read
        // as "not found" even though the product had been located - which is what kept a corrected
        // line in "Needs a fix" after a correction that genuinely matched a product.
        Set<String> resolvedNormalizedCodes = new Set<String>();
        for (String resolvedCode : productIdByCode.keySet()) {
            String normalizedResolved = normalizeProductCode(resolvedCode);
            if (normalizedResolved != null) {
                resolvedNormalizedCodes.add(normalizedResolved);
            }
        }

        for (SLO_Sellout_Item__c item : items) {
            if (item.SLO_Processing_Status__c == 'Skipped'
                    || item.SLO_Processing_Status__c == 'Invoice_Created') {
                continue;
            }

            String itemDuplicateKey = buildDuplicateKey(item);
            if (mode == DUP_MODE_SECTION && duplicateKeySource.containsKey(itemDuplicateKey)) {
                item.SLO_Processing_Status__c = STATUS_DUPLICATE;
                item.SLO_Processing_Notes__c = NOTE_DUPLICATE_REVIEW;
                counts.duplicates++;
                continue;
            }
            if (mode != DUP_MODE_PROCESS && duplicateKeySource.containsKey(itemDuplicateKey)) {
                String duplicateSource = duplicateKeySource.get(itemDuplicateKey);
                item.SLO_Processing_Status__c = 'Skipped';
                // Name the earlier report so the overlap reconciles itself on the row; a repeat
                // within the same file needs no pointer
                item.SLO_Processing_Notes__c = SOURCE_THIS_FILE.equals(duplicateSource)
                    ? NOTE_DUPLICATE
                    : NOTE_DUPLICATE + ' (' + duplicateSource + ')';
                counts.duplicates++;
                continue;
            }

            if (String.isBlank(item.SLO_Product_Code_EAN__c)
                    || !resolvedNormalizedCodes.contains(
                        normalizeProductCode(item.SLO_Product_Code_EAN__c)
                    )) {
                item.SLO_Processing_Status__c = 'Error';
                item.SLO_Processing_Notes__c = NOTE_PRODUCT_NOT_FOUND;
                counts.productErrors++;
                registerValidatedRow(item, duplicateKeySource);
                continue;
            }

            String groupKey = buildGroupKey(item);
            Decimal itemQuantity = item.SLO_Quantity__c == null ? 0 : item.SLO_Quantity__c;
            Decimal recordedQuantity = recordedQuantityByGroup.get(groupKey);
            // An identical quantity is a processed duplicate, not a conflict
            if (recordedQuantityByGroup.containsKey(groupKey)
                    && (mode != DUP_MODE_PROCESS
                        || (recordedQuantity == null ? 0 : recordedQuantity) != itemQuantity)) {
                item.SLO_Processing_Status__c = 'Error';
                item.SLO_Processing_Notes__c = buildQuantityConflictNote(
                    recordedQuantityByGroup.get(groupKey),
                    recordedGroupSource.get(groupKey)
                );
                counts.quantityConflicts++;
                registerValidatedRow(item, duplicateKeySource);
                continue;
            }

            // An edited duplicate that is no longer one moves on to Ready
            if (item.SLO_Processing_Status__c == STATUS_DUPLICATE) {
                item.SLO_Processing_Status__c = 'Pending';
                item.SLO_Processing_Notes__c = null;
            }
            // Clean row: clear a stale validation error so a fixed row stops reading as broken,
            // but leave every other status alone - matching decides what a valid row becomes
            if (item.SLO_Processing_Status__c == 'Error'
                    && isValidationNote(item.SLO_Processing_Notes__c)) {
                item.SLO_Processing_Status__c = 'Pending';
                item.SLO_Processing_Notes__c = null;
            }
            registerValidatedRow(item, duplicateKeySource);
        }

        return counts;
    }

    /**
     * @description Count a validated row as recorded for the duplicate check, so an identical
     * line later in the same list is skipped exactly as it would be against a stored row. It is
     * deliberately not registered for the quantity-conflict check: a later line for the same
     * customer, product and date with another quantity is another order in the same file.
     * @param item Row just validated
     * @param duplicateKeySource Recorded 4-field keys to their source, added to in place
     */
    private static void registerValidatedRow(
        SLO_Sellout_Item__c item,
        Map<String, String> duplicateKeySource
    ) {
        String itemDuplicateKey = buildDuplicateKey(item);
        if (!duplicateKeySource.containsKey(itemDuplicateKey)) {
            duplicateKeySource.put(itemDuplicateKey, SOURCE_THIS_FILE);
        }
    }

    /**
     * @description True when a processing note was written by the validator, so only its own
     * errors are ever cleared by a re-check
     * @param note Processing note to inspect
     * @return True for the product-not-found and quantity-conflict notes
     */
    private static Boolean isValidationNote(String note) {
        return note != null
            && (note == NOTE_PRODUCT_NOT_FOUND
                || note.startsWith(NOTE_QUANTITY_CONFLICT_PREFIX)
                // The apply run words its own product failure differently. A corrected code has to
                // clear that note too, or a line flagged during an apply would keep reading as
                // broken however many times it is fixed.
                || note.startsWith(NOTE_APPLY_PRODUCT_NOT_FOUND_PREFIX));
    }

    /**
     * @description The 4-field key that defines an exact duplicate row
     * @param item Row to key
     * @return customer|product|date|quantity, case-insensitive and quantity-normalized
     */
    public static String buildDuplicateKey(SLO_Sellout_Item__c item) {
        return buildGroupKey(item) + '|' +
            (item.SLO_Quantity__c != null
                ? item.SLO_Quantity__c.stripTrailingZeros().toPlainString()
                : '0');
    }

    /**
     * @description The customer|product|date key shared by rows that must agree on quantity
     * @param item Row to key
     * @return Case-insensitive composite key without the quantity
     */
    public static String buildGroupKey(SLO_Sellout_Item__c item) {
        return nameKey(item.SLO_Customer_Account_Name__c) +
            '|' + (item.SLO_Product_Code_EAN__c != null ? item.SLO_Product_Code_EAN__c.trim() : '') +
            '|' + String.valueOf(item.SLO_Item_Date__c);
    }

    /**
     * @description Get status picklist values
     * @return List of status picklist options
     */
    @AuraEnabled(cacheable=false)
    public static List<PicklistOption> getProcessingStatusValues() {
        List<PicklistOption> options = new List<PicklistOption>();
        Schema.DescribeFieldResult fieldResult = SLO_Sellout_Item__c.SLO_Processing_Status__c.getDescribe();
        List<Schema.PicklistEntry> entries = fieldResult.getPicklistValues();

        for (Schema.PicklistEntry entry : entries) {
            if (entry.isActive()) {
                options.add(new PicklistOption(entry.getLabel(), entry.getValue()));
            }
        }
        return options;
    }

    /**
     * @description Wrapper class for picklist options
     */
    public class PicklistOption {
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String value { get; set; }

        public PicklistOption(String label, String value) {
            this.label = label;
            this.value = value;
        }
    }

    /**
     * @description Wrapper class for account matching result
     */
    public class AccountMatchResult {
        @AuraEnabled public List<String> selloutItemIds { get; set; }
        @AuraEnabled public String customerAccountName { get; set; }
        @AuraEnabled public Boolean matched { get; set; }
        @AuraEnabled public String matchType { get; set; }
        @AuraEnabled public Boolean needsUserDecision { get; set; }
        @AuraEnabled public Boolean isInactive { get; set; }
        @AuraEnabled public String accountId { get; set; }
    }

    /**
     * @description Wrapper class for apply sellout result
     */
    public class ApplySelloutResult {
        @AuraEnabled public Boolean success { get; set; }
        @AuraEnabled public String errorMessage { get; set; }
        @AuraEnabled public Integer itemsMatched { get; set; }
        @AuraEnabled public Integer invoicesCreated { get; set; }
        @AuraEnabled public Integer lineItemsCreated { get; set; }
        @AuraEnabled public Integer itemsWithErrors { get; set; }
        @AuraEnabled public List<AccountMatchResult> unmatchedItems { get; set; }
        @AuraEnabled public Integer positiveInvoicesCreated { get; set; }
        @AuraEnabled public Integer negativeInvoicesCreated { get; set; }
        @AuraEnabled public Integer itemsSkipped { get; set; }
        @AuraEnabled public Integer duplicateGroupsSkipped { get; set; }
        // Items whose product is already on the existing invoice for that customer and date but with
        // a different quantity. These are flagged for review rather than invoiced or skipped.
        @AuraEnabled public Integer itemsQuantityMismatch { get; set; }
        // Line items added to invoices that already existed, for products not previously invoiced
        @AuraEnabled public Integer lineItemsAddedToExistingInvoices { get; set; }
        @AuraEnabled public String warningMessage { get; set; }
        // True when the report still holds matched items that did not fit in this chunk, so the
        // caller must run another pass before the report is fully invoiced
        @AuraEnabled public Boolean moreItemsRemaining { get; set; }
        // Items this pass actually resolved (invoiced or skipped). A pass that resolves nothing has
        // made no forward progress, so the caller must stop chaining instead of looping.
        @AuraEnabled public Integer itemsResolved { get; set; }
        // Matched items still awaiting invoicing after this pass, counted rather than inferred
        @AuraEnabled public Integer matchedItemsRemaining { get; set; }
        // Highest sellout item Id examined by this pass, used as the cursor for the next pass
        @AuraEnabled public String lastItemIdExamined { get; set; }

        public ApplySelloutResult() {
            this.success = false;
            this.errorMessage = null;
            this.itemsMatched = 0;
            this.invoicesCreated = 0;
            this.lineItemsCreated = 0;
            this.itemsWithErrors = 0;
            this.unmatchedItems = new List<AccountMatchResult>();
            this.positiveInvoicesCreated = 0;
            this.negativeInvoicesCreated = 0;
            this.itemsSkipped = 0;
            this.duplicateGroupsSkipped = 0;
            this.itemsQuantityMismatch = 0;
            this.lineItemsAddedToExistingInvoices = 0;
            this.warningMessage = null;
            this.moreItemsRemaining = false;
            this.itemsResolved = 0;
            this.matchedItemsRemaining = 0;
            this.lastItemIdExamined = null;
        }
    }

    /**
     * @description Apply sellout - match accounts and create invoices
     * @param reportId ID of the sellout report
     * @param currentAccountId ID of the current account (main account)
     * @return ApplySelloutResult with matching and invoice creation results
     */
    @AuraEnabled(cacheable=false)
    public static ApplySelloutResult applySellout(String reportId, String currentAccountId) {
        ApplySelloutResult result = new ApplySelloutResult();

        try {
            assertReportEditable(reportId);
            // Get all sellout items for the report
            List<SLO_Sellout_Item__c> items = [
                SELECT Id, SLO_Customer_Account_Name__c, SLO_Item_Date__c,
                       SLO_Product_Code_EAN__c, SLO_Quantity__c,
                       SLO_Matched_Account__c, SLO_Processing_Status__c
                FROM SLO_Sellout_Item__c
                WHERE SLO_Sellout_Report__c = :reportId
            ];

            if (items.isEmpty()) {
                result.errorMessage = 'No sellout items found for this report';
                return result;
            }

            // Get current account name and country
            Account currentAccount = [SELECT Id, Name, BillingCountry, Status__c FROM Account WHERE Id = :currentAccountId LIMIT 1];
            String billingCountry = currentAccount.BillingCountry;

            // Get all child and grandchild accounts in the same country with Status__c
            List<Account> childAccounts = [
                SELECT Id, Name, Status__c
                FROM Account
                WHERE ParentId = :currentAccountId
                AND BillingCountry = :billingCountry
            ];
            Set<Id> childAccountIds = new Set<Id>();
            for (Account child : childAccounts) {
                childAccountIds.add(child.Id);
            }

            List<Account> grandchildAccounts = new List<Account>();
            if (!childAccountIds.isEmpty()) {
                grandchildAccounts = [
                    SELECT Id, Name, Status__c
                    FROM Account
                    WHERE ParentId IN :childAccountIds
                    AND BillingCountry = :billingCountry
                ];
            }

            // Build account map for matching (case-insensitive) with Status__c tracking. The
            // hierarchy is passed in match-precedence order - main account, then children, then
            // grandchildren - and each tier is matched on its exact name first and its _Sellout
            // variant second.
            Map<String, Id> accountNameToIdMap = new Map<String, Id>();
            Map<String, String> accountNameToStatusMap = new Map<String, String>();

            List<Account> hierarchyAccounts = new List<Account>{ currentAccount };
            hierarchyAccounts.addAll(childAccounts);
            hierarchyAccounts.addAll(grandchildAccounts);
            buildAccountNameMaps(hierarchyAccounts, accountNameToIdMap, accountNameToStatusMap);

            // Match accounts for each item - detect inactive accounts
            List<SLO_Sellout_Item__c> itemsToUpdate = new List<SLO_Sellout_Item__c>();
            Set<String> unmatchedAccountNames = new Set<String>();
            Map<String, List<String>> unmatchedNameToItemIds = new Map<String, List<String>>();
            Set<String> inactiveAccountNames = new Set<String>();
            Map<String, List<String>> inactiveNameToItemIds = new Map<String, List<String>>();

            for (SLO_Sellout_Item__c item : items) {
                // Skip items with zero or null quantity
                if (item.SLO_Quantity__c == null || item.SLO_Quantity__c == 0) {
                    item.SLO_Processing_Status__c = 'Skipped';
                    item.SLO_Processing_Notes__c = NOTE_ZERO_QUANTITY;
                    itemsToUpdate.add(item);
                    result.itemsSkipped++;
                    continue;
                }

                if (String.isBlank(item.SLO_Customer_Account_Name__c)) {
                    continue;
                }

                String customerName = item.SLO_Customer_Account_Name__c.toLowerCase().trim();
                if (accountNameToIdMap.containsKey(customerName)) {
                    Id matchedAccountId = accountNameToIdMap.get(customerName);
                    String accountStatus = accountNameToStatusMap.get(customerName);

                    // Check if account is inactive (Status__c = 'N')
                    if (accountStatus == 'N') {
                        // Inactive account - track for user decision
                        String originalName = item.SLO_Customer_Account_Name__c.trim();

                        if (!inactiveNameToItemIds.containsKey(customerName)) {
                            inactiveNameToItemIds.put(customerName, new List<String>());
                        }
                        inactiveNameToItemIds.get(customerName).add(item.Id);

                        // Add to result only once per unique name
                        if (!inactiveAccountNames.contains(customerName)) {
                            inactiveAccountNames.add(customerName);

                            AccountMatchResult inactiveResult = new AccountMatchResult();
                            inactiveResult.selloutItemIds = inactiveNameToItemIds.get(customerName);
                            inactiveResult.customerAccountName = originalName;
                            inactiveResult.matched = true;
                            inactiveResult.isInactive = true;
                            inactiveResult.accountId = matchedAccountId;
                            inactiveResult.needsUserDecision = true;
                            result.unmatchedItems.add(inactiveResult);
                        }

                        // Flag the item so the review list can offer the decision on the row itself
                        item.SLO_Processing_Status__c = 'Pending_Decision';
                        item.SLO_Processing_Notes__c = NOTE_ACCOUNT_INACTIVE;
                        itemsToUpdate.add(item);
                    } else {
                        // Active account - auto-match
                        item.SLO_Matched_Account__c = matchedAccountId;
                        item.SLO_Processing_Status__c = 'Matched';
                        item.SLO_Processing_Notes__c = NOTE_READY;
                        itemsToUpdate.add(item);
                        result.itemsMatched++;
                    }
                } else {
                    // Unmatched - track unique names and all item IDs
                    String originalName = item.SLO_Customer_Account_Name__c.trim();

                    // Track all item IDs for this account name
                    if (!unmatchedNameToItemIds.containsKey(customerName)) {
                        unmatchedNameToItemIds.put(customerName, new List<String>());
                    }
                    unmatchedNameToItemIds.get(customerName).add(item.Id);

                    // Add to result only once per unique name
                    if (!unmatchedAccountNames.contains(customerName)) {
                        unmatchedAccountNames.add(customerName);

                        AccountMatchResult unmatchedResult = new AccountMatchResult();
                        unmatchedResult.selloutItemIds = unmatchedNameToItemIds.get(customerName);
                        unmatchedResult.customerAccountName = originalName;
                        unmatchedResult.matched = false;
                        unmatchedResult.isInactive = false;
                        unmatchedResult.needsUserDecision = true;
                        result.unmatchedItems.add(unmatchedResult);
                    }

                    // Flag the item so the review list can offer the decision on the row itself
                    item.SLO_Processing_Status__c = 'Pending_Decision';
                    item.SLO_Processing_Notes__c = NOTE_ACCOUNT_NOT_FOUND;
                    itemsToUpdate.add(item);
                }
            }

            // Update matched items
            if (!itemsToUpdate.isEmpty()) {
                update itemsToUpdate;
            }

            // If there are unmatched items, return now for user decision
            if (!result.unmatchedItems.isEmpty()) {
                result.success = true;
                return result;
            }

            // All items matched - automatically proceed to create invoices
            ApplySelloutResult invoiceResult = createInvoicesForReport(reportId);

            // Merge invoice creation results into the result
            result.success = invoiceResult.success;
            result.invoicesCreated = invoiceResult.invoicesCreated;
            result.lineItemsCreated = invoiceResult.lineItemsCreated;
            result.itemsWithErrors += invoiceResult.itemsWithErrors;
            result.positiveInvoicesCreated = invoiceResult.positiveInvoicesCreated;
            result.negativeInvoicesCreated = invoiceResult.negativeInvoicesCreated;
            result.duplicateGroupsSkipped = invoiceResult.duplicateGroupsSkipped;
            result.itemsQuantityMismatch = invoiceResult.itemsQuantityMismatch;
            result.lineItemsAddedToExistingInvoices = invoiceResult.lineItemsAddedToExistingInvoices;
            result.itemsSkipped += invoiceResult.itemsSkipped;
            result.warningMessage = invoiceResult.warningMessage;
            result.moreItemsRemaining = invoiceResult.moreItemsRemaining;
            result.itemsResolved = invoiceResult.itemsResolved;
            result.matchedItemsRemaining = invoiceResult.matchedItemsRemaining;
            result.lastItemIdExamined = invoiceResult.lastItemIdExamined;

            // If invoice creation failed, use that error message
            if (!invoiceResult.success && invoiceResult.errorMessage != null) {
                result.errorMessage = invoiceResult.errorMessage;
            }

            // The report was too large to invoice in one transaction - finish the remainder in the
            // background so the synchronous path never trips the DML row limit
            if (invoiceResult.success == true && invoiceResult.moreItemsRemaining == true) {
                try {
                    // Hand the cursor to the chain so the background passes resume above the items
                    // this synchronous pass already examined instead of re-reading them
                    SLO_SelloutApplyBatch.RunContext handover = new SLO_SelloutApplyBatch.RunContext();
                    handover.invoiceCursorId = invoiceResult.lastItemIdExamined;
                    Database.executeBatch(
                        new SLO_SelloutApplyBatch(
                            reportId, currentAccountId, SLO_SelloutApplyBatch.MODE_INVOICE, handover
                        ),
                        SLO_SelloutApplyBatch.scopeSizeForAttempt(1)
                    );
                    result.warningMessage = String.isBlank(result.warningMessage)
                        ? 'The remaining items are being invoiced in the background and you will receive an email when they are done.'
                        : result.warningMessage +
                            ' The remaining items are being invoiced in the background and you will receive an email when they are done.';
                } catch (Exception chainEx) {
                    result.warningMessage = String.isBlank(result.warningMessage)
                        ? 'Some items were not invoiced. Run Apply Sellout again to process the remainder.'
                        : result.warningMessage +
                            ' Some items were not invoiced. Run Apply Sellout again to process the remainder.';
                }
            }

        } catch (Exception e) {
            result.success = false;
            result.errorMessage = 'Error applying sellout: ' + e.getMessage();

            // Update report status to Error
            try {
                SLO_Sellout_Report__c report = new SLO_Sellout_Report__c(
                    Id = reportId,
                    SLO_Status__c = 'Error',
                    SLO_Error_Message__c = e.getMessage()
                );
                update report;
            } catch (Exception updateEx) {
                System.debug('Error updating report status: ' + updateEx.getMessage());
            }
        }

        return result;
    }

    /**
     * @description Create child account for unmatched customer
     * @param parentAccountId ID of the parent account
     * @param accountName Name of the new child account
     * @param selloutItemIds List of sellout item IDs to link
     * @return ID of the newly created account
     */
    @AuraEnabled(cacheable=false)
    public static String createChildAccount(String parentAccountId, String accountName, List<String> selloutItemIds) {
        try {
            assertItemsEditable(selloutItemIds);
            // Query parent account to get Name, BillingCountry, OwnerId, and CurrencyIsoCode
            Account parentAccount = [SELECT Id, Name, BillingCountry, OwnerId, CurrencyIsoCode FROM Account WHERE Id = :parentAccountId LIMIT 1];

            // Create new child account with placeholder address values
            Account newAccount = new Account(
                Name = buildSelloutAccountName(accountName, parentAccount.Name),
                ParentId = parentAccountId,
                OwnerId = parentAccount.OwnerId,
                BillingStreet = 'Automatic',
                BillingCity = 'Automatic',
                BillingCountry = parentAccount.BillingCountry,
                BillingPostalCode = '99999',
                Status__c = 'Active',
                CurrencyIsoCode = parentAccount.CurrencyIsoCode
            );
            Database.insert(newAccount, buildSingleCreateOptions());
            addAccountsCreatedForItems(selloutItemIds, 1);

            // Update all sellout items with this account name
            List<SLO_Sellout_Item__c> itemsToUpdate = new List<SLO_Sellout_Item__c>();
            for (String itemId : selloutItemIds) {
                itemsToUpdate.add(new SLO_Sellout_Item__c(
                    Id = itemId,
                    SLO_Matched_Account__c = newAccount.Id,
                    SLO_Processing_Status__c = 'Matched',
                    SLO_Processing_Notes__c = NOTE_READY
                ));
            }

            if (!itemsToUpdate.isEmpty()) {
                update itemsToUpdate;
            }

            return newAccount.Id;
        } catch (Exception e) {
            throw new AuraHandledException('Error creating child account: ' + e.getMessage());
        }
    }

    /**
     * @description Skip matching for sellout items
     * @param selloutItemIds List of sellout item IDs to skip
     */
    @AuraEnabled(cacheable=false)
    public static void skipMatchingForItem(List<String> selloutItemIds) {
        assertItemsEditable(selloutItemIds);
        try {
            List<SLO_Sellout_Item__c> itemsToUpdate = new List<SLO_Sellout_Item__c>();
            for (String itemId : selloutItemIds) {
                itemsToUpdate.add(new SLO_Sellout_Item__c(
                    Id = itemId,
                    SLO_Processing_Status__c = 'Skipped',
                    SLO_Processing_Notes__c = NOTE_ACCOUNT_DECLINED
                ));
            }

            if (!itemsToUpdate.isEmpty()) {
                update itemsToUpdate;
            }
        } catch (Exception e) {
            throw new AuraHandledException('Error skipping item: ' + e.getMessage());
        }
    }

    /**
     * @description Set aside every line still in error on a report, because the user was told the
     * exact count and chose to apply the sellout anyway. A line whose product code was corrected has
     * already left Error during re-validation, so only the genuinely uncorrected ones are caught.
     * Runs in bounded passes so a report of thousands of failing lines cannot exceed the DML limit.
     * @param reportId ID of the sellout report
     * @return Number of lines set aside
     */
    @AuraEnabled(cacheable=false)
    public static Integer skipUncorrectedErrorItems(String reportId) {
        if (String.isBlank(reportId)) {
            return 0;
        }

        try {
            List<SLO_Sellout_Item__c> failing = [
                SELECT Id
                FROM SLO_Sellout_Item__c
                WHERE SLO_Sellout_Report__c = :reportId
                AND SLO_Processing_Status__c = 'Error'
                LIMIT :UNCORRECTED_SKIP_LIMIT
            ];

            for (SLO_Sellout_Item__c item : failing) {
                item.SLO_Processing_Status__c = STATUS_ENFORCED_SKIPPED;
                item.SLO_Processing_Notes__c = NOTE_LEFT_UNCORRECTED;
            }

            if (!failing.isEmpty()) {
                update failing;
            }

            return failing.size();
        } catch (Exception e) {
            throw new AuraHandledException(
                'Unable to set aside the lines that still need a fix: ' + e.getMessage()
            );
        }
    }

    // One pass of the uncorrected-error sweep. Well inside the DML row limit, so a very large report
    // is cleared over a few calls rather than failing outright.
    @TestVisible
    public static final Integer UNCORRECTED_SKIP_LIMIT = 5000;

    /**
     * @description Set the ticked lines that still need a fix aside as Enforced Skipped, from the
     * needs-a-fix view. Only lines still in error are touched, so a line corrected meanwhile stays.
     * @param itemIds Ids of the ticked lines
     * @return Number of lines set aside
     */
    @AuraEnabled(cacheable=false)
    public static Integer enforceSkipItems(List<String> itemIds) {
        if (itemIds == null || itemIds.isEmpty()) {
            return 0;
        }
        assertItemsEditable(itemIds);

        try {
            // ponytail: one update, so a selection is capped by the 10,000 DML row limit
            List<SLO_Sellout_Item__c> failing = [
                SELECT Id
                FROM SLO_Sellout_Item__c
                WHERE Id IN :itemIds
                AND SLO_Processing_Status__c = 'Error'
            ];
            for (SLO_Sellout_Item__c item : failing) {
                item.SLO_Processing_Status__c = STATUS_ENFORCED_SKIPPED;
                item.SLO_Processing_Notes__c = NOTE_ENFORCED_SKIP;
            }
            update failing;
            return failing.size();
        } catch (Exception e) {
            throw new AuraHandledException('Unable to set the lines aside: ' + e.getMessage());
        }
    }

    /**
     * @description Mark a report's Duplicate lines as Enforced Skipped, one bounded block per call
     * @param reportId ID of the sellout report
     * @return Number of lines set aside; call again while it is above zero
     */
    @AuraEnabled(cacheable=false)
    public static Integer enforceSkipDuplicates(String reportId) {
        if (String.isBlank(reportId)) {
            return 0;
        }
        assertReportEditable(reportId);
        try {
            List<SLO_Sellout_Item__c> duplicates = [
                SELECT Id
                FROM SLO_Sellout_Item__c
                WHERE SLO_Sellout_Report__c = :reportId
                AND SLO_Processing_Status__c = :STATUS_DUPLICATE
                LIMIT :UNCORRECTED_SKIP_LIMIT
            ];
            for (SLO_Sellout_Item__c item : duplicates) {
                item.SLO_Processing_Status__c = STATUS_ENFORCED_SKIPPED;
                item.SLO_Processing_Notes__c = NOTE_ENFORCED_SKIP_DUPLICATE;
            }
            if (!duplicates.isEmpty()) {
                update duplicates;
            }
            return duplicates.size();
        } catch (Exception e) {
            throw new AuraHandledException('Unable to skip the duplicate lines: ' + e.getMessage());
        }
    }

    public static final String NOTE_ENFORCED_SKIP_DUPLICATE =
        'Enforced skipped - duplicate line set aside';

    /**
     * @description Reset report status to allow retry
     * @param reportId ID of the sellout report
     */
    @AuraEnabled(cacheable=false)
    public static void resetReportStatus(String reportId) {
        assertReportEditable(reportId);
        try {
            SLO_Sellout_Report__c report = new SLO_Sellout_Report__c(
                Id = reportId,
                SLO_Status__c = 'Draft',
                SLO_Error_Message__c = null
            );
            update report;
        } catch (Exception e) {
            throw new AuraHandledException('Error resetting report status: ' + e.getMessage());
        }
    }

    /**
     * @description Create invoices and line items for all matched items in a report
     * @param reportId ID of the sellout report
     * @return ApplySelloutResult with invoice creation results
     */
    @AuraEnabled(cacheable=false)
    public static ApplySelloutResult createInvoicesForReport(String reportId) {
        assertReportEditable(reportId);
        return createInvoicePass(reportId, null);
    }

    /**
     * @description Create invoices and line items for one bounded pass of a report's matched items
     * @param reportId ID of the sellout report
     * @param afterItemId Cursor - only items with an Id above this are examined. Pass null to start
     *        at the beginning. Paging on Id guarantees the pass advances even when every group it
     *        reads is skipped as a duplicate, which a "first N matched items" page could never do.
     * @return ApplySelloutResult with invoice creation results, the new cursor and remaining counts
     */
    public static ApplySelloutResult createInvoicePass(String reportId, String afterItemId) {
        ApplySelloutResult result = new ApplySelloutResult();
        SLO_Sellout_Report__c report = null;

        try {
            // Get the parent account from the report
            report = [
                SELECT Id, SLO_Account__c, SLO_Account__r.Account_Usage_Company__c,
                       SLO_Price_Method__c, SLO_Price_Book__c, SLO_Auto_Accepted__c
                FROM SLO_Sellout_Report__c
                WHERE Id = :reportId
                LIMIT 1
            ];
            Boolean autoAcceptedReport = report.SLO_Auto_Accepted__c == true;
            Id parentAccountId = report.SLO_Account__c;
            String parentUsageCompany = report.SLO_Account__r.Account_Usage_Company__c;

            // Take at most one pass worth of matched items so a large report cannot exhaust the
            // DML row or heap limits. Paging strictly forward on Id is what makes the chain
            // terminate: whatever this pass does with the items it reads - invoice them, skip them
            // as duplicates - the next pass starts above the last Id examined and can never re-read
            // them. An earlier version paged on "the first N matched items", which meant any item
            // left at status Matched was read again on every pass and the chain never advanced.
            Id cursorId = String.isBlank(afterItemId) ? null : (Id) afterItemId;
            List<SLO_Sellout_Item__c> matchedItems;
            if (cursorId == null) {
                matchedItems = [
                    SELECT Id, SLO_Matched_Account__c, SLO_Item_Date__c,
                           SLO_Product_Code_EAN__c, SLO_Quantity__c, SLO_Source_Line_Item__c
                    FROM SLO_Sellout_Item__c
                    WHERE SLO_Sellout_Report__c = :reportId
                    AND SLO_Matched_Account__c != null
                    AND SLO_Processing_Status__c = 'Matched'
                    ORDER BY Id
                    LIMIT :INVOICE_ITEMS_PER_PASS
                ];
            } else {
                matchedItems = [
                    SELECT Id, SLO_Matched_Account__c, SLO_Item_Date__c,
                           SLO_Product_Code_EAN__c, SLO_Quantity__c, SLO_Source_Line_Item__c
                    FROM SLO_Sellout_Item__c
                    WHERE SLO_Sellout_Report__c = :reportId
                    AND SLO_Matched_Account__c != null
                    AND SLO_Processing_Status__c = 'Matched'
                    AND Id > :cursorId
                    ORDER BY Id
                    LIMIT :INVOICE_ITEMS_PER_PASS
                ];
            }

            if (!matchedItems.isEmpty()) {
                result.lastItemIdExamined = String.valueOf(matchedItems[matchedItems.size() - 1].Id);
            }

            // Because the page is ordered by Id rather than by group, the items of one account/date
            // group can straddle the page boundary. Pull in the missing members of every group this
            // page touched so each group is invoiced exactly once and in full - a split group would
            // make its second half look like a duplicate of the invoice its first half just created.
            // Items pulled in this way may sit above the cursor, but they finish this pass as
            // Invoice_Created or Skipped, so a later pass reading over them finds nothing to do.
            if (matchedItems.size() == INVOICE_ITEMS_PER_PASS) {
                InvoicePass pass = completePartialGroups(reportId, matchedItems);
                matchedItems = pass.items;
                // A group too large to complete is held back whole, so the cursor must stop below it
                result.lastItemIdExamined = pass.cursorId;
            }

            // Anything still Matched beyond the cursor needs another pass. Both figures are counted
            // rather than inferred from the page, so the report is only ever closed on real evidence.
            result.matchedItemsRemaining = countMatchedItems(reportId, null);
            result.moreItemsRemaining = (result.lastItemIdExamined != null) &&
                countMatchedItems(reportId, (Id) result.lastItemIdExamined) > 0;

            if (matchedItems.isEmpty() && cursorId != null) {
                // The cursor has reached the end of the report. Items may still be Matched below it
                // (a group held back for size, or one that failed to save), so report the real count
                // and rewind the cursor - the next pass sweeps from the start. The caller's
                // zero-progress guard stops the chain if that sweep resolves nothing.
                result.success = true;
                result.lastItemIdExamined = null;
                closeReportIfFullyInvoiced(report, result);
                return result;
            }

            if (matchedItems.isEmpty() && countInvoicedItems(reportId) > 0) {
                // Nothing is waiting and this report has already produced invoices, so it is finished
                // rather than broken - the diagnostic error path below is for reports that never got
                // as far as invoicing anything
                result.success = true;
                closeReportIfFullyInvoiced(report, result);
                return result;
            }

            if (matchedItems.isEmpty()) {
                // Enhanced diagnostics - check status distribution
                Map<String, Integer> statusCounts = new Map<String, Integer>();
                List<SLO_Sellout_Item__c> allItems = [
                    SELECT SLO_Processing_Status__c, SLO_Matched_Account__c
                    FROM SLO_Sellout_Item__c
                    WHERE SLO_Sellout_Report__c = :reportId
                ];

                Integer totalItems = allItems.size();
                Integer itemsWithAccount = 0;

                for (SLO_Sellout_Item__c item : allItems) {
                    String status = item.SLO_Processing_Status__c != null ? item.SLO_Processing_Status__c : 'null';
                    statusCounts.put(status, statusCounts.containsKey(status) ? statusCounts.get(status) + 1 : 1);

                    if (item.SLO_Matched_Account__c != null) {
                        itemsWithAccount++;
                    }
                }

                // Build detailed error message
                String detailedError = 'No matched items found to create invoices. ';

                if (totalItems == 0) {
                    detailedError += 'This report has no items.';
                } else if (statusCounts.containsKey('Invoice_Created') && statusCounts.get('Invoice_Created') == totalItems) {
                    detailedError += 'All ' + totalItems + ' items have already been processed (invoices already created).';
                } else {
                    detailedError += 'Status breakdown: ';
                    for (String status : statusCounts.keySet()) {
                        detailedError += status + ': ' + statusCounts.get(status) + ', ';
                    }
                    detailedError += 'Items with matched accounts: ' + itemsWithAccount + '. ';

                    if (itemsWithAccount == 0) {
                        detailedError += 'Account matching has not been completed yet. Please use "Apply Sellout" to match accounts first.';
                    } else if (statusCounts.containsKey('Error')) {
                        detailedError += statusCounts.get('Error') + ' items have errors. Review and fix errors before creating invoices.';
                    } else {
                        detailedError += 'Items need to have status "Matched" to create invoices.';
                    }
                }

                result.errorMessage = detailedError;
                return result;
            }

            // Group items by matched account AND date
            Map<String, List<SLO_Sellout_Item__c>> itemsByAccountAndDate = new Map<String, List<SLO_Sellout_Item__c>>();
            Map<String, Id> keyToAccountId = new Map<String, Id>(); // Track account ID for each key
            Map<String, Date> keyToDate = new Map<String, Date>(); // Track date for each key

            // Like the weekly batch, daily items create one invoice per source invoice, so the
            // group key carries the source invoice; baseKeyByGroupKey keeps the account+date key
            // used to find invoices that already exist
            Set<Id> groupingLineIds = new Set<Id>();
            for (SLO_Sellout_Item__c item : matchedItems) {
                if (item.SLO_Source_Line_Item__c != null) {
                    groupingLineIds.add(item.SLO_Source_Line_Item__c);
                }
            }
            Map<Id, Id> sourceInvoiceByLineId = new Map<Id, Id>();
            if (!groupingLineIds.isEmpty()) {
                for (Invoice_Line_Item__c line : [
                    SELECT Id, Invoice_Number__c FROM Invoice_Line_Item__c WHERE Id IN :groupingLineIds
                ]) {
                    sourceInvoiceByLineId.put(line.Id, line.Invoice_Number__c);
                }
            }
            Map<String, String> baseKeyByGroupKey = new Map<String, String>();

            for (SLO_Sellout_Item__c item : matchedItems) {
                String baseKey = item.SLO_Matched_Account__c + '_' + String.valueOf(item.SLO_Item_Date__c);
                Id sourceInvoiceId = item.SLO_Source_Line_Item__c == null
                    ? null : sourceInvoiceByLineId.get(item.SLO_Source_Line_Item__c);
                String key = sourceInvoiceId == null ? baseKey : baseKey + '_' + sourceInvoiceId;

                if (!itemsByAccountAndDate.containsKey(key)) {
                    itemsByAccountAndDate.put(key, new List<SLO_Sellout_Item__c>());
                    keyToAccountId.put(key, item.SLO_Matched_Account__c);
                    keyToDate.put(key, item.SLO_Item_Date__c);
                    baseKeyByGroupKey.put(key, baseKey);
                }
                itemsByAccountAndDate.get(key).add(item);
            }

            // Check for an existing SELLOUT invoice for each child account and date combination.
            // The guard is deliberately precise on child account + date:
            //  - Only sellout-generated invoices count, so SAP or manually created invoices for the
            //    same account and date must not block sellout processing.
            //  - Only the positive 'Internal Sellout' invoice counts. The offsetting
            //    'Internal Sellout N' invoices all belong to the parent account, one per date, so
            //    treating them as duplicates blocked every child account on any date the parent had
            //    ever been invoiced for - far wider than intended.
            //  - The comparison is made line item by line item rather than whole invoice, so a
            //    genuinely new product for a customer and date that has already been invoiced is
            //    still added, instead of the whole group being turned away.
            Set<Id> accountIds = new Set<Id>(keyToAccountId.values());
            Set<Date> invoiceDates = new Set<Date>(keyToDate.values());
            List<Invoice__c> existingInvoices = [
                SELECT Id, Name, Account_Name__c, Invoice_Date__c,
                       (SELECT Id, Product_Name__c, SKU_Code__c, Quantity__c
                        FROM Invoice_Line_Items__r
                        WHERE Valid__c = true)
                FROM Invoice__c
                WHERE Account_Name__c IN :accountIds
                AND Invoice_Date__c IN :invoiceDates
                AND Transaction_type__c = 'Internal Sellout'
            ];

            // Build map of existing invoices by child account and date, plus the quantity already
            // invoiced per product within each of them. Product codes are normalized so a missing or
            // extra leading zero on either side does not read as a different product.
            Map<String, Invoice__c> existingInvoiceMap = new Map<String, Invoice__c>();
            Map<String, Decimal> existingQuantityByProductKey = new Map<String, Decimal>();
            for (Invoice__c existingInvoice : existingInvoices) {
                String key = existingInvoice.Account_Name__c + '_' + String.valueOf(existingInvoice.Invoice_Date__c);
                existingInvoiceMap.put(key, existingInvoice);

                for (Invoice_Line_Item__c existingLine : existingInvoice.Invoice_Line_Items__r) {
                    // Lines now carry the product name, so the SKU code is matched as well
                    Set<String> lineCodes = new Set<String>();
                    String nameCode = normalizeProductCode(existingLine.Product_Name__c);
                    String skuCode = normalizeProductCode(existingLine.SKU_Code__c);
                    if (nameCode != null) {
                        lineCodes.add(nameCode);
                    }
                    if (skuCode != null) {
                        lineCodes.add(skuCode);
                    }
                    Decimal lineQuantity = existingLine.Quantity__c == null ? 0 : existingLine.Quantity__c;
                    for (String normalizedCode : lineCodes) {
                        String productKey = key + '_' + normalizedCode;
                        // Several lines for the same product are compared on their combined quantity
                        Decimal runningQuantity = existingQuantityByProductKey.containsKey(productKey)
                            ? existingQuantityByProductKey.get(productKey) + lineQuantity
                            : lineQuantity;
                        existingQuantityByProductKey.put(productKey, runningQuantity);
                    }
                }
            }

            // Compare each item against what the existing invoice already holds:
            //  - same product and same quantity -> skipped, it is a true duplicate
            //  - same product, different quantity -> flagged as an error for someone to look at,
            //    because silently keeping either figure would misstate the customer's sellout
            //  - product not on the invoice yet -> kept, and added to that existing invoice below
            List<String> duplicateMessages = new List<String>();
            List<String> mismatchMessages = new List<String>();
            List<SLO_Sellout_Item__c> duplicateItemsToUpdate = new List<SLO_Sellout_Item__c>();
            List<SLO_Sellout_Item__c> quantityMismatchItems = new List<SLO_Sellout_Item__c>();
            // Groups whose items belong on an invoice that already exists, keyed the same way as
            // itemsByAccountAndDate so the creation step below knows to reuse rather than insert
            Map<String, Id> appendToExistingInvoiceIds = new Map<String, Id>();
            Map<Id, Account> accountMap = new Map<Id, Account>([SELECT Id, Name FROM Account WHERE Id IN :accountIds]);

            for (String compositeKey : new List<String>(itemsByAccountAndDate.keySet())) {
                Id accountId = keyToAccountId.get(compositeKey);
                Date invoiceDate = keyToDate.get(compositeKey);

                String baseGroupKey = baseKeyByGroupKey.get(compositeKey);
                if (!existingInvoiceMap.containsKey(baseGroupKey)) {
                    continue;
                }

                Invoice__c existingInvoice = existingInvoiceMap.get(baseGroupKey);
                String accountName = accountMap.containsKey(accountId) ? accountMap.get(accountId).Name : 'Unknown Account';
                String invoiceLabel = String.isBlank(existingInvoice.Name) ? 'the existing sellout invoice' : existingInvoice.Name;
                List<SLO_Sellout_Item__c> newProductItems = new List<SLO_Sellout_Item__c>();

                for (SLO_Sellout_Item__c item : itemsByAccountAndDate.get(compositeKey)) {
                    // The automated sellout never skips duplicates: every line is invoiced
                    if (autoAcceptedReport) {
                        newProductItems.add(item);
                        continue;
                    }
                    String normalizedCode = normalizeProductCode(item.SLO_Product_Code_EAN__c);
                    String productKey = normalizedCode == null ? null : baseGroupKey + '_' + normalizedCode;
                    String reportedCode = String.isBlank(item.SLO_Product_Code_EAN__c)
                        ? '(blank)'
                        : item.SLO_Product_Code_EAN__c.trim();

                    if (productKey == null || !existingQuantityByProductKey.containsKey(productKey)) {
                        newProductItems.add(item);
                        continue;
                    }

                    Decimal existingQuantity = existingQuantityByProductKey.get(productKey);
                    Decimal incomingQuantity = item.SLO_Quantity__c == null ? 0 : item.SLO_Quantity__c;

                    if (existingQuantity == incomingQuantity) {
                        item.SLO_Processing_Status__c = 'Skipped';
                        item.SLO_Processing_Notes__c = 'Skipped - an identical line already exists on ' +
                            invoiceLabel + ' for ' + accountName + ' on ' + invoiceDate.format() +
                            ' (product ' + reportedCode + ', quantity ' + incomingQuantity + ')';
                        duplicateItemsToUpdate.add(item);
                        continue;
                    }

                    item.SLO_Processing_Status__c = STATUS_ENFORCED_SKIPPED;
                    item.SLO_Processing_Notes__c = 'Quantity mismatch - ' + invoiceLabel + ' for ' +
                        accountName + ' on ' + invoiceDate.format() + ' already has product ' +
                        reportedCode + ' with quantity ' + existingQuantity +
                        ', but this sellout reports quantity ' + incomingQuantity;
                    quantityMismatchItems.add(item);
                    if (mismatchMessages.size() < 10) {
                        mismatchMessages.add(accountName + ' on ' + invoiceDate.format() + ' - product ' +
                            reportedCode + ' (invoiced ' + existingQuantity + ', sellout ' + incomingQuantity + ')');
                    }
                }

                if (newProductItems.isEmpty()) {
                    // Nothing new for this customer and date, so no invoice or line item is created
                    itemsByAccountAndDate.remove(compositeKey);
                    keyToAccountId.remove(compositeKey);
                    keyToDate.remove(compositeKey);
                } else {
                    itemsByAccountAndDate.put(compositeKey, newProductItems);
                    appendToExistingInvoiceIds.put(compositeKey, existingInvoice.Id);
                }

                if (duplicateMessages.size() < 10) {
                    duplicateMessages.add(accountName + ' on ' + invoiceDate.format());
                }
            }

            List<String> duplicateWarnings = new List<String>();

            if (!duplicateItemsToUpdate.isEmpty()) {
                Database.update(duplicateItemsToUpdate, false);
                result.itemsSkipped += duplicateItemsToUpdate.size();
                result.itemsResolved += duplicateItemsToUpdate.size();
                result.duplicateGroupsSkipped = duplicateMessages.size();
                duplicateWarnings.add('Skipped ' + duplicateItemsToUpdate.size() +
                    ' item(s) already invoiced with the same product and quantity for: ' +
                    String.join(duplicateMessages, '; '));
            }

            if (!quantityMismatchItems.isEmpty()) {
                Database.update(quantityMismatchItems, false);
                result.itemsQuantityMismatch += quantityMismatchItems.size();
                // Flagging these is real forward progress - they leave the Matched pool, so the
                // chain's zero-progress guard must not read this pass as having stalled
                result.itemsResolved += quantityMismatchItems.size();
                duplicateWarnings.add(quantityMismatchItems.size() +
                    ' item(s) have a quantity that differs from the existing invoice and were set aside as Enforced Skipped: ' +
                    String.join(mismatchMessages, '; '));
            }

            if (!duplicateWarnings.isEmpty()) {
                result.warningMessage = String.join(duplicateWarnings, ' | ');
            }

            // Every remaining item was a duplicate or a mismatch - nothing left to invoice, but this is not a failure
            if (itemsByAccountAndDate.isEmpty()) {
                result.success = true;
                closeReportIfFullyInvoiced(report, result);
                return result;
            }

            // Only the items still eligible for invoicing should drive price lookup and updates
            List<SLO_Sellout_Item__c> itemsToInvoice = new List<SLO_Sellout_Item__c>();
            for (String compositeKey : itemsByAccountAndDate.keySet()) {
                itemsToInvoice.addAll(itemsByAccountAndDate.get(compositeKey));
            }
            matchedItems = itemsToInvoice;

            // Resolve pricebook and product prices before anything is created. An item whose EAN
            // matches no product is flagged and dropped here rather than producing an invoice
            // line for a product that does not exist in the catalogue.
            Boolean isDedicatedBook = (report.SLO_Price_Method__c == 'Dedicated_Price_Book' || report.SLO_Price_Method__c == 'Customer_Price_List')
                && report.SLO_Price_Book__c != null;
            Id pricebookId = isDedicatedBook ? report.SLO_Price_Book__c : resolvePricebook(withUserUsageCompany(parentUsageCompany));
            Map<String, ProductPriceMatch> eanToMatchMap = new Map<String, ProductPriceMatch>();

            // Collect all unique EAN codes from matched items. Product resolution runs even
            // without a pricebook so unknown product codes are still reported as errors.
            Set<String> eanCodes = new Set<String>();
            for (SLO_Sellout_Item__c item : matchedItems) {
                if (String.isNotBlank(item.SLO_Product_Code_EAN__c)) {
                    eanCodes.add(item.SLO_Product_Code_EAN__c);
                }
            }

            if (!eanCodes.isEmpty()) {
                eanToMatchMap = resolveProductPrices(eanCodes, pricebookId);
            }

            // Price source per EAN: selected book first, then the account country's default book,
            // then the running user's country default book when the product has no entry
            priceSourceByEan = new Map<String, String>();
            List<Id> bookChain = new List<Id>();
            List<String> bookLabels = new List<String>();
            Boolean isCustomerList = report.SLO_Price_Method__c == 'Customer_Price_List';
            if (pricebookId != null) {
                bookChain.add(pricebookId);
                bookLabels.add(isDedicatedBook ? (isCustomerList ? 'customer price list' : 'selected price book') : 'country default');
            }
            Id countryBook = resolvePricebook(parentUsageCompany);
            Id userBook = resolvePricebook(withUserUsageCompany(null));
            if (countryBook != null && !bookChain.contains(countryBook)) {
                bookChain.add(countryBook);
                bookLabels.add('account country default');
            }
            if (userBook != null && !bookChain.contains(userBook)) {
                bookChain.add(userBook);
                bookLabels.add('user country default');
            }
            if (!bookChain.isEmpty() && !eanToMatchMap.isEmpty()) {
                Map<Id, String> bookNames = new Map<Id, String>();
                for (Pricebook2 pb : [SELECT Id, Name FROM Pricebook2 WHERE Id IN :bookChain]) {
                    bookNames.put(pb.Id, pb.Name);
                }
                for (Integer i = 0; i < bookChain.size(); i++) {
                    Set<String> missing = new Set<String>();
                    for (String ean : eanToMatchMap.keySet()) {
                        ProductPriceMatch m = eanToMatchMap.get(ean);
                        if (m.productId != null && m.unitPrice == null) {
                            missing.add(ean);
                        }
                    }
                    if (i > 0 && missing.isEmpty()) {
                        break;
                    }
                    Map<String, ProductPriceMatch> viaBook = i == 0
                        ? eanToMatchMap
                        : resolveProductPrices(missing, bookChain[i]);
                    for (String ean : viaBook.keySet()) {
                        ProductPriceMatch m = viaBook.get(ean);
                        if (m.unitPrice == null) {
                            continue;
                        }
                        if (i > 0) {
                            eanToMatchMap.get(ean).unitPrice = m.unitPrice;
                        }
                        priceSourceByEan.put(ean, 'Price book: ' + bookNames.get(bookChain[i])
                            + ' (' + bookLabels[i] + ')');
                    }
                }
            }

            // Drop items with no product match, and drop any group left with no valid items at all
            List<SLO_Sellout_Item__c> productErrorItems = new List<SLO_Sellout_Item__c>();
            Set<String> unmatchedProductCodes = new Set<String>();

            for (String compositeKey : new List<String>(itemsByAccountAndDate.keySet())) {
                List<SLO_Sellout_Item__c> validItems = new List<SLO_Sellout_Item__c>();

                for (SLO_Sellout_Item__c item : itemsByAccountAndDate.get(compositeKey)) {
                    ProductPriceMatch itemMatch = String.isBlank(item.SLO_Product_Code_EAN__c)
                        ? null
                        : eanToMatchMap.get(item.SLO_Product_Code_EAN__c);

                    if (itemMatch == null || itemMatch.productId == null) {
                        String reportedCode = String.isBlank(item.SLO_Product_Code_EAN__c)
                            ? '(blank)'
                            : item.SLO_Product_Code_EAN__c.trim();
                        item.SLO_Processing_Status__c = 'Error';
                        item.SLO_Processing_Notes__c =
                            NOTE_APPLY_PRODUCT_NOT_FOUND_PREFIX + ': ' + reportedCode;
                        productErrorItems.add(item);
                        unmatchedProductCodes.add(reportedCode);
                        continue;
                    }

                    validItems.add(item);
                }

                if (validItems.isEmpty()) {
                    itemsByAccountAndDate.remove(compositeKey);
                    keyToAccountId.remove(compositeKey);
                    keyToDate.remove(compositeKey);
                } else {
                    itemsByAccountAndDate.put(compositeKey, validItems);
                }
            }

            if (!productErrorItems.isEmpty()) {
                Database.update(productErrorItems, false);
                result.itemsSkipped += productErrorItems.size();
                // Flagging these is real forward progress - they leave the Matched pool, so the
                // chain's zero-progress guard must not read this pass as having stalled
                result.itemsResolved += productErrorItems.size();

                // Only a sample of codes goes in the message - the item records carry the full detail
                List<String> sampleCodes = new List<String>();
                for (String code : unmatchedProductCodes) {
                    if (sampleCodes.size() >= 10) {
                        break;
                    }
                    sampleCodes.add(code);
                }

                String productWarning = productErrorItems.size() + ' item(s) skipped - product not found for EAN code(s): ' +
                    String.join(sampleCodes, ', ') +
                    (unmatchedProductCodes.size() > sampleCodes.size()
                        ? ' and ' + (unmatchedProductCodes.size() - sampleCodes.size()) + ' more'
                        : '');
                result.warningMessage = String.isBlank(result.warningMessage)
                    ? productWarning
                    : result.warningMessage + ' | ' + productWarning;
            }

            // Every remaining group lost all of its items to unmatched products - nothing to invoice
            if (itemsByAccountAndDate.isEmpty()) {
                result.success = true;
                closeReportIfFullyInvoiced(report, result);
                return result;
            }

            // Rebuild the working item list from the groups that survived the product check
            List<SLO_Sellout_Item__c> invoiceableItems = new List<SLO_Sellout_Item__c>();
            for (String compositeKey : itemsByAccountAndDate.keySet()) {
                invoiceableItems.addAll(itemsByAccountAndDate.get(compositeKey));
            }
            matchedItems = invoiceableItems;

            // Work out the amounts of every line before anything is created. A line with no usable
            // price is set aside instead of being invoiced at zero.
            Map<Id, LineAmounts> amountsByItemId = resolveLineAmounts(
                invoiceableItems, eanToMatchMap, isDedicatedBook, pricebookId
            );
            List<SLO_Sellout_Item__c> unpricedItems = new List<SLO_Sellout_Item__c>();
            Integer unpricedCount = 0;
            for (String compositeKey : new List<String>(itemsByAccountAndDate.keySet())) {
                List<SLO_Sellout_Item__c> pricedItems = new List<SLO_Sellout_Item__c>();
                for (SLO_Sellout_Item__c item : itemsByAccountAndDate.get(compositeKey)) {
                    LineAmounts amounts = amountsByItemId.get(item.Id);
                    if (amounts != null && amounts.failureNote == null) {
                        pricedItems.add(item);
                        continue;
                    }
                    item.SLO_Processing_Status__c = item.SLO_Source_Line_Item__c != null ? 'Skipped' : 'Error';
                    item.SLO_Processing_Notes__c = amounts == null ? NOTE_NO_PRICE : amounts.failureNote;
                    unpricedItems.add(item);
                    unpricedCount++;
                }
                if (pricedItems.isEmpty()) {
                    itemsByAccountAndDate.remove(compositeKey);
                    keyToAccountId.remove(compositeKey);
                    keyToDate.remove(compositeKey);
                } else {
                    itemsByAccountAndDate.put(compositeKey, pricedItems);
                }
            }

            if (!unpricedItems.isEmpty()) {
                Database.update(unpricedItems, false);
                result.itemsSkipped += unpricedCount;
                result.itemsResolved += unpricedCount;
                String priceWarning = unpricedCount + ' item(s) not invoiced - no price found (' +
                    NOTE_NO_PRICE + ')';
                result.warningMessage = String.isBlank(result.warningMessage)
                    ? priceWarning
                    : result.warningMessage + ' | ' + priceWarning;
            }

            if (itemsByAccountAndDate.isEmpty()) {
                result.success = true;
                closeReportIfFullyInvoiced(report, result);
                return result;
            }

            invoiceableItems = new List<SLO_Sellout_Item__c>();
            for (String compositeKey : itemsByAccountAndDate.keySet()) {
                invoiceableItems.addAll(itemsByAccountAndDate.get(compositeKey));
            }
            matchedItems = invoiceableItems;

            // Daily items point at their source invoice line; the new invoices and lines take their
            // Usage Company, number and product fields from it, as the weekly batch does
            Set<Id> sourceLineIds = new Set<Id>();
            for (SLO_Sellout_Item__c item : invoiceableItems) {
                if (item.SLO_Source_Line_Item__c != null) {
                    sourceLineIds.add(item.SLO_Source_Line_Item__c);
                }
            }
            Map<Id, Invoice_Line_Item__c> sourceLines = sourceLineIds.isEmpty()
                ? new Map<Id, Invoice_Line_Item__c>()
                : new Map<Id, Invoice_Line_Item__c>([
                    SELECT Id, Name, Product_Name__c, Product_SKU__c, SKU_Code__c, Order__c,
                           Invoice_Number__c, Invoice_Number__r.Name, Invoice_Number__r.Usage_Company__c,
                           Invoice_Number__r.CurrencyIsoCode
                    FROM Invoice_Line_Item__c
                    WHERE Id IN :sourceLineIds
                ]);
            Map<String, Invoice_Line_Item__c> keyToSourceLine = new Map<String, Invoice_Line_Item__c>();
            Map<Date, Invoice_Line_Item__c> dateToSourceLine = new Map<Date, Invoice_Line_Item__c>();
            for (String compositeKey : itemsByAccountAndDate.keySet()) {
                for (SLO_Sellout_Item__c item : itemsByAccountAndDate.get(compositeKey)) {
                    Invoice_Line_Item__c src = item.SLO_Source_Line_Item__c == null
                        ? null : sourceLines.get(item.SLO_Source_Line_Item__c);
                    if (src == null) {
                        continue;
                    }
                    if (!keyToSourceLine.containsKey(compositeKey)) {
                        keyToSourceLine.put(compositeKey, src);
                    }
                    Date groupDate = keyToDate.get(compositeKey);
                    if (!dateToSourceLine.containsKey(groupDate)) {
                        dateToSourceLine.put(groupDate, src);
                    }
                }
            }

            // Orders whose Child Account Non SBO is empty get the matched child account
            Set<Id> sourceOrderIds = new Set<Id>();
            for (Invoice_Line_Item__c src : sourceLines.values()) {
                if (src.Order__c != null) {
                    sourceOrderIds.add(src.Order__c);
                }
            }
            Map<Id, Order> sourceOrders = sourceOrderIds.isEmpty()
                ? new Map<Id, Order>()
                : new Map<Id, Order>([
                    SELECT Id, Child_Account_Non_SBO__c FROM Order WHERE Id IN :sourceOrderIds
                ]);
            Map<Id, Order> ordersToFill = new Map<Id, Order>();
            for (String compositeKey : itemsByAccountAndDate.keySet()) {
                Invoice_Line_Item__c src = keyToSourceLine.get(compositeKey);
                Id childId = keyToAccountId.get(compositeKey);
                if (src != null && src.Order__c != null && childId != null && childId != parentAccountId) {
                    Order ord = sourceOrders.get(src.Order__c);
                    if (ord != null && ord.Child_Account_Non_SBO__c == null
                        && !ordersToFill.containsKey(ord.Id)) {
                        ordersToFill.put(ord.Id, new Order(Id = ord.Id, Child_Account_Non_SBO__c = childId));
                    }
                }
            }
            List<Invoice__c> invoicesToInsert = new List<Invoice__c>();
            Map<String, List<SLO_Sellout_Item__c>> keyToItems = new Map<String, List<SLO_Sellout_Item__c>>();
            // Keep an explicit ordered key list so each inserted invoice is paired with the exact
            // group it came from - relying on map key order would risk attaching line items
            // to the wrong invoice
            List<String> orderedInvoiceKeys = new List<String>();

            for (String compositeKey : itemsByAccountAndDate.keySet()) {
                Id accountId = keyToAccountId.get(compositeKey);
                Date invoiceDate = keyToDate.get(compositeKey);
                List<SLO_Sellout_Item__c> items = itemsByAccountAndDate.get(compositeKey);
                keyToItems.put(compositeKey, items);

                // A group whose customer and date already has a sellout invoice keeps that invoice -
                // only the products it does not yet carry reach this point, so they are added as new
                // lines on it rather than duplicating the invoice itself
                if (appendToExistingInvoiceIds.containsKey(compositeKey)) {
                    continue;
                }

                // Create invoice (Name will be set after insert)
                Invoice_Line_Item__c groupSource = keyToSourceLine.get(compositeKey);
                Invoice__c invoice = new Invoice__c(
                    Account_Name__c = accountId,
                    Invoice_Date__c = invoiceDate,
                    Status__c = 'Closed',
                    Delivered_VN__c = false,
                    Manual_Creation__c = false,
                    Valid__c = true,
                    Transaction_type__c = 'Internal Sellout',
                    Usage_Company__c = groupSource != null && String.isNotBlank(groupSource.Invoice_Number__r.Usage_Company__c)
                        ? groupSource.Invoice_Number__r.Usage_Company__c : parentUsageCompany
                );
                // Follow the original invoice's currency
                if (groupSource != null && groupSource.Invoice_Number__r.CurrencyIsoCode != null) {
                    invoice.put('CurrencyIsoCode', groupSource.Invoice_Number__r.CurrencyIsoCode);
                }
                if (groupSource != null && accountId != parentAccountId) {
                    invoice.Child_Account_Non_SBO__c = accountId;
                }
                invoicesToInsert.add(invoice);
                orderedInvoiceKeys.add(compositeKey);
            }

            // Insert positive invoices
            insert invoicesToInsert;
            Integer positiveInvoiceCount = invoicesToInsert.size();

            // Generate and set invoice numbers for positive invoices; daily groups reuse the weekly
            // batch convention (source invoice number plus suffix)
            List<Invoice__c> invoicesToUpdateWithNumbers = new List<Invoice__c>();
            Integer positiveSequence = 1;
            Map<Id, Integer> namesPerSourceInvoice = new Map<Id, Integer>();
            Map<String, String> sourceNamedPositiveByKey = new Map<String, String>();

            for (Integer i = 0; i < invoicesToInsert.size(); i++) {
                Invoice__c invoice = invoicesToInsert[i];
                Invoice_Line_Item__c groupSource = keyToSourceLine.get(orderedInvoiceKeys[i]);
                String invoiceNumber = null;
                if (groupSource != null) {
                    Id sourceInvoiceId = groupSource.Invoice_Number__c;
                    Integer used = namesPerSourceInvoice.containsKey(sourceInvoiceId)
                        ? namesPerSourceInvoice.get(sourceInvoiceId) : 0;
                    namesPerSourceInvoice.put(sourceInvoiceId, used + 1);
                    invoiceNumber = SLO_SelloutInvoiceReviewBatch.deriveSelloutInvoiceName(
                        groupSource.Invoice_Number__r.Name, used
                    );
                }
                if (invoiceNumber == null) {
                    invoiceNumber = generateInvoiceNumber(
                        invoice.Usage_Company__c, invoice.Invoice_Date__c, positiveSequence, false
                    );
                } else if (groupSource != null) {
                    sourceNamedPositiveByKey.put(orderedInvoiceKeys[i], invoiceNumber);
                }
                invoice.Name = invoiceNumber;
                invoicesToUpdateWithNumbers.add(invoice);
                positiveSequence++;
            }

            // Update invoices with generated numbers
            update invoicesToUpdateWithNumbers;

            // Resolve which invoice each group's line items belong on - the one just inserted, or the
            // one that already existed for that customer and date
            Map<String, Id> keyToInvoiceId = new Map<String, Id>(appendToExistingInvoiceIds);
            for (Integer i = 0; i < invoicesToInsert.size(); i++) {
                keyToInvoiceId.put(orderedInvoiceKeys[i], invoicesToInsert[i].Id);
            }

            // Offsetting invoices on the parent account: a group built from a source invoice gets its
            // own '<source>-N' invoice paired with its '<source>-SO'; other groups keep the
            // legacy one-per-date invoice.
            Map<String, List<SLO_Sellout_Item__c>> itemsByNegativeKey = new Map<String, List<SLO_Sellout_Item__c>>();
            Map<String, Date> dateByNegativeKey = new Map<String, Date>();
            Map<String, String> nameByNegativeKey = new Map<String, String>();
            Map<String, Invoice_Line_Item__c> sourceByNegativeKey = new Map<String, Invoice_Line_Item__c>();

            for (String compositeKey : itemsByAccountAndDate.keySet()) {
                Date invoiceDate = keyToDate.get(compositeKey);
                String posName = sourceNamedPositiveByKey.get(compositeKey);
                String negKey;
                if (posName != null) {
                    negKey = 'N_' + posName;
                    nameByNegativeKey.put(negKey, posName.replaceFirst('-SO(-[0-9]+)?$', '-N$1'));
                    sourceByNegativeKey.put(negKey, keyToSourceLine.get(compositeKey));
                } else {
                    negKey = 'D_' + String.valueOf(invoiceDate);
                    if (dateToSourceLine.containsKey(invoiceDate)) {
                        sourceByNegativeKey.put(negKey, dateToSourceLine.get(invoiceDate));
                    }
                }
                if (!itemsByNegativeKey.containsKey(negKey)) {
                    itemsByNegativeKey.put(negKey, new List<SLO_Sellout_Item__c>());
                    dateByNegativeKey.put(negKey, invoiceDate);
                }
                itemsByNegativeKey.get(negKey).addAll(itemsByAccountAndDate.get(compositeKey));
            }

            // Reuse an existing offsetting invoice: by date for legacy groups, by name for source ones
            Set<Date> parentInvoiceDates = new Set<Date>(dateByNegativeKey.values());
            Set<String> negativeNames = new Set<String>(nameByNegativeKey.values());
            Map<String, Id> existingNegativeByKey = new Map<String, Id>();
            for (Invoice__c existingNegative : [
                SELECT Id, Name, Invoice_Date__c
                FROM Invoice__c
                WHERE Account_Name__c = :parentAccountId
                AND Transaction_type__c = 'Internal Sellout N'
                AND (Invoice_Date__c IN :parentInvoiceDates OR Name IN :negativeNames)
            ]) {
                if (negativeNames.contains(existingNegative.Name)) {
                    existingNegativeByKey.put(
                        'N_' + existingNegative.Name.replaceFirst('-N(-[0-9]+)?$', '-SO$1'),
                        existingNegative.Id
                    );
                }
                String dateKey = 'D_' + String.valueOf(existingNegative.Invoice_Date__c);
                if (!existingNegativeByKey.containsKey(dateKey)) {
                    existingNegativeByKey.put(dateKey, existingNegative.Id);
                }
            }

            // Create negative invoices for parent account
            List<Invoice__c> negativeInvoicesToInsert = new List<Invoice__c>();
            List<String> orderedNegativeKeys = new List<String>();

            for (String negKey : itemsByNegativeKey.keySet()) {
                if (existingNegativeByKey.containsKey(negKey)) {
                    continue;
                }

                Date invoiceDate = dateByNegativeKey.get(negKey);
                Invoice_Line_Item__c dateSource = sourceByNegativeKey.get(negKey);
                Invoice__c negativeInvoice = new Invoice__c(
                    Account_Name__c = parentAccountId,
                    Invoice_Date__c = invoiceDate,
                    Status__c = 'Closed',
                    Delivered_VN__c = false,
                    Manual_Creation__c = false,
                    Valid__c = true,
                    Transaction_type__c = 'Internal Sellout N',
                    Usage_Company__c = dateSource != null && String.isNotBlank(dateSource.Invoice_Number__r.Usage_Company__c)
                        ? dateSource.Invoice_Number__r.Usage_Company__c : parentUsageCompany
                );
                // Follow the original invoice's currency
                if (dateSource != null && dateSource.Invoice_Number__r.CurrencyIsoCode != null) {
                    negativeInvoice.put('CurrencyIsoCode', dateSource.Invoice_Number__r.CurrencyIsoCode);
                }
                negativeInvoicesToInsert.add(negativeInvoice);
                orderedNegativeKeys.add(negKey);
            }

            // Insert negative invoices
            insert negativeInvoicesToInsert;
            Integer negativeInvoiceCount = negativeInvoicesToInsert.size();

            Map<String, Id> negativeInvoiceIdByKey = new Map<String, Id>(existingNegativeByKey);
            for (Integer i = 0; i < negativeInvoicesToInsert.size(); i++) {
                negativeInvoiceIdByKey.put(orderedNegativeKeys[i], negativeInvoicesToInsert[i].Id);
            }

            // Name negative invoices: '<source>-N' for source groups, legacy numbering otherwise
            List<Invoice__c> negativeInvoicesToUpdateWithNumbers = new List<Invoice__c>();
            Integer negativeSequence = 1;

            for (Integer i = 0; i < negativeInvoicesToInsert.size(); i++) {
                Invoice__c negativeInvoice = negativeInvoicesToInsert[i];
                String invoiceNumber = nameByNegativeKey.get(orderedNegativeKeys[i]);
                if (invoiceNumber == null) {
                    invoiceNumber = generateInvoiceNumber(negativeInvoice.Usage_Company__c, negativeInvoice.Invoice_Date__c, negativeSequence, true);
                }
                negativeInvoice.Name = invoiceNumber;
                negativeInvoicesToUpdateWithNumbers.add(negativeInvoice);
                negativeSequence++;
            }

            // Update negative invoices with generated numbers
            update negativeInvoicesToUpdateWithNumbers;

            result.invoicesCreated = positiveInvoiceCount + negativeInvoiceCount;
            result.positiveInvoicesCreated = positiveInvoiceCount;
            result.negativeInvoicesCreated = negativeInvoiceCount;

            // Create line items for positive invoices. Groups are walked by key, because a group can
            // now be attached either to an invoice inserted above or to one that already existed.
            List<Invoice_Line_Item__c> lineItemsToInsert = new List<Invoice_Line_Item__c>();
            List<SLO_Sellout_Item__c> itemsToUpdate = new List<SLO_Sellout_Item__c>();
            // Next manual line number per invoice, for lines that have no source line to copy from
            Map<Id, Integer> manualLineCounters = new Map<Id, Integer>();
            // Same order used again below to pair each inserted line item with its sellout item
            List<String> orderedLineItemKeys = new List<String>(itemsByAccountAndDate.keySet());
            Integer linesAddedToExisting = 0;

            // Lines must carry their invoice's currency, otherwise they default to the user's currency
            Set<Id> allInvoiceIds = new Set<Id>(keyToInvoiceId.values());
            allInvoiceIds.addAll(negativeInvoiceIdByKey.values());
            Map<Id, String> currencyByInvoiceId = new Map<Id, String>();
            for (Invoice__c inv : [SELECT Id, CurrencyIsoCode FROM Invoice__c WHERE Id IN :allInvoiceIds]) {
                currencyByInvoiceId.put(inv.Id, (String) inv.get('CurrencyIsoCode'));
            }

            for (String compositeKey : orderedLineItemKeys) {
                Id targetInvoiceId = keyToInvoiceId.get(compositeKey);
                List<SLO_Sellout_Item__c> items = keyToItems.get(compositeKey);
                Boolean isExistingInvoice = appendToExistingInvoiceIds.containsKey(compositeKey);

                for (SLO_Sellout_Item__c item : items) {
                    // Every surviving item has a resolved product; price may still be null when
                    // the country has no pricebook entry for it
                    ProductPriceMatch match = eanToMatchMap.get(item.SLO_Product_Code_EAN__c);
                    LineAmounts amounts = amountsByItemId.get(item.Id);

                    Invoice_Line_Item__c lineItem = new Invoice_Line_Item__c(
                        Invoice_Number__c = targetInvoiceId,
                        Product_Name__c = item.SLO_Product_Code_EAN__c,
                        Quantity__c = item.SLO_Quantity__c,
                        Status__c = 'Closed',
                        Valid__c = true
                    );
                    if (currencyByInvoiceId.get(targetInvoiceId) != null) {
                        lineItem.put('CurrencyIsoCode', currencyByInvoiceId.get(targetInvoiceId));
                    }
                    applyAmounts(lineItem, amounts, false);
                    applyResolvedProduct(lineItem, match);
                    applySourceProduct(lineItem, item, sourceLines);
                    applyManualLineName(lineItem, manualLineCounters);
                    lineItemsToInsert.add(lineItem);

                    if (isExistingInvoice) {
                        linesAddedToExisting++;
                    }
                }
            }

            // Insert positive line items
            insert lineItemsToInsert;
            result.lineItemsAddedToExistingInvoices = linesAddedToExisting;

            // Create negative line items for parent account invoices
            List<Invoice_Line_Item__c> negativeLineItemsToInsert = new List<Invoice_Line_Item__c>();

            for (String negKey : itemsByNegativeKey.keySet()) {
                Id negativeInvoiceId = negativeInvoiceIdByKey.get(negKey);
                List<SLO_Sellout_Item__c> items = itemsByNegativeKey.get(negKey);

                for (SLO_Sellout_Item__c item : items) {
                    // Mirrors the positive line: the product is guaranteed resolved by this point
                    LineAmounts amounts = amountsByItemId.get(item.Id);

                    Invoice_Line_Item__c negativeLineItem = new Invoice_Line_Item__c(
                        Invoice_Number__c = negativeInvoiceId,
                        Product_Name__c = item.SLO_Product_Code_EAN__c,
                        Quantity__c = -item.SLO_Quantity__c,
                        Status__c = 'Closed',
                        Valid__c = true
                    );
                    if (currencyByInvoiceId.get(negativeInvoiceId) != null) {
                        negativeLineItem.put('CurrencyIsoCode', currencyByInvoiceId.get(negativeInvoiceId));
                    }
                    applyAmounts(negativeLineItem, amounts, true);
                    applyResolvedProduct(negativeLineItem, eanToMatchMap.get(item.SLO_Product_Code_EAN__c));
                    applySourceProduct(negativeLineItem, item, sourceLines);
                    applyManualLineName(negativeLineItem, manualLineCounters);
                    negativeLineItemsToInsert.add(negativeLineItem);
                }
            }

            // Insert negative line items
            insert negativeLineItemsToInsert;
            result.lineItemsCreated = lineItemsToInsert.size() + negativeLineItemsToInsert.size();

            // Update sellout items with line item references, walking the groups in exactly the order
            // their line items were built so each item points at its own line
            Integer lineItemIndex = 0;
            for (String compositeKey : orderedLineItemKeys) {
                List<SLO_Sellout_Item__c> items = keyToItems.get(compositeKey);

                for (SLO_Sellout_Item__c item : items) {
                    item.SLO_Invoice_Line_Item__c = lineItemsToInsert[lineItemIndex].Id;
                    item.SLO_Processing_Status__c = 'Invoice_Created';
                    LineAmounts usedAmounts = amountsByItemId.get(item.Id);
                    if (usedAmounts != null && usedAmounts.priceSource != null) {
                        item.SLO_Processing_Notes__c = usedAmounts.priceSource;
                    } else if (item.SLO_Source_Line_Item__c != null) {
                        item.SLO_Processing_Notes__c = 'Price copied from the source invoice line';
                    }
                    itemsToUpdate.add(item);
                    lineItemIndex++;
                }
            }

            update itemsToUpdate;
            result.itemsResolved += itemsToUpdate.size();

            if (!ordersToFill.isEmpty()) {
                Database.update(ordersToFill.values(), false);
            }

            closeReportIfFullyInvoiced(report, result);

            result.success = true;

        } catch (Exception e) {
            result.success = false;
            result.errorMessage = 'Error creating invoices: ' + e.getMessage();

            // Update report status to Error. The report may be null if the query itself failed.
            try {
                if (report != null) {
                    report.SLO_Status__c = 'Error';
                    report.SLO_Error_Message__c = e.getMessage();
                    update report;
                }
            } catch (Exception updateEx) {
                System.debug('Error updating report status: ' + updateEx.getMessage());
            }
        }

        return result;
    }

    /**
     * @description The items one invoicing pass will process, with the cursor the next pass resumes from
     */
    private class InvoicePass {
        private List<SLO_Sellout_Item__c> items;
        private String cursorId;

        private InvoicePass(List<SLO_Sellout_Item__c> items, String cursorId) {
            this.items = items;
            this.cursorId = cursorId;
        }
    }

    /**
     * @description Pull in the remaining Matched items of every account/date group present in the
     * page, so a group split across the Id-ordered page boundary is still invoiced as one whole
     * group. Bounded by INVOICE_ITEMS_PASS_CEILING; a group that would push the pass past the
     * ceiling is held back whole and the cursor stops below it, so a later pass takes it from the
     * start rather than inheriting half of it.
     * @param reportId Sellout report being invoiced
     * @param pageItems Items read for this pass, ordered by Id
     * @return The items to process this pass and the cursor for the next one
     */
    private static InvoicePass completePartialGroups(
        String reportId,
        List<SLO_Sellout_Item__c> pageItems
    ) {
        Set<Id> pageItemIds = new Set<Id>();
        Set<Id> groupAccountIds = new Set<Id>();
        Set<Date> groupDates = new Set<Date>();
        Set<String> groupKeys = new Set<String>();

        for (SLO_Sellout_Item__c item : pageItems) {
            pageItemIds.add(item.Id);
            groupAccountIds.add(item.SLO_Matched_Account__c);
            groupDates.add(item.SLO_Item_Date__c);
            groupKeys.add(item.SLO_Matched_Account__c + '_' + String.valueOf(item.SLO_Item_Date__c));
        }

        // The account/date filter keeps this selective; the key check below discards the
        // account-by-date cross products that the filter cannot express in SOQL
        List<SLO_Sellout_Item__c> siblings = [
            SELECT Id, SLO_Matched_Account__c, SLO_Item_Date__c,
                   SLO_Product_Code_EAN__c, SLO_Quantity__c, SLO_Source_Line_Item__c
            FROM SLO_Sellout_Item__c
            WHERE SLO_Sellout_Report__c = :reportId
            AND SLO_Matched_Account__c IN :groupAccountIds
            AND SLO_Item_Date__c IN :groupDates
            AND SLO_Processing_Status__c = 'Matched'
            AND Id NOT IN :pageItemIds
            ORDER BY Id
            LIMIT :INVOICE_ITEMS_PASS_CEILING
        ];

        // Count how many extra items each straddling group would add, so a group is only completed
        // when the whole of it fits inside the ceiling
        Map<String, List<SLO_Sellout_Item__c>> extrasByKey = new Map<String, List<SLO_Sellout_Item__c>>();
        for (SLO_Sellout_Item__c sibling : siblings) {
            String key = sibling.SLO_Matched_Account__c + '_' + String.valueOf(sibling.SLO_Item_Date__c);
            if (!groupKeys.contains(key)) {
                continue;
            }
            if (!extrasByKey.containsKey(key)) {
                extrasByKey.put(key, new List<SLO_Sellout_Item__c>());
            }
            extrasByKey.get(key).add(sibling);
        }

        String pageCursorId = String.valueOf(pageItems[pageItems.size() - 1].Id);

        if (extrasByKey.isEmpty()) {
            return new InvoicePass(pageItems, pageCursorId);
        }

        // A group that cannot be completed within the ceiling is removed from this pass entirely -
        // leaving half of it behind would create an invoice its remainder then looks like a
        // duplicate of.
        Set<String> deferredKeys = new Set<String>();
        Integer runningTotal = pageItems.size();
        for (String key : extrasByKey.keySet()) {
            Integer extras = extrasByKey.get(key).size();
            if (runningTotal + extras > INVOICE_ITEMS_PASS_CEILING) {
                deferredKeys.add(key);
            } else {
                runningTotal += extras;
            }
        }

        // The page arrived ordered by Id, so position in it stands in for Id ordering - Apex has no
        // relational operators for Id. Find where the earliest deferred group starts.
        Integer firstDeferredIndex = -1;
        for (Integer i = 0; i < pageItems.size(); i++) {
            SLO_Sellout_Item__c item = pageItems[i];
            String key = item.SLO_Matched_Account__c + '_' + String.valueOf(item.SLO_Item_Date__c);
            if (deferredKeys.contains(key)) {
                firstDeferredIndex = i;
                break;
            }
        }

        // No group was deferred, so the whole page plus its completions runs this pass
        if (firstDeferredIndex < 0) {
            List<SLO_Sellout_Item__c> completed = new List<SLO_Sellout_Item__c>(pageItems);
            for (String key : extrasByKey.keySet()) {
                completed.addAll(extrasByKey.get(key));
            }
            return new InvoicePass(completed, pageCursorId);
        }

        // A group is deferred, so stop the cursor just below where it starts and process only the
        // items before it. Splitting the deferred group would create an invoice that its remainder
        // then looks like a duplicate of, which is exactly the stall this rework removes.
        if (firstDeferredIndex == 0) {
            // The deferred group starts the page, so there is no safe lower cursor. Process the page
            // as read and move past it rather than stalling.
            return new InvoicePass(pageItems, pageCursorId);
        }

        List<SLO_Sellout_Item__c> beforeDeferred = new List<SLO_Sellout_Item__c>();
        Set<String> keysBeforeDeferred = new Set<String>();
        for (Integer i = 0; i < firstDeferredIndex; i++) {
            beforeDeferred.add(pageItems[i]);
            keysBeforeDeferred.add(
                pageItems[i].SLO_Matched_Account__c + '_' + String.valueOf(pageItems[i].SLO_Item_Date__c)
            );
        }
        // Complete the groups that are staying in this pass
        for (String key : keysBeforeDeferred) {
            if (extrasByKey.containsKey(key)) {
                beforeDeferred.addAll(extrasByKey.get(key));
            }
        }

        return new InvoicePass(beforeDeferred, String.valueOf(pageItems[firstDeferredIndex - 1].Id));
    }

    /**
     * @description Count the report's items still waiting to be invoiced
     * @param reportId Sellout report to count
     * @param afterItemId Only count items above this Id; pass null to count all of them
     * @return Number of items still at status Matched with an account
     */
    private static Integer countMatchedItems(String reportId, Id afterItemId) {
        if (afterItemId == null) {
            return [
                SELECT COUNT()
                FROM SLO_Sellout_Item__c
                WHERE SLO_Sellout_Report__c = :reportId
                AND SLO_Matched_Account__c != null
                AND SLO_Processing_Status__c = 'Matched'
            ];
        }
        return [
            SELECT COUNT()
            FROM SLO_Sellout_Item__c
            WHERE SLO_Sellout_Report__c = :reportId
            AND SLO_Matched_Account__c != null
            AND SLO_Processing_Status__c = 'Matched'
            AND Id > :afterItemId
        ];
    }

    /**
     * @description Count the report's items that have already produced an invoice line item
     * @param reportId Sellout report to count
     * @return Number of items at status Invoice_Created
     */
    private static Integer countInvoicedItems(String reportId) {
        return [
            SELECT COUNT()
            FROM SLO_Sellout_Item__c
            WHERE SLO_Sellout_Report__c = :reportId
            AND SLO_Processing_Status__c = 'Invoice_Created'
        ];
    }

    /**
     * @description Mark the report Completed only when a live count confirms no item is still
     * waiting to be invoiced. Closing on "the last page looked empty" is what previously left
     * reports showing Completed with thousands of items still matched.
     * @param report Report record being processed, updated in place
     * @param result Result of the pass just finished, re-counted before closing
     */
    private static void closeReportIfFullyInvoiced(SLO_Sellout_Report__c report, ApplySelloutResult result) {
        Integer stillMatched = countMatchedItems(report.Id, null);
        result.matchedItemsRemaining = stillMatched;
        result.moreItemsRemaining = (stillMatched > 0);

        if (stillMatched == 0) {
            report.SLO_Status__c = 'Completed';
            report.SLO_Error_Message__c = null;
            update report;
        }
    }

    /**
     * @description Recount a report's items and correct a status that no longer matches reality -
     * used to repair reports left Completed or Error while items were still awaiting invoicing
     * @param reportId Sellout report to reconcile
     * @return ReportStatus reflecting the corrected status and current item counts
     */
    @AuraEnabled(cacheable=false)
    public static ReportStatus reconcileReportStatus(String reportId) {
        try {
            SLO_Sellout_Report__c report = [
                SELECT Id, SLO_Status__c, SLO_Error_Message__c
                FROM SLO_Sellout_Report__c
                WHERE Id = :reportId
                LIMIT 1
            ];

            Integer stillMatched = countMatchedItems(reportId, null);

            if (stillMatched > 0 && report.SLO_Status__c == 'Completed') {
                // Items are still waiting, so Completed is wrong. Reopen to Draft rather than New:
                // the items are already imported and matched, so the report is reviewable and
                // Apply Sellout must stay available to finish invoicing them.
                report.SLO_Status__c = 'Draft';
                report.SLO_Error_Message__c = stillMatched +
                    ' item(s) are still waiting to be invoiced. Run Apply Sellout to finish them.';
                update report;
            } else if (stillMatched == 0 && report.SLO_Status__c == 'Error') {
                // Nothing is outstanding, so the error no longer describes the report
                report.SLO_Status__c = 'Completed';
                report.SLO_Error_Message__c = null;
                update report;
            } else if (report.SLO_Status__c == SLO_SelloutApplyBatch.STATUS_IN_PROCESS && !isSelloutJobRunning()) {
                // The run that set it is gone, so nothing will release it - hand it back for review
                report.SLO_Status__c = 'Draft';
                update report;
            }

            return getReportStatus(reportId);
        } catch (Exception e) {
            throw new AuraHandledException('Error reconciling report status: ' + e.getMessage());
        }
    }

    /**
     * @description Activate an inactive account and link sellout items
     * @param accountId ID of the account to activate
     * @param selloutItemIds List of sellout item IDs to link
     * @return String Success message or error
     */
    @AuraEnabled(cacheable=false)
    public static String activateAccount(String accountId, List<String> selloutItemIds) {
        assertItemsEditable(selloutItemIds);
        try {
            // Update account Status__c from 'N' to 'Active'
            Account accountToActivate = new Account(
                Id = accountId,
                Status__c = 'Active'
            );
            update accountToActivate;

            // Update all sellout items with this account
            List<SLO_Sellout_Item__c> itemsToUpdate = new List<SLO_Sellout_Item__c>();
            for (String itemId : selloutItemIds) {
                itemsToUpdate.add(new SLO_Sellout_Item__c(
                    Id = itemId,
                    SLO_Matched_Account__c = accountId,
                    SLO_Processing_Status__c = 'Matched',
                    SLO_Processing_Notes__c = NOTE_READY
                ));
            }

            if (!itemsToUpdate.isEmpty()) {
                update itemsToUpdate;
            }

            return 'Success';
        } catch (Exception e) {
            throw new AuraHandledException('Error activating account: ' + e.getMessage());
        }
    }

    /**
     * @description Create new child account with suffix for inactive account alternative
     * @param parentAccountId ID of the parent account
     * @param accountName Base name for the new account
     * @param selloutItemIds List of sellout item IDs to link
     * @return String ID of the newly created account
     */
    @AuraEnabled(cacheable=false)
    public static String createChildAccountWithSuffix(String parentAccountId, String accountName, List<String> selloutItemIds) {
        try {
            assertItemsEditable(selloutItemIds);
            // Query parent account to get Name, BillingCountry, OwnerId, and CurrencyIsoCode
            Account parentAccount = [SELECT Id, Name, BillingCountry, OwnerId, CurrencyIsoCode FROM Account WHERE Id = :parentAccountId LIMIT 1];

            // Sellout-created accounts always carry the sellout suffix and parent marker, so the
            // name is predictable and the matching pass can find it again on the next import.
            String newAccountName = buildSelloutAccountName(accountName, parentAccount.Name);
            Account newAccount = new Account(
                Name = newAccountName,
                ParentId = parentAccountId,
                OwnerId = parentAccount.OwnerId,
                BillingStreet = 'Automatic',
                BillingCity = 'Automatic',
                BillingCountry = parentAccount.BillingCountry,
                BillingPostalCode = '99999',
                Status__c = 'Active',
                CurrencyIsoCode = parentAccount.CurrencyIsoCode
            );
            Database.insert(newAccount, buildSingleCreateOptions());
            addAccountsCreatedForItems(selloutItemIds, 1);

            // Update all sellout items with this account name
            List<SLO_Sellout_Item__c> itemsToUpdate = new List<SLO_Sellout_Item__c>();
            for (String itemId : selloutItemIds) {
                itemsToUpdate.add(new SLO_Sellout_Item__c(
                    Id = itemId,
                    SLO_Matched_Account__c = newAccount.Id,
                    SLO_Processing_Status__c = 'Matched',
                    SLO_Processing_Notes__c = NOTE_READY
                ));
            }

            if (!itemsToUpdate.isEmpty()) {
                update itemsToUpdate;
            }

            return newAccount.Id;
        } catch (Exception e) {
            throw new AuraHandledException('Error creating child account with suffix: ' + e.getMessage());
        }
    }

    /**
     * @description Get saved column mapping from Account record
     * @param accountId ID of the account
     * @return String JSON string containing saved column mapping or null if none exists
     */
    @AuraEnabled(cacheable=false)
    public static String getSavedColumnMapping(String accountId) {
        try {
            if (String.isBlank(accountId)) {
                return null;
            }

            Account acc = [
                SELECT Id, SLO_Sellout_Column_Mapping__c
                FROM Account
                WHERE Id = :accountId
                LIMIT 1
            ];

            return acc.SLO_Sellout_Column_Mapping__c;
        } catch (Exception e) {
            System.debug('Error retrieving saved column mapping: ' + e.getMessage());
            return null;
        }
    }

    /**
     * @description Save column mapping to Account record
     * @param accountId ID of the account
     * @param mappingJson JSON string containing column mapping
     */
    @AuraEnabled(cacheable=false)
    public static void saveColumnMapping(String accountId, String mappingJson) {
        try {
            if (String.isBlank(accountId) || String.isBlank(mappingJson)) {
                return;
            }

            Account acc = new Account(
                Id = accountId,
                SLO_Sellout_Column_Mapping__c = mappingJson
            );
            update acc;
        } catch (Exception e) {
            throw new AuraHandledException('Error saving column mapping: ' + e.getMessage());
        }
    }

    public class AutomaticSelloutConfig {
        @AuraEnabled public Boolean automaticSellout { get; set; }
        @AuraEnabled public String selloutMethod { get; set; }
    }

    @AuraEnabled(cacheable=false)
    public static String runDailySelloutNow(String accountId) {
        if (String.isBlank(accountId)) {
            throw new AuraHandledException('Account is required.');
        }
        try {
            Account acc = [
                SELECT Id, SLO_Automatic_Sellout__c, SLO_Sellout_Method__c
                FROM Account WHERE Id = :accountId LIMIT 1
            ];
            if (acc.SLO_Automatic_Sellout__c != true) {
                throw new AuraHandledException('Enable Automated Sellout on this account first.');
            }
            if (acc.SLO_Sellout_Method__c != SLO_SelloutDailyAutoBatch.REQUIRED_METHOD) {
                throw new AuraHandledException('Set the Sellout Method to the linked order details method first.');
            }
            return Database.executeBatch(new SLO_SelloutDailyAutoBatch(acc.Id), 1);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Error starting the automated sellout: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=false)
    public static AutomaticSelloutConfig getAutomaticSelloutConfig(String accountId) {
        AutomaticSelloutConfig config = new AutomaticSelloutConfig();
        config.automaticSellout = false;
        if (String.isBlank(accountId)) {
            return config;
        }
        try {
            Account acc = [
                SELECT Id, SLO_Automatic_Sellout__c, SLO_Sellout_Method__c
                FROM Account
                WHERE Id = :accountId
                LIMIT 1
            ];
            config.automaticSellout = acc.SLO_Automatic_Sellout__c == true;
            config.selloutMethod = acc.SLO_Sellout_Method__c;
            return config;
        } catch (Exception e) {
            throw new AuraHandledException('Error loading automatic sellout settings: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=false)
    public static AutomaticSelloutConfig saveAutomaticSelloutConfig(
        String accountId,
        Boolean automaticSellout,
        String selloutMethod
    ) {
        if (String.isBlank(accountId)) {
            throw new AuraHandledException('An account is required to save automatic sellout settings.');
        }
        try {
            Boolean enabled = automaticSellout == true;
            Account acc = new Account(
                Id = accountId,
                SLO_Automatic_Sellout__c = enabled,
                SLO_Sellout_Method__c = String.isBlank(selloutMethod) ? null : selloutMethod
            );
            update acc;
            AutomaticSelloutConfig config = new AutomaticSelloutConfig();
            config.automaticSellout = acc.SLO_Automatic_Sellout__c;
            config.selloutMethod = acc.SLO_Sellout_Method__c;
            return config;
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        } catch (Exception e) {
            throw new AuraHandledException('Error saving automatic sellout settings: ' + e.getMessage());
        }
    }

    /**
     * @description The running user's import preferences, resolved user -> profile -> org default,
     * so an administrator can set a country's delimiter on its profile while each user's own last
     * choice still wins
     */
    public class ImportPreferences {
        @AuraEnabled public Date startDate { get; set; }
        @AuraEnabled public String csvDelimiter { get; set; }
        @AuraEnabled public String delimiterSource { get; set; }
    }

    private static final Date DEFAULT_START_DATE = Date.newInstance(2026, 1, 1);

    @AuraEnabled(cacheable=false)
    public static ImportPreferences getImportPreferences() {
        SLO_Import_Preferences__c stored = SLO_Import_Preferences__c.getInstance();
        ImportPreferences prefs = new ImportPreferences();
        prefs.startDate = stored.SLO_Start_Date__c ?? DEFAULT_START_DATE;
        String countryDelimiter = getCountryCsvDelimiter();
        // Priority: country setting, then the user's saved preference, then comma
        if (String.isNotBlank(countryDelimiter)) {
            prefs.csvDelimiter = countryDelimiter;
            prefs.delimiterSource = 'COUNTRY';
        } else if (String.isNotBlank(stored.SLO_CSV_Delimiter__c)) {
            prefs.csvDelimiter = stored.SLO_CSV_Delimiter__c;
            prefs.delimiterSource = 'USER';
        } else {
            prefs.csvDelimiter = ',';
            prefs.delimiterSource = 'DEFAULT';
        }
        return prefs;
    }

    /**
     * @description CSV delimiter configured for the running user's Usage Company in the country settings
     * @return Delimiter character, or null when no active country setting or delimiter is found
     */
    @AuraEnabled(cacheable=false)
    public static String getCountryCsvDelimiter() {
        try {
            List<User> users = [SELECT Usage_Company__c FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
            if (users.isEmpty() || String.isBlank(users[0].Usage_Company__c)) {
                return null;
            }
            List<ARF_CountrySettings__c> settings = [
                SELECT ARF_CsvDelimiter__c
                FROM ARF_CountrySettings__c
                WHERE ARF_CountryCode__c = :users[0].Usage_Company__c
                AND ARF_IsActive__c = true
                LIMIT 1
            ];
            if (settings.isEmpty()) {
                return null;
            }
            return normalizeDelimiter(settings[0].ARF_CsvDelimiter__c);
        } catch (Exception e) {
            System.debug('Error resolving country CSV delimiter: ' + e.getMessage());
            return null;
        }
    }

    private static String normalizeDelimiter(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        String v = raw.trim().toLowerCase();
        if (v.startsWith('semicolon')) {
            return ';';
        }
        if (v.startsWith('comma')) {
            return ',';
        }
        if (v.startsWith('tab')) {
            return '\\t';
        }
        if (v.startsWith('pipe')) {
            return '|';
        }
        return raw.trim().length() == 1 ? raw.trim() : null;
    }

    /**
     * @description Remember the start date and delimiter on the running user's own preferences record
     * @param startDate Start date chosen on the import screen
     * @param csvDelimiter Delimiter chosen on the import screen
     */
    @AuraEnabled(cacheable=false)
    public static void saveImportPreferences(Date startDate, String csvDelimiter) {
        try {
            SLO_Import_Preferences__c prefs = SLO_Import_Preferences__c.getValues(UserInfo.getUserId());
            if (prefs == null) {
                prefs = new SLO_Import_Preferences__c(SetupOwnerId = UserInfo.getUserId());
            }
            prefs.SLO_Start_Date__c = startDate;
            // Store the user's chosen delimiter; comma (the final fallback) needs no stored value
            Boolean isDefault = String.isBlank(csvDelimiter) || csvDelimiter == ',';
            prefs.SLO_CSV_Delimiter__c = isDefault ? null : csvDelimiter;
            upsert prefs;
        } catch (Exception e) {
            throw new AuraHandledException('Error saving import preferences: ' + e.getMessage());
        }
    }

    /**
     * @description Resolve pricebook for a given usage company (country code)
     * Checks ARF_UserPricebookOverrides__c JSON for current user first (highest priority),
     * then falls back to ARF_DefaultPricebook__c (country default)
     * @param usageCompany The usage company code (e.g., 'GR', 'FR', 'US') from Account.Account_Usage_Company__c
     * @return Id of the resolved pricebook, or null if no pricebook found
     */
    private static String withUserUsageCompany(String accountUsageCompany) {
        if (String.isNotBlank(accountUsageCompany)) {
            return accountUsageCompany;
        }
        List<User> users = [SELECT Usage_Company__c FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        return users.isEmpty() ? null : users[0].Usage_Company__c;
    }

    private static Id resolvePricebook(String usageCompany) {
        if (String.isBlank(usageCompany)) {
            return null;
        }

        try {
            // Query ARF_CountrySettings__c for the matching country code
            List<ARF_CountrySettings__c> countrySettings = [
                SELECT Id, ARF_DefaultPricebook__c, ARF_UserPricebookOverrides__c
                FROM ARF_CountrySettings__c
                WHERE ARF_CountryCode__c = :usageCompany
                AND ARF_IsActive__c = true
                LIMIT 1
            ];

            if (countrySettings.isEmpty()) {
                System.debug('No active country settings found for usage company: ' + usageCompany);
                return null;
            }

            ARF_CountrySettings__c countrySetting = countrySettings[0];
            Id currentUserId = UserInfo.getUserId();

            // Check ARF_UserPricebookOverrides__c JSON for user-specific pricebook (highest priority)
            if (String.isNotBlank(countrySetting.ARF_UserPricebookOverrides__c)) {
                try {
                    List<Object> overrides = (List<Object>) JSON.deserializeUntyped(countrySetting.ARF_UserPricebookOverrides__c);

                    for (Object overrideObj : overrides) {
                        Map<String, Object> overrideMap = (Map<String, Object>) overrideObj;
                        String userId = (String) overrideMap.get('userId');
                        String pricebookId = (String) overrideMap.get('pricebookId');

                        if (userId == currentUserId && String.isNotBlank(pricebookId)) {
                            System.debug('User-specific pricebook found for user ' + currentUserId + ': ' + pricebookId);
                            return Id.valueOf(pricebookId);
                        }
                    }
                } catch (Exception e) {
                    System.debug('Error parsing ARF_UserPricebookOverrides__c JSON: ' + e.getMessage());
                }
            }

            // Fall back to country default pricebook
            if (countrySetting.ARF_DefaultPricebook__c != null) {
                System.debug('Using country default pricebook: ' + countrySetting.ARF_DefaultPricebook__c);
                return countrySetting.ARF_DefaultPricebook__c;
            }

            System.debug('No pricebook configured for usage company: ' + usageCompany);
            return null;

        } catch (Exception e) {
            System.debug('Error resolving pricebook for usage company ' + usageCompany + ': ' + e.getMessage());
            return null;
        }
    }

    public static final String NOTE_NO_PRICE = 'No previous invoice price or price book entry found';
    public static final String NOTE_NO_SOURCE_AMOUNTS = 'Source invoice line has no amounts to copy';

    /**
     * @description Resolved amounts for one sellout line; failureNote is set when it cannot be invoiced
     */
    private class LineAmounts {
        Decimal unitPrice;
        Decimal netPrice;
        Decimal totalAfterDiscount;
        Decimal grossPrice;
        Decimal grossValue;
        Decimal vatOriginal;
        Decimal vatDollars;
        Boolean yearAfter2022;
        String failureNote;
        String priceSource;
    }

    private static Map<String, String> priceSourceByEan = new Map<String, String>();

    /**
     * @description Copy the product name, Product (SKU) and SKU Id from the source invoice line
     * onto a new line; lines without a source keep the product code they were created with
     */
    private static void applyResolvedProduct(Invoice_Line_Item__c line, ProductPriceMatch match) {
        if (match == null) {
            return;
        }
        line.Product_SKU__c = match.productId;
        if (String.isNotBlank(match.productName)) {
            line.Product_Name__c = match.productName;
        }
        if (String.isNotBlank(match.productCode)) {
            line.SKU_Code__c = match.productCode;
        }
    }

    private static void applySourceProduct(
        Invoice_Line_Item__c line,
        SLO_Sellout_Item__c item,
        Map<Id, Invoice_Line_Item__c> sourceLines
    ) {
        Invoice_Line_Item__c src = item.SLO_Source_Line_Item__c == null
            ? null : sourceLines.get(item.SLO_Source_Line_Item__c);
        if (src == null) {
            return;
        }
        if (String.isNotBlank(src.Product_Name__c)) {
            line.Product_Name__c = src.Product_Name__c;
        }
        // Never blank out a product or SKU Id already resolved from the imported code
        if (src.Product_SKU__c != null) {
            line.Product_SKU__c = src.Product_SKU__c;
        }
        if (String.isNotBlank(src.SKU_Code__c)) {
            line.SKU_Code__c = src.SKU_Code__c;
        }
        // Keep the original line item number instead of the auto-generated one
        if (String.isNotBlank(src.Name)) {
            line.Name = src.Name;
        }
    }

    /**
     * @description Name a manual line (one that kept no source line number) "Line 0", "Line 1", ...
     * counting per invoice, instead of leaving the auto-generated record number
     */
    private static void applyManualLineName(
        Invoice_Line_Item__c line,
        Map<Id, Integer> counters
    ) {
        if (String.isNotBlank(line.Name) || line.Invoice_Number__c == null) {
            return;
        }
        Integer next = counters.containsKey(line.Invoice_Number__c)
            ? counters.get(line.Invoice_Number__c) : 0;
        line.Name = 'Line ' + next;
        counters.put(line.Invoice_Number__c, next + 1);
    }

    /**
     * @description Copy resolved amounts onto a line; the offsetting line keeps unit prices (its
     * quantity is already negative) and negates the totals
     */
    private static void applyAmounts(Invoice_Line_Item__c line, LineAmounts a, Boolean negate) {
        Decimal sign = negate ? -1 : 1;
        line.Unit_Price__c = a.unitPrice;
        line.Net_Price__c = a.netPrice == null ? null : a.netPrice * sign;
        line.Gross_Price__c = a.grossPrice;
        line.VAT_In_Original_Price__c = a.vatOriginal == null ? null : a.vatOriginal * sign;
        line.Total_After_Discount__c = a.totalAfterDiscount == null ? null : a.totalAfterDiscount * sign;
        line.Gross_Value__c = a.grossValue == null ? null : a.grossValue * sign;
        line.VAT_In_Dollars__c = a.vatDollars == null ? null : a.vatDollars * sign;
        if (a.yearAfter2022 != null) {
            line.YearAfter2022__c = a.yearAfter2022;
        }
    }

    /**
     * @description Work out the amounts for every item. Daily items copy their source line; manual
     * items use the latest invoice price for the customer and product (Last Item Price, falling back
     * to the country default price book) or the chosen price book.
     */
    private static Map<Id, LineAmounts> resolveLineAmounts(
        List<SLO_Sellout_Item__c> items,
        Map<String, ProductPriceMatch> eanToMatchMap,
        Boolean isDedicatedBook,
        Id fallbackPricebookId
    ) {
        Map<Id, LineAmounts> result = new Map<Id, LineAmounts>();

        Set<Id> sourceIds = new Set<Id>();
        Set<Id> accountIds = new Set<Id>();
        for (SLO_Sellout_Item__c item : items) {
            if (item.SLO_Source_Line_Item__c != null) {
                sourceIds.add(item.SLO_Source_Line_Item__c);
            } else if (item.SLO_Matched_Account__c != null) {
                accountIds.add(item.SLO_Matched_Account__c);
            }
        }

        Map<Id, Invoice_Line_Item__c> sources = sourceIds.isEmpty()
            ? new Map<Id, Invoice_Line_Item__c>()
            : new Map<Id, Invoice_Line_Item__c>([
                SELECT Id, Unit_Price__c, Net_Price__c, Total_After_Discount__c, Gross_Price__c,
                       Gross_Value__c, VAT_In_Original_Price__c, VAT_In_Dollars__c, YearAfter2022__c
                FROM Invoice_Line_Item__c
                WHERE Id IN :sourceIds
            ]);

        // Latest price per customer and normalized product code, newest invoice first
        Map<String, Decimal> lastPrice = new Map<String, Decimal>();
        if (!isDedicatedBook && !accountIds.isEmpty()) {
            for (Invoice_Line_Item__c line : [
                SELECT Product_Name__c, SKU_Code__c, Unit_Price__c, Invoice_Number__r.Account_Name__c
                FROM Invoice_Line_Item__c
                WHERE Invoice_Number__r.Account_Name__c IN :accountIds
                AND Unit_Price__c != null AND Unit_Price__c != 0
                ORDER BY Invoice_Number__r.Invoice_Date__c DESC, CreatedDate DESC
                LIMIT 50000
            ]) {
                String code = normalizeProductCode(String.isNotBlank(line.SKU_Code__c) ? line.SKU_Code__c : line.Product_Name__c);
                if (code == null) {
                    continue;
                }
                String key = line.Invoice_Number__r.Account_Name__c + '_' + code;
                if (!lastPrice.containsKey(key)) {
                    lastPrice.put(key, line.Unit_Price__c);
                }
            }
        }

        for (SLO_Sellout_Item__c item : items) {
            LineAmounts a = new LineAmounts();
            result.put(item.Id, a);
            Decimal quantity = item.SLO_Quantity__c == null ? 0 : item.SLO_Quantity__c;

            if (item.SLO_Source_Line_Item__c != null) {
                Invoice_Line_Item__c src = sources.get(item.SLO_Source_Line_Item__c);
                if (src == null || src.Unit_Price__c == null || src.Total_After_Discount__c == null) {
                    a.failureNote = NOTE_NO_SOURCE_AMOUNTS;
                    continue;
                }
                a.unitPrice = src.Unit_Price__c;
                a.netPrice = src.Net_Price__c;
                a.totalAfterDiscount = src.Total_After_Discount__c;
                a.grossPrice = src.Gross_Price__c;
                a.grossValue = src.Gross_Value__c;
                a.vatOriginal = src.VAT_In_Original_Price__c;
                // GST (VAT In Dollars) falls back to the VAT amount when the source line has none
                a.vatDollars = src.VAT_In_Dollars__c != null ? src.VAT_In_Dollars__c : src.VAT_In_Original_Price__c;
                a.yearAfter2022 = src.YearAfter2022__c;
                continue;
            }

            ProductPriceMatch match = eanToMatchMap.get(item.SLO_Product_Code_EAN__c);
            Decimal price = null;
            if (!isDedicatedBook) {
                price = lastPrice.get(item.SLO_Matched_Account__c + '_' + normalizeProductCode(item.SLO_Product_Code_EAN__c));
            }
            if (price == null && match != null) {
                price = match.unitPrice;
            }
            if (price == null) {
                a.failureNote = isDedicatedBook
                    ? 'Product found for code ' + item.SLO_Product_Code_EAN__c + (match != null ? ' (' + match.productId + ')' : '')
                        + ' but no price book entry with a price above zero in the selected price book, the account country default or the user country default price book'
                    : NOTE_NO_PRICE;
                continue;
            }
            Boolean fromBook = match != null && match.unitPrice != null && price == match.unitPrice
                && priceSourceByEan.containsKey(item.SLO_Product_Code_EAN__c);
            a.priceSource = fromBook
                ? priceSourceByEan.get(item.SLO_Product_Code_EAN__c)
                : 'Last invoice price for this customer and item';
            a.unitPrice = price;
            a.netPrice = price * quantity;
            a.grossPrice = price;
            a.totalAfterDiscount = price * quantity;
            a.grossValue = price * quantity;
        }
        return result;
    }

    /**
     * @description Holds the product and price resolved for a single EAN code
     */
    public class ProductPriceMatch {
        public Id productId { get; set; }
        public Decimal unitPrice { get; set; }
        public String productName { get; set; }
        public String productCode { get; set; }

        public ProductPriceMatch(Id productId, Decimal unitPrice) {
            this.productId = productId;
            this.unitPrice = unitPrice;
        }
    }

    /**
     * @description Normalize a product code for matching by trimming whitespace and
     * removing leading zeros. Excel exports frequently drop the leading zero of an
     * EAN-13 code (e.g. 03700249117336 becomes 3700249117336), so both sides of the
     * comparison are normalized before matching.
     * @param code Raw EAN/product code
     * @return Normalized code, or null when the input is blank
     */
    private static String normalizeProductCode(String code) {
        if (String.isBlank(code)) {
            return null;
        }
        String trimmed = code.trim();
        // A code pasted from a spreadsheet often carries spaces or a non-breaking space inside it.
        // Those are stripped only when what remains is a pure number, so a genuinely alphanumeric
        // product code keeps its own spacing: a corrected EAN typed with a stray space must not go
        // on reading as "not found".
        String unspaced = trimmed.replaceAll('[\\s\\u00A0]', '');
        if (unspaced.length() > 0 && unspaced.isNumeric()) {
            trimmed = unspaced;
        }
        while (trimmed.length() > 1 && trimmed.startsWith('0')) {
            trimmed = trimmed.substring(1);
        }
        return trimmed;
    }

    // How many leading zeros a catalogue code may carry beyond the code as typed. A sellout file
    // and the product catalogue routinely disagree on padding (a 13-digit EAN stored as a 14-digit
    // GTIN, for instance), and the catalogue side has to be queried on the exact stored value - so
    // the padded variants are generated here rather than discovered. Without them a corrected code
    // that genuinely exists in the catalogue still came back "Product code not found", which left
    // the corrected lines sitting in "Needs a fix".
    private static final Integer PRODUCT_CODE_ZERO_PAD_VARIANTS = 3;

    /**
     * @description Bulk resolve products and prices from pricebook by EAN codes.
     * Matches products by Barcode__c first, then ProductCode fallback, tolerating
     * missing/extra leading zeros on either side. Then queries PricebookEntry for UnitPrice.
     * @param eanCodes Set of EAN/product codes from sellout items
     * @param pricebookId The pricebook ID to look up prices in
     * @return Map of EAN code to the matched product Id and unit price
     */
    private static Map<String, ProductPriceMatch> resolveProductPrices(Set<String> eanCodes, Id pricebookId) {
        Map<String, ProductPriceMatch> eanToMatchMap = new Map<String, ProductPriceMatch>();

        if (eanCodes == null || eanCodes.isEmpty()) {
            return eanToMatchMap;
        }

        try {
            Map<String, Id> eanToProductId = resolveProductIdsByEan(eanCodes);

            if (eanToProductId.isEmpty()) {
                return eanToMatchMap;
            }

            // Query PricebookEntry for resolved products (skipped when no pricebook is
            // configured — the product link is still returned so the lookup gets populated)
            Map<Id, Decimal> productIdToPriceMap = new Map<Id, Decimal>();

            if (pricebookId != null) {
                Set<Id> productIds = new Set<Id>(eanToProductId.values());

                // Entries of an inactive price book (country-default fallback) are accepted even if inactive
                Boolean bookActive = ![SELECT Id FROM Pricebook2 WHERE Id = :pricebookId AND IsActive = true LIMIT 1].isEmpty();
                List<PricebookEntry> pricebookEntries = [
                    SELECT Id, Product2Id, UnitPrice
                    FROM PricebookEntry
                    WHERE Pricebook2Id = :pricebookId
                    AND Product2Id IN :productIds
                    AND (IsActive = true OR IsActive = :bookActive)
                ];

                for (PricebookEntry entry : pricebookEntries) {
                    // A zero or empty entry counts as missing so the next price book is tried
                    if (entry.UnitPrice == null || entry.UnitPrice == 0) {
                        continue;
                    }
                    productIdToPriceMap.put(entry.Product2Id, entry.UnitPrice);
                }
            }

            // Product name and code, so new lines are filled the same way as the daily ones
            Map<Id, Product2> productsById = new Map<Id, Product2>([
                SELECT Id, Name, ProductCode FROM Product2 WHERE Id IN :eanToProductId.values()
            ]);

            for (String ean : eanToProductId.keySet()) {
                Id productId = eanToProductId.get(ean);
                ProductPriceMatch priceMatch = new ProductPriceMatch(productId, productIdToPriceMap.get(productId));
                Product2 prod = productsById.get(productId);
                if (prod != null) {
                    priceMatch.productName = prod.Name;
                    priceMatch.productCode = prod.ProductCode;
                }
                eanToMatchMap.put(ean, priceMatch);
            }

        } catch (Exception e) {
            System.debug('Error resolving product prices: ' + e.getMessage());
        }

        return eanToMatchMap;
    }

    /**
     * @description Every stored form of one product code worth querying the catalogue on: the code
     * as typed, its trimmed and normalized forms, and the normalized form re-padded with leading
     * zeros. The catalogue has to be queried on the exact value it stores, so a code the user has
     * just corrected resolves whichever padding the catalogue happens to use.
     * @param code Raw code as it appears on the sellout row
     * @return Candidate values to query Barcode__c / ProductCode on; never null
     */
    private static Set<String> buildProductCodeCandidates(String code) {
        Set<String> candidates = new Set<String>();
        if (String.isBlank(code)) {
            return candidates;
        }

        candidates.add(code);
        candidates.add(code.trim());

        String normalized = normalizeProductCode(code);
        if (String.isBlank(normalized)) {
            return candidates;
        }

        candidates.add(normalized);
        String padded = normalized;
        for (Integer i = 0; i < PRODUCT_CODE_ZERO_PAD_VARIANTS; i++) {
            padded = '0' + padded;
            candidates.add(padded);
        }

        return candidates;
    }

    /**
     * @description Resolve product Ids for a set of raw EAN/product codes: Product2 by Barcode__c
     * first, ProductCode as the fallback, tolerating missing or extra leading zeros on either side.
     * Shared by the invoice-time price lookup and the review-time validator, so a code both agree
     * on is the definition of a valid product.
     * @param eanCodes Raw codes as they appear on the sellout rows
     * @return Map of each resolvable raw code to its Product2 Id
     */
    private static Map<String, Id> resolveProductIdsByEan(Set<String> eanCodes) {
        Map<String, Id> eanToProductId = new Map<String, Id>();

        if (eanCodes == null || eanCodes.isEmpty()) {
            return eanToProductId;
        }

        // Build the candidate values to query: the raw code, its normalized form, and the
        // zero-padded variants of that form, so a catalogue entry that stores the code with extra
        // leading zeros is still returned. The comparison itself is done on the normalized form -
        // these variants exist only so the query can hit the exact value the catalogue stores.
        Set<String> candidateCodes = new Set<String>();
        for (String ean : eanCodes) {
            if (String.isBlank(ean)) {
                continue;
            }
            candidateCodes.addAll(buildProductCodeCandidates(ean));
        }
        candidateCodes.remove(null);

        if (candidateCodes.isEmpty()) {
            return eanToProductId;
        }

        // Step 1: Query Product2 by Barcode__c (primary match field), keyed on the
        // normalized code so leading-zero differences do not prevent a match
        Map<String, Id> normalizedToProductIdMap = new Map<String, Id>();

        List<Product2> productsByBarcode = [
            SELECT Id, Barcode__c, IsActive
            FROM Product2
            WHERE Barcode__c IN :candidateCodes
            ORDER BY IsActive DESC
        ];

        // An active product wins; an inactive one is used only when no active product has the code
        Set<Id> activeProductIds = new Set<Id>();
        for (Product2 product : productsByBarcode) {
            String normalizedBarcode = normalizeProductCode(product.Barcode__c);
            if (normalizedBarcode != null
                && (!normalizedToProductIdMap.containsKey(normalizedBarcode)
                    || (product.IsActive && !activeProductIds.contains(normalizedToProductIdMap.get(normalizedBarcode))))) {
                normalizedToProductIdMap.put(normalizedBarcode, product.Id);
            }
            if (product.IsActive) {
                activeProductIds.add(product.Id);
            }
        }

        // Step 2: Query Product2 by ProductCode for unmatched EANs (fallback)
        Set<String> unmatchedCandidates = new Set<String>();
        for (String ean : eanCodes) {
            String normalizedEan = normalizeProductCode(ean);
            if (normalizedEan != null && !normalizedToProductIdMap.containsKey(normalizedEan)) {
                unmatchedCandidates.addAll(buildProductCodeCandidates(ean));
            }
        }
        unmatchedCandidates.remove(null);

        if (!unmatchedCandidates.isEmpty()) {
            List<Product2> productsByCode = [
                SELECT Id, ProductCode, IsActive
                FROM Product2
                WHERE ProductCode IN :unmatchedCandidates
                ORDER BY IsActive DESC
            ];

            for (Product2 product : productsByCode) {
                String normalizedCode = normalizeProductCode(product.ProductCode);
                if (normalizedCode != null
                    && (!normalizedToProductIdMap.containsKey(normalizedCode)
                        || (product.IsActive && !activeProductIds.contains(normalizedToProductIdMap.get(normalizedCode))))) {
                    normalizedToProductIdMap.put(normalizedCode, product.Id);
                }
                if (product.IsActive) {
                    activeProductIds.add(product.Id);
                }
            }
        }

        // Map back from the original EAN value to the matched product
        for (String ean : eanCodes) {
            String normalizedEan = normalizeProductCode(ean);
            if (normalizedEan == null || !normalizedToProductIdMap.containsKey(normalizedEan)) {
                continue;
            }
            eanToProductId.put(ean, normalizedToProductIdMap.get(normalizedEan));
        }

        return eanToProductId;
    }

    /**
     * @description Generate invoice number in format SLO-{UsageCompany}-{YYYYMMDD}-{Sequence} or SLO-{UsageCompany}-{YYYYMMDD}-{Sequence}-N
     * @param usageCompany The usage company code (e.g., 'GR', 'US')
     * @param invoiceDate The invoice date
     * @param sequence The sequence number for this date
     * @param isNegative True if this is a negative invoice (adds -N suffix)
     * @return String The generated invoice number
     */
    private static String generateInvoiceNumber(String usageCompany, Date invoiceDate, Integer sequence, Boolean isNegative) {
        // Handle null or blank usage company
        String usageCompanyCode = String.isNotBlank(usageCompany) ? usageCompany : 'XX';

        // Format date as YYYYMMDD
        String dateStr = String.valueOf(invoiceDate.year()) +
                        String.valueOf(invoiceDate.month()).leftPad(2, '0') +
                        String.valueOf(invoiceDate.day()).leftPad(2, '0');

        // Format sequence with leading zeros (3 digits)
        String sequenceStr = String.valueOf(sequence).leftPad(3, '0');

        // Build invoice number
        String invoiceNumber = 'SLO-' + usageCompanyCode + '-' + dateStr + '-' + sequenceStr;

        // Add -N suffix for negative invoices
        if (isNegative) {
            invoiceNumber += '-N';
        }

        return invoiceNumber;
    }

    /**
     * @description Parse a CSV line handling quoted fields with configurable delimiter
     * @param line The CSV line to parse
     * @param delimiter The delimiter character (default: comma)
     * @return List of field values
     */
    private static List<String> parseCSVLine(String line, String delimiter) {
        // Default to comma if delimiter is null or blank
        if (String.isBlank(delimiter)) {
            delimiter = ',';
        }

        // Handle tab delimiter - convert from literal '\t' string to actual tab character
        if (delimiter == '\\t') {
            delimiter = '\t';
        }

        List<String> fields = new List<String>();
        Boolean inQuotes = false;
        String currentField = '';

        for (Integer i = 0; i < line.length(); i++) {
            String currentChar = line.substring(i, i + 1);

            if (currentChar == '"') {
                inQuotes = !inQuotes;
            } else if (currentChar == delimiter && !inQuotes) {
                fields.add(cleanCellValue(currentField));
                currentField = '';
            } else {
                currentField += currentChar;
            }
        }

        // Add last field
        fields.add(cleanCellValue(currentField));

        return fields;
    }

    /**
     * @description Parse a CSV line handling quoted fields (overload with default comma delimiter)
     * @param line The CSV line to parse
     * @return List of field values
     */
    private static List<String> parseCSVLine(String line) {
        return parseCSVLine(line, ',');
    }

    /**
     * @description Split file content into lines without using String.split, whose regex engine
     * throws "Regex too complicated" on large files. Trailing carriage returns are removed.
     * @param content The full file content
     * @param maxLines Stop after this many lines; null reads every line
     * @return List of lines
     */
    public static List<String> splitLines(String content, Integer maxLines) {
        List<String> lines = new List<String>();
        if (String.isEmpty(content)) {
            return lines;
        }

        Integer start = 0;
        Integer length = content.length();

        while (start <= length) {
            if (maxLines != null && lines.size() >= maxLines) {
                break;
            }

            Integer breakIndex = content.indexOf('\n', start);
            Integer lineEnd = (breakIndex == -1) ? length : breakIndex;

            String line = content.substring(start, lineEnd);
            if (line.endsWith('\r')) {
                line = line.substring(0, line.length() - 1);
            }
            lines.add(line);

            if (breakIndex == -1) {
                break;
            }
            start = breakIndex + 1;
        }

        return lines;
    }

    /**
     * @description Count the lines in file content without materialising them, so row counts can be
     * reported for files far too large to split into a list.
     * @param content The full file content
     * @return Integer number of lines (0 for empty content)
     */
    public static Integer countLines(String content) {
        if (String.isEmpty(content)) {
            return 0;
        }

        Integer count = 1;
        Integer index = content.indexOf('\n');
        while (index != -1) {
            // A trailing newline does not start another line
            if (index == content.length() - 1) {
                break;
            }
            count++;
            index = content.indexOf('\n', index + 1);
        }

        return count;
    }

    // =========================================================================
    // Async path: large files are handled by batch Apex and the user is emailed
    // =========================================================================

    /**
     * @description Row threshold above which imports and Apply Sellout run asynchronously
     * @return Integer number of rows at which the async path is used
     */
    @AuraEnabled(cacheable=false)
    public static Integer getAsyncRowThreshold() {
        return ASYNC_ROW_THRESHOLD;
    }

    /**
     * @description Column mapping and delimiter configuration passed to the import batch
     */
    public class ImportMappingConfig {
        @AuraEnabled public Integer itemDateIndex { get; set; }
        @AuraEnabled public Integer productCodeIndex { get; set; }
        @AuraEnabled public Integer quantityIndex { get; set; }
        @AuraEnabled public Integer customerAccountIndex { get; set; }
        // Optional column holding the original invoice line Id; its amounts are copied at invoicing
        @AuraEnabled public Integer sourceLineIndex { get; set; }
        @AuraEnabled public String csvDelimiter { get; set; }
        // Rows dated before this are ignored; null imports every row
        @AuraEnabled public Date startDate { get; set; }
        // Create accounts, skip lines needing a fix and apply the sellout without review
        @AuraEnabled public Boolean autoAccept { get; set; }
        // True (default) sets exact duplicates aside as Skipped; false diverts them to the
        // Duplicates section, or processes them when Auto Accept is on
        @AuraEnabled public Boolean skipDuplicates { get; set; }
        // Last_Item_Price or Dedicated_Price_Book, saved on the report for invoice pricing
        @AuraEnabled public String priceMethod { get; set; }
        @AuraEnabled public String priceBookId { get; set; }
    }

    /**
     * @description Active price books offered when the Dedicated Price Book option is chosen
     * @return Label/value options
     */
    @AuraEnabled(cacheable=false)
    public static List<PicklistOption> getPriceBookOptions() {
        List<PicklistOption> options = new List<PicklistOption>();
        for (Pricebook2 pb : [SELECT Id, Name FROM Pricebook2 WHERE IsActive = true ORDER BY Name LIMIT 500]) {
            options.add(new PicklistOption(pb.Name, pb.Id));
        }
        return options;
    }

    /**
     * @description Active price books of the account's country (Usage Company)
     * @param accountId The account being imported
     * @return Label/value options
     */
    @AuraEnabled(cacheable=false)
    public static List<PicklistOption> getCountryPriceBookOptions(Id accountId) {
        List<PicklistOption> options = new List<PicklistOption>();
        try {
            List<Account> accounts = [SELECT Account_Usage_Company__c FROM Account WHERE Id = :accountId LIMIT 1];
            String country = withUserUsageCompany(accounts.isEmpty() ? null : accounts[0].Account_Usage_Company__c);
            if (String.isBlank(country)) {
                return options;
            }
            // Active price books whose Usage Company is the same as, or similar to, the account's
            String countryLike = '%' + String.escapeSingleQuotes(country) + '%';
            for (Pricebook2 pb : [SELECT Id, Name FROM Pricebook2
                                  WHERE IsActive = true
                                  AND (Usage_Company__c = :country OR Usage_Company__c LIKE :countryLike)
                                  ORDER BY Name LIMIT 200]) {
                options.add(new PicklistOption(pb.Name, pb.Id));
            }
            if (options.isEmpty()) {
                // No active price book for the country: offer the country default, even if inactive
                Id defaultId = resolvePricebook(country);
                if (defaultId != null) {
                    for (Pricebook2 pb : [SELECT Id, Name FROM Pricebook2 WHERE Id = :defaultId LIMIT 1]) {
                        options.add(new PicklistOption(pb.Name, pb.Id));
                    }
                }
            }
        } catch (Exception e) {
            System.debug('Error loading country price books: ' + e.getMessage());
        }
        return options;
    }

    /**
     * @description Result of kicking off an asynchronous job
     */
    public class AsyncStartResult {
        @AuraEnabled public Boolean success { get; set; }
        @AuraEnabled public String errorMessage { get; set; }
        @AuraEnabled public String jobId { get; set; }
        @AuraEnabled public String selloutReportId { get; set; }
        @AuraEnabled public String notificationEmail { get; set; }
        // Non-blocking heads-up shown at upload time - e.g. earlier reports exist for the same
        // account and date, so overlapping lines will reconcile as duplicates
        @AuraEnabled public String warningMessage { get; set; }

        public AsyncStartResult() {
            this.success = false;
            this.errorMessage = null;
            this.jobId = null;
            this.selloutReportId = null;
            this.notificationEmail = UserInfo.getUserEmail();
        }
    }

    /**
     * @description Status snapshot of a sellout report, used to refresh the UI on return
     */
    public class ReportStatus {
        @AuraEnabled public String selloutReportId { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Integer totalItems { get; set; }
        @AuraEnabled public Integer pendingDecisionCount { get; set; }
        @AuraEnabled public Integer matchedCount { get; set; }
        @AuraEnabled public Integer invoiceCreatedCount { get; set; }
        @AuraEnabled public Integer errorCount { get; set; }
        @AuraEnabled public Integer pendingCount { get; set; }
        @AuraEnabled public Integer skippedCount { get; set; }
        @AuraEnabled public Integer invoiceCount { get; set; }
        @AuraEnabled public String errorMessage { get; set; }
        // True when the report's own status no longer matches its items and a background job is not
        // going to fix it. The recovery button is hidden unless this is set, so the normal flow stays
        // as simple as upload, review, apply.
        @AuraEnabled public Boolean isStuck { get; set; }
        @AuraEnabled public String stuckReason { get; set; }
        @AuraEnabled public Integer accountsCreated { get; set; }
        @AuraEnabled public Boolean autoAccepted { get; set; }

        public ReportStatus() {
            this.accountsCreated = 0;
            this.autoAccepted = false;
            this.totalItems = 0;
            this.isStuck = false;
            this.pendingDecisionCount = 0;
            this.matchedCount = 0;
            this.invoiceCreatedCount = 0;
            this.errorCount = 0;
            this.pendingCount = 0;
            this.skippedCount = 0;
            this.invoiceCount = 0;
        }
    }

    /**
     * @description Counts-only record of what a finished sellout produced, shown when the user
     * reopens a completed report
     */
    public class SelloutSummary {
        @AuraEnabled public String reportName { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Datetime importDate { get; set; }
        @AuraEnabled public Integer totalItems { get; set; }
        @AuraEnabled public Integer invoicesCreated { get; set; }
        @AuraEnabled public Integer linesInvoiced { get; set; }
        @AuraEnabled public Integer duplicatesSkipped { get; set; }
        @AuraEnabled public Integer enforcedSkipped { get; set; }
        @AuraEnabled public Integer errors { get; set; }
        @AuraEnabled public Integer accountsCreated { get; set; }
        @AuraEnabled public Boolean autoAccepted { get; set; }
        @AuraEnabled public List<SelloutErrorDetail> errorDetails { get; set; }

        public SelloutSummary() {
            this.accountsCreated = 0;
            this.autoAccepted = false;
            this.errorDetails = new List<SelloutErrorDetail>();
            this.totalItems = 0;
            this.invoicesCreated = 0;
            this.linesInvoiced = 0;
            this.duplicatesSkipped = 0;
            this.enforcedSkipped = 0;
            this.errors = 0;
        }
    }

    /**
     * @description One errored row and the reason it failed, shown in the results summary
     */
    public class SelloutErrorDetail {
        @AuraEnabled public String itemId { get; set; }
        @AuraEnabled public String customerName { get; set; }
        @AuraEnabled public String productCode { get; set; }
        @AuraEnabled public String message { get; set; }
    }

    /**
     * @description A user's decision for one unresolved customer account name
     */
    public class UnmatchedDecision {
        @AuraEnabled public String customerAccountName { get; set; }
        @AuraEnabled public String action { get; set; } // 'create', 'activate', 'reassign' or 'skip'
        // The account to activate (action 'activate') or to point the lines at (action 'reassign')
        @AuraEnabled public String existingAccountId { get; set; }
    }

    /**
     * @description Summary of a bulk unmatched resolution run
     */
    public class BulkResolveResult {
        @AuraEnabled public Boolean success { get; set; }
        @AuraEnabled public String errorMessage { get; set; }
        @AuraEnabled public Integer accountsCreated { get; set; }
        @AuraEnabled public Integer accountsActivated { get; set; }
        @AuraEnabled public Integer itemsSkipped { get; set; }
        @AuraEnabled public Integer itemsMatched { get; set; }
        @AuraEnabled public Integer accountsFailed { get; set; }
        // Lines renamed onto an existing account by a reassign decision
        @AuraEnabled public Integer itemsReassigned { get; set; }
        // Reassigned lines the re-check turned into errors (quantity conflict, unknown product)
        @AuraEnabled public Integer itemsFlagged { get; set; }
        @AuraEnabled public String warningMessage { get; set; }
        @AuraEnabled public String jobId { get; set; }
        // True when the row updates were handed to a background job because the report is too large
        // to update in one transaction, so the UI reports progress rather than final counts
        @AuraEnabled public Boolean rowsDeferred { get; set; }
        // True when the background job will go on to create invoices without further user action
        @AuraEnabled public Boolean invoicingQueued { get; set; }

        public BulkResolveResult() {
            this.success = false;
            this.accountsCreated = 0;
            this.accountsActivated = 0;
            this.itemsSkipped = 0;
            this.itemsMatched = 0;
            this.accountsFailed = 0;
            this.itemsReassigned = 0;
            this.itemsFlagged = 0;
            this.rowsDeferred = false;
            this.invoicingQueued = false;
        }
    }

    /**
     * @description Append a warning to a bulk resolve result without losing one already recorded
     * @param result Result the warning belongs to
     * @param warning Warning text to add
     */
    private static void appendWarning(BulkResolveResult result, String warning) {
        result.warningMessage = String.isBlank(result.warningMessage)
            ? warning
            : result.warningMessage + ' ' + warning;
    }

    /**
     * @description Store the uploaded CSV as a ContentVersion so the import batch can stream it
     * without the LWC having to hold thousands of rows in memory
     * @param fileName Name of the uploaded file (must be .csv)
     * @param base64Content Base64 encoded file content
     * @return String Id of the created ContentVersion
     */
    @AuraEnabled(cacheable=false)
    public static String saveCsvFile(String fileName, String base64Content) {
        try {
            if (String.isBlank(fileName) || !fileName.toLowerCase().endsWith('.csv')) {
                throw new AuraHandledException('Only CSV files are supported.');
            }
            if (String.isBlank(base64Content)) {
                throw new AuraHandledException('File content is empty.');
            }

            ContentVersion version = new ContentVersion(
                Title = fileName,
                PathOnClient = fileName,
                VersionData = EncodingUtil.base64Decode(base64Content)
            );
            insert version;

            return version.Id;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Error storing CSV file: ' + e.getMessage());
        }
    }

    /**
     * @description Start an asynchronous import of a CSV already uploaded as a ContentVersion.
     * Creates the sellout report up front so the UI can close immediately; the batch emails the
     * running user when the import finishes.
     * @param accountId Account the sellout report belongs to
     * @param reportDate Report date string in the running user's locale format
     * @param contentVersionId ContentVersion Id holding the uploaded CSV
     * @param config Column index mapping and delimiter
     * @return AsyncStartResult with the queued job Id and the report Id
     */
    @AuraEnabled(cacheable=false)
    public static AsyncStartResult startAsyncImport(String accountId, String reportDate,
                                                   String contentVersionId, ImportMappingConfig config) {
        AsyncStartResult result = new AsyncStartResult();

        try {
            if (String.isBlank(accountId) || String.isBlank(contentVersionId) || config == null) {
                result.errorMessage = 'Invalid input parameters';
                return result;
            }

            String userLocale = getUserLocale();
            Date reportDateParsed = parseDateByLocale(reportDate, userLocale);

            // Reconciliation heads-up rather than a hard block: earlier uploads for the same
            // account and date are normal (files overlap month to month), and the validator
            // reconciles them line by line - but the user should know it is going to happen
            Integer earlierReports = [
                SELECT COUNT()
                FROM SLO_Sellout_Report__c
                WHERE SLO_Account__c = :accountId
                AND SLO_Report_Date__c = :reportDateParsed
            ];
            if (earlierReports > 0) {
                result.warningMessage = earlierReports +
                    ' earlier report(s) already exist for this account with the same report date. ' +
                    'Lines already accepted or invoiced by an earlier report will be skipped as ' +
                    'duplicates, and a matching line with a different quantity will be flagged for review.';
            }

            // Auto Accept comes from the wizard toggle; when off the report stops at Draft for review
            config.autoAccept = config.autoAccept == true;
            config.skipDuplicates = config.skipDuplicates != false;

            SLO_Sellout_Report__c report = new SLO_Sellout_Report__c(
                SLO_Account__c = accountId,
                SLO_Report_Date__c = reportDateParsed,
                SLO_Status__c = 'New'
            );
            if (config.priceMethod == 'Last_Item_Price' || config.priceMethod == 'Dedicated_Price_Book'
                || config.priceMethod == 'Customer_Price_List') {
                report.SLO_Price_Method__c = config.priceMethod;
                if (config.priceMethod == 'Dedicated_Price_Book') {
                    if (String.isBlank(config.priceBookId)) {
                        result.success = false;
                        result.errorMessage = 'Select a Dedicated Price Book or choose another price method.';
                        return result;
                    }
                    report.SLO_Price_Book__c = Id.valueOf(config.priceBookId);
                } else if (config.priceMethod == 'Customer_Price_List') {
                    List<Account> priceAccounts = [SELECT Price_Book__c, Account_Usage_Company__c FROM Account WHERE Id = :accountId LIMIT 1];
                    Id accountPriceBook = priceAccounts.isEmpty() ? null : priceAccounts[0].Price_Book__c;
                    if (accountPriceBook == null) {
                        accountPriceBook = resolvePricebook(withUserUsageCompany(
                            priceAccounts.isEmpty() ? null : priceAccounts[0].Account_Usage_Company__c));
                    }
                    if (accountPriceBook == null) {
                        // Account country had no default: use the running user's country configuration
                        accountPriceBook = resolvePricebook(withUserUsageCompany(null));
                    }
                    if (accountPriceBook == null) {
                        // No price book anywhere: fall back to Last Item Price instead of blocking the import
                        report.SLO_Price_Method__c = 'Last_Item_Price';
                        config.priceMethod = 'Last_Item_Price';
                    } else {
                        report.SLO_Price_Book__c = accountPriceBook;
                    }
                }
            }
            insert report;
            result.selloutReportId = report.Id;

            SLO_SelloutItemImportBatch batchJob = new SLO_SelloutItemImportBatch(
                accountId, report.Id, contentVersionId, config, userLocale, true
            );
            result.jobId = Database.executeBatch(batchJob, BATCH_SIZE);
            result.success = true;

        } catch (Exception e) {
            result.success = false;
            result.errorMessage = 'Error starting import: ' + e.getMessage();
        }

        return result;
    }

    /**
     * @description Start an asynchronous Apply Sellout (account matching) run. Matching parks the
     * report in Draft for review and does not email - only a run that reaches invoice creation does.
     * @param reportId Sellout report to apply
     * @param currentAccountId Parent account whose hierarchy is searched
     * @return AsyncStartResult with the queued job Id
     */
    @AuraEnabled(cacheable=false)
    public static AsyncStartResult startAsyncApplySellout(String reportId, String currentAccountId) {
        assertReportEditable(reportId);
        AsyncStartResult result = new AsyncStartResult();

        try {
            if (String.isBlank(reportId) || String.isBlank(currentAccountId)) {
                result.errorMessage = 'Invalid input parameters';
                return result;
            }

            result.selloutReportId = reportId;
            result.jobId = Database.executeBatch(
                new SLO_SelloutApplyBatch(reportId, currentAccountId, SLO_SelloutApplyBatch.MODE_MATCH),
                SLO_SelloutApplyBatch.scopeSizeForAttempt(1)
            );
            result.success = true;

        } catch (Exception e) {
            result.success = false;
            result.errorMessage = 'Error starting Apply Sellout: ' + e.getMessage();
        }

        return result;
    }

    /**
     * @description Resume invoice creation for a report whose items are already matched. Matching
     * only looks at Pending items, so a report stuck with matched-but-uninvoiced items needs the
     * invoice stage started directly rather than the whole Apply Sellout run.
     * @param reportId Sellout report to resume
     * @param currentAccountId Parent account whose hierarchy the report belongs to
     * @return AsyncStartResult with the queued job Id
     */
    @AuraEnabled(cacheable=false)
    public static AsyncStartResult resumeInvoiceCreation(String reportId, String currentAccountId) {
        assertReportEditable(reportId);
        AsyncStartResult result = new AsyncStartResult();

        try {
            if (String.isBlank(reportId) || String.isBlank(currentAccountId)) {
                result.errorMessage = 'Invalid input parameters';
                return result;
            }

            if (countMatchedItems(reportId, null) == 0) {
                result.errorMessage = 'This report has no items waiting to be invoiced.';
                return result;
            }

            result.selloutReportId = reportId;
            // Auto Accept context: the resumed run finishes the report (Completed, or Error with the
            // reason) instead of dropping it back to Draft
            SLO_SelloutApplyBatch.RunContext resumeContext = new SLO_SelloutApplyBatch.RunContext();
            resumeContext.autoAccept = true;
            result.jobId = Database.executeBatch(
                new SLO_SelloutApplyBatch(reportId, currentAccountId, SLO_SelloutApplyBatch.MODE_INVOICE, resumeContext),
                SLO_SelloutApplyBatch.scopeSizeForAttempt(1)
            );
            result.success = true;

        } catch (Exception e) {
            result.success = false;
            result.errorMessage = 'Error resuming invoice creation: ' + e.getMessage();
        }

        return result;
    }

    private static final Set<String> SELLOUT_JOB_CLASSES = new Set<String>{
        'SLO_SelloutApplyBatch', 'SLO_SelloutItemImportBatch', 'SLO_SelloutDailyAutoBatch'
    };
    private static final Integer STUCK_MINUTES = 10;

    /**
     * @description Put a report into Error with a reason, only while it is still In Process. Never throws.
     * @param reportId Sellout report to fail
     * @param message Reason shown to the user
     */
    public static void failStuckReport(Id reportId, String message) {
        try {
            List<SLO_Sellout_Report__c> reports = [
                SELECT Id FROM SLO_Sellout_Report__c
                WHERE Id = :reportId AND SLO_Status__c = :SLO_SelloutApplyBatch.STATUS_IN_PROCESS
                LIMIT 1
            ];
            if (!reports.isEmpty()) {
                reports[0].SLO_Status__c = 'Error';
                reports[0].SLO_Error_Message__c = String.isBlank(message) ? null : message.abbreviate(32000);
                update reports;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Unable to fail sellout report: ' + e.getMessage());
        }
    }

    /**
     * @description A report left In Process with no sellout job running and no recent change has lost
     * its job (crash, limit error, abort). Move it to Error with the job's failure reason so the user
     * can delete or re-import it instead of waiting forever.
     */
    private static void recoverStuckReport(SLO_Sellout_Report__c report) {
        if (report.SLO_Status__c != SLO_SelloutApplyBatch.STATUS_IN_PROCESS) {
            return;
        }
        try {
            Integer active = [
                SELECT COUNT() FROM AsyncApexJob
                WHERE ApexClass.Name IN :SELLOUT_JOB_CLASSES
                AND Status IN ('Holding', 'Queued', 'Preparing', 'Processing')
            ];
            if (active > 0) {
                return;
            }
            SLO_Sellout_Report__c fresh = [
                SELECT LastModifiedDate FROM SLO_Sellout_Report__c WHERE Id = :report.Id
            ];
            if (fresh.LastModifiedDate > Datetime.now().addMinutes(-STUCK_MINUTES)) {
                return;
            }
            String reason = 'The background job stopped before it finished.';
            List<AsyncApexJob> failed = [
                SELECT ExtendedStatus FROM AsyncApexJob
                WHERE ApexClass.Name IN :SELLOUT_JOB_CLASSES
                AND ExtendedStatus != null
                ORDER BY CreatedDate DESC LIMIT 1
            ];
            if (!failed.isEmpty()) {
                reason += ' Last job error: ' + failed[0].ExtendedStatus;
            }
            report.SLO_Status__c = 'Error';
            report.SLO_Error_Message__c = (reason + ' Items not invoiced remain matched; run Apply Sellout again to resume.').abbreviate(32000);
            update report;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Unable to recover stuck report: ' + e.getMessage());
        }
    }

    /**
     * @description Get the current status of a sellout report and its item status breakdown
     * @param reportId Sellout report Id
     * @return ReportStatus snapshot
     */
    @AuraEnabled(cacheable=false)
    public static ReportStatus getReportStatus(String reportId) {
        ReportStatus status = new ReportStatus();

        if (String.isBlank(reportId)) {
            return status;
        }

        SLO_Sellout_Report__c report = [
            SELECT Id, SLO_Status__c, SLO_Total_Items__c, SLO_Error_Message__c,
                   SLO_Accounts_Created__c, SLO_Auto_Accepted__c
            FROM SLO_Sellout_Report__c
            WHERE Id = :reportId
            LIMIT 1
        ];

        recoverStuckReport(report);

        status.accountsCreated = report.SLO_Accounts_Created__c != null
            ? report.SLO_Accounts_Created__c.intValue()
            : 0;
        status.autoAccepted = report.SLO_Auto_Accepted__c == true;
        status.selloutReportId = report.Id;
        status.status = report.SLO_Status__c;
        status.errorMessage = report.SLO_Error_Message__c;
        status.totalItems = report.SLO_Total_Items__c != null ? report.SLO_Total_Items__c.intValue() : 0;

        for (AggregateResult ar : [
            SELECT SLO_Processing_Status__c itemStatus, COUNT(Id) itemCount
            FROM SLO_Sellout_Item__c
            WHERE SLO_Sellout_Report__c = :reportId
            GROUP BY SLO_Processing_Status__c
        ]) {
            String itemStatus = (String) ar.get('itemStatus');
            Integer itemCount = ((Decimal) ar.get('itemCount')).intValue();

            if (itemStatus == 'Pending_Decision') {
                status.pendingDecisionCount = itemCount;
            } else if (itemStatus == 'Matched') {
                status.matchedCount = itemCount;
            } else if (itemStatus == 'Invoice_Created') {
                status.invoiceCreatedCount = itemCount;
            } else if (itemStatus == 'Error') {
                status.errorCount = itemCount;
            } else if (itemStatus == 'Skipped' || itemStatus == STATUS_ENFORCED_SKIPPED) {
                status.skippedCount += itemCount;
            } else if (itemStatus == 'Pending' || itemStatus == null) {
                status.pendingCount = itemCount;
            }
        }

        // Count the sellout invoices actually produced for this report so the UI can confirm
        // that invoice creation ran, rather than only reporting item-level statuses. An aggregate
        // keeps this safe for reports with thousands of items.
        for (AggregateResult ar : [
            SELECT COUNT_DISTINCT(Invoice_Number__c) invoiceTotal
            FROM Invoice_Line_Item__c
            WHERE Invoice_Number__c != null
            AND Id IN (
                SELECT SLO_Invoice_Line_Item__c
                FROM SLO_Sellout_Item__c
                WHERE SLO_Sellout_Report__c = :reportId
                AND SLO_Invoice_Line_Item__c != null
            )
        ]) {
            // COUNT_DISTINCT returns an Integer, so read it through a string to stay cast-safe
            String invoiceTotal = String.valueOf(ar.get('invoiceTotal'));
            status.invoiceCount = String.isBlank(invoiceTotal) ? 0 : Integer.valueOf(invoiceTotal);
        }

        applyStuckSignal(status);

        return status;
    }

    /**
     * @description Decide whether a report needs manual recovery, so the UI can keep the recovery
     * button hidden during the normal flow and only offer it when the report is genuinely stalled
     * @param status Status snapshot to annotate in place
     */
    private static void applyStuckSignal(ReportStatus status) {
        status.isStuck = false;
        status.stuckReason = null;

        // A running background job will move the report on by itself, so nothing is stuck yet
        if (isSelloutJobRunning()) {
            return;
        }

        if (status.status == 'Completed' && status.matchedCount > 0) {
            status.isStuck = true;
            status.stuckReason = status.matchedCount +
                ' item(s) are still waiting to be invoiced even though the report is marked complete.';
        } else if (status.status == 'New' && status.totalItems == 0
                   && status.pendingCount == 0 && status.errorCount == 0) {
            status.isStuck = true;
            status.stuckReason = 'The import did not produce any items.';
        } else if (status.status == SLO_SelloutApplyBatch.STATUS_IN_PROCESS) {
            status.isStuck = true;
            status.stuckReason = 'The background run stopped before it finished.';
        } else if (status.status == 'Error') {
            status.isStuck = true;
            status.stuckReason = String.isBlank(status.errorMessage)
                ? 'The last run finished with an error.'
                : status.errorMessage;
        }
    }

    /**
     * @description Check whether any sellout import or apply batch is still running
     * @return True when a sellout batch job is queued, preparing or processing
     */
    private static Boolean isSelloutJobRunning() {
        List<AsyncApexJob> running = [
            SELECT Id
            FROM AsyncApexJob
            WHERE JobType = 'BatchApex'
            AND Status IN ('Holding', 'Queued', 'Preparing', 'Processing')
            AND ApexClass.Name IN ('SLO_SelloutItemImportBatch', 'SLO_SelloutApplyBatch')
            LIMIT 1
        ];
        return !running.isEmpty();
    }

    // Items removed per call when an administrator deletes a report. A report can hold more rows
    // than one transaction may delete (10,000 DML rows), so the screen calls back until the report
    // itself has gone; each pass stays well inside the limit.
    @TestVisible
    private static final Integer DELETE_ITEMS_PER_PASS = 4000;

    /**
     * @description Whether the running user may delete uploaded reports from the screen. Deleting
     * a report is a testing convenience for system administrators - the button is hidden from
     * everyone else - and the server re-checks on every delete rather than trusting the screen.
     * @return True when the user is a system administrator
     */
    @AuraEnabled(cacheable=false)
    public static Boolean canDeleteReports() {
        return isSystemAdministrator();
    }

    /**
     * @description A system administrator here is a user holding Modify All Data. Profile
     * permissions surface through the profile's own permission set, so one query covers both the
     * System Administrator profile and a permission set granting the same power, and it works
     * whatever language the profile name is shown in.
     * @return True when the running user holds Modify All Data
     */
    private static Boolean isSystemAdministrator() {
        List<PermissionSetAssignment> adminAssignments = [
            SELECT Id
            FROM PermissionSetAssignment
            WHERE AssigneeId = :UserInfo.getUserId()
            AND PermissionSet.PermissionsModifyAllData = true
            LIMIT 1
        ];
        return !adminAssignments.isEmpty();
    }

    /**
     * @description Delete an uploaded report and its items, so an administrator can clear test
     * uploads without leaving the screen. One call removes up to DELETE_ITEMS_PER_PASS items; the
     * report itself goes on the call that finds no further items, and the result says whether that
     * has happened so the screen can call again until it has. Invoices created from the report are
     * never touched - they belong to the finance flow - so the screen warns about them beforehand.
     * A report still importing, or any sellout background run, blocks the delete: a batch could
     * otherwise be inserting or updating the very rows being removed.
     * @param reportId Sellout report Id
     * @return ReportDeleteResult with the items removed by this pass and whether the report is gone
     */
    @AuraEnabled(cacheable=false)
    public static ReportDeleteResult deleteSelloutReport(String reportId) {
        ReportDeleteResult result = new ReportDeleteResult();

        try {
            if (!isSystemAdministrator()) {
                throw new AuraHandledException('Only system administrators can delete sellout reports.');
            }
            if (!Schema.sObjectType.SLO_Sellout_Report__c.isDeletable()
                || !Schema.sObjectType.SLO_Sellout_Item__c.isDeletable()) {
                throw new AuraHandledException('You do not have delete access to sellout reports and items.');
            }
            if (String.isBlank(reportId)) {
                throw new AuraHandledException('No report was selected.');
            }

            List<SLO_Sellout_Report__c> reports = [
                SELECT Id, Name, SLO_Status__c
                FROM SLO_Sellout_Report__c
                WHERE Id = :reportId
                LIMIT 1
            ];
            if (reports.isEmpty()) {
                // Already gone - a second click, or another administrator got there first
                result.finished = true;
                return result;
            }

            if (reports[0].SLO_Status__c == 'New'
                || reports[0].SLO_Status__c == SLO_SelloutApplyBatch.STATUS_IN_PROCESS
                || isSelloutJobRunning()) {
                throw new AuraHandledException(
                    'A sellout background run is still in progress. Wait for it to finish, then try again.'
                );
            }

            List<SLO_Sellout_Item__c> items = [
                SELECT Id
                FROM SLO_Sellout_Item__c
                WHERE SLO_Sellout_Report__c = :reportId
                LIMIT :DELETE_ITEMS_PER_PASS
            ];
            if (!items.isEmpty()) {
                delete items;
                result.itemsDeleted = items.size();
            }

            // A short page means these were the last items, so the report can go in the same pass
            if (items.size() < DELETE_ITEMS_PER_PASS) {
                delete reports;
                result.finished = true;
            }

            return result;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Error deleting the report: ' + e.getMessage());
        }
    }

    /**
     * @description Outcome of one delete pass over a report
     */
    public class ReportDeleteResult {
        @AuraEnabled public Integer itemsDeleted { get; set; }
        // True once the report record itself has been deleted; until then the screen calls again
        @AuraEnabled public Boolean finished { get; set; }

        public ReportDeleteResult() {
            this.itemsDeleted = 0;
            this.finished = false;
        }
    }

    /**
     * @description List the distinct customer account names that need a user decision before the
     * report can be applied. Matching is computed here, live against the hierarchy, rather than
     * read back from row statuses: a name is listed when no active account answers to it, whether
     * its rows are still pending (matching never ran), already flagged for a decision, or sitting
     * in error over a data problem - a row with a bad product code still needs its account
     * resolved, and the accounts step is where that happens.
     * @param reportId Sellout report Id
     * @return List of AccountMatchResult, one per distinct unresolved customer name
     */
    @AuraEnabled(cacheable=false)
    public static List<AccountMatchResult> getUnmatchedAccounts(String reportId) {
        List<AccountMatchResult> unmatched = new List<AccountMatchResult>();

        if (String.isBlank(reportId)) {
            return unmatched;
        }

        List<SLO_Sellout_Report__c> reports = [
            SELECT SLO_Account__c
            FROM SLO_Sellout_Report__c
            WHERE Id = :reportId
            LIMIT 1
        ];
        if (reports.isEmpty() || reports[0].SLO_Account__c == null) {
            return unmatched;
        }

        Map<String, Id> nameToId = new Map<String, Id>();
        Map<String, String> nameToStatus = new Map<String, String>();
        buildAccountNameMaps(getHierarchyAccounts(reports[0].SLO_Account__c), nameToId, nameToStatus);

        Map<String, AccountMatchResult> nameToResult = new Map<String, AccountMatchResult>();

        for (SLO_Sellout_Item__c item : [
            SELECT Id, SLO_Customer_Account_Name__c
            FROM SLO_Sellout_Item__c
            WHERE SLO_Sellout_Report__c = :reportId
            AND SLO_Processing_Status__c IN ('Pending', 'Pending_Decision', 'Error')
            AND SLO_Customer_Account_Name__c != null
            ORDER BY SLO_Customer_Account_Name__c
        ]) {
            String key = nameKey(item.SLO_Customer_Account_Name__c);
            if (String.isBlank(key)) {
                continue;
            }

            // A name an active account answers to needs no decision, whatever the row's status
            if (nameToId.containsKey(key) && nameToStatus.get(key) != 'N') {
                continue;
            }

            AccountMatchResult entry = nameToResult.get(key);
            if (entry == null) {
                entry = new AccountMatchResult();
                entry.selloutItemIds = new List<String>();
                entry.customerAccountName = item.SLO_Customer_Account_Name__c;
                entry.matched = false;
                entry.needsUserDecision = true;
                entry.isInactive = nameToId.containsKey(key);
                if (entry.isInactive) {
                    entry.accountId = nameToId.get(key);
                }
                nameToResult.put(key, entry);
                unmatched.add(entry);
            }
            entry.selloutItemIds.add(item.Id);
        }

        return unmatched;
    }

    /**
     * @description Active accounts of the hierarchy as picklist options, so the resolve screen can
     * offer "use an existing account" for a misspelt customer name. Sorted by name; inactive
     * accounts are left out, because activating one is its own decision.
     * @param accountId Main account Id
     * @return Options with the account name as label and the account Id as value
     */
    @AuraEnabled(cacheable=false)
    public static List<PicklistOption> getHierarchyAccountOptions(String accountId) {
        List<PicklistOption> options = new List<PicklistOption>();
        if (String.isBlank(accountId)) {
            return options;
        }

        Map<String, PicklistOption> sortedOptions = new Map<String, PicklistOption>();
        for (Account acc : getHierarchyAccounts((Id) accountId)) {
            if (acc.Status__c == 'N' || String.isBlank(acc.Name)) {
                continue;
            }
            sortedOptions.put(
                acc.Name.toLowerCase() + '|' + acc.Id,
                new PicklistOption(acc.Name, acc.Id)
            );
        }

        List<String> sortKeys = new List<String>(sortedOptions.keySet());
        sortKeys.sort();
        for (String sortKey : sortKeys) {
            options.add(sortedOptions.get(sortKey));
        }
        return options;
    }

    /**
     * @description Apply the user's bulk Create/Activate/Reassign/Skip decisions to every item
     * awaiting a decision, optionally starting invoice creation asynchronously afterwards
     * @param reportId Sellout report Id
     * @param parentAccountId Parent account new child accounts are created under
     * @param decisions One decision per distinct unresolved customer account name
     * @param startInvoicing False to leave the resolved items for the user's own Apply Sellout -
     *        the review wizard's accounts step, where the user still has the line list to work
     *        through. Null or true queues invoice creation straight away (the status-check path).
     * @return BulkResolveResult with counts and, when invoicing was started, the queued job Id
     */
    @AuraEnabled(cacheable=false)
    public static BulkResolveResult bulkResolveUnmatched(String reportId, String parentAccountId,
                                                        List<UnmatchedDecision> decisions,
                                                        Boolean startInvoicing) {
        assertReportEditable(reportId);
        return applyUnmatchedDecisions(reportId, parentAccountId, decisions, startInvoicing != false, null);
    }

    /**
     * @description Same as bulkResolveUnmatched, for the Auto Accept chain: the run's totals travel
     * on to the decision and invoice jobs so the final email covers the whole run
     * @param reportId Sellout report Id
     * @param parentAccountId Parent account new child accounts are created under
     * @param decisions One decision per distinct unresolved customer account name
     * @param startInvoicing True to queue invoice creation once the rows are decided
     * @param context Running totals of the chain this call belongs to
     * @return BulkResolveResult with counts and the queued job Id
     */
    public static BulkResolveResult bulkResolveUnmatchedForRun(String reportId, String parentAccountId,
                                                              List<UnmatchedDecision> decisions,
                                                              Boolean startInvoicing,
                                                              SLO_SelloutApplyBatch.RunContext context) {
        return applyUnmatchedDecisions(reportId, parentAccountId, decisions, startInvoicing != false, context);
    }

    /**
     * @description Apply one account decision to several customer names at once, from the account
     * decision view. Every line carrying a selected name is covered, not merely the ones the user
     * has scrolled into view, because the decision is resolved per name before it is expanded onto
     * the rows - and on a report too large to update while the user waits the expansion is handed
     * to the background job, exactly as a single decision is.
     * @param reportId Sellout report Id
     * @param parentAccountId Account the sellout is being applied to; new child accounts hang off it
     * @param customerAccountNames The distinct customer names the user ticked
     * @param action 'create' to create one child account per name, 'skip' to leave those customers
     *        out, or 'reassign' to point every line at one existing account
     * @param existingAccountId The chosen existing account; only read when the action is 'reassign'
     * @return BulkResolveResult with the counts, warnings and any queued job Id
     */
    @AuraEnabled(cacheable=false)
    public static BulkResolveResult bulkDecideCustomerNames(
        String reportId,
        String parentAccountId,
        List<String> customerAccountNames,
        String action,
        String existingAccountId
    ) {
        BulkResolveResult result = new BulkResolveResult();

        if (customerAccountNames == null || customerAccountNames.isEmpty()) {
            result.errorMessage = 'Select at least one customer name before applying a bulk action.';
            return result;
        }

        String requested = action == null ? '' : action.toLowerCase();
        if (requested != 'create' && requested != 'skip' && requested != 'reassign') {
            result.errorMessage = 'Unsupported bulk action: ' + action;
            return result;
        }
        if (requested == 'reassign' && String.isBlank(existingAccountId)) {
            result.errorMessage = 'Choose the existing account the selected customers should point at.';
            return result;
        }

        // One decision per distinct name, de-duplicated on the same case-insensitive key the row
        // grouping uses, so a name ticked twice is not created twice
        Map<String, UnmatchedDecision> decisionByKey = new Map<String, UnmatchedDecision>();
        for (String customerName : customerAccountNames) {
            if (String.isBlank(customerName)) {
                continue;
            }
            UnmatchedDecision decision = new UnmatchedDecision();
            decision.customerAccountName = customerName;
            decision.action = requested;
            decision.existingAccountId = existingAccountId;
            decisionByKey.put(nameKey(customerName), decision);
        }

        if (decisionByKey.isEmpty()) {
            result.errorMessage = 'The selected rows carry no customer name to decide on.';
            return result;
        }

        // Invoicing is never started here: the user is mid-review and presses Apply Sellout once the
        // whole list reads right
        assertReportEditable(reportId);
        return applyUnmatchedDecisions(
            reportId, parentAccountId, decisionByKey.values(), false
        );
    }

    // The two values a bulk correction may write on the needs-a-fix view. Nothing else is editable
    // in bulk, so a mistyped field name can never reach the rows.
    private static final String BULK_FIELD_PRODUCT_CODE = 'productCode';
    private static final String BULK_FIELD_CUSTOMER_NAME = 'customerAccountName';

    // Rows corrected per pass. Each pass re-validates only the rows it wrote - the ticked lines are
    // already the whole block sharing the problem - so a pass reads its own rows plus the recorded
    // lines for their customers and products, and nothing else.
    private static final Integer BULK_EDIT_CHUNK_SIZE = 200;

    // Rows one call will attempt. The screen sends a large selection as several calls, so this is
    // the per-call ceiling rather than a limit on what the user may correct; each pass runs its own
    // handful of queries, so the ceiling keeps a single call inside the query-count limit too.
    private static final Integer MAX_BULK_EDIT_ROWS = 1000;


    /**
     * @description Summary of a bulk inline correction
     */
    public class BulkEditResult {
        @AuraEnabled public Boolean success { get; set; }
        @AuraEnabled public String errorMessage { get; set; }
        @AuraEnabled public String warningMessage { get; set; }
        // Rows updated, with their new status and notes, so the client refreshes them in place
        @AuraEnabled public List<SLO_Sellout_Item__c> rows { get; set; }
        @AuraEnabled public Integer rowsUpdated { get; set; }
        // Rows the correction was asked for but could not be written - reported so the user knows
        // exactly what still needs attention rather than the whole batch failing silently
        @AuraEnabled public Integer rowsFailed { get; set; }
        @AuraEnabled public Integer nowReady { get; set; }
        @AuraEnabled public Integer stillNeedFix { get; set; }
        @AuraEnabled public Integer needDecision { get; set; }
        // Corrected lines the re-check set aside - an exact duplicate of a line already recorded, or
        // a zero quantity. Reported so a correction is never summarised as having done nothing: a
        // line in this bucket has moved, it has simply moved out of the review altogether.
        @AuraEnabled public Integer nowSkipped { get; set; }
        // The report's status counts as they stand once the correction has been written, read back
        // from the report itself. The badges are set from this rather than inferred from the rows
        // that happened to be on screen, so a correction applied to lines further down a large
        // report still moves "Needs a fix" and "Ready" the moment it lands.
        @AuraEnabled public Map<String, Integer> reportCounts { get; set; }

        public BulkEditResult() {
            this.success = false;
            this.rows = new List<SLO_Sellout_Item__c>();
            this.rowsUpdated = 0;
            this.rowsFailed = 0;
            this.nowReady = 0;
            this.stillNeedFix = 0;
            this.needDecision = 0;
            this.nowSkipped = 0;
            this.reportCounts = new Map<String, Integer>();
        }
    }

    /**
     * @description Write one corrected Product Code or Customer Account Name to every selected line
     * and re-validate them straight away, so a whole block of lines failing for the same reason is
     * fixed in one action. The correction runs in passes and reports per line, so a line the save
     * rejects is named rather than taking the rest of the batch down with it.
     * @param itemIds Ids of the lines the user ticked on the needs-a-fix view
     * @param fieldName 'productCode' or 'customerAccountName'
     * @param newValue The corrected value to write to all of them
     * @return BulkEditResult with the re-validated rows and a breakdown of where they now stand
     */
    @AuraEnabled(cacheable=false)
    public static BulkEditResult bulkEditItemField(
        List<String> itemIds,
        String fieldName,
        String newValue
    ) {
        BulkEditResult result = new BulkEditResult();
        assertItemsEditable(itemIds);

        if (itemIds == null || itemIds.isEmpty()) {
            result.errorMessage = 'Select at least one line before applying a bulk correction.';
            return result;
        }
        if (fieldName != BULK_FIELD_PRODUCT_CODE && fieldName != BULK_FIELD_CUSTOMER_NAME) {
            result.errorMessage = 'Unsupported bulk edit field: ' + fieldName;
            return result;
        }
        if (String.isBlank(newValue)) {
            result.errorMessage = fieldName == BULK_FIELD_PRODUCT_CODE
                ? 'Enter the corrected product code.'
                : 'Enter the corrected customer account name.';
            return result;
        }

        String correctedValue = newValue.trim();

        // De-duplicated so a row ticked twice is written once
        Set<Id> targetIds = new Set<Id>();
        for (String itemId : itemIds) {
            if (String.isNotBlank(itemId)) {
                targetIds.add((Id) itemId);
            }
        }

        List<Id> orderedIds = new List<Id>(targetIds);
        Integer attemptCount = Math.min(orderedIds.size(), MAX_BULK_EDIT_ROWS);
        if (orderedIds.size() > MAX_BULK_EDIT_ROWS) {
            result.warningMessage = 'Only the first ' + MAX_BULK_EDIT_ROWS +
                ' selected line(s) were corrected. Select the remaining ' +
                (orderedIds.size() - MAX_BULK_EDIT_ROWS) +
                ' line(s) and apply the correction again.';
        }

        try {
            Map<Id, SLO_Sellout_Item__c> revalidatedById = new Map<Id, SLO_Sellout_Item__c>();

            for (Integer offset = 0; offset < attemptCount; offset += BULK_EDIT_CHUNK_SIZE) {
                Integer endIndex = Math.min(offset + BULK_EDIT_CHUNK_SIZE, attemptCount);

                List<SLO_Sellout_Item__c> chunk = new List<SLO_Sellout_Item__c>();
                for (Integer i = offset; i < endIndex; i++) {
                    SLO_Sellout_Item__c row = new SLO_Sellout_Item__c(Id = orderedIds[i]);
                    if (fieldName == BULK_FIELD_PRODUCT_CODE) {
                        row.SLO_Product_Code_EAN__c = correctedValue;
                    } else {
                        row.SLO_Customer_Account_Name__c = correctedValue;
                    }
                    chunk.add(row);
                }

                // Partial success so one blocked row - a validation rule, a lock - never discards
                // the correction on every other line in the pass
                Set<Id> savedIds = new Set<Id>();
                Database.SaveResult[] saveResults = Database.update(chunk, false);
                for (Integer i = 0; i < saveResults.size(); i++) {
                    if (saveResults[i].isSuccess()) {
                        savedIds.add(chunk[i].Id);
                    } else {
                        result.rowsFailed++;
                    }
                }

                if (savedIds.isEmpty()) {
                    continue;
                }

                result.rowsUpdated += savedIds.size();

                // Same re-check a single cell edit runs, so statuses, notes and badges settle
                // exactly as they do for a one-row correction - without widening to same-name
                // siblings, which on a selection of hundreds of lines read far more than the
                // transaction allows and failed the correction outright
                for (SLO_Sellout_Item__c revalidated : revalidateEditedItems(savedIds, false)) {
                    revalidatedById.put(revalidated.Id, revalidated);
                }
            }

            for (SLO_Sellout_Item__c row : revalidatedById.values()) {
                if (row.SLO_Processing_Status__c == 'Matched'
                        || row.SLO_Processing_Status__c == 'Pending') {
                    // Both read as ready on the review screen: a Pending line is valid data whose
                    // account the apply run still has to match. Counting only Matched here is what
                    // made a successful correction report "0 now ready".
                    result.nowReady++;
                } else if (row.SLO_Processing_Status__c == 'Error') {
                    result.stillNeedFix++;
                } else if (row.SLO_Processing_Status__c == 'Pending_Decision') {
                    result.needDecision++;
                } else if (row.SLO_Processing_Status__c == 'Skipped') {
                    result.nowSkipped++;
                }
            }

            result.rows = revalidatedById.values();

            // The badges are driven from the report as a whole, read back here in the same request
            // that wrote the correction. Shifting them from the rows the screen happened to hold
            // left "Needs a fix" and "Ready" frozen whenever the corrected lines were not all
            // loaded, which is what made a finished correction look as though nothing had moved.
            Id countedReportId = null;
            for (SLO_Sellout_Item__c row : revalidatedById.values()) {
                // The re-check already carries the report on every row it returns, so the common
                // case costs no extra query
                if (row.SLO_Sellout_Report__c != null) {
                    countedReportId = row.SLO_Sellout_Report__c;
                    break;
                }
            }
            if (countedReportId == null) {
                countedReportId = resolveReportIdForItems(targetIds);
            }
            if (countedReportId != null) {
                result.reportCounts = getItemStatusCounts(countedReportId);
            }

            result.success = true;

        } catch (Exception e) {
            result.success = false;
            result.errorMessage = 'Error applying the bulk correction: ' + e.getMessage();
        }

        return result;
    }

    /**
     * @description The report a set of corrected lines belongs to, so the badge counts can be read
     * back for it in the same request that wrote the correction. A bulk correction is always applied
     * within one report's review list, so the first line answers for all of them.
     * @param itemIds Ids of the corrected lines
     * @return The report Id, or null when the lines cannot be read
     */
    private static Id resolveReportIdForItems(Set<Id> itemIds) {
        if (itemIds == null || itemIds.isEmpty()) {
            return null;
        }
        for (SLO_Sellout_Item__c item : [
            SELECT SLO_Sellout_Report__c
            FROM SLO_Sellout_Item__c
            WHERE Id IN :itemIds
            AND SLO_Sellout_Report__c != null
            LIMIT 1
        ]) {
            return item.SLO_Sellout_Report__c;
        }
        return null;
    }

    // Lines one lookup will name for a product-code block. A block larger than this is corrected as
    // far as the ceiling reaches and the rest on the next pass, so the lookup itself can never be
    // what fails the correction.
    private static final Integer MAX_PRODUCT_BLOCK_ROWS = 2000;

    /**
     * @description Name every line of a report that still needs a fix and carries the given product
     * code. Used when a single-line correction is offered to the whole matching block: the block is
     * resolved here rather than from the rows the screen happens to have loaded, so accepting the
     * offer corrects every line sharing the code - including the ones further down a large report
     * that have not been scrolled into view yet.
     * @param reportId Sellout report the lines belong to
     * @param productCode The product code the block shares - the code that was just replaced
     * @return Ids of the lines still needing a fix under that code, oldest first
     */
    @AuraEnabled(cacheable=false)
    public static List<String> getItemIdsByProductCode(String reportId, String productCode) {
        List<String> itemIds = new List<String>();

        if (String.isBlank(reportId) || String.isBlank(productCode)) {
            return itemIds;
        }

        try {
            String wanted = productCode.trim();

            for (SLO_Sellout_Item__c item : [
                SELECT Id
                FROM SLO_Sellout_Item__c
                WHERE SLO_Sellout_Report__c = :reportId
                AND SLO_Processing_Status__c = 'Error'
                AND SLO_Product_Code_EAN__c = :wanted
                ORDER BY Id ASC
                LIMIT :MAX_PRODUCT_BLOCK_ROWS
            ]) {
                itemIds.add(item.Id);
            }
        } catch (Exception e) {
            // The block lookup is an enhancement to a correction the client can already run on the
            // lines it has loaded, so a failure here must never block the correction itself
            System.debug(LoggingLevel.ERROR,
                'Product code block lookup failed: ' + e.getMessage());
        }

        return itemIds;
    }

    /**
     * @description Apply Create/Activate/Skip decisions to the items awaiting a decision, optionally
     * starting invoice creation once they are resolved
     * @param reportId Sellout report Id
     * @param parentAccountId Parent account new child accounts are created under
     * @param decisions One decision per distinct unresolved customer account name
     * @param startInvoicing True to queue invoice creation straight away; false to leave the resolved
     *        items for the user's own Apply Sellout
     * @return BulkResolveResult with counts and, when requested, the queued invoice job Id
     */
    private static BulkResolveResult applyUnmatchedDecisions(String reportId, String parentAccountId,
                                                            List<UnmatchedDecision> decisions,
                                                            Boolean startInvoicing) {
        return applyUnmatchedDecisions(reportId, parentAccountId, decisions, startInvoicing, null);
    }

    /**
     * @description As above, optionally carrying the running totals of an Auto Accept chain into the
     * decision job or the invoice job queued here
     * @param context Running totals of the chain, or null for a run started from the screen
     */
    private static BulkResolveResult applyUnmatchedDecisions(String reportId, String parentAccountId,
                                                            List<UnmatchedDecision> decisions,
                                                            Boolean startInvoicing,
                                                            SLO_SelloutApplyBatch.RunContext context) {
        BulkResolveResult result = new BulkResolveResult();

        try {
            if (String.isBlank(reportId) || String.isBlank(parentAccountId) || decisions == null || decisions.isEmpty()) {
                result.errorMessage = 'Invalid input parameters';
                return result;
            }

            Account parentAccount = [
                SELECT Id, Name, BillingCountry, OwnerId, CurrencyIsoCode
                FROM Account
                WHERE Id = :parentAccountId
                LIMIT 1
            ];

            // How many rows the decisions have to reach. A report of a few hundred rows is applied
            // here and the user sees the exact counts straight away; a report of thousands cannot be
            // read and updated inside one transaction, so the accounts are still created here and a
            // background job carries the decisions to the rows.
            Integer awaitingRowCount = [
                SELECT COUNT()
                FROM SLO_Sellout_Item__c
                WHERE SLO_Sellout_Report__c = :reportId
                AND SLO_Processing_Status__c IN :DECISION_DECIDABLE_STATUSES
            ];
            Boolean deferRowUpdates = awaitingRowCount > MAX_SYNC_DECISION_ROWS;

            // Group the items a decision can still settle by their normalised customer name. Error
            // rows are included because a row can carry a data error AND an unresolved account name -
            // the account decision must reach it too. Pending rows cover a report whose matching
            // never ran. Rows set aside by an earlier account decision are included so a customer
            // left out can be brought back, which is what the account-decision view offers; any
            // other skipped row is filtered out. Only names present in the decisions are touched.
            Map<String, List<Id>> nameToItemIds = new Map<String, List<Id>>();
            if (!deferRowUpdates) {
                for (SLO_Sellout_Item__c item : [
                    SELECT Id, SLO_Customer_Account_Name__c, SLO_Processing_Status__c,
                           SLO_Processing_Notes__c
                    FROM SLO_Sellout_Item__c
                    WHERE SLO_Sellout_Report__c = :reportId
                    AND SLO_Processing_Status__c IN :DECISION_DECIDABLE_STATUSES
                ]) {
                    if (!isDecidableRow(item)) {
                        continue;
                    }
                    String key = nameKey(item.SLO_Customer_Account_Name__c);
                    if (!nameToItemIds.containsKey(key)) {
                        nameToItemIds.put(key, new List<Id>());
                    }
                    nameToItemIds.get(key).add(item.Id);
                }
            }

            // Build the accounts to create and the accounts to activate in bulk
            List<Account> accountsToCreate = new List<Account>();
            List<String> createKeys = new List<String>();
            List<Account> accountsToActivate = new List<Account>();
            Map<String, Id> activateKeyToAccountId = new Map<String, Id>();
            Map<String, Id> reassignKeyToAccountId = new Map<String, Id>();
            Set<String> skipKeys = new Set<String>();

            // Activate and re-map may only target the report account's own hierarchy (the account,
            // its children and grandchildren), never another distributor's account
            Set<Id> hierarchyIds = new Set<Id>();
            for (Account hierarchyAccount : [
                SELECT Id
                FROM Account
                WHERE Id = :parentAccountId
                OR ParentId = :parentAccountId
                OR Parent.ParentId = :parentAccountId
            ]) {
                hierarchyIds.add(hierarchyAccount.Id);
            }

            for (UnmatchedDecision decision : decisions) {
                if (decision == null || String.isBlank(decision.customerAccountName)) {
                    continue;
                }
                String key = nameKey(decision.customerAccountName);
                String action = decision.action != null ? decision.action.toLowerCase() : 'skip';

                if ((action == 'activate' || action == 'reassign')
                        && String.isNotBlank(decision.existingAccountId)
                        && !hierarchyIds.contains(decision.existingAccountId)) {
                    // Outside the hierarchy: ignore the chosen account, leaving the rows awaiting a decision
                    decision.existingAccountId = null;
                    action = 'reassign';
                }

                // Auto Accept: a customer name equal to the distributor itself gets no child account
                // and no sellout invoice line; the lines are skipped instead
                if (context != null && context.autoAccept == true && action != 'skip'
                        && key == nameKey(parentAccount.Name)) {
                    action = 'skip';
                }

                if (action == 'create') {
                    accountsToCreate.add(new Account(
                        Name = buildSelloutAccountName(decision.customerAccountName, parentAccount.Name),
                        ParentId = parentAccountId,
                        OwnerId = parentAccount.OwnerId,
                        BillingStreet = 'Automatic',
                        BillingCity = 'Automatic',
                        BillingCountry = parentAccount.BillingCountry,
                        BillingPostalCode = '99999',
                        Status__c = 'Active',
                        CurrencyIsoCode = parentAccount.CurrencyIsoCode
                    ));
                    createKeys.add(key);
                } else if (action == 'activate' && String.isNotBlank(decision.existingAccountId)) {
                    accountsToActivate.add(new Account(Id = decision.existingAccountId, Status__c = 'Active'));
                    activateKeyToAccountId.put(key, decision.existingAccountId);
                } else if (action == 'reassign') {
                    // "You put Agora, but we have Agora_DM": point the name at an existing account.
                    // With no account chosen the items are left awaiting a decision, never skipped.
                    if (String.isNotBlank(decision.existingAccountId)) {
                        reassignKeyToAccountId.put(key, decision.existingAccountId);
                    }
                } else {
                    skipKeys.add(key);
                }
            }

            // Names that could not be created; reported back so the user knows what was left out
            List<String> failedNames = new List<String>();

            if (!accountsToCreate.isEmpty()) {
                // Partial success so one blocked row does not discard every other account, and
                // duplicate rules are bypassed because exact-name matching already ran and the
                // user explicitly chose to create these accounts
                result.accountsCreated = insertAccountsWithRetry(accountsToCreate);
                addAccountsCreated(reportId, result.accountsCreated);
            }
            if (!accountsToActivate.isEmpty()) {
                for (Database.SaveResult saveResult : Database.update(accountsToActivate, false)) {
                    if (saveResult.isSuccess()) {
                        result.accountsActivated++;
                    }
                }
            }

            List<SLO_Sellout_Item__c> itemsToUpdate = new List<SLO_Sellout_Item__c>();

            // Every account decision - create, activate, reassign - ends the same way: the rows
            // carry the account, are marked Matched, and are re-checked, so a row whose data is
            // still wrong (bad product code, quantity conflict, exact duplicate under a corrected
            // name) surfaces on the review list instead of failing later at invoice time. The
            // decisions are first resolved per customer name - one entry per name, however many
            // rows carry it - and only then expanded onto the rows.
            Map<String, Id> keyToAccountId = new Map<String, Id>();
            Map<String, String> keyToNewName = new Map<String, String>();
            Set<String> reassignedKeys = new Set<String>();

            for (Integer i = 0; i < createKeys.size(); i++) {
                Id newAccountId = accountsToCreate[i].Id;

                // A blocked account leaves its items pending so the user can retry or skip them
                if (newAccountId == null) {
                    failedNames.add(accountsToCreate[i].Name);
                    result.accountsFailed++;
                    continue;
                }

                keyToAccountId.put(createKeys[i], newAccountId);
            }

            for (String key : activateKeyToAccountId.keySet()) {
                keyToAccountId.put(key, activateKeyToAccountId.get(key));
            }

            // Reassignments additionally rename every line onto the chosen account's name
            if (!reassignKeyToAccountId.isEmpty()) {
                Map<Id, Account> reassignTargets = new Map<Id, Account>([
                    SELECT Id, Name
                    FROM Account
                    WHERE Id IN :reassignKeyToAccountId.values()
                ]);
                for (String key : reassignKeyToAccountId.keySet()) {
                    Account target = reassignTargets.get(reassignKeyToAccountId.get(key));
                    if (target == null) {
                        continue;
                    }
                    keyToAccountId.put(key, target.Id);
                    keyToNewName.put(key, target.Name);
                    reassignedKeys.add(key);
                }
            }

            // A large report's rows are updated by a background job: reading them all, validating
            // them and updating them cannot fit in this transaction's DML row limit. The accounts
            // are already created, so nothing about the user's decisions is lost.
            if (deferRowUpdates) {
                SLO_SelloutApplyBatch.DecisionPlan plan = new SLO_SelloutApplyBatch.DecisionPlan();
                plan.keyToAccountId = keyToAccountId;
                plan.keyToNewName = keyToNewName;
                plan.reassignedKeys = reassignedKeys;
                plan.skipKeys = skipKeys;
                plan.startInvoicing = (startInvoicing == true);

                if (!failedNames.isEmpty()) {
                    appendWarning(result, failedNames.size() +
                        ' account(s) could not be created and were left for a later decision: ' +
                        String.join(failedNames, ', '));
                }

                result.rowsDeferred = true;
                result.invoicingQueued = plan.startInvoicing;
                result.jobId = Database.executeBatch(
                    new SLO_SelloutApplyBatch(
                        reportId, parentAccountId, SLO_SelloutApplyBatch.MODE_DECISION, context, plan
                    ),
                    SLO_SelloutApplyBatch.scopeSizeForAttempt(1)
                );
                // Marked now rather than when the job starts, so a screen polling straight away
                // already sees the report as busy
                SLO_SelloutApplyBatch.markInProcess(reportId);
                result.success = true;
                return result;
            }

            Map<Id, Id> itemIdToAccountId = new Map<Id, Id>();
            Map<Id, String> itemIdToNewName = new Map<Id, String>();
            Integer reassignedItemCount = 0;

            for (String key : keyToAccountId.keySet()) {
                for (Id itemId : nullSafeIds(nameToItemIds.get(key))) {
                    itemIdToAccountId.put(itemId, keyToAccountId.get(key));
                    if (keyToNewName.containsKey(key)) {
                        itemIdToNewName.put(itemId, keyToNewName.get(key));
                    }
                    if (reassignedKeys.contains(key)) {
                        reassignedItemCount++;
                    }
                }
            }

            for (String key : skipKeys) {
                for (Id itemId : nullSafeIds(nameToItemIds.get(key))) {
                    itemsToUpdate.add(new SLO_Sellout_Item__c(
                        Id = itemId,
                        SLO_Processing_Status__c = 'Skipped',
                        SLO_Processing_Notes__c = NOTE_ACCOUNT_DECLINED
                    ));
                    result.itemsSkipped++;
                }
            }

            if (!itemIdToAccountId.isEmpty()) {
                List<SLO_Sellout_Item__c> decidedRows = [
                    SELECT Id, SLO_Item_Date__c, SLO_Product_Code_EAN__c, SLO_Quantity__c,
                           SLO_Customer_Account_Name__c, SLO_Matched_Account__c,
                           SLO_Processing_Status__c, SLO_Processing_Notes__c, SLO_Sellout_Report__c
                    FROM SLO_Sellout_Item__c
                    WHERE Id IN :itemIdToAccountId.keySet()
                    ORDER BY Id ASC
                ];

                for (SLO_Sellout_Item__c row : decidedRows) {
                    if (row.SLO_Quantity__c == null || row.SLO_Quantity__c == 0) {
                        row.SLO_Processing_Status__c = 'Skipped';
                        row.SLO_Processing_Notes__c = NOTE_ZERO_QUANTITY;
                        continue;
                    }
                    if (itemIdToNewName.containsKey(row.Id)) {
                        row.SLO_Customer_Account_Name__c = itemIdToNewName.get(row.Id);
                    }
                    row.SLO_Matched_Account__c = itemIdToAccountId.get(row.Id);
                    row.SLO_Processing_Status__c = 'Matched';
                    row.SLO_Processing_Notes__c = NOTE_READY;
                }

                // A decision resolves the account, not the data - re-check the decided rows
                ValidationCounts flagged = validateItemsForAccount(
                    decidedRows, parentAccountId, itemIdToAccountId.keySet(),
                    context != null && context.processDuplicates == true ? DUP_MODE_PROCESS : null
                );

                result.itemsReassigned = reassignedItemCount;
                for (SLO_Sellout_Item__c row : decidedRows) {
                    if (row.SLO_Processing_Status__c == 'Matched') {
                        result.itemsMatched++;
                    } else if (row.SLO_Processing_Status__c == 'Error') {
                        result.itemsFlagged++;
                    }
                    itemsToUpdate.add(row);
                }

                List<String> flagNotes = new List<String>();
                if (flagged.duplicates > 0) {
                    flagNotes.add(flagged.duplicates +
                        ' line(s) were already recorded and were skipped as duplicates');
                }
                if (flagged.quantityConflicts > 0) {
                    flagNotes.add(flagged.quantityConflicts +
                        ' line(s) conflict on quantity with a recorded line - review them in the item list');
                }
                if (flagged.productErrors > 0) {
                    flagNotes.add(flagged.productErrors +
                        ' line(s) have an unknown product code - review them in the item list');
                }
                if (!flagNotes.isEmpty()) {
                    appendWarning(result, String.join(flagNotes, '; ') + '.');
                }
            }

            if (!itemsToUpdate.isEmpty()) {
                Database.update(itemsToUpdate, false);
            }

            if (!failedNames.isEmpty()) {
                appendWarning(result, failedNames.size() +
                    ' account(s) could not be created and were left for a later decision: ' +
                    String.join(failedNames, ', '));
            }

            // Kick off invoice creation asynchronously so the user can close the browser. A single
            // row resolved inside the review list skips this - the user is still reviewing and will
            // press Apply Sellout when the whole list is right.
            Boolean autoAcceptRun = context != null && context.autoAccept == true;
            if (autoAcceptRun) {
                skipUncorrectedErrorItems(reportId);
            }
            if (startInvoicing == true && (result.itemsMatched > 0 || autoAcceptRun)) {
                result.jobId = Database.executeBatch(
                    new SLO_SelloutApplyBatch(
                        reportId, parentAccountId, SLO_SelloutApplyBatch.MODE_INVOICE,
                        context == null ? new SLO_SelloutApplyBatch.RunContext() : context
                    ),
                    SLO_SelloutApplyBatch.scopeSizeForAttempt(1)
                );
            }

            result.success = true;

        } catch (Exception e) {
            result.success = false;
            result.errorMessage = 'Error resolving unmatched accounts: ' + e.getMessage();
        }

        return result;
    }

    /**
     * @description Insert child accounts in small chunks, silently retrying the rows that failed.
     * Chunking keeps each insert well inside the DML row limit, and a retry clears the transient
     * lock and row-contention failures that occur when many accounts share one parent.
     * @param accountsToCreate Accounts to insert; each successfully inserted record has its Id populated
     * @return Count of accounts created
     */
    private static Integer insertAccountsWithRetry(List<Account> accountsToCreate) {
        Integer created = 0;
        Integer chunkSize = 50;

        for (Integer offset = 0; offset < accountsToCreate.size(); offset += chunkSize) {
            Integer endIndex = Math.min(offset + chunkSize, accountsToCreate.size());
            List<Account> chunk = new List<Account>();
            for (Integer i = offset; i < endIndex; i++) {
                chunk.add(accountsToCreate[i]);
            }

            List<Account> retryChunk = new List<Account>();
            for (Database.SaveResult saveResult : Database.insert(chunk, buildCreateOptions())) {
                if (saveResult.isSuccess()) {
                    created++;
                }
            }

            // The Ids land on the original records, so any still-null Id marks a row to retry once
            for (Account account : chunk) {
                if (account.Id == null) {
                    retryChunk.add(account);
                }
            }

            if (!retryChunk.isEmpty()) {
                for (Database.SaveResult saveResult : Database.insert(retryChunk, buildCreateOptions())) {
                    if (saveResult.isSuccess()) {
                        created++;
                    }
                }
            }
        }

        return created;
    }

    /**
     * @description Null-safe list accessor used when grouping items by customer name
     * @param ids Possibly null list of Ids
     * @return The list, or an empty list when null
     */
    private static List<Id> nullSafeIds(List<Id> ids) {
        return ids == null ? new List<Id>() : ids;
    }

    /**
     * @description DML options for creating child accounts the user has explicitly asked for:
     * partial success plus duplicate-rule bypass, since fuzzy duplicate rules match these
     * accounts against each other within the same batch even when no duplicate exists
     * @return Database.DMLOptions configured for tolerant account creation
     */
    private static Database.DMLOptions buildCreateOptions() {
        Database.DMLOptions options = buildSingleCreateOptions();
        options.optAllOrNone = false;
        return options;
    }

    /**
     * @description DML options for creating one child account: duplicate rules are bypassed for
     * the same reason as the bulk path, but all-or-none is kept so callers still get an exception
     * they can surface to the user when the single insert fails
     * @return Database.DMLOptions configured for single-account creation
     */
    private static Database.DMLOptions buildSingleCreateOptions() {
        Database.DMLOptions options = new Database.DMLOptions();
        options.optAllOrNone = true;
        options.DuplicateRuleHeader.AllowSave = true;
        options.DuplicateRuleHeader.RunAsCurrentUser = true;
        return options;
    }

    // =========================================================================
    // Helpers exposed to the batch classes
    // =========================================================================

    /**
     * @description Parse one CSV line with the given delimiter (exposed for the import batch)
     * @param line The CSV line to parse
     * @param delimiter The delimiter character
     * @return List of field values
     */
    public static List<String> parseCsvRow(String line, String delimiter) {
        return parseCSVLine(line, delimiter);
    }

    /**
     * @description Parse a date string for the given locale (exposed for the import batch)
     * @param dateStr Date string from the CSV
     * @param locale LocaleSidKey of the importing user
     * @return Date parsed value
     */
    public static Date parseDateForLocale(String dateStr, String locale) {
        return parseDateByLocale(dateStr, locale);
    }

    /**
     * @description Parse a number string for the given locale (exposed for the import batch)
     * @param numStr Number string from the CSV
     * @param locale LocaleSidKey of the importing user
     * @return Decimal parsed value
     */
    public static Decimal parseNumberForLocale(String numStr, String locale) {
        return parseNumberByLocale(numStr, locale);
    }

    /**
     * @description Email the running user a completion summary. Failures are logged rather than
     * thrown so a hit email limit never rolls back the work the batch already committed.
     * @param toAddress Recipient email address
     * @param subject Email subject
     * @param body Plain text email body
     */
    public static void sendCompletionEmail(String toAddress, String subject, String body) {
        if (String.isBlank(toAddress)) {
            return;
        }

        try {
            Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
            message.setToAddresses(new List<String>{ toAddress });
            message.setSubject(subject);
            message.setPlainTextBody(body);
            message.setSaveAsActivity(false);

            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ message }, false);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Unable to send completion email: ' + e.getMessage());
        }
    }
}