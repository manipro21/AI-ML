# Quality Gate PRD

Trainer sends Drive link → download ZIP → extract → static checks → execution log checks → LLM review → verdict.

---

## Static Checks (Layer 1)

### S-01 ZIP Package

| #   | File        | Check                                                    | PASS                                                                                                                                                                | FAIL         |
| --- | ----------- | -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| 1   | ZIP         | One root folder                                          | Exactly one                                                                                                                                                         | Zero or many |
| 2   | Folder name | Format: `<uuid>-SWARMBENCH-<coord_slug>-<domain>-<task>` | Matches regex                                                                                                                                                       | Broken       |
| 3   | Folder name | UUID = 32-char lowercase hex                             | `[0-9a-f]{32}`                                                                                                                                                      | Invalid      |
| 4   | Folder name | Coord slug valid                                         | `MAPREDUCE` `FANOUT` `SPECIALIST` `PIPELINE` `HIERARCHICAL` `DEBATE`                                                                                                | Other        |
| 5   | `task.toml` | `[task].name` == `swarmbench/<folder_name>`              | Match                                                                                                                                                               | Mismatch     |
| 6   | `task.toml` | Coord slug maps to `metadata.coordination_pattern`       | `map-reduce`→`MAPREDUCE`, `fan-out-synthesize`→`FANOUT`, `specialist-routing`→`SPECIALIST`, `pipeline`→`PIPELINE`, `hierarchical`→`HIERARCHICAL`, `debate`→`DEBATE` | Mismatch     |

### S-02 Required Files

| #   | File                                           | When        | FAIL if                                                                                                   |
| --- | ---------------------------------------------- | ----------- | --------------------------------------------------------------------------------------------------------- |
| 1   | `instruction.md`                               | Always      | Missing                                                                                                   |
| 2   | `task.toml`                                    | Always      | Missing                                                                                                   |
| 3   | `decomposition.yaml`                           | Always      | Missing                                                                                                   |
| 4   | `environment/Dockerfile`                       | Always      | Missing                                                                                                   |
| 5   | `tests/test.sh`                                | Always      | Missing                                                                                                   |
| 6   | `solution/solve.sh`                            | Always      | Missing                                                                                                   |
| 7   | `execution_logs/oracle/result.json`            | Always      | Missing                                                                                                   |
| 8   | `execution_logs/single-kimi-agent/result.json` | Always      | Missing                                                                                                   |
| 9   | `execution_logs/multi-kimi-agent/result.json`  | Always      | Missing                                                                                                   |
| 10  | `tests/judge.py`                               | `llm-judge` | Recommended but not enforced — trainer can use any script as long as `test.sh` calls it and writes reward |

### S-03 task.toml

**[task]**

| #   | Field         | Type | Rule                  | FAIL if            |
| --- | ------------- | ---- | --------------------- | ------------------ |
| 1   | `name`        | str  | `swarmbench/<folder>` | Missing / mismatch |
| 2   | `description` | str  | 10–500 chars          | Missing / empty    |

**[metadata] — all mandatory**

| #   | Field                               | Type | Valid                                                                                          | FAIL if                      |
| --- | ----------------------------------- | ---- | ---------------------------------------------------------------------------------------------- | ---------------------------- |
| 3   | `verifier_type`                     | str  | `llm-judge`, `executable`                                                                      | Missing / invalid            |
| 4   | `domain`                            | str  | `code-swe`, `knowledge-research`, `data-analysis`, `planning-operations`, `reasoning-math`     | Missing / invalid            |
| 5   | `coordination_pattern`              | str  | `map-reduce`, `fan-out-synthesize`, `specialist-routing`, `pipeline`, `hierarchical`, `debate` | Missing / invalid            |
| 6   | `human_solving_hours_estimate`      | int  | >= 10                                                                                          | Missing / not int / < 10     |
| 7   | `human_solving_hours_justification` | str  | Non-empty, has numbers                                                                         | Missing / empty / no numbers |
| 8   | `estimated_sub_agents`              | int  | >= 2                                                                                           | Missing / not int / < 2      |
| 9   | `input_token_estimate`              | int  | >= 1000                                                                                        | Missing / not int / < 1000   |
| 10  | `why_multi_agent`                   | str  | >= 50 chars                                                                                    | Missing / too short          |
| 11  | `reference_link`                    | str  | Valid URL or `"synthetic"`                                                                     | Missing / invalid            |

**[agent]** — `timeout_sec`: float 300–7200, default 3600. FAIL if out of range.

**[verifier]** — `timeout_sec`: float 60–1800, default 600. FAIL if hardcoded API keys present.

**[environment]** — `cpus`: int 1–8. `memory_mb`: int 1024–16384. `build_timeout_sec`: float 60–1800.

### S-04 decomposition.yaml

| #   | Check                                                                 | FAIL if                   |
| --- | --------------------------------------------------------------------- | ------------------------- |
| 1   | YAML parses                                                           | Parse error               |
| 2   | `sub_tasks` exists and is list                                        | Missing / wrong type      |
| 3   | Each sub-task has `id`, `description`, `depends_on`, `parallel_group` | Any field missing         |
| 4   | No duplicate `id`                                                     | Duplicate                 |
| 5   | All `depends_on` point to existing `id`                               | Dangling ref              |
| 6   | No cycles                                                             | Cycle in dependency graph |
| 7   | Count == `estimated_sub_agents`                                       | Mismatch                  |
| 8   | All descriptions non-empty                                            | Empty description         |

