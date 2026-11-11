# 1. Executive Summary

The Sellout Import Manager is a Lightning Web Component that enables sales users to import and manage customer sellout data directly from Account record pages. This solution streamlines the process of uploading Excel/CSV files containing product sales information, automatically matching customer accounts in the hierarchy, and creating consolidated invoices for downstream processing. The component eliminates manual data entry, prevents duplicate imports, and provides intelligent account matching with user-friendly error handling—allowing teams to process thousands of sellout records efficiently while maintaining data accuracy.

# 2. Manual Configuration Steps

1. **Assign Permission Set to Users**
   - Navigate to Setup > Users
   - For each user who needs access to the Sellout Import Manager, assign the **SLO_SelloutImportFullAccess** permission set
   - This grants access to the LWC, batch Apex classes, sellout objects, invoice objects, and pricebook lookups

2. **Add Component to Account Record Page**
   - Navigate to Setup > Lightning App Builder
   - Open the Account record page layout
   - Click **Edit**
   - Drag the **Sellout Import Manager** component onto the page
   - Configure the component to use the Account record context (recordId)
   - Click **Save** and **Activate**

3. **Verify ARF_CountrySettings Configuration**
   - Ensure ARF_CountrySettings__c records exist for each country/usage company code (e.g., 'FR', 'GR', 'SP')
   - Each record must have:
     - ARF_CountryCode__c matching the Account.Account_Usage_Company__c values
     - ARF_DefaultPricebook__c populated with the appropriate Pricebook2 record
     - ARF_IsActive__c set to true
   - These settings are used to resolve product prices during invoice creation

4. **Verify Product and Pricebook Setup**
   - Ensure Product2 records have Barcode__c (EAN code) populated for product matching
   - Verify PricebookEntry records exist in the resolved pricebooks with active status and unit prices
   - The system matches products by Barcode__c first, then falls back to ProductCode

5. **Configure Email Notifications (Optional)**
   - The system sends completion emails to the running user automatically
   - Verify that your Salesforce org has email relay configured if using a sandbox
   - No additional setup required for production orgs

# 3. How to Use This Solution

## Accessing the Component
1. Navigate to any Account record page where the Sellout Import Manager component has been added
2. The component displays a table of all previous sellout reports for that account, sorted by most recent import date first

## Importing Sellout Data
1. Click the **"Import Sellout Report"** button at the top of the component
2. **Step 1 – File Upload:**
   - Select a CSV file from your computer (Excel files must be exported as CSV first)
   - Maximum file size: 5 MB
   - Click **Next** to proceed

3. **Step 2 – Column Mapping:**
   - Select the CSV delimiter (comma for US files, semicolon for European files)
   - Map each required column from your CSV to the corresponding field:
     - Item Date
     - Product Code (EAN)
     - Quantity
     - Customer Account Name
   - The system saves your mappings for this account and auto-applies them to future imports
   - Click **Next** to preview the data

4. **Step 3 – Preview:**
   - Review the first 20 rows of your data to ensure columns are mapped correctly
   - The total row count is displayed
   - Click **Back** to adjust mappings or **Import** to start the batch import

## Monitoring Import Progress
- After clicking **Import**, the system processes your file in the background
- You will receive an email notification when the import completes with a summary of:
  - Items imported
  - Duplicate rows skipped
  - Any errors encountered
- The report status changes to **Draft**, indicating it is ready for review

## Reviewing and Correcting Imported Data
1. Click **"View Items"** on any Draft report to see the imported sellout items
2. The review screen shows:
   - **Summary badges:** Total rows, new items, ready items, errors, and duplicates skipped
   - **Items table:** All imported items with inline editing capability
   - **Error highlighting:** Items with errors are highlighted for easy identification

3. **Inline Editing:**
   - Click any cell in the Item Date, Product Code, Quantity, or Customer Account Name columns to edit
   - Changes are saved automatically when you move to another cell
   - The system validates data types and required fields

4. **Filter and Load Options:**
   - Click **"Show Errors Only"** to focus on items that need attention
   - Click **"Load All"** to load the complete list for bulk review

## Applying Sellout (Creating Invoices)
1. After reviewing and correcting items, click the **"Apply Sellout"** button
2. The system performs account matching:
   - Matches customer names to existing accounts in the hierarchy (main, child, or grandchild accounts)
   - Matching is case-insensitive and trims whitespace
   - For unmatched accounts, you are prompted to create a new child account or skip the items

3. **Handling Unmatched Accounts:**
   - A modal appears for each unmatched account name
   - Choose **"Yes"** to create a new child account or **"No"** to skip those items
   - Alternatively, use the **"Resolve Unmatched Accounts"** modal to handle all unmatched names at once with bulk actions

4. **Invoice Creation:**
   - Once all accounts are matched, the system groups items by account and date
   - One invoice is created per account with all related line items
   - You receive an email with the final summary including:
     - Invoices created
     - Line items added
     - Any items that could not be invoiced

## Viewing Completed Reports
- Click **"View Items"** on a Completed report to see a read-only summary of what was invoiced
- The summary displays total rows imported, invoices created, lines invoiced, duplicates skipped, and errors

# 4. Technical Summary

This deployment includes a Lightning Web Component (selloutImportManager2) integrated with three Apex batch classes for asynchronous processing of large sellout imports. The architecture uses a chained batch pattern where SLO_SelloutItemImportBatch handles CSV parsing and duplicate detection, then chains into SLO_SelloutApplyBatch in match mode for account hierarchy matching, and finally into invoice mode for grouped invoice creation with pricebook-based price lookup. The component provides a multi-step import wizard with column mapping persistence, inline editing of imported items, and intelligent account matching with case-insensitive comparison across main/child/grandchild account hierarchies. Key technical decisions include: (1) storing all imported rows (including duplicates marked as Skipped) to maintain a complete file record, (2) using a Draft status after import to allow user review before invoice creation, (3) implementing a RunContext object to carry processing metrics through the batch chain for a single completion email, and (4) leveraging ARF_CountrySettings for country-specific pricebook resolution. The solution integrates with existing Invoice__c and Invoice_Line_Item__c objects, supports locale-aware date/number parsing, and includes graceful error handling with retry logic for transient failures.

