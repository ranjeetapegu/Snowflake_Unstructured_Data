-- =====================================================================
-- AI_PARSE_DOCUMENT Demo
-- File:  AI_PARSE_Demo_Quarterly_Report.pdf  (3 pages, synthetic data)
--   Page 1: headings, paragraphs, bullet list
--   Page 2: table + bar chart (drawn shapes)
--   Page 3: two-column text + signature
-- Stage: DEMO_DB.UNSTRUCTURE_DATA.AI_PARSE_DEMO
-- Billing: per page. OCR 0.68 / LAYOUT 3.66 / AGENTIC 8.18 AI credits per 1,000 pages.
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE DEMO_WH;
USE SCHEMA DEMO_DB.UNSTRUCTURE_DATA;

-- Already uploaded. To re-upload:
-- PUT 'file:///Users/rpegu/Documents/SE Customer Work/Vayner/document_parsing/sample_docs/AI_PARSE_Demo_Quarterly_Report.pdf'
--     @AI_PARSE_DEMO AUTO_COMPRESS = FALSE OVERWRITE = TRUE;
-- ALTER STAGE AI_PARSE_DEMO REFRESH;

SELECT relative_path, size FROM DIRECTORY(@AI_PARSE_DEMO);


-- 1. OCR mode (default): plain text, fastest and cheapest. No structure.
SELECT AI_PARSE_DOCUMENT(
  TO_FILE('@AI_PARSE_DEMO', 'AI_PARSE_Demo_Quarterly_Report.pdf'),
  {'mode': 'OCR'}
):content::STRING AS ocr_text;


-- 2. LAYOUT mode: Markdown with headings, bullets and tables preserved.
SELECT AI_PARSE_DOCUMENT(
  TO_FILE('@AI_PARSE_DEMO', 'AI_PARSE_Demo_Quarterly_Report.pdf'),
  {'mode': 'LAYOUT'}
):content::STRING AS layout_markdown;
-- Compare with query 1: look at how the page 2 regional table comes back.


-- 3. One row per page (page_split). Result has a pages array.
SELECT
  p.value:index::INT       AS page_no,
  p.value:content::STRING  AS page_markdown
FROM (
  SELECT AI_PARSE_DOCUMENT(
    TO_FILE('@AI_PARSE_DEMO', 'AI_PARSE_Demo_Quarterly_Report.pdf'),
    {'mode': 'LAYOUT', 'page_split': TRUE}
  ) AS r
), LATERAL FLATTEN(input => r:pages) p
ORDER BY page_no;


-- 4. Metadata: page count (this is what you are billed on).
SELECT AI_PARSE_DOCUMENT(
  TO_FILE('@AI_PARSE_DEMO', 'AI_PARSE_Demo_Quarterly_Report.pdf'),
  {'mode': 'LAYOUT'}
):metadata AS meta;


-- 5. Parse only the pages you need (page 2 only), so you pay for 1 page.
SELECT AI_PARSE_DOCUMENT(
  FL_FILTER_PAGES(
    TO_FILE('@AI_PARSE_DEMO', 'AI_PARSE_Demo_Quarterly_Report.pdf'),
    [{'start': 1, 'end': 2}]),
  {'mode': 'LAYOUT'}
):content::STRING AS page2_only;


-- 6. Persist the result so you parse once and reuse it.
CREATE OR REPLACE TABLE PARSED_REPORT AS
SELECT
  'AI_PARSE_Demo_Quarterly_Report.pdf' AS file_name,
  r:content::STRING                    AS markdown_text,
  r:metadata:pageCount::INT            AS page_count,
  CURRENT_TIMESTAMP()                  AS parsed_at
FROM (
  SELECT AI_PARSE_DOCUMENT(
    TO_FILE('@AI_PARSE_DEMO', 'AI_PARSE_Demo_Quarterly_Report.pdf'),
    {'mode': 'LAYOUT'}) AS r
);

SELECT * FROM PARSED_REPORT;


-- 7. Next step: feed the parsed text to other functions.
-- 7a. Ask AI_EXTRACT questions on the parsed TEXT (text input, no page tokens):
SELECT AI_EXTRACT(
  text => markdown_text,
  responseFormat => {
    'q3_revenue':       'Total Q3 2026 revenue in millions of dollars, number only.',
    'gross_margin':     'Gross margin percentage for Q3.',
    'best_region':      'Which region had the highest growth?',
    'q4_guidance':      'Q4 revenue guidance range.',
    'approved_by':      'Who approved this report?'
  }
):response::STRING AS answers
FROM PARSED_REPORT;

-- 7b. Summarize with AI_COMPLETE:
SELECT AI_COMPLETE(
  'claude-sonnet-4-5',
  'Summarize this report in 3 bullet points:\n\n' || markdown_text
) AS summary
FROM PARSED_REPORT;


-- 8. Things to point out in the demo:
--   * OCR returns text only; LAYOUT keeps headings, bullets and the table.
--   * The bar chart is not turned into data in either mode; to read a chart use
--     AI_COMPLETE with the page as an image, or AI_PARSE_DOCUMENT AGENTIC (preview).
--   * Page 3's two columns are read in the correct order in LAYOUT mode.