### S-05 Cross-File Checks

| #   | Files                    | Check                                           | FAIL if                          |
| --- | ------------------------ | ----------------------------------------------- | -------------------------------- |
| 1   | `environment/Dockerfile` | No `COPY tests/`, `COPY solution/`, `COPY . /`  | Tests/solution leaked into image |
| 2   | `tests/test.sh`          | Contains write to `reward.txt` or `reward.json` | No reward write found in script  |

> All context-dependent cross-file checks (oracle↔instruction alignment, input file path matching, output format validation, judge.py arg validation) are handled by the LLM reviewer in Layer 3 (QD-02, QD-08) — these require understanding file content and cannot be reliably scripted.

### S-06 Leakage & Reward-Hack Scan

| #   | Files                    | What                              | FAIL if                                | Severity  |
| --- | ------------------------ | --------------------------------- | -------------------------------------- | --------- |
| 1   | `environment/Dockerfile` | No tests/solution copy            | COPY found                             | P0 REJECT |
| 2   | `environment/Dockerfile` | Git depth restricted (executable) | Full history exposed, no `rm -rf .git` | P0 REJECT |

---

## Execution Log Checks (Layer 2)

**File:** `execution_logs/{mode}/result.json` — mean at `stats.evals.<first_key>.metrics[0].mean`

| #   | Mode         | Folder               | Trials | Errors | Mean reward                       | FAIL if             |
| --- | ------------ | -------------------- | ------ | ------ | --------------------------------- | ------------------- |
| 1   | Oracle       | `oracle/`            | == 1   | == 0   | == 1.0                            | Any mismatch        |
| 2   | Single-agent | `single-kimi-agent/` | >= 1   | == 0   | —                                 | Missing, errors > 0 |
| 3   | Multi-agent  | `multi-kimi-agent/`  | >= 1   | == 0   | —                                 | Missing, errors > 0 |
| 4   | Gap          | —                    | —      | —      | `multi_mean - single_mean > 0.38` | Gap <= 0.38         |

**Any failure → REJECT.**

### E-02 Per-Trial Artifact Checks

For every trial directory inside `execution_logs/{mode}/`, verify the agent and verifier produced expected outputs:

| #   | Artifact                                        | Check                 | FAIL if                                                                                                                                                             | Severity |
| --- | ----------------------------------------------- | --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| 1   | `agent/` directory                              | Exists and non-empty  | Missing or empty — agent didn't run                                                                                                                                 | REJECT   |
| 2   | `verifier/` directory                           | Exists and non-empty  | Missing — verification didn't run                                                                                                                                   | REJECT   |
| 3   | `verifier/reward.txt` or `verifier/reward.json` | At least one exists   | Neither exists — `test.sh` crashed before writing reward. Read `verifier/test-stdout.txt` for the error. This is always a trainer error in `test.sh` or `judge.py`. | REJECT   |
| 4   | `verifier/test-stdout.txt`                      | Exists                | Missing — test.sh never ran at all. Likely Dockerfile issue (missing package, build failure).                                                                       | REJECT   |
| 5   | `agent/judge_justification.txt`                 | Exists                | Missing — judge crashed before writing justification. Check `verifier/test-stdout.txt`.                                                                             | WARN     |
| 7   | `agent/trajectory.json`                         | Exists                | Missing — agent wire output wasn't parsed. Non-blocking but limits debugging.                                                                                       | WARN     |
| 8   | `result.json`                                   | Exists at trial level | Missing — trial didn't complete at all                                                                                                                              | REJECT   |

**Common failure patterns:**

`RewardFileNotFoundError` in result.json → Row 3 failed. `test.sh` ran but crashed. Causes:

- `judge.py` syntax error (check `verifier/test-stdout.txt`)
- `oracle.json` missing from `tests/`
- `openai` not installed in Dockerfile (`pip install openai` missing)
- `FIREWORKS_API_KEY` not passed via `--ve` flag

`agent/output.json` missing → Row 5 failed. Agent ran but didn't write output. Causes:

- `instruction.md` has wrong output path (not `/logs/agent/output.json`)
- Agent timed out before writing
- Agent wrote to `/workspace/output.json` instead of `/logs/agent/output.json`

`reward = 0.0` on all trials but no errors → Not a structural failure. The agent genuinely scored 0. Check `agent/judge_justification.txt` to understand why.

---

## LLM Quality Dimensions (Layer 3)

Runs only if Layers 1–2 pass. Each QD returns `pass | fail | not_applicable`.

---

### BLOCKING QDs (any fail → REJECT)

---

#### QD-01: Instruction Completeness

The instruction is the single artifact the agent receives — it never sees the oracle, the verifier, or the decomposition. Every constraint the verifier will enforce must be stated here, every input file path must be explicit, and the working directory must be named. If the instruction is underspecified, the agent will make reasonable assumptions that happen to diverge from the verifier's expectations, producing a false failure where a correct approach scores zero. If the instruction is overspecified with contradictory requirements, or is obviously LLM-generated boilerplate, the benchmark loses credibility. This QD reads the instruction end-to-end and checks that a domain expert given only this document could produce the exact output the verifier expects — no guessing, no ambiguity, no missing pieces.