---

## Appendix — Requirements

## Introduction

This document outlines the requirements for building a Lightning Web Component (LWC) that enables sales users to import and manage sellout data directly from Account record pages. The component will provide Excel file upload capabilities with flexible column mapping, preview functionality, batch processing for large datasets, duplicate prevention, inline editing of imported data, intelligent account matching, and automated invoice creation. The solution leverages existing custom objects **SLO_Sellout_Report__c** and **SLO_Sellout_Item__c** to store sellout reports and individual sellout items, and integrates with **Invoice__c** and **Invoice_Line_Item__c** for downstream invoice processing.

## Requirements

### 1. Account Record Page Lightning Web Component
**Status:** approved

**User Story:** As a sales user, I want to see a Lightning Web Component on the Account record page that displays all sellout reports for this account and allows me to import new sellout data so that I can manage customer sellout information efficiently.

**Acceptance Criteria:**
- Create a Lightning Web Component named **selloutImportManager2**
- Component displays a table of all SLO_Sellout_Report__c records related to the current Account, showing:
- Report Number (Name field)
- Report Date (SLO_Report_Date__c)
- Status (SLO_Status__c)
- Total Items (SLO_Total_Items__c)
- Import Date (SLO_Import_Date__c)
- Table is sorted by Import Date descending (most recent first)
- Component includes an "Import Sellout Report" button at the top
- Component refreshes automatically after successful import
- Component shows loading spinner during data fetch and import operations
- Component is designed to be placed on Account record pages via Lightning App Builder
- Component uses the recordId attribute to identify the current Account

**Related Elements:** AC_SLOSelloutImportController, LWC_SelloutImportManager2, PS_SelloutImportFullAccess, AC_SLOSelloutImportControllerTest

### 2. Excel File Upload and Column Mapping
**Status:** approved

**User Story:** As a sales user, I want to upload an Excel file with sellout data and map the columns to the required fields so that I can import data from various Excel formats flexibly.

**Acceptance Criteria:**
- Clicking "Import Sellout Report" button opens a modal dialog
- Modal allows user to select a file with accepted formats: .xls, .xlsx, .csv
- File size limit: 5MB maximum
- After file selection, system parses the Excel file and displays all column headers
- User is presented with 4 dropdown fields to map Excel columns to:
- Item Date (SLO_Item_Date__c)
- Product Code EAN (SLO_Product_Code_EAN__c)
- Quantity (SLO_Quantity__c)
- Customer Account Name (SLO_Customer_Account_Name__c)
- Each dropdown shows all available column headers from the uploaded Excel
- System validates that all 4 mappings are selected before allowing user to proceed
- "Next" button is disabled until all 4 columns are mapped
- "Cancel" button closes the modal and discards the upload
- System displays clear error messages for invalid file formats or file size violations

**Related Elements:** AC_SLOSelloutImportController, LWC_SelloutImportManager2, PS_SelloutImportFullAccess, CO_SLOImportPreferences, DF_SLOImportPreferencesStartDate, TF_SLOImportPreferencesCSVDelimiter, AC_SLOSelloutImportControllerTest, LTAF_AccountSelloutColumnMapping, TF_ARFCsvDelimiter, TF_UserUsageCompany

### 3. Import Preview and Confirmation
**Status:** approved

**User Story:** As a sales user, I want to preview the data that will be imported before confirming the import so that I can verify the data is correct and cancel if needed.

**Acceptance Criteria:**
- After column mapping, user clicks "Next" to see preview screen
- Preview screen displays a table showing the first 20 rows of mapped data with columns:
- Item Date
- Product Code (EAN)
- Quantity
- Customer Account Name
- Preview screen shows total row count that will be imported
- Preview screen includes "Back" button to return to column mapping step
- Preview screen includes "Cancel" button to close modal and discard import
- Preview screen includes "Import" button to proceed with import
- Clicking "Back" returns user to column mapping step with previous selections preserved
- Clicking "Cancel" closes the modal and discards all data
- Clicking "Import" initiates the batch import process

**Related Elements:** AC_SLOSelloutImportController, LWC_SelloutImportManager2, PS_SelloutImportFullAccess, AC_SLOSelloutImportControllerTest

### 4. Batch Import Processing with Duplicate Prevention
**Status:** approved

**User Story:** As a sales user, I want the system to import large Excel files efficiently in batches and prevent duplicate imports so that I can import thousands of records without hitting Salesforce governor limits or creating duplicate data.

