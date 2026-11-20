-- =====================================================================
-- AI_EXTRACT Demo: Table, Form and Contract
-- 3-page PDF: page 1 = invoice table, page 2 = filled form, page 3 = contract
-- Stage: DEMO_DB.UNSTRUCTURE_DATA.AI_EXTRACT_DEMO
-- File:  AI_EXTRACT_Demo_Table_Form_Contract.pdf
-- All data is fictional / synthetic.
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE DEMO_WH;
USE SCHEMA DEMO_DB.UNSTRUCTURE_DATA;

-- =====================================================================
-- SETUP (run once)
-- =====================================================================

-- 1. Create the stage
CREATE STAGE IF NOT EXISTS AI_EXTRACT_DEMO
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

-- 2. Upload the PDF (run from Cortex Code, SnowSQL or Snow CLI)
PUT 'file:///Users/rpegu/Documents/document_parsing/sample_docs/AI_EXTRACT_Demo_Table_Form_Contract.pdf'
    @AI_EXTRACT_DEMO AUTO_COMPRESS = FALSE OVERWRITE = TRUE;

-- 3. Register in directory table
ALTER STAGE AI_EXTRACT_DEMO REFRESH;

-- Verify the file is there
SELECT relative_path, size, last_modified FROM DIRECTORY(@AI_EXTRACT_DEMO);


-- =====================================================================
-- DEMO 1: ENTITY EXTRACTION — Invoice fields (page 1)
--         Shows: plain-English questions, typed answers, confidence scores
-- =====================================================================

SELECT AI_EXTRACT(
  file => FL_FILTER_PAGES(
    TO_FILE('@AI_EXTRACT_DEMO', 'AI_EXTRACT_Demo_Table_Form_Contract.pdf'),
    [{'end': 1}]                                    -- page 1 only (0-based, end exclusive)
  ),
  responseFormat => {
    'invoice_number': 'What is the invoice number? NOT the PO number.',
    'invoice_date':   'Invoice date in YYYY-MM-DD format.',
    'due_date':       'Due date in YYYY-MM-DD format.',
    'po_number':      'Purchase order number.',
    'vendor':         'Company that issued the invoice.',
    'bill_to':        'Company the invoice is billed to.',
    'subtotal':       'Subtotal amount before tax, number only without dollar sign.',
    'tax':            'Sales tax amount, number only.',
    'total_due':      'Total amount due, number only without dollar sign.',
    'payment_terms':  'Payment terms.'
  },
  scores => TRUE
)::STRING AS invoice_entities;

-- Expected:
--   invoice_number = INV-2026-0457  (score ~0.98)
--   invoice_date   = 2026-10-14     (score ~0.97)
--   po_number      = PO-77821       (score ~0.97)
--   vendor         = Northwind Office Supply Co.
--   bill_to        = Acme Beverage Co.
--   subtotal       = 1568.50
--   tax            = 94.11
--   total_due      = 1707.61        (score ~0.96)
--   payment_terms  = Net 30


-- =====================================================================
-- DEMO 2: TABLE EXTRACTION — Invoice line items (page 1)
--         Shows: JSON schema with column_ordering, array columns, table score
-- =====================================================================

SELECT AI_EXTRACT(
  file => FL_FILTER_PAGES(
    TO_FILE('@AI_EXTRACT_DEMO', 'AI_EXTRACT_Demo_Table_Form_Contract.pdf'),
    [{'end': 1}]
  ),
  responseFormat => {
    'schema': {
      'type': 'object',
      'properties': {
        'line_items': {
          'type': 'object',
          'description': 'Invoice line items table. Exclude subtotal, tax, shipping and total rows.',
          'column_ordering': ['item_code', 'description', 'qty', 'unit_price', 'amount'],
          'properties': {
            'item_code':    {'type': 'array', 'description': 'Item Code'},
            'description':  {'type': 'array', 'description': 'Description'},
            'qty':          {'type': 'array', 'description': 'Qty'},
            'unit_price':   {'type': 'array', 'description': 'Unit Price'},
            'amount':       {'type': 'array', 'description': 'Amount'}
          }
        }
      }
    }
  },
  scores => TRUE
)::STRING AS invoice_table;

-- Expected: 5 line items (PPR-A4-500 through PEN-BLK-12), table score ~0.97