**Read:** the task instruction

| #   | Check                                                 | PASS                                                                                                                                                                                                      | FAIL                                                                                                                             |
| --- | ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Authorship                                            | Human-written, professional tone                                                                                                                                                                          | LLM-generated, template-like, placeholder text                                                                                   |
| 2   | Input file paths `[Harbor: file_reference_mentioned]` | Every file the agent needs is named with full path. If the agent must produce files for tests to check, those filenames should be explicitly stated in instruction.md. PASS if mentioned; FAIL otherwise. | Vague references ("analyze these files", "the data"), or output filenames not mentioned                                          |
| 3   | Working directory                                     | Explicitly stated                                                                                                                                                                                         | Not mentioned                                                                                                                    |
| 4   | Output requirements                                   | Clear deliverables with success criteria                                                                                                                                                                  | Ambiguous what "done" means                                                                                                      |
| 5   | Domain grounding                                      | Enough context for an expert to execute without guessing                                                                                                                                                  | Missing domain constraints, unstated assumptions                                                                                 |
| 6   | Completeness                                          | Every field the verifier checks is mentioned in instruction                                                                                                                                               | Instruction omits requirements that the verifier enforces                                                                        |
| 7   | No typos `[Harbor: typos]`                            | Whether there are any typos. Look very closely at file and variable names, because these can be hard to catch. PASS if none found; FAIL if present.                                                       | A typo in a path or identifier causes the agent to write to the wrong location or call the wrong function — silent false failure |

---

#### QD-02: Instruction–Verifier Alignment

The instruction tells the agent what to do; the verifier decides if the agent did it. If these two disagree, the benchmark is broken in one of two dangerous ways. Either the verifier checks something the instruction never mentioned — a hidden spec that punishes correct agents — or the verifier is weaker than the instruction implies, letting incorrect solutions slip through with high scores. This QD cross-reads the instruction against every check the verifier performs and confirms there is exactly one clean success contract: what the instruction promises is what the verifier measures, nothing more, nothing less. A single misaligned function name, file path, or output key is enough to silently invalidate every trial.

**Read:** the task instruction, every file in the test/verification directory, and the ground-truth answer if present

| #   | Check                                                                             | PASS                                                                                                                                                                                                                                                                                                                                                                                       | FAIL                                                                                                                     |
| --- | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------ |
| 1   | Checked identifiers exist in instruction `[Harbor: behavior_in_task_description]` | Every function, file, command, or output key the verifier checks is named in the instruction. All behavior that tests verify should be clearly described in instruction.md. PASS if the instruction explicitly covers what tests check (including filenames, schema, exact commands or interfaces when relevant). FAIL if tests require details not specified or only implied by examples. | Verifier tests something the instruction never mentions                                                                  |
| 2   | Checked paths exist in instruction                                                | Every file path the verifier reads or validates is stated in the instruction                                                                                                                                                                                                                                                                                                               | Verifier references a path the agent was never told about                                                                |
| 3   | Every assertion traces to a requirement                                           | Each verifier check maps to a clearly stated instruction requirement                                                                                                                                                                                                                                                                                                                       | Verifier enforces behavior the instruction never asked for                                                               |
| 4   | Edge cases are stated or obvious                                                  | Edge conditions the verifier tests are either explicitly listed or logically implied by the instruction                                                                                                                                                                                                                                                                                    | Verifier tests a surprising edge case the agent could not anticipate                                                     |
| 5   | No hidden specs                                                                   | An agent that perfectly follows the instruction will pass all verifier checks                                                                                                                                                                                                                                                                                                              | A correct solution fails because the verifier enforces undisclosed constraints                                           |
| 6   | All instruction behavior is tested `[Harbor: behavior_in_tests]`                  | All behavior described in instruction.md should be tested. PASS if tests cover the specified behavior and outputs. FAIL if important required behavior is not tested.                                                                                                                                                                                                                      | Instruction requires something but no verifier check exists for it                                                       |
| 7   | Output structure alignment `[Harbor: structured_data_schema]`                     | If the task expects structured output (APIs, JSON, CSV, DB schemas), the exact schema must be documented in instruction.md or a clearly referenced spec file. PASS if schema is explicit; FAIL if only examples are given without marking them as normative.                                                                                                                               | Structural mismatch between what the instruction shows and what the verifier expects                                     |
| 8   | Test structure is readable `[Harbor: informative_test_structure]`                 | Tests should be readable and clearly organized (sections/comments naming what is being checked). PASS if the structure is clear and maintainable; FAIL otherwise.                                                                                                                                                                                                                          | Verification logic is opaque, uncommented, or so tangled that it is impossible to confirm alignment with the instruction |

---

#### QD-03: Oracle / Gold Integrity

The ground truth — whether it is an expected-answer file or a gold solution — is what every score is computed against. If it contains a wrong value, a perfect agent gets penalized and a lucky wrong agent gets rewarded. If it is incomplete and missing fields the instruction requires, agents lose points on work they were never told to do. If it is too rigid — accepting only one spelling when multiple valid forms exist — correct answers score zero. If the gold solution does not actually fix the stated problem, the oracle run fails and the entire pipeline is broken. This QD verifies that the ground truth is factually correct against the source data, complete against the instruction, and flexible where the domain requires it.

