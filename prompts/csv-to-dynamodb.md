<!--
Task library entry: CSV -> DynamoDB single-table load. Two ways to use it —

  ./run-agent.sh --prompt prompts/csv-to-dynamodb.md    # this run only
  cp prompts/csv-to-dynamodb.md agent-prompt.md         # make it the default

No rebuild: boto3 is not in the image for the agent either, so the loader runs
under `uv run --with boto3`, like every other library this lab uses.

Two things it DOES need, neither of them a rebuild:
  - the table `sales-table`, with string PK and SK, plus a GSI named GSI1 over
    GSI1PK/GSI1SK if you want the region index to be queryable
  - dynamodb:BatchWriteItem and dynamodb:DescribeTable on that table for the
    MicroVM execution role (grant-permissions.sh does not add these)
Without the grant every run ends with AccessDeniedException and a report that
says so, which is the intended outcome rather than a silent half-load.

Same contract as every task: the input is in INPUT_DIR, every artifact goes in
OUTPUT_DIR. This one is different in one way worth knowing: its real output is
rows in DynamoDB, and OUTPUT_DIR carries the account of what happened.

The loader takes the CSV path as an argument rather than through a FILE_CSV
placeholder: the agent is handed a directory, so one script has to serve N
files, and a placeholder nobody passes would reach it as literal text.
-->

# CSV to DynamoDB load job

You are running headless inside a single-use Lambda MicroVM. This directory is
your workspace and nobody is watching the session — there is no one to ask, so
finish the job and leave the results in `{{OUTPUT_DIR}}/`.

## Your task

Load **every `.csv` file in `{{INPUT_DIR}}/`** into the DynamoDB table
`sales-table`, then leave **two kinds of artifact**:

1. **`{{OUTPUT_DIR}}/LOAD-REPORT.md`** — the account of the load, written in
   **{{LANGUAGE}}**.
2. **`{{OUTPUT_DIR}}/rejected/<file>.csv`** — one file per input that had rows
   you could not load, with the original columns plus a `_reason` column. Write
   nothing for an input whose every row loaded.

There are **{{INPUT_COUNT}} file(s)** in `{{INPUT_DIR}}/`:

{{INPUT_LIST}}

A file that is not a CSV is not an error: say so in the report and skip it.

## The columns the loader needs

Every row must carry these, spelled exactly like this:

`Row ID`, `Order ID`, `Order Date`, `Date Key`, `Customer ID`, `Customer`,
`Contact Name`, `Industry`, `Segment`, `Country`, `City`, `Region`,
`Subregion`, `Product`, `License`, `Sales`, `Quantity`, `Discount`, `Profit`

`Order Date` is `M/D/YYYY`. `Sales`, `Discount` and `Profit` are decimals,
`Row ID` and `Quantity` integers.

## The item design you are writing

One table, four item types, so that a customer and their orders sit in one
partition and an order and its lines sit in another:

| Item | PK | SK |
| --- | --- | --- |
| Customer profile | `CUSTOMER#<id>` | `PROFILE` |
| Order summary under its customer | `CUSTOMER#<id>` | `ORDER#<dateKey>#<orderId>` |
| Order header | `ORDER#<id>` | `HEADER` |
| Order line | `ORDER#<id>` | `LINE#<rowId padded to 6>` |

The order summary also carries `GSI1PK = REGION#<region>#<subregion>` and
`GSI1SK = <dateKey>#<orderId>`, which is what makes "orders in a region, by
date" a query instead of a scan.

## The loader

No Python libraries are installed in this VM and you are not root, so boto3
comes from `uv`, which is installed for exactly this. Save the script as
`extracted/load.py` and run it **once per CSV**, passing the path:

```bash
mkdir -p extracted output/rejected
uv run --with boto3 python extracted/load.py "{{INPUT_DIR}}/example.csv"
```

Start from this script. It is the design above, already correct about the two
things that are easy to get wrong — `Decimal(str(x))` because DynamoDB refuses
floats, and `batch_writer` because it batches, retries and drops duplicate
keys for you:

```python
import csv
import sys
import boto3
from datetime import datetime
from decimal import Decimal

TABLE = "sales-table"
table = boto3.resource("dynamodb").Table(TABLE)   # region comes from the environment

def d(x): return Decimal(str(x))

seen_customers = set()
seen_orders = set()

with table.batch_writer(overwrite_by_pkeys=["PK", "SK"]) as batch, \
     open(sys.argv[1], newline="", encoding="utf-8") as f:
    for r in csv.DictReader(f):
        cid, oid, dk = r["Customer ID"], r["Order ID"], r["Date Key"]
        iso = datetime.strptime(r["Order Date"], "%m/%d/%Y").date().isoformat()

        # Customer, once
        if cid not in seen_customers:
            seen_customers.add(cid)
            batch.put_item(Item={
                "PK": f"CUSTOMER#{cid}", "SK": "PROFILE", "Type": "Customer",
                "customerId": cid, "customerName": r["Customer"],
                "industry": r["Industry"], "segment": r["Segment"],
            })

        # Order, once: header plus the summary that lives under the customer
        if oid not in seen_orders:
            seen_orders.add(oid)
            common = {
                "orderId": oid, "customerId": cid, "customerName": r["Customer"],
                "orderDate": iso, "dateKey": dk, "contactName": r["Contact Name"],
                "country": r["Country"], "city": r["City"],
                "region": r["Region"], "subregion": r["Subregion"],
            }
            batch.put_item(Item={
                "PK": f"ORDER#{oid}", "SK": "HEADER", "Type": "Order", **common,
            })
            batch.put_item(Item={
                "PK": f"CUSTOMER#{cid}", "SK": f"ORDER#{dk}#{oid}",
                "Type": "OrderSummary", **common,
                "GSI1PK": f"REGION#{r['Region']}#{r['Subregion']}",
                "GSI1SK": f"{dk}#{oid}",
            })

        # Line
        batch.put_item(Item={
            "PK": f"ORDER#{oid}", "SK": f"LINE#{int(r['Row ID']):06d}",
            "Type": "OrderLine", "rowId": int(r["Row ID"]), "orderId": oid,
            "product": r["Product"], "license": r["License"],
            "sales": d(r["Sales"]), "quantity": int(r["Quantity"]),
            "discount": d(r["Discount"]), "profit": d(r["Profit"]),
        })
```

**You must change two things about it, and nothing else about the item shapes.**

1. **One bad row must not abort the file.** As written, a missing column, an
   unparseable date or a non-numeric `Sales` raises and the loader stops with
   the file half-written. Put the per-row work in a `try`, and on failure
   append the row and the exception message to a rejects list instead of
   re-raising. A loader that stops at row 900 of 5000 is worse than one that
   loads 4999 and tells you which row it refused.
2. **Count what you did.** Keep running totals per file: rows read, items
   written by type, rows rejected. The report is built from those counters, not
   from your memory of the run.

Keep intermediate files and any script you write in `extracted/` in the
workspace root — create it, and keep it out of `{{OUTPUT_DIR}}/`, which is for
finished artifacts only.

## Before you write a single item

In this order, because each step makes the next one meaningful:

1. **Check the table is reachable and is the shape you expect.** One
   `describe_table` tells you it exists, that `PK`/`SK` are its key schema, and
   whether `GSI1` is there. If that call fails with `AccessDeniedException` or
   `ResourceNotFoundException`, **stop**: write the report explaining exactly
   which call failed and what it needs, and do not attempt the load.
2. **Check each file's header** against the column list above. A file missing a
   required column is a rejected file, not a crash: report it, name the missing
   columns, and move on to the next file.
3. **Count the rows** in each file before loading, so the report can compare
   what went in against what the counters say came out.

## Rules that matter

- **Never invent a number.** Every figure in the report must come from a
  counter in your loader or from a call you made, not from an estimate.
- **Do not create, delete or alter the table**, and do not touch items that
  this input did not produce. Loading is the whole mandate.
- **Report problems instead of smoothing them over.** Duplicate `Row ID`s
  within a file, two different customer names for one `Customer ID`, dates that
  did not parse, negative quantities, empty `Order ID`s: these are findings.
  Name the file and the row.
- **A re-run must be safe.** These are `put_item` writes on deterministic keys,
  so loading the same CSV twice overwrites rather than duplicates — say so in
  the report, and say what it means for a partially loaded file.
- **Verify, do not assume.** After loading a file, read back at least one order
  you wrote: `query` on `PK = ORDER#<id>` and confirm the header and the line
  count match what you loaded. A write that returned no error is not evidence.

## Required shape of `LOAD-REPORT.md`

1. **`# Carga CSV a DynamoDB`** (or the equivalent heading in {{LANGUAGE}}) — a
   short paragraph: how many files, how many rows, how many items, into which
   table and region, and whether every file loaded.

2. **Load table** — one row per input file:

   | Archivo | Filas | Clientes | Pedidos | Líneas | Rechazadas | Estado |
   |---|---|---|---|---|---|---|
   | ventas.csv | 5000 | 48 | 912 | 5000 | 0 | Cargado |
   | notas.csv | — | — | — | — | — | Omitido (no es CSV) |

3. **`## Verificación`** — the read-back for each file: the order you queried,
   its header and how many `LINE#` items came back, next to how many your
   counters say you wrote. If they disagree, that is the most important
   sentence in the report.

4. **`## Calidad de los datos`** — every problem found, grouped by kind, each
   with the file and the row, and what it would break for someone querying this
   table later. If a file is clean, say so explicitly rather than omitting it.

5. **`## Rechazos`** — for each `rejected/<file>.csv`, how many rows and the
   reasons by frequency. If nothing was rejected, say so.

6. **`## Herramientas utilizadas`** — one line naming what you installed and
   what each was for, plus any install that failed.

Finish by listing what you left in `{{OUTPUT_DIR}}/` and stating the totals
written to `sales-table`, by item type.
