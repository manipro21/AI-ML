# Multi-Region Sales Audit

You are a financial analyst. You have been given four regional sales transaction files:

- `input_artifacts/north.csv`
- `input_artifacts/south.csv`
- `input_artifacts/east.csv`
- `input_artifacts/west.csv`

Each file contains columns: `invoice_id`, `rep_name`, `amount`, `type`

Where `type` is either `SALE` or `REFUND`.

## Your Tasks

1. **Calculate net sales per region** (sum of all amounts per file)
2. **Detect duplicate invoice IDs** that appear in more than one region file
3. **Detect suspicious refunds** where the absolute amount exceeds 5000
4. **Identify the top 3 sales reps** by total net sales across all regions
5. **Produce a final structured JSON report** with all findings

## Output Format

Return your answer as a single JSON object with this exact structure:

```json
{
  "regional_net_sales": {
    "north": <number>,
    "south": <number>,
    "east": <number>,
    "west": <number>
  },
  "duplicate_invoice_ids": [<list of invoice_id strings>],
  "suspicious_refunds": [
    {"invoice_id": <string>, "rep_name": <string>, "amount": <number>, "region": <string>}
  ],
  "top_3_reps": [<rep_name_1>, <rep_name_2>, <rep_name_3>]
}
```

Be precise. Cross-check invoice IDs across all four files carefully.