**Read:** the ground-truth/oracle file(s), the gold solution, the task instruction, and the input data

| #   | Check                             | PASS                                                                                                                   | FAIL                                                                             |
| --- | --------------------------------- | ---------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| 1   | Factual correctness               | Ground-truth values are verifiable against the source data                                                             | Wrong counts, wrong identifiers, wrong conclusions                               |
| 2   | Completeness                      | Ground truth covers every requirement stated in the instruction                                                        | Missing fields or criteria that the instruction asks for                         |
| 3   | Variant handling                  | Accepts multiple valid forms where the domain permits them (synonyms, alternate spellings, equivalent representations) | Rigid exact-match on fields where valid alternatives exist                       |
| 4   | Gold solution works               | The gold solution applies cleanly and produces a perfect score when run through the verifier                           | Gold solution fails to apply, or verifier still reports errors after applying it |
| 5   | Gold solution matches instruction | The fix or answer addresses exactly what the instruction describes                                                     | Gold solution solves a different problem or includes unrequested changes         |

---

#### QD-04: Reward-Hacking Resistance

A benchmark is only useful if the score reflects genuine capability. Reward hacking is when an agent achieves a high score through a shortcut that bypasses the intended work entirely — reading the ground truth from a leaked file, extracting answers from the decomposition descriptions, submitting empty output with correct structure for partial credit, or exploiting infrastructure to find the solution without reasoning. This QD systematically traces every path an agent could take to reach a perfect score without doing the task: it checks that the ground truth is invisible during execution, that the decomposition carries no answer values, that the evaluation enforces per-field correctness rather than surface impressions, that verification tests real behavior rather than keyword presence, and that no infrastructure shortcut exists. If any shortcut path is found, the task's scores are meaningless.

**Read:** the task instruction, decomposition, ground-truth files, all verification/judge scripts, the environment directory, and the Dockerfile

| #   | Check                                                                                                       | PASS                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | FAIL                                                                                                                             |
| --- | ----------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Ground truth not visible to agent `[Harbor: tests_or_solution_in_image]` `[Harbor: anti_cheating_measures]` | No answer file — regardless of what it is named (`oracle.json`, `solution.json`, `golden_answer.json`, `expected_output.json`, or anything else) — or answer content anywhere in the agent-accessible environment. The image should not copy tests/ or solution/ into the runtime build. The agent does not see the solution or tests at run time. This is a semantic check: read every file inside `environment/` and assess whether its content contains ground-truth answers, not just whether a specific filename exists. PASS if the setup discourages trivial shortcuts; FAIL if there are obvious ways to bypass intended behavior (e.g., answer embedded in environment under any filename, copying ground-truth files into image, or relying on network calls that leak answers). | Answer data found in the environment the agent can read at runtime — under any filename — or tests/solution baked into the image |
| 2   | Decomposition clean                                                                                         | Sub-task descriptions contain no specific answer values                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | Descriptions contain exact numbers, identifiers, or conclusions from the ground truth                                            |
| 3   | Instruction clean                                                                                           | No answer hints in instruction text                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | Instruction reveals the expected result or narrows it to a trivial guess                                                         |
| 4   | Evaluation is strict and per-field                                                                          | The scoring mechanism compares each output field individually against ground truth                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | Scoring is based on overall impression, vague similarity, or surface-level quality                                               |
| 5   | Empty/placeholder output penalized                                                                          | Null, empty, or placeholder values are explicitly scored as zero                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | Agent gets partial credit for structurally correct but content-empty output                                                      |
| 6   | Verification tests behavior not keywords                                                                    | Verification checks functional correctness — return values, computed results, behavioral assertions                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | Verification checks substring presence or keyword matching                                                                       |
| 7   | No infrastructure shortcut                                                                                  | No path to a high score without doing the intended work                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | Agent can copy a visible answer, hardcode expected returns, or exploit other shortcuts                                           |
| 8   | Git history does not leak the answer                                                                        | If the environment clones a repository, it must checkout a specific commit and remove `.git` so the agent has no access to commit history. A `git clone <repo>` without this gives the agent full history — if the task is based on a real PR, the agent can find and cherry-pick the fix without reasoning. The ideal pattern in the Dockerfile is: `git clone <repo_url> repo && cd repo && git checkout <commit_hash> && rm -rf .git`. PASS if `.git` is removed after checkout. FAIL if full history is accessible.                                                                                                                                                                                                                                                                    | `git clone` without `rm -rf .git` — agent runs `git log`, finds the fix commit, and cherry-picks it                              |

---

#### QD-05: Multi-Agent Necessity

SwarmBench exists to measure whether multi-agent coordination solves problems that a single agent cannot. If a task is small enough or simple enough that one agent handles it fine, the benchmark proves nothing — the observed gap is just noise or an artifact of the decomposition giving free hints. This QD checks that the task has a genuine structural reason why a single agent fails: the input exceeds effective context so the agent loses precision across documents, or the task requires parallel specialist reasoning across domains that degrade when mixed in one context, or the problem space is large enough that a single agent cannot hold all relevant pieces in working memory. It reads the metadata claims and cross-checks them against the actual input scale and task structure — if someone claims "context overflow" for a small task, or "specialist domains" for a single-topic analysis, this QD catches it.