-- Flatten the table into rows:
WITH raw AS (
  SELECT PARSE_JSON(AI_EXTRACT(
    file => FL_FILTER_PAGES(
      TO_FILE('@AI_EXTRACT_DEMO', 'AI_EXTRACT_Demo_Table_Form_Contract.pdf'), [{'end': 1}]),
    responseFormat => {
      'schema': {'type': 'object', 'properties': {
        'line_items': {'type': 'object', 'description': 'Invoice line items, excluding totals',
          'column_ordering': ['item_code', 'description', 'qty', 'unit_price', 'amount'],
          'properties': {
            'item_code': {'type': 'array', 'description': 'Item Code'},
            'description': {'type': 'array', 'description': 'Description'},
            'qty': {'type': 'array', 'description': 'Qty'},
            'unit_price': {'type': 'array', 'description': 'Unit Price'},
            'amount': {'type': 'array', 'description': 'Amount'}
          }}}}
  }):response:line_items AS t)
SELECT
  i.index + 1                           AS line,
  t:item_code[i.index]::STRING          AS item_code,
  t:description[i.index]::STRING        AS description,
  t:qty[i.index]::STRING                AS qty,
  t:unit_price[i.index]::STRING         AS unit_price,
  t:amount[i.index]::STRING             AS amount
FROM raw, LATERAL FLATTEN(input => t:item_code) i;


-- =====================================================================
-- DEMO 3: FORM EXTRACTION — Vendor registration form (page 2)
--         Shows: checkboxes, filled fields, signature, all as structured data
-- =====================================================================

SELECT AI_EXTRACT(
  file => FL_FILTER_PAGES(
    TO_FILE('@AI_EXTRACT_DEMO', 'AI_EXTRACT_Demo_Table_Form_Contract.pdf'),
    [{'start': 1, 'end': 2}]                       -- page 2 only
  ),
  responseFormat => {
    'company_name':       'Legal company name on the form.',
    'tax_id':             'Tax ID or EIN.',
    'address':            'Full street address, city, state and ZIP.',
    'primary_contact':    'Primary contact name.',
    'contact_email':      'Contact email address.',
    'business_type':      'Which business type checkbox is checked? (Sole proprietor, Partnership, LLC, or Corporation)',
    'services_provided':  'List every service checkbox that is checked.',
    'insurance_attached': 'Is the certificate of insurance attached? Yes or No.',
    'minority_owned':     'Is this a minority- or women-owned business? Yes or No.',
    'payment_method':     'Which payment method checkbox is checked?',
    'signature_name':     'Name in the signature.',
    'date_signed':        'Date signed in YYYY-MM-DD format.'
  },
  scores => TRUE
)::STRING AS form_fields;

-- Expected:
--   company_name       = Brightline Studios LLC    (score ~0.97)
--   tax_id             = 84-1932076                (score ~0.95)
--   business_type      = LLC                       (score ~0.97)
--   services_provided  = Video production, Photography, Event staffing  (score ~0.95)
--   insurance_attached = Yes                       (score ~0.96)
--   minority_owned     = No                        (score ~0.96)
--   payment_method     = ACH                       (score ~0.96)
--   signature_name     = Dana Whitfield            (score ~0.95)
--   date_signed        = 2026-09-22


-- =====================================================================
-- DEMO 4: CONTRACT TEXT EXTRACTION — Services agreement (page 3)
--         Shows: clause-by-clause fields, citations (page + bounding box)
--         Note: citation => TRUE requires cross-region inference enabled
-- =====================================================================

SELECT AI_EXTRACT(
  file => FL_FILTER_PAGES(
    TO_FILE('@AI_EXTRACT_DEMO', 'AI_EXTRACT_Demo_Table_Form_Contract.pdf'),
    [{'start': 2}]                                  -- page 3 only
  ),
  responseFormat => {
    'agreement_number':         'Agreement number.',
    'effective_date':           'Effective date in YYYY-MM-DD.',
    'client':                   'Full legal name of the client.',
    'provider':                 'Full legal name of the provider.',
    'deliverables':             'What deliverables will the provider produce?',
    'fixed_fee':                'Total fixed fee in USD, number only.',
    'payment_split':            'How is the fee split (e.g. 50/50)?',
    'end_date':                 'End date of the agreement in YYYY-MM-DD.',
    'termination_notice':       'Notice period for termination for convenience.',
    'confidentiality_survival': 'How long do confidentiality obligations last after the agreement ends?',
    'liability_cap':            'Limitation of liability.',
    'governing_law':            'Governing law.'
  },
  scores => TRUE,
  citation => TRUE                                  -- returns page + bounding box per field
)::STRING AS contract_fields;

-- Expected:
--   agreement_number         = SA-2026-0193         (score ~0.97)
--   effective_date           = 2026-09-30           (score ~0.95)
--   client / provider        = Acme Beverage Co. / Brightline Studios LLC
--   deliverables             = one 60-second brand video and twelve still photographs
--   fixed_fee                = 38500                (score ~0.96)
--   payment_split            = 50/50
--   end_date                 = 2027-01-31
--   confidentiality_survival = three (3) years
--   governing_law            = laws of the State of New York
--
-- The citations object contains page numbers and bounding boxes for each field,
-- e.g. "effective_date": [{"page": 3, "upper_left": [60.3, 15.9], "lower_right": [75.1, 17.5]}]
-- These locate the source text on the page as percentages of page width and height.


-- =====================================================================
-- SUMMARY: What each demo shows
-- =====================================================================
-- Demo 1: Entity extraction    — plain-English questions, typed answers, scores
-- Demo 2: Table extraction     — JSON schema, column_ordering, flatten to rows
-- Demo 3: Form extraction      — checkboxes, filled fields, handwritten signature
-- Demo 4: Contract extraction  — clause-level fields, citations with page + bounding box
--
-- All four use FL_FILTER_PAGES so each demo reads only the relevant page.
-- scores => TRUE is free. citation => TRUE (preview) is free, needs cross-region inference.