**Acceptance Criteria:**
- Before starting import, system checks for existing SLO_Sellout_Report__c records with:
- Same SLO_Account__c (current Account record ID)
- Same SLO_Report_Date__c (today's date)
- If duplicate found, system displays error message: "A sellout report for this account and date already exists. Please delete the existing report or change the report date before importing."
- If duplicate found, system prevents import and returns user to import wizard
- If no duplicate, system creates a new SLO_Sellout_Report__c record with SLO_Status__c = "New" when import starts
- SLO_Sellout_Report__c.SLO_Account__c is set to the current Account record ID
- SLO_Sellout_Report__c.SLO_Report_Date__c is set to today's date
- System processes SLO_Sellout_Item__c records in batches of 200 records maximum
- Each batch is inserted using Apex DML operations
- Each SLO_Sellout_Item__c record is linked to the SLO_Sellout_Report__c via SLO_Sellout_Report__c lookup field
- System displays progress indicator showing "Importing X of Y records..."
- If any batch fails, system:
- Updates SLO_Sellout_Report__c.SLO_Status__c to "Error"
- Captures error message in SLO_Sellout_Report__c.SLO_Error_Message__c
- Displays error message to user
- Stops further processing
- If all batches succeed, system:
- Updates SLO_Sellout_Report__c.SLO_Status__c to "Completed"
- Sets SLO_Sellout_Report__c.SLO_Import_Date__c to current timestamp
- Updates SLO_Sellout_Report__c.SLO_Total_Items__c with count of imported items
- Displays success message: "Successfully imported X sellout items"
- Modal closes automatically after successful import
- Component table refreshes to show the newly created report

**Related Elements:** AC_SLOSelloutItemImportBatch, AC_SLOSelloutImportController, LWC_SelloutImportManager2, PS_SelloutImportFullAccess, PF_SLOSelloutReportStatus, AC_SLOSelloutApplyBatch, AC_SLOSelloutValidationTest, CO_SLOImportPreferences, DF_SLOImportPreferencesStartDate, TF_SLOImportPreferencesCSVDelimiter, AC_SLOSelloutApplyBatchTest, AC_SLOSelloutImportControllerTest

### 5. Sellout Items Table with Inline Editing
**Status:** approved

**User Story:** As a sales user, I want to view all imported sellout items in a table with inline editing capability so that I can correct any data issues before applying the sellout to create invoices.

**Acceptance Criteria:**
- User can click on any sellout report row in the main table to expand and view related items
- Expanded section displays a table of all SLO_Sellout_Item__c records for the selected SLO_Sellout_Report__c
- Table columns are inline-editable:
- Item Date (SLO_Item_Date__c)
- Product Code EAN (SLO_Product_Code_EAN__c)
- Quantity (SLO_Quantity__c)
- Customer Account Name (SLO_Customer_Account_Name__c)
- Table includes read-only columns:
- Processing Status (SLO_Processing_Status__c)
- Processing Notes (SLO_Processing_Notes__c)
- User can click on any editable cell to modify the value
- Changes are saved automatically when user moves to another cell or presses Enter
- System validates required fields and data types during inline edit
- Invalid edits show error message and revert to previous value
- System displays loading indicator during save operations
- Table includes "Apply Sellout" button at the top of the expanded section
- "Apply Sellout" button is enabled only when SLO_Status__c = "Completed"
- "Apply Sellout" button is disabled when SLO_Status__c = "New" or "Error"
- Clicking "Apply Sellout" triggers downstream processing (Requirement 6 and 7)

**Related Elements:** AC_SLOSelloutImportController, LWC_SelloutImportManager2, PS_SelloutImportFullAccess, PF_SLOSelloutReportStatus, AC_SLOSelloutApplyBatch, AC_SLOSelloutValidationTest, AC_SLOSelloutImportControllerTest

### 6. Apply Sellout - Account Matching Logic with Case-Insensitive Matching
**Status:** approved

**User Story:** As a sales user, I want the system to intelligently match customer account names from sellout items to existing accounts in the hierarchy using case-insensitive matching so that invoices are created for the correct accounts automatically regardless of capitalization differences.

**Acceptance Criteria:**
- When user clicks "Apply Sellout" button, system processes each SLO_Sellout_Item__c record
- For each SLO_Sellout_Item__c, system retrieves SLO_Customer_Account_Name__c value and trims whitespace
- System performs account matching with case-insensitive comparison in the following order:
- **Main Account Match**: If SLO_Customer_Account_Name__c equals the current Account.Name (case-insensitive, whitespace trimmed), system:
- Sets SLO_Sellout_Item__c.SLO_Matched_Account__c to current Account ID
- Marks item for invoice creation with main account flag
- Updates SLO_Sellout_Item__c.SLO_Processing_Status__c to "Matched"
- **Child Account Match**: If no main account match, system queries for Account records where:
- Account.ParentId = current Account ID
- Account.Name matches SLO_Customer_Account_Name__c (case-insensitive, whitespace trimmed)
- If found, system:
- Sets SLO_Sellout_Item__c.SLO_Matched_Account__c to matched child Account ID
- Marks item for invoice creation with child account flag
- Updates SLO_Sellout_Item__c.SLO_Processing_Status__c to "Matched"
- **Grandchild Account Match**: If no child account match, system queries for Account records where:
- Account.ParentId IN (child account IDs of current Account)
- Account.Name matches SLO_Customer_Account_Name__c (case-insensitive, whitespace trimmed)
- If found, system:
- Sets SLO_Sellout_Item__c.SLO_Matched_Account__c to matched grandchild Account ID
- Marks item for invoice creation with child account flag
- Updates SLO_Sellout_Item__c.SLO_Processing_Status__c to "Matched"
- **No Match - Prompt User Individually**: If no match found in main/child/grandchild accounts, system:
- Pauses processing and displays modal prompt: "Account '[SLO_Customer_Account_Name__c]' not found. Would you like to create a new child account?"
- Modal includes "Yes" and "No" buttons
- If user clicks "Yes":
- System creates new Account record with Name = SLO_Customer_Account_Name__c (trimmed)
- Sets new Account.ParentId = current Account ID
- Sets SLO_Sellout_Item__c.SLO_Matched_Account__c to new Account ID
- Marks item for invoice creation with new account flag
- Updates SLO_Sellout_Item__c.SLO_Processing_Status__c to "Matched"
- Continues processing next unmatched item
- If user clicks "No":
- Updates SLO_Sellout_Item__c.SLO_Processing_Status__c to "Error"
- Sets SLO_Sellout_Item__c.SLO_Processing_Notes__c to "Account not found and user declined to create new account"
- Continues processing next unmatched item
- After all items are matched, system proceeds to grouped invoice creation (Requirement 7)
- System displays summary: "Matched X items: Y to existing accounts, Z new accounts created, W errors"

**Related Elements:** PF_SLOSelloutItemProcessingStatus, AC_SLOSelloutApplyBatch, AC_SLOSelloutImportController, LWC_SelloutImportManager2, PS_SelloutImportFullAccess, AC_SLOSelloutValidationTest, AC_SLOSelloutAccountMatcher, AC_SLOSelloutInvoiceReviewBatch, AC_SLOSelloutInvoiceReviewBatchTest, AC_SLOSelloutApplyBatchTest, AC_SLOSelloutImportControllerTest

### 7. Grouped Invoice and Invoice Line Item Creation
**Status:** approved

**User Story:** As a sales user, I want the system to automatically group sellout items by account and create one invoice per account with multiple line items so that all products for the same customer are consolidated into a single invoice.

**Acceptance Criteria:**
- After account matching is complete, system groups all matched SLO_Sellout_Item__c records by SLO_Matched_Account__c
- For each unique SLO_Matched_Account__c, system creates ONE Invoice__c record with:
- Account_Name__c (required) = SLO_Matched_Account__c (the matched account ID)
- Invoice_Date__c = earliest SLO_Item_Date__c from all sellout items in this group
- Status__c = "New" (or appropriate default status)
- Delivered_VN__c = false (required boolean field)
- Manual_Creation__c = false (required boolean field)
- Valid__c = true (required boolean field)
- For each SLO_Sellout_Item__c in the group, system creates ONE Invoice_Line_Item__c record with:
- Invoice_Number__c (required) = the Invoice__c ID created for this account group
- Product_Name__c = SLO_Sellout_Item__c.SLO_Product_Code_EAN__c
- Quantity__c = SLO_Sellout_Item__c.SLO_Quantity__c
- Valid__c = true (required boolean field)
- After creating each Invoice_Line_Item__c, system updates the corresponding SLO_Sellout_Item__c:
- Sets SLO_Sellout_Item__c.SLO_Invoice_Line_Item__c = newly created Invoice_Line_Item__c ID (for tracking)
- Updates SLO_Sellout_Item__c.SLO_Processing_Status__c to "Invoice Created"
- System handles DML exceptions for each account group:
- If invoice or line item creation fails for a group, system:
- Updates all SLO_Sellout_Item__c records in that group to SLO_Processing_Status__c = "Error"
- Captures error details in SLO_Sellout_Item__c.SLO_Processing_Notes__c
- Continues processing remaining account groups
- System commits all invoice and line item records in a single transaction per account group
- System displays final summary: "Created X invoices for Y accounts with Z total line items. W errors occurred."
- System provides breakdown showing:
- Number of invoices created for main account
- Number of invoices created for child/grandchild accounts
- Number of invoices created for newly created accounts
- Number of sellout items that failed to create invoices

**Related Elements:** AC_SLOSelloutApplyBatch, AC_SLOSelloutImportController, LWC_SelloutImportManager2, PS_SelloutImportFullAccess, CF_InvoiceLineItemNetPrice, CF_InvoiceLineItemGrossValue, CF_InvoiceLineItemGrossPrice, CF_InvoiceLineItemTotalAfterDiscount, CF_InvoiceLineItemVATInOriginalPrice, CF_InvoiceLineItemVATInDollars, FF_InvoiceLineItemInvoiceValue, RSF_InvoiceTotalInvoiceValue, RSF_InvoiceTotalGrossValue, RSF_InvoiceTotalVAT, RSF_InvoiceNetPrice, AC_SLOSelloutInvoiceReviewBatch, AC_SLOSelloutInvoiceReviewBatchTest, AC_SLOSelloutApplyBatchTest, AC_SLOSelloutImportControllerTest

### 8. Bulk Actions on Account Decision and Needs a Fix Views
**Status:** approved

**User Story:** As a sales user, I want to select multiple rows in the Account decision and Needs a fix views and apply one action or correction to all of them at once so that I can resolve large numbers of unmatched accounts or invalid data efficiently instead of handling each line individually.

**Acceptance Criteria:**
- On the Account decision view, checkboxes select by distinct Customer Account Name, not by individual line row — selecting one checkbox selects all SLO_Sellout_Item__c lines sharing that customer name
- Row count/summary text on the Account decision view reflects the number of distinct customer names selected and the total lines those names cover
- Account decision view provides a bulk action "Create these accounts": for all selected customer names, creates a new child Account per distinct name (Name = customer name, ParentId = current Account) and maps all lines for that name to the newly created Account, transitioning them out of Skipped/Account decision toward Ready/Matched (subject to re-validation)
- Account decision view provides a bulk action "Leave these customers out": for all selected customer names, marks all lines for those names as Skipped with a processing note indicating the customer was intentionally left out, consistent with the existing single-row skip behavior
- Account decision view provides a bulk re-map action allowing the user to pick one existing Account and apply it to all lines under the selected customer name(s) in a single operation, mapping SLO_Matched_Account__c for every selected line to that chosen existing Account and re-validating them
- Bulk actions on Account decision process all lines for the selected customer names, not just the currently loaded/paginated subset, respecting existing governor-limit-safe batching patterns already used for re-validation
- Needs a fix view supports selecting multiple individual line rows via checkboxes (row-level selection, not grouped by customer name)
- Needs a fix view provides a bulk edit action to apply the same corrected Product Code (EAN) value to all selected rows in a single operation, then re-validates each affected line immediately
- Needs a fix view provides a bulk edit action to apply the same corrected Customer Account Name value to all selected rows in a single operation, then re-validates each affected line immediately
- After any bulk action completes, the Ready/Need a fix/Account decision/Skipped badge counts refresh to reflect the outcome, consistent with how single-row edits update counts today
- Bulk action results display a confirmation summary (e.g. number of lines updated, number now Ready, number still needing a fix or a decision), consistent with the existing single-edit confirmation messaging
- If a bulk action partially fails (e.g. some lines fail re-validation or DML), the system reports which lines succeeded and which still need attention rather than silently failing the entire batch
- Bulk selection and actions are available only on the Account decision and Needs a fix views; other views (Ready, Skipped, Not checked yet) do not require bulk action controls for this requirement

**Related Elements:** AC_SLOSelloutImportController

### 9. Daily Automated Sellout: Invoice-to-CSV Generation and Auto-Accept Apply
**Status:** approved

**User Story:** As a sales operations user, I want a new daily job that builds a sellout CSV from the latest unreviewed closed customer invoices and their original orders, then imports and applies it automatically with auto-accept, so that sellout is created every day for opted-in accounts without manual uploads or review.

**Acceptance Criteria:**
- The daily job is a NEW process, separate from the existing weekly SLO_SelloutInvoiceReviewBatch / SLO_SelloutInvoiceReviewScheduler, which stay unchanged and keep running weekly
- The new job is scheduled to run once every day and processes only accounts where Account.SLO_Automatic_Sellout__c = true (existing field reused, no new checkbox)
- For each opted-in account, the job scans the latest closed customer Invoice__c records where Invoice__c.SLO_Sellout_Reviewed__c = false, Invoice_Date__c is on or after the fixed start date 01-Jan-2026, and which are not Internal Sellout / Internal Sellout N transactions. The start date is a fixed value for all automated runs (not a user preference or setting); invoices dated before it are ignored and left unreviewed (SLO_Sellout_Reviewed__c stays false). Manual imports keep their own Start Date preference.
- For each such invoice line, the job locates the original Order (via Invoice_Line_Item__c.Order__c) and takes the customer name from the same Order customer-input field the existing weekly process uses today
- The job generates a CSV file containing one row per invoice line with: Customer Name (from the Order), and Quantity, Date and SKU/Item Code (from the Invoice and Invoice Line Item)
- The CSV is generated independently of the import batch (built first as a file, not inline in the import batch), then stored as a ContentVersion attached to the SLO_Sellout_Report__c record the job creates
- The job creates the SLO_Sellout_Report__c for the account and runs the existing import pipeline (SLO_SelloutItemImportBatch) on the generated CSV, so SLO_Sellout_Item__c records are created through the same path as a manual import
- The existing duplicate rule applies: if a report for the same account and report date already exists, the job does not create a second one and logs the skip
- After import, the job runs the existing Apply Sellout process (SLO_SelloutApplyBatch) with Auto Accept enabled
- With Auto Accept, items in Need a fix are skipped automatically without prior review, and invoices are generated only for items that are Ready/Matched; no manual prompts are shown
- The customer-input field on the Order is updated exactly as the existing weekly process does today (same field, same behavior)
- After a source invoice has been included in a generated CSV, the job sets Invoice__c.SLO_Sellout_Reviewed__c = true; flagged invoices are skipped in later runs, so the same invoice is never included twice
- If no unreviewed invoices exist for an account, no file or report is created for that account and the job completes without error
- A failure on one account (file generation, import or apply) is recorded on that account's report (SLO_Status__c = Error, SLO_Error_Message__c) and does not stop processing of other accounts
- Note: because the weekly batch and the new daily job share Invoice__c.SLO_Sellout_Reviewed__c, an invoice processed by either is skipped by the other
- Apex test coverage is included for the CSV generation, reviewed-flag handling, scheduling, and the per-account error path

**Related Elements:** AC_SLOSelloutDailyCsvBuilder, AC_SLOSelloutDailyAutoBatch, AC_SLOSelloutDailyAutoScheduler, PS_SelloutImportFullAccess, AC_SLOSelloutDailyAutoBatchTest

### 10. Account Creation Count in Sellout Results
**Status:** approved

**User Story:** As a sales user, I want the Sellout results summary to show how many new accounts were created during Apply Sellout so that I can see the effect of the run on the account hierarchy.

**Acceptance Criteria:**
- The Sellout results summary (shown after Apply Sellout, manual or Auto Accept) shows 'Accounts created: N'
- N counts the distinct new child Accounts created during the run, whether created by user decision, bulk 'Create these accounts', or Auto Accept
- Accounts matched to existing accounts are not counted in N
- The count is stored on the SLO_Sellout_Report__c (new number field) so it persists and appears in the reports table and the Check Status result
- The count shows 0 when no accounts were created
- The count is included in the existing summary message and in the completion email, if one is sent
- Re-running Apply Sellout to resume does not double-count accounts already created

**Related Elements:** NF_SLOSelloutReportAccountsCreated, AC_SLOSelloutApplyBatch, AC_SLOSelloutImportController, LWC_SelloutImportManager2, PS_SelloutImportFullAccess

### 11. Read-Only Review of Auto-Accepted Sellout Lines
**Status:** approved

**User Story:** As a sales user, I want to open the review lines of a sellout that was applied with Auto Accept, in a locked read-only view, so that I can see what was matched, skipped or invoiced without changing the result.

**Acceptance Criteria:**
- Reports processed with Auto Accept (the daily automated job) show a 'Review Lines' action in the reports table
- Review Lines opens the existing view tabs (Ready, Need a fix, Account decision, Skipped, Invoiced) with their badge counts
- In this mode all editing is disabled: no inline editing, no row checkboxes, no bulk actions, no Apply Sellout, no create-account or re-map actions
- A 'Locked: applied with Auto Accept' notice is shown at the top of the view
- Each line still shows Processing Status and Processing Notes, including why it was skipped
- Locking is enforced in Apex as well: update and bulk-action methods reject changes to items on an Auto Accept report, not only in the UI
- A new checkbox on SLO_Sellout_Report__c (e.g. SLO_Auto_Accepted__c) is set by the daily job to identify these reports
- Manually imported reports keep the current editable behaviour
- Apex test coverage is included for the lock enforcement and the flag

**Related Elements:** CF_SLOSelloutReportAutoAccepted, AC_SLOSelloutImportController, LWC_SelloutImportManager2, PS_SelloutImportFullAccess, AC_SLOSelloutDailyAutoBatch

### 12. Automatic Sellout Configuration on Account (Epic A)
**Status:** approved

**User Story:** As a sales operations user, I want to enable and configure automatic sellout from the Sellout section of the Account so that the daily automated job runs only for accounts that opted in, using the standard "by linked order details" method, and keeps the Order customer input field populated.

**Acceptance Criteria:**
- A1: Account.SLO_Automatic_Sellout__c (existing checkbox, labelled 'Automated Sellout Enabled') is shown and editable inside the selloutImportManager2 component, and the toggle saves to the Account
- A2: The daily automated job processes only Accounts where SLO_Automatic_Sellout__c = true; accounts set to false are skipped and the skip is logged
- A3: A new single-value picklist on Account (e.g. SLO_Sellout_Method__c) offers only 'By linked order details'; the user selects it when the automatic flag is on
- A3: When SLO_Automatic_Sellout__c = true, the method is required (validation blocks saving the flag without the method)
- A3: The daily job runs only with the method 'By linked order details'; accounts with any other or empty method are skipped and flagged in the log
- A4: Same process as the existing batch import (SLO_SelloutInvoiceReviewBatch): the customer name is read from Order.Customer_name_Description__c, trimmed, matched to or created as a child Account, and its Id is written to Order.Child_Account_Non_SBO__c only when that field is empty
- A4: Order.Child_Account_Non_SBO__c is populated for all orders linked to the invoice lines included in the run (orders already populated are left unchanged)
- Apex test coverage is included for the flag check, method check, skip logging and Order field update

**Related Elements:** PF_AccountSelloutMethod, AC_SLOSelloutImportController, LWC_SelloutImportManager2, PS_SelloutImportFullAccess, AC_SLOSelloutDailyAutoBatch, VR_AccountSelloutMethodRequired

### 13. Auto-Generated Sellout Upload File (Epic B)
**Status:** approved

**User Story:** As a sales operations user, I want the system to build the sellout upload file itself, in the same format as the manual file, and hand it to the import Batch as if I had uploaded it, so that I no longer prepare and upload the file by hand.

**Acceptance Criteria:**
- B2: The file is built by its own step outside SLO_SelloutItemImportBatch (existing SLO_SelloutDailyCsvBuilder service class), from the invoice and order data selected for the run
- B2: The file has the 4 mapped columns of the manual template, with the template's header names: PERIODE DE VENTES (Item Date), EAN PRODUIT (Product Code EAN), QTY FACTUREE (Quantity), NOM CLIENT (Customer Account Name); the other columns of the Actura sample are not generated
- B2: PERIODE DE VENTES is written in the format dd/mm/yy (jj/mm/aa) and the import parses this format correctly into SLO_Item_Date__c
- B2: One row per invoice line; NOM CLIENT comes from the Order customer name field used by the existing weekly process, EAN PRODUIT from the invoice line item code, QTY FACTUREE from the line quantity
- B3: The file is saved as a ContentVersion linked to the SLO_Sellout_Report__c, the same place and way as a manual upload, and appears in the report's Files
- B3: The file title starts with the prefix 'AUTO - ' so it can be told apart from user uploads; no new field is added
- B4: SLO_SelloutItemImportBatch picks up the generated file through the same path as a manual upload (same column mapping, delimiter and start-date handling) and produces the same outcomes as a manual file with the same rows
- B4: After import, the existing Apply Sellout step runs as in the daily job (Auto Accept)
- Apex test coverage is included for the column headers and date format, the 'AUTO - ' title prefix and the Batch processing the generated file

**Related Elements:** AC_SLOSelloutItemImportBatch, AC_SLOSelloutDailyCsvBuilder, AC_SLOSelloutDailyAutoBatch

### 14. Auto Accept Logic for Automated Sellout (Epic C)
**Status:** approved

**User Story:** As a sales operations user, I want automated sellout runs to use the existing Auto Accept logic end to end, so that accounts are resolved, lines needing a fix are set aside and invoices are created without any user action.

**Acceptance Criteria:**
- C1: The existing Auto Accept option (ImportMappingConfig.autoAccept, carried in the Apply Sellout run context) is switched on for every run started by the daily automated job; no new setting or field is added
- C1: With Auto Accept on, the run needs no user action: no account-decision prompt, no review step and no manual Apply Sellout click
- C1: Unmatched customer names are resolved automatically: an inactive matching account is activated, otherwise a new child Account is created under the current Account, and the count is stored in SLO_Accounts_Created__c
- C2: Auto Accept runs create Invoice__c and Invoice_Line_Item__c records for Ready/Matched lines only, using the existing invoice creation pass of SLO_SelloutApplyBatch, and no other record types are created apart from the child Accounts of C1
- C3: Lines in Need a fix (Error) status are set aside as Skipped automatically with no prior review, using the existing skipUncorrectedErrorItems logic, with the reason kept in SLO_Processing_Notes__c for follow-up
- C3: In a run with mixed lines, valid lines are invoiced and need-fix lines are not invoiced, and their count appears in the run summary
- C4: SLO_SelloutApplyBatch is started directly by the automated flow right after the import completes, without a manual run step, and runs through to the final summary
- C4: A failure in the run is recorded on the report (SLO_Status__c = Error, SLO_Error_Message__c) and does not stop other accounts
- No change to manually imported reports: they keep the review flow and the Apply Sellout button
- Apex test coverage is included for the Auto Accept stages: set aside, account resolution, invoicing and a mixed-lines run

**Related Elements:** AC_SLOSelloutApplyBatch

### 15. Run Log, Failure Notification and Tests for Daily Automated Sellout (Epic E)
**Status:** approved

**User Story:** As a sales operations user, I want each daily automated sellout run to leave a log with counts on the Sellout Report and to email the scheduling user on failure, so that I can monitor the automation without checking debug logs.

**Acceptance Criteria:**
- E1/E2 (already delivered by requirements #9, #13, #14): the daily scheduler chains invoice scan and CSV (Epic D), import and Auto Accept apply (Epics B and C); an account with no unreviewed invoices creates no file or report and exits without error
- E3: The run log is stored on the existing SLO_Sellout_Report__c; no new object is created
- E3: New number fields on SLO_Sellout_Report__c store the run counts: invoice lines processed, invoice lines skipped (e.g. no Order or no customer name), and lines needing a fix (set aside as Skipped by Auto Accept)
- E3: The counts are filled by the daily job (processed and skipped at CSV build, need-fix at the end of the Auto Accept run) and are visible to users with the Sellout permission set
- E3: When an account's run fails (CSV, import or apply), SLO_Status__c = Error and SLO_Error_Message__c are set on its report, and an email describing the failure is sent to the user who scheduled the job; processing of other accounts continues
- E3: Failed runs send at most one email per job run (a single consolidated message listing the failed accounts)
- E1: The scheduler run time is defined at scheduling time by the admin (no fixed time is hard-coded beyond the existing scheduler class)
- E4: Apex tests cover the scheduler, the daily batch, the CSV builder, the reviewed-flag logic (flag set only after the file is saved, released on failure), run-count population and the failure email
- E4: Overall coverage of the classes involved is at least 75%, and existing tests broken by the Epic B format changes (headers, column order, dd/mm/yy dates) are updated

**Related Elements:** NF_SLOSelloutReportLinesProcessed, NF_SLOSelloutReportLinesSkipped, NF_SLOSelloutReportLinesNeedFix, PS_SelloutImportFullAccess, AC_SLOSelloutApplyBatch, AC_SLOSelloutDailyAutoBatch, AC_SLOSelloutDailyAutoBatchTest

### 16. Price List Selection and Price Population for Manual Sellout
**Status:** approved

**User Story:** As a sales user running a manual sellout, I want to choose how invoice prices are determined (Last Item Price or a Dedicated Price Book) so that the invoices Apply Sellout creates carry real prices and values instead of zero.

**Acceptance Criteria:**
- The Apply Sellout step in selloutImportManager2 shows a required 'Customer Price List' choice with two options: 'Last Item Price' and 'Dedicated Price Book'
- Last Item Price: for each sellout line, the system finds the latest Invoice__c for the same matched customer Account and the same product, and uses that invoice line's price as Invoice_Line_Item__c.Unit_Price__c
- Last Item Price: 'latest' is decided by Invoice_Date__c (most recent first) across all invoice types, including Internal Sellout; the product is matched with the same EAN/Product Code normalization used today
- Last Item Price: if the customer has no earlier invoice for the item, the price falls back to the active PricebookEntry of the country default price book (existing resolution via Country Settings, including user override); if there is no default price book or no entry for the product, the line is not invoiced with a zero price but flagged as Need a fix with a note 'No previous invoice price or price book entry found'
- Dedicated Price Book: the user sees a list of all active Pricebook2 records whose name or a country field identifies the customer's country (Usage Company code) and must select one before continuing; the existing country-default resolution is preselected when it is in the list
- Dedicated Price Book: the price comes from the active PricebookEntry of the selected price book for the matched product; a product with no entry is flagged as Need a fix with a note naming the price book
- The chosen option (and price book, if any) applies to the whole Apply Sellout run and is stored on the SLO_Sellout_Report__c so it is visible afterwards and reused if the run is resumed
- Invoice_Line_Item__c fields that drive Invoice Value are populated from the resolved price and quantity (Unit_Price__c, Net_Price__c, Total_After_Discount__c, Gross_Price__c, Gross_Value__c), so the line Invoice_Value__c and the invoice roll-ups Total Invoice Value, Total Gross Value and Total VAT are no longer zero
- The offsetting negative parent invoice ('Internal Sellout N') uses the same resolved prices with negated quantity so it still cancels the child invoices
- Auto Accept runs from the daily job do not use this selection (see the daily price requirement)
- Apex test coverage is included for both options, the missing-price Need-a-fix path, price book selection, and non-zero invoice totals

**Related Elements:** PF_SLOSelloutReportPriceMethod, LF_SLOSelloutReportPriceBook, TF_Pricebook2UsageCompany, AC_SLOSelloutImportController, LWC_SelloutImportManager2, PS_SelloutImportFullAccess

### 17. Daily Automated Sellout: Copy Amounts from Source Invoice Lines
**Status:** approved

**User Story:** As a sales operations user, I want invoices created by the daily automated sellout to carry the amounts of the source invoice lines they come from so that prices and values are never empty or zero.

**Acceptance Criteria:**
- Each generated sellout line keeps a reference to its source Invoice_Line_Item__c through the CSV, import and apply steps (no change to the 4 mapped CSV columns required from the user)
- When Apply Sellout creates Invoice_Line_Item__c records for a daily Auto Accept run, the amounts are copied directly from the source line: Unit_Price__c, Net_Price__c, Total_After_Discount__c, Gross_Price__c, Gross_Value__c, VAT_In_Original_Price__c and VAT_In_Dollars__c
- No pricebook or Last Item Price lookup is used for daily runs
- Invoice_Value__c and the invoice roll-ups Total Invoice Value, Total Gross Value and Total VAT on the new invoices match the source amounts and are not zero or empty
- The offsetting negative parent invoice copies the same amounts with negated quantity and amounts, including VAT and VAT In Dollars (see requirement 18)
- A line whose source amounts are missing is not invoiced with empty values: it is set aside as Skipped with a processing note and counted in the run log
- Manual imports are unaffected
- Apex test coverage is included for amount copying, the negative offset, and the missing-amount path

**Related Elements:** LF_SLOSelloutItemSourceLineItem, AC_SLOSelloutItemImportBatch, AC_SLOSelloutImportController, PS_SelloutImportFullAccess, AC_SLOSelloutDailyCsvBuilder, AC_SLOSelloutDailyAutoBatch, AC_SLOSelloutDailyAutoBatchTest

### 18. Daily Automated Sellout: Align Matching and Invoice Creation with Weekly Batch
**Status:** approved

**User Story:** As a sales operations user, I want the daily automated sellout to match customers and create invoices with the same logic as the weekly SLO_SelloutInvoiceReviewBatch, while keeping the daily pipeline, so that both jobs give the same invoices and the amounts come from the original invoice lines.

**Acceptance Criteria:**
- The daily pipeline stays: CSV build, Sellout Report, SLO_SelloutItemImportBatch, SLO_SelloutApplyBatch with Auto Accept, and read-only Review Lines
- Invoice selection: only accounts with SLO_Automatic_Sellout__c = true; invoices that are not Internal Sellout or Internal Sellout N and have SLO_Sellout_Reviewed__c = false
- Customer matching follows the weekly batch: the end customer is read from Order.Customer_name_Description__c (trimmed) and matched to an existing child account, otherwise a child Account is created with the Distributor / Dealer (non-SBO) record type
- Order.Child_Account_Non_SBO__c is filled with the matched or created child account only when it is empty. Distributor-as-customer rule: when the Order customer name (trimmed, case-insensitive) equals the distributor account itself (e.g. ALCOR), the line is skipped: no child account is created, no Internal Sellout (-SO) or offset (-N) invoice line is created for it, and Order.Child_Account_Non_SBO__c is left unchanged. The skipped line is counted in SLO_Lines_Skipped__c with a processing note, and its source invoice is still marked SLO_Sellout_Reviewed__c = true so it is not re-processed. Manual imports are unaffected. Apex tests cover this skip.
- Invoice creation follows the weekly batch: one Internal Sellout Invoice__c per child account, using the same derived invoice number convention
- Amounts on Invoice_Line_Item__c are copied from the original invoice lines (no price book or Last Item Price lookup)
- Usage Company is copied from the source invoice onto the created invoices
- Product Name (SKU) (Product_Name__c) and Product (SKU) (the product lookup, plus SKU Id) are copied from the source invoice line onto the new lines
- Offset invoice: follows the weekly batch logic with amounts from the original lines; quantity and all amounts, including VAT_In_Original_Price__c and VAT_In_Dollars__c, are negated so the pair nets to zero VAT
- After the file is saved, the source invoices are marked SLO_Sellout_Reviewed__c = true
- A summary email is sent after the run, consistent with the weekly batch
- Existing N invoices with positive VAT are corrected by a one-time script
- Apex tests cover matching, invoice number, VAT negation, product and Usage Company copy, and the reviewed flag

**Related Elements:** LF_InvoiceLineItemProductSKU, TF_InvoiceLineItemSKUCode, AC_SLOSelloutFixOffsetVat, AC_SLOSelloutImportController, AC_SLOSelloutDailyAutoBatchTest

## Glossary

Sellout: Sales of products by a distributor to its own customers, reported back to Adama and turned into internal invoices. Sellout Report (SLO_Sellout_Report__c): header record for one import. Sellout Item (SLO_Sellout_Item__c): one line of a report (date, product EAN, quantity, customer name). Apply Sellout: the process that matches items to accounts and creates Invoice__c and Invoice_Line_Item__c records. Auto Accept: Apply Sellout mode that skips items needing a fix and proceeds without manual review. Need a fix: items whose data failed validation. Account decision: items whose customer name matched no account. Automatic Sellout flag (Account.SLO_Automatic_Sellout__c): opts an account into scheduled automated sellout. Reviewed flag (Invoice__c.SLO_Sellout_Reviewed__c): marks an invoice as already processed so it is not picked up again. EAN: European Article Number, the product barcode code. Batch Apex: asynchronous Salesforce processing of large data volumes in chunks. ContentVersion: the Salesforce file record used to store an uploaded or generated file. Usage Company: the user's country code, used to find country-specific settings. CSV Delimiter: the character separating columns in a CSV file, for example comma or semicolon.

## Existing Salesforce Elements

### SLO_Sellout_Report__c Object

The Sellout Report object stores header information for each sellout import, tracking the import status, date, and related account.

**Metadata ID:** 01I7z00000E8mNaEAJ

**Details:**
- Name: Auto-number field serving as Report Number
- SLO_Account__c (Lookup to Account): Links the report to the Account record
- SLO_Report_Date__c (Date, Required): Date of the sellout report
- SLO_Status__c (Picklist, Required): Import status (New, Completed, Error)
- SLO_Total_Items__c (Number): Count of imported sellout items
- SLO_Import_Date__c (DateTime): Timestamp when import completed
- SLO_Error_Message__c (Long Text Area): Error details if import fails

### SLO_Sellout_Item__c Object

The Sellout Item object stores individual line items from the imported Excel file, with fields for product, quantity, customer, and processing status.

**Metadata ID:** 01I7z00000E8mNZEAZ

**Details:**
- Name: Auto-number field serving as Item Number
- SLO_Sellout_Report__c (Lookup to SLO_Sellout_Report__c): Links item to parent report
- SLO_Item_Date__c (Date, Required): Date of the sellout transaction
- SLO_Product_Code_EAN__c (Text, Required): Product identifier (EAN code)
- SLO_Quantity__c (Number, Required): Quantity sold
- SLO_Customer_Account_Name__c (Text, Required): Name of the customer account
- SLO_Processing_Status__c (Picklist): Status of downstream processing
- SLO_Processing_Notes__c (Long Text Area): Notes from processing operations
- SLO_Matched_Account__c (Lookup to Account): Matched account record for the customer
- SLO_Invoice_Line_Item__c (Lookup to Invoice_Line_Item__c): Related invoice line item after processing

### Invoice__c Object

The Invoice object stores invoice header information for sellout-generated invoices.

**Metadata ID:** 01Ij0000001NAv5EAG

**Details:**
- Name: Invoice Number (text field)
- Account_Name__c (Lookup to Account, Required): The account for which the invoice is created
- Invoice_Date__c (Date): Date of the invoice
- Status__c (Text): Invoice status
- Delivered_VN__c (Checkbox, Required): Delivery status flag
- Manual_Creation__c (Checkbox, Required): Flag indicating if invoice was manually created
- Valid__c (Checkbox, Required): Validation flag for the invoice

### Invoice_Line_Item__c Object

The Invoice Line Item object stores individual line items for invoices.

**Metadata ID:** 01Ij0000001NAv4EAG

**Details:**
- Name: Invoice Line Item Number (text field)
- Invoice_Number__c (Lookup to Invoice__c, Required): The parent invoice
- Product_Name__c (Long Text Area): Product name or SKU
- Quantity__c (Number): Quantity of the product
- Valid__c (Checkbox, Required): Validation flag for the line item