**Read:** task metadata (`input_token_estimate`, `why_multi_agent`), the task instruction, and the input artifacts

| #   | Check                         | PASS                                                                                                                                     | FAIL                                                                                    |
| --- | ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| 1   | Scale justifies decomposition | Input volume or problem complexity genuinely exceeds what a single agent can handle effectively                                          | Input is small and simple enough for one agent to process completely                    |
| 2   | Failure mode is named         | The metadata explains what specifically breaks for a single agent — not just "it's hard"                                                 | Vague claims like "too complex" or "too large" without specifying the failure mechanism |
| 3   | Fix mechanism is named        | The metadata explains how decomposition addresses the stated failure mode                                                                | No explanation of how splitting the work into sub-agents actually helps                 |
| 4   | Coordination over parallelism | The multi-agent advantage comes from coordination quality (context splitting, specialist reasoning, structured synthesis) not just speed | The only benefit is doing the same work in parallel — faster, not better                |
| 5   | Natural split boundaries      | The task input has clear decomposition points — independent files, independent domains, independent modules                              | The input is monolithic and splitting it is artificial or arbitrary                     |

---

#### QD-06: Decomposition Soundness

The decomposition is the coordination blueprint injected into the multi-agent orchestrator. Each sub-agent sees only its own description — not the instruction, not other descriptions. If a description is vague, the sub-agent has no idea what to do and fails. If descriptions overlap, two agents do the same work and waste capacity. If a dependency is missing, the synthesizer runs before its inputs are ready and produces garbage. If the decomposition contains exact commands or patterns, the orchestrator is just executing a script rather than demonstrating coordination intelligence. This QD walks the full decomposition graph: checks that every sub-task is self-contained with clear inputs and outputs, that responsibilities do not overlap, that the dependency structure is correct and complete, that agent count is minimal, and that the structure matches the declared coordination pattern.

**Read:** the decomposition file, the task instruction

| #   | Check                | PASS                                                                                                                  | FAIL                                                                                                                                                                                                                                                                                                                                  |
| --- | -------------------- | --------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Non-overlapping      | Each sub-agent has exactly one clear responsibility                                                                   | Multiple agents assigned to the same data or same analysis                                                                                                                                                                                                                                                                            |
| 2   | Self-contained       | Each description includes what files to read, what to produce, and in what format — does not defer to other documents | Descriptions say "see the instruction" or reference other sub-tasks instead of being standalone                                                                                                                                                                                                                                       |
| 3   | Complete coverage    | Every part of the input data is assigned to at least one sub-agent                                                    | Some input segments have no assigned agent                                                                                                                                                                                                                                                                                            |
| 4   | Dependencies correct | Downstream sub-tasks depend on all the upstream sub-tasks they need                                                   | A synthesis step is missing a dependency on one of its required inputs                                                                                                                                                                                                                                                                |
| 5   | Minimal              | No redundant agents — each one is necessary                                                                           | Two agents doing the same work, or an agent with no meaningful responsibility                                                                                                                                                                                                                                                         |
| 6   | WHAT not HOW         | Descriptions say what to find or produce, not the exact commands or code to execute                                   | Contains specific shell commands, regex patterns, or step-by-step implementation instructions, descriptions must not contain the exact lines of code to change, before and after code strings, exact file locations or method names indicating where to insert code, or the exact attribute names and values that constitute the fix. |
| 7   | Pattern match        | The decomposition structure matches the declared coordination pattern                                                 | Claims map-reduce but has no reduce step; claims fan-out but sub-tasks are not independent                                                                                                                                                                                                                                            |

---

#### QD-07: AHT Justification Quality

The human-solving-hours estimate drives task difficulty classification (10–50h Easy, 50–100h Medium, 100h+ Hard) and is the primary signal reviewers use to assess whether a task is substantial enough for the benchmark. If a trainer inflates the estimate, they game the difficulty tier and dilute the benchmark's credibility. If they provide no arithmetic — just "this is complex work" — there is no way to verify the claim. This QD reads the justification and checks that it contains a real quantified breakdown: number of items multiplied by time per item, broken into reading, analysis, and synthesis phases, adding up to the claimed total. It then cross-checks plausibility against the declared input scale.

**Read:** task metadata (`human_solving_hours_estimate`, `human_solving_hours_justification`, `input_token_estimate`)

| #   | Check                     | PASS                                                                  | FAIL                                                        |
| --- | ------------------------- | --------------------------------------------------------------------- | ----------------------------------------------------------- |
| 1   | Has arithmetic            | Breakdown with numbers: N items x M min/item = H hours                | Pure prose with no quantification                           |
| 2   | Covers phases             | Accounts for reading, analysis, and synthesis separately              | Only mentions one phase of the work                         |
| 3   | Arithmetic matches total  | Component hours add up to the claimed total                           | Components sum to a different number than claimed           |
| 4   | Plausible for input scale | Hours are proportional to the actual input size and domain complexity | Claimed hours are wildly inconsistent with the input volume |
| 5   | Not inflated              | Estimate reflects genuine work, not difficulty-tier gaming            | Estimate is clearly padded to reach a higher tier           |

