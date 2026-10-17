---
name: soda-fountain
description: Use when answering questions about US city, county, state or federal open data held on Socrata portals (311 requests, permits, payrolls, wildfires, business registrations, CDC data), or whenever the soda-fountain MCP tools (list_domains, search_datasets, get_dataset_schema, query_dataset, validate_soql, find_correlation_keys) are available. Covers the tool order, SoQL pitfalls, cross-dataset joins, and what to do on errors or retired datasets.
---

# soda-fountain: Socrata open data

The `soda-fountain` MCP server (npm `soda-fountain-mcp`) reads Socrata open data portals. Installed from this plugin, the tools are named `mcp__plugin_soda-fountain_soda-fountain__<tool>` (a manual `claude mcp add soda-fountain` install gives `mcp__soda-fountain__<tool>`). They may be deferred, so load them with ToolSearch first. Never invent numbers: every figure in an answer must come from a `query_dataset` result.

## Tools

| Tool | Use it to |
|---|---|
| `list_domains` | List the built-in portals (about 20, such as data.cityofchicago.org, data.lacity.org, data.oregon.gov, data.wa.gov, data.ny.gov, data.texas.gov, data.cdc.gov) with approximate dataset counts. |
| `get_domain_categories` | List a portal's categories and popular tags. |
| `search_datasets` | Find datasets on one portal by `query` and/or `category`. At least one is required. The category match is case-sensitive, so copy it from `get_domain_categories`. |
| `get_dataset_schema` | Get column field names, types and 3 sample rows for one dataset. |
| `query_dataset` | Run SoQL: `select`, `where`, `group`, `having`, `order`, `limit`, `offset`, `search`, `format`. |
| `validate_soql` | Check clause syntax (no network). Takes `select`, `where`, `order`, `group`, `having`, `limit`, `offset`, `q`. |
| `find_correlation_keys` | Look up columns that line up across datasets (see below). |

`domain` is the bare hostname (`data.oregon.gov`). `datasetId` must be a 4x4 ID like `tckn-sxa6`.

## Workflow

1. Pick the portal. Use `list_domains` if the user did not name one. Portals not on the list may still work if you pass the hostname, but the list is what the server knows.
2. `get_domain_categories`, then `search_datasets` with a short keyword. Read the names and descriptions and pick the best match. Search results are re-ranked by column relevance and the keyword is expanded (for example "fire" also tries "wildfire", "burn", "acre"), so try one or two plain words rather than a sentence.
3. `get_dataset_schema` on the chosen ID. Use the exact `fieldName` values it returns. Read the sample rows to see how values are written (case, codes, date format).
4. Build the query. Run `validate_soql` if you are unsure; `query_dataset` also validates against the schema before it calls the API.
5. `query_dataset`. Use `format: "markdown"` when you want a table to show the user, and `json` (the default) when you need the numbers. JSON replies include column types, null counts, numeric summaries and a truncation warning.
6. State the dataset, portal, filters and any caveat (nulls, truncation, date range) in the answer.

## SoQL rules and pitfalls