Cross-check: `input_token_estimate` < 50K → unlikely > 30h. 50K–200K → 30–80h plausible. 200K+ → 80–200h plausible.

---

#### QD-08: Output Format Precision _(llm-judge tasks only)_

For tasks where an LLM judge scores the agent's output against a ground-truth answer, the agent must produce structured output matching the ground truth's schema exactly — every key, every nesting level, every type. The output format block in the instruction is the agent's only guide to this structure. If the format block is missing a key that the ground truth contains, the agent will never produce it and scores zero on that field through no fault of its own. If the format block shows one type but the ground truth has another, the agent writes the wrong type and the judge marks it wrong. These are the most common source of false failures in judge-scored tasks — the task is correct, the ground truth is correct, but the format block does not match, so every agent run produces a zero. This QD does a field-by-field comparison of the instruction's format block against the ground-truth structure.

**Read:** the task instruction (output format block), the ground-truth answer file

| #   | Check                                               | PASS                                                                                                                                                                                                                                                                                                                           | FAIL                                                                                                   |
| --- | --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| 1   | All keys present `[Harbor: structured_data_schema]` | Every ground-truth key appears in the instruction's format block. If the task expects structured output (APIs, JSON, CSV, DB schemas), the exact schema must be documented in instruction.md or a clearly referenced spec file. PASS if schema is explicit; FAIL if only examples are given without marking them as normative. | A key exists in ground truth but is missing from the format block, or schema not explicitly documented |
| 2   | Nesting matches                                     | Every nested key appears at the correct depth in the format block                                                                                                                                                                                                                                                              | Ground truth is nested but format block shows a flat structure, or vice versa                          |
| 3   | Types correct                                       | Type annotations in the format block match the actual ground-truth value types                                                                                                                                                                                                                                                 | Format block says integer but ground truth has a string, or similar mismatch                           |
| 4   | Collection types match                              | Format block correctly shows arrays where ground truth has arrays, objects where it has objects                                                                                                                                                                                                                                | Format shows a single value where ground truth expects a list                                          |
| 5   | Precision stated                                    | For non-round numeric values in the ground truth, the instruction states rounding or precision rules                                                                                                                                                                                                                           | Ground truth has specific decimals but no precision guidance exists                                    |
| 6   | No phantom keys                                     | Format block does not show keys that are absent from the ground truth                                                                                                                                                                                                                                                          | Extra keys in format block that confuse the agent into producing unnecessary output                    |

---

### ADVISORY QDs (fail → MANUAL REVIEW)

---

#### QD-09: Environment & Reproducibility

A task that works on the trainer's laptop but fails in CI is worthless. Environments that reference local paths, clone repos without pinning a commit (so the code drifts), install unpinned packages (so a breaking update changes behavior), or depend on network calls that rate-limit or disappear — all produce tasks that pass once and fail unpredictably afterward. Non-deterministic verifiers are equally dangerous: a verification script that uses randomness, wall-clock time, or external API calls can produce different scores on identical agent outputs, making the benchmark unreliable. This QD scans the environment setup for local paths, unpinned dependencies, and floating references, and scans the verifier for sources of non-determinism.

**Read:** the Dockerfile / environment setup, all verification scripts

| #   | Check                                                 | PASS                                                                                                                                                                                                                                                              | FAIL                                                                                                                     |
| --- | ----------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| 1   | No local paths                                        | Environment setup has no references to trainer-local directories                                                                                                                                                                                                  | Hardcoded paths that only exist on one machine                                                                           |
| 2   | Pinned base image                                     | Uses a specific tagged base image, not a floating tag                                                                                                                                                                                                             | Uses `:latest` or untagged image                                                                                         |
| 3   | Pinned packages `[Harbor: pinned_dependencies]`       | If the task uses external dependencies (e.g. pip packages), their versions should be pinned to ensure reproducibility. Apt packages shall not be pinned, but all python dependencies should be pinned. PASS if pinning is adequate; FAIL otherwise.               | Unpinned installs that can change between runs                                                                           |
| 4   | Source code pinned                                    | Any cloned repositories are checked out at a specific commit                                                                                                                                                                                                      | Repository cloned at a floating branch head                                                                              |
| 5   | Deterministic verifier                                | Verification script has no sources of randomness, timing, or external calls                                                                                                                                                                                       | Uses random number generation, wall-clock time, or network requests                                                      |
| 6   | Network documented                                    | If the agent needs internet access during execution, the instruction says so                                                                                                                                                                                      | Undocumented network dependency                                                                                          |
| 7   | Build feasible                                        | Environment setup does not pull excessively large dependencies for the task at hand                                                                                                                                                                               | Build will timeout or consume unreasonable resources                                                                     |
| 8   | Test deps not in image `[Harbor: test_deps_in_image]` | Are any test dependencies installed in the image during the build process? They should be installed in the test.sh script instead. Test-only dependencies should not be baked into the image build. PASS if test-only deps are isolated to tests; FAIL otherwise. | Test-only packages installed in the Dockerfile — bloats the image and leaks verifier implementation details to the agent |

---

#### QD-10: Benchmark Validity & Fairness

The entire point of SwarmBench is measuring whether multi-agent coordination produces better results than a single agent on the same task. If the comparison is unfair — the multi-agent system gets domain knowledge the single agent does not, or the decomposition essentially solves the problem with step-by-step instructions, or the gap is just from parallel execution rather than coordination quality — then the benchmark number is misleading. This QD checks that both agent configurations receive the same instruction and timeout, that the decomposition describes work division rather than teaching analytical methodology, that no helper tooling does the substantive work, and that the observed reward gap reflects genuine coordination advantage.

**Read:** the decomposition, the task instruction, input artifacts, execution logs

| #   | Check                                               | PASS                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | FAIL                                                                                                                                            |
| --- | --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Same instruction                                    | Both single and multi agent receive the identical task instruction                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | Different instructions for each configuration                                                                                                   |
| 2   | Same timeout                                        | Both configurations have the same time limit                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | Asymmetric timeouts                                                                                                                             |
| 3   | Coordination-driven gap                             | Multi-agent advantage comes from coordination quality — context splitting, specialist reasoning, structured synthesis                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | Gap is only from parallelism — doing the same work faster, not better                                                                           |
| 4   | Decomposition is guidance not solution              | Decomposition describes how to divide the work, not how to solve the problem                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | Decomposition teaches analytical methods or domain rules not present in the instruction                                                         |
| 5   | No custom tooling advantage                         | Input artifacts are data for the agent to process, not scripts that do the processing                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | Executable scripts in the input artifacts perform the substantive analysis                                                                      |
| 6   | Multi-agent trajectory follows coordination pattern | Review the multi-agent execution trajectory. The orchestrator must have actually spawned sub-agents matching the declared `coordination_pattern` and decomposition structure — map-reduce should show map sub-agents producing intermediate results fed into a reduce step, fan-out should show independent parallel sub-agents followed by synthesis, specialist-routing should show domain-specific sub-agents. PASS if the trajectory demonstrates the claimed coordination. FAIL if the orchestrator solved the task monolithically, ignored the decomposition, or used a different pattern than declared. | Trajectory shows the orchestrator doing all the work itself, or sub-agents not following the declared pattern — the coordination claim is false |

---

#### QD-11: Task Real-Worldness

A benchmark task should represent a problem that professionals actually face — not a toy exercise dressed up with enterprise language. If the input data is a handful of records pretending to be enterprise-scale, or the scenario is a contrived puzzle with no real-world analog, or the task is trivially solvable with a few lines of scripting, it does not belong in SwarmBench. This QD evaluates whether the task feels like genuine professional work: realistic data at realistic volume, a scenario that would actually arise in the claimed domain, and a problem that genuinely benefits from expert-level reasoning rather than simple automation. It also checks that the reference material grounds the task in an actual domain context.

**Read:** the task instruction, input artifacts, task metadata (`domain`, `reference_link`)

| #   | Check                     | PASS                                                                                         | FAIL                                                         |
| --- | ------------------------- | -------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| 1   | Realistic scenario        | Task describes a problem a professional would actually encounter                             | Contrived or artificially constructed scenario               |
| 2   | Real-scale data           | Input data is real-world or convincingly synthetic at realistic volume                       | Trivial data volume pretending to represent large-scale work |
| 3   | Professional framing      | Instruction reads like a work brief, not a homework assignment                               | Academic or tutorial-style framing                           |
| 4   | Not trivially automatable | Task genuinely requires reasoning, not just simple scripting                                 | A few lines of code solve the entire problem                 |
| 5   | Reference grounded        | Reference material points to real source context (or synthetic data is explicitly justified) | Broken link, generic search URL, or no grounding at all      |

---

#### QD-12: Trajectory Analysis

The execution logs are the ground truth of what actually happened. Numbers in a results table mean nothing if the underlying agent behavior is broken, gamed, or artificially constrained. This QD reads the highest-scoring multi-agent trajectory and the single-agent trajectories to verify that the scores reflect genuine capability differences — not task construction flaws.

**Read:** `execution_logs/multi-kimi-agent/` (trial's `agent/trajectory.json`) and `execution_logs/single-kimi-agent/` (trial's trajectory + `judge_justification.txt`)

**Multi-agent (best run):**

| #   | Check                                | PASS                                                                                                   | FAIL                                                                                                                                                                    |
| --- | ------------------------------------ | ------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Sub-agents received adequate context | Each spawned sub-agent's prompt contains the file paths, output format, and analysis criteria it needs | Sub-agents received vague or incomplete prompts — failures are from poor orchestration, not task difficulty                                                             |
| 2   | No redundant sub-agents              | Each sub-agent did distinct work — no two agents processed the same data for the same purpose          | Multiple agents did identical work, inflating agent count without benefit                                                                                               |
| 4   | Synthesis step exists                | Orchestrator aggregated sub-agent results before writing final output                                  | Sub-agent outputs concatenated without synthesis, or orchestrator wrote output without waiting for all sub-agents                                                       |
| 5   | Room for decomposition improvement   | The decomposition as executed was near-optimal for the task                                            | Obvious improvements exist — sub-tasks could be split further, merged, or reordered to significantly improve the score. Flag for trainer to revise `decomposition.yaml` |
| 6   | Failures are genuine                 | Any fields the multi-agent scored 0 on are genuinely hard, not caused by task construction issues      | Multi-agent failures trace back to missing spec in instruction, wrong oracle value, or broken verifier — not agent incapability                                         |