- SoQL is not SQL. No `JOIN`, no `FROM`, no `DISTINCT` in `select` (group instead), no subqueries, no `ILIKE`, no backtick or double-quoted identifiers. Strings use single quotes. The server flags each of these.
- Test nulls with `IS NULL` / `IS NOT NULL`, never `= NULL`.
- Any aggregate (`count(*)`, `sum(x)`, `avg(x)`, `min`, `max`) mixed with plain columns needs `group`. `having` needs `group`. Alias aggregates: `count(*) AS total`, then `order: "total DESC"`.
- `where` operators: `= != > < >= <=`, `AND OR NOT`, `LIKE`, `IN(...)`, `BETWEEN a AND b`, `starts_with(col,'x')`. Case-insensitive match: `upper(col) LIKE '%COFFEE%'`.
- Text values are often stored uppercase (`city='PORTLAND'`). Check the sample rows first.
- Number columns come back as strings in JSON (`"123.45"`), so convert before doing arithmetic. Numeric filters still compare as numbers.
- Dates are `calendar_date` and look like `2024-01-15T00:00:00.000`. Filter with `date_col >= '2024-01-01T00:00:00'`. Use `date_extract_y(col)`, `date_extract_m(col)`, `date_trunc_ym(col)` for year or month trends. Some datasets store a year as a text column (Oregon fire data's `fireyear` is text), so compare it as `'2020'`, not `2020`.
- `search` (full-text) uses only the first word you give it, because multi-word `$q` returns too few rows. For several terms use `where` with `LIKE`.
- Paging: `limit` is 1 to 1000 (default 100) and `offset` starts at 0. Add an `order` (for example `:id` or a date column) so pages do not overlap. When a filtered query returns exactly `limit` rows, the reply warns it may be truncated. Raise `limit`, page with `offset`, or aggregate in SoQL instead of downloading rows.
- Prefer aggregating on the server (`count(*)`, `group`) over fetching many rows. For "how many", use `select: "count(*)"` with the filter.
- Location columns are `point` or `location` types. Geo functions include `within_circle(col, lat, lon, meters)` and `within_box(...)`.

## Joining across datasets

SoQL cannot join, so you query each dataset separately and combine the results yourself. `find_correlation_keys` is a static index (shipped with the server, not live) of shared keys: `county`, `city`, `zip`, `lat_long`, `fiscal_year`, `calendar_year`, `date`, `business_name`, `entity_type`, `naics`, `agency`, `expenditure_category`, `complaint_status`, `complaint_category`. It covers only six state portals: Oregon, Washington, New York, Connecticut, Texas, New Jersey.

- No arguments lists all keys. `crossStateOnly: true` keeps keys usable across states (zip, naics, calendar_year, fiscal_year, date, lat_long, entity_type).
- `key: "county"` gives every indexed dataset with the exact column name and type. `datasetId` gives the keys for one dataset, and with `key` too it lists the other datasets that share it. `domain` filters to one portal.
- Entries list `normalizations` (for example `upper()`, trim whitespace, strip " County"). Apply them before matching values. Column names differ per dataset (`county`, `county_name`, `county_code`), and `columnNote` warns about oddities such as codes instead of names.
- The index entry gives the column; still confirm with `get_dataset_schema`, because portals change.

## Errors, rate limits, tokens

Failures come back as `isError` results with `code`, `message`, `recoverable` and `suggestion`. `recoverable: true` means fix the input or wait, then retry. `recoverable: false` means stop and tell the user.

| Code | Meaning | Do this |
|---|---|---|
| `QUERY_VALIDATION_FAILED` | Pre-flight check found wrong columns or SQL habits | Apply the `suggestion` (fuzzy column match) and retry. |
| `UNKNOWN_COLUMN` | Column not in the schema | Use a `fieldName` from `get_dataset_schema`. |
| `BAD_QUERY` | Socrata returned 400 | Read `diagnostics`, fix the clause. |
| `PROCESSING` | Socrata returned 202, still working | Wait a few seconds and retry the same call. |
| `RATE_LIMITED` | HTTP 429 | Wait, then retry; slow down. Set an app token for higher limits. |
| `DATASET_NOT_FOUND` | HTTP 404 | Not recoverable by retrying; see below. |
| `ACCESS_DENIED` | HTTP 403, private dataset | Pick a different dataset. |
| `NETWORK_ERROR` / `SERVER_ERROR` | Could not reach the portal | Retry shortly. A request that exceeds 30 seconds is reported as `NETWORK_ERROR` ("AbortError") even when the network is fine, so retry once and narrow the query (filter by date, aggregate) if it repeats. |

An empty result carries a `notice` telling you not to make up data. Report "no rows" and check your filter (case, spelling, date format) before concluding there is none.

The server reads the optional environment variable `SOCRATA_API_KEY` (a free Socrata app token from dev.socrata.com) and sends it as `X-App-Token`. Without it everything works, but the shared per-IP pool throttles sooner. The plugin passes it through from your shell: `export SOCRATA_API_KEY=...` before starting Claude Code.

## Retired datasets

Portals retire and replace datasets. Oregon's wildfire dataset `fbwv-q84y` was retired in 2026; the current one in the server's index is `fa7z-shhx` (ODF Fire Occurrence 2000-2025). The docs and examples in the server repo may still show old IDs. A `DATASET_NOT_FOUND` on an ID you remembered means the ID is dead: do not retry it. Run `search_datasets` on the same portal for the topic, take the new ID, and re-read its schema, because column names and codes can change between versions. Say in the answer that you used the replacement. If the user supplied the ID, tell them it appears retired.