**Single-agent (all runs):**

| #   | Check                    | PASS                                                                                                                               | FAIL                                                                                                                                                          |
| --- | ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 7   | Failure is structural    | Single agent failed due to context limits, attention degradation, or timeout — the structural reasons claimed in `why_multi_agent` | Single agent failed due to missing information in instruction, wrong file path, or verifier bug — these are task construction failures, not agent limitations |
| 8   | No sub-agent spawning    | Single agent trajectory shows zero Task/CreateSubagent tool calls                                                                  | Single agent spawned sub-agents despite tool restriction — isolation is broken                                                                                |
| 9   | Agent attempted the task | Single agent read input files and made a genuine attempt                                                                           | Agent immediately wrote empty output or timed out without reading any input — task may be too vaguely specified                                               |
| 10  | False failure check      | Low scores are from incorrect answers, not format mismatches or missing fields the prompt didn't mention                           | Judge justification shows score=0 on fields the instruction never specified — false failure from underspecified prompt                                        |

---

## Decision

| L1 Static | L2 Execution | L3 Blocking QDs | L3 Advisory QDs | Verdict       |
| --------- | ------------ | --------------- | --------------- | ------------- |
| FAIL      | —            | —               | —               | REJECT        |
| PASS      | FAIL         | —               | —               | REJECT        |
| PASS      | PASS         | Any FAIL        | —               | REJECT        |
| PASS      | PASS         | All PASS        | Any FAIL        | MANUAL REVIEW |
| PASS      | PASS         | All PASS        | All PASS        | APPROVE       |

---

## Report

Single output file: `quality_gate_report.json`

```json
{
  "task_id": "<folder_name>",
  "decision": "APPROVE | REJECT | MANUAL_REVIEW",

  "static_validation": {
    "result": "PASS | FAIL",
    "checks": {
      "zip_packaging": { "result": "PASS | FAIL", "reason": "..." },
      "file_structure": { "result": "PASS | FAIL", "reason": "..." },
      "task_toml_schema": { "result": "PASS | FAIL", "reason": "..." },
      "decomposition_yaml": { "result": "PASS | FAIL", "reason": "..." },
      "cross_file_consistency": { "result": "PASS | FAIL", "reason": "..." },
      "leakage_scan": { "result": "PASS | FAIL", "reason": "..." }
    }
  },

  "execution_validation": {
    "result": "PASS | FAIL",
    "oracle": { "n_trials": 1, "n_errors": 0, "mean_reward": 1.0 },
    "single": { "n_trials": 1, "n_errors": 0, "mean_reward": 0.12 },
    "multi": { "n_trials": 1, "n_errors": 0, "mean_reward": 0.85 },
    "gap": 0.73,
    "reason": "..."
  },

  "llm_review": {
    "result": "PASS | FAIL",
    "dimensions": {
      "QD-01_instruction_completeness": {
        "result": "PASS | FAIL",
        "justification": "..."
      },
      "QD-02_instruction_verifier_alignment": {
        "result": "PASS | FAIL",
        "justification": "..."
      },
      "QD-03_oracle_gold_integrity": {
        "result": "PASS | FAIL",
        "justification": "..."
      },
      "QD-04_reward_hacking_resistance": {
        "result": "PASS | FAIL",
        "justification": "..."
      },
      "QD-05_multi_agent_necessity": {
        "result": "PASS | FAIL",
        "justification": "..."
      },
      "QD-06_decomposition_soundness": {
        "result": "PASS | FAIL",
        "justification": "..."
      },
      "QD-07_aht_justification_quality": {
        "result": "PASS | FAIL",
        "justification": "..."
      },
      "QD-08_output_format_precision": {
        "result": "PASS | FAIL | NOT_APPLICABLE",
        "justification": "..."
      },
      "QD-09_environment_reproducibility": {
        "result": "PASS | FAIL",
        "justification": "..."
      },
      "QD-10_benchmark_validity_fairness": {
        "result": "PASS | FAIL",
        "justification": "..."
      },
      "QD-11_task_real_worldness": {
        "result": "PASS | FAIL",
        "justification": "..."
      }
    }
  },

  "rejection_reasons": [
    {
      "layer": "static | execution | llm_review",
      "code": "S-03 | QD-04 | ...",
      "message": "..."
    }
  ]
}
```

---

## Build Order

1. ZIP download + extract + folder validation
2. Naming validator (UUID, slug, name match)
3. task.toml parser + enum/range checks
4. File structure validator
5. decomposition.yaml validator + cycle detection
6. Cross-file consistency checks
7. Leakage + reward-hack scan
8. llm-judge / executable specific checks
9. Execution log parser + threshold enforcement
10. LLM reviewer (11-QD rubric via Claude Agent SDK)
11. Decision aggregator + report generator

This PRD is self-contained — no external rubric dependency. All 11 Harbor `default_rubric.toml` checks are embedded verbatim inside the QDs above (search for `[Harbor:` to find each one).
