# Monknot Flow Fixed-Corpus QA

Seed: `0x4D4F4E4B4E4F5421`

These case numbers and IDs were frozen before product execution. Run 10 assigned cases by typing and 10 by paste. Enter final punctuation or Return as a separate event.

## Case 01 — `repair-exact-001`

- Domain: personal message
- Classification: exact deterministic
- Trigger: punctuation `.`
- Mutations: adjacent-letter transposition
- Long or hard-wrapped: no
- Input:

~~~text
I will brnig the keys when I meet you outside.
~~~

- Human reference (not a required exact AI wording):

~~~text
I will bring the keys when I meet you outside.
~~~

- Runtime record: NSSpellChecker issues ___; owner ___; visible proposal ___; direct/review-only ___; terminal reason ___; latency ___ ms; final text ___; undo ___; result ___

## Case 02 — `repair-exact-002`

- Domain: work update
- Classification: exact deterministic
- Trigger: punctuation `.`
- Mutations: subject–verb disagreement
- Long or hard-wrapped: no
- Input:

~~~text
The release notes is ready for review by the support team.
~~~

- Human reference (not a required exact AI wording):

~~~text
The release notes are ready for review by the support team.
~~~

- Runtime record: NSSpellChecker issues ___; owner ___; visible proposal ___; direct/review-only ___; terminal reason ___; latency ___ ms; final text ___; undo ___; result ___

## Case 03 — `repair-exact-003`

- Domain: email
- Classification: exact deterministic
- Trigger: punctuation `.`
- Mutations: wrong article
- Long or hard-wrapped: no
- Input:

~~~text
I attached a updated estimate for the client meeting.
~~~

- Human reference (not a required exact AI wording):

~~~text
I attached an updated estimate for the client meeting.
~~~

- Runtime record: NSSpellChecker issues ___; owner ___; visible proposal ___; direct/review-only ___; terminal reason ___; latency ___ ms; final text ___; undo ___; result ___

## Case 04 — `repair-exact-004`

- Domain: meeting note
- Classification: exact deterministic
- Trigger: punctuation `.`
- Mutations: missing comma
- Long or hard-wrapped: no
- Input:

~~~text
After the demo we will collect questions from the design team.
~~~

- Human reference (not a required exact AI wording):

~~~text
After the demo, we will collect questions from the design team.
~~~

- Runtime record: NSSpellChecker issues ___; owner ___; visible proposal ___; direct/review-only ___; terminal reason ___; latency ___ ms; final text ___; undo ___; result ___

## Case 05 — `repair-exact-005`

- Domain: health-related message
- Classification: exact deterministic
- Trigger: punctuation `.`
- Mutations: spelling mistake
- Long or hard-wrapped: no
- Input:

~~~text
I need to rescheduel my appointment because I have a fever.
~~~

- Human reference (not a required exact AI wording):

~~~text
I need to reschedule my appointment because I have a fever.
~~~

- Runtime record: NSSpellChecker issues ___; owner ___; visible proposal ___; direct/review-only ___; terminal reason ___; latency ___ ms; final text ___; undo ___; result ___

## Case 06 — `repair-exact-013`

- Domain: work update
- Classification: exact deterministic
- Trigger: punctuation `.`
- Mutations: spelling mistake, subject–verb disagreement
- Long or hard-wrapped: no
- Input:

~~~text
The enginers is testing the backup process before tonight.
~~~

- Human reference (not a required exact AI wording):

~~~text
The engineers are testing the backup process before tonight.
~~~

- Runtime record: NSSpellChecker issues ___; owner ___; visible proposal ___; direct/review-only ___; terminal reason ___; latency ___ ms; final text ___; undo ___; result ___

## Case 07 — `repair-exact-014`

- Domain: meeting note
- Classification: exact deterministic
- Trigger: punctuation `.`
- Mutations: wrong article, wrong preposition
- Long or hard-wrapped: no
- Input:

~~~text
We scheduled an review in Monday for the new prototype.
~~~

- Human reference (not a required exact AI wording):

~~~text
We scheduled a review on Monday for the new prototype.
~~~

- Runtime record: NSSpellChecker issues ___; owner ___; visible proposal ___; direct/review-only ___; terminal reason ___; latency ___ ms; final text ___; undo ___; result ___

## Case 08 — `repair-exact-015`

- Domain: email
- Classification: exact deterministic
- Trigger: punctuation `.`
- Mutations: capitalization error, missing comma, adjacent-letter transposition
- Long or hard-wrapped: no
- Input:

~~~text
after lunch Priya will chekc the figures and send the summary.
~~~

- Human reference (not a required exact AI wording):

~~~text
After lunch, Priya will check the figures and send the summary.
~~~

- Runtime record: NSSpellChecker issues ___; owner ___; visible proposal ___; direct/review-only ___; terminal reason ___; latency ___ ms; final text ___; undo ___; result ___

## Case 09 — `repair-exact-016`

- Domain: personal message
- Classification: exact deterministic
- Trigger: punctuation `.`
- Mutations: spelling mistake, spelling mistake, incorrect punctuation
- Long or hard-wrapped: no
- Input:

~~~text
Can you confrim the adress before we leave.
~~~

- Human reference (not a required exact AI wording):

~~~text
Can you confirm the address before we leave?
~~~

- Runtime record: NSSpellChecker issues ___; owner ___; visible proposal ___; direct/review-only ___; terminal reason ___; latency ___ ms; final text ___; undo ___; result ___

## Case 10 — `repair-exact-017`

- Domain: meeting note
- Classification: exact deterministic
- Trigger: punctuation `.`
- Mutations: subject–verb disagreement, spelling mistake
- Long or hard-wrapped: no
- Input:

~~~text
The meeting notes was uploded to the shared folder.
~~~

- Human reference (not a required exact AI wording):

~~~text
The meeting notes were uploaded to the shared folder.
~~~

- Runtime record: NSSpellChecker issues ___; owner ___; visible proposal ___; direct/review-only ___; terminal reason ___; latency ___ ms; final text ___; undo ___; result ___

## Case 11 — `repair-exact-021`

- Domain: hard-wrapped prose
- Classification: exact deterministic
- Trigger: punctuation `.`
- Mutations: adjacent-letter transposition, spelling mistake, spelling mistake
- Long or hard-wrapped: yes
- Input:

~~~text
The tehcnical review found no critical risks during the first pass,
but the second revieiw found a critcal deployment warning.
~~~

- Human reference (not a required exact AI wording):

~~~text
The technical review found no critical risks during the first pass,
but the second review found a critical deployment warning.
~~~

- Runtime record: NSSpellChecker issues ___; owner ___; visible proposal ___; direct/review-only ___; terminal reason ___; latency ___ ms; final text ___; undo ___; result ___

## Case 12 — `repair-exact-022`

- Domain: hard-wrapped prose
- Classification: exact deterministic
- Trigger: punctuation `.` followed by 1 closing delimiter(s)
- Mutations: subject–verb disagreement, incorrect punctuation
- Long or hard-wrapped: yes
- Input:

~~~text
In the final note, Sofia asked,
“Is the packages ready for the Berlin office.”
~~~

- Human reference (not a required exact AI wording):

~~~text
In the final note, Sofia asked,
“Are the packages ready for the Berlin office?”
~~~

- Runtime record: NSSpellChecker issues ___; owner ___; visible proposal ___; direct/review-only ___; terminal reason ___; latency ___ ms; final text ___; undo ___; result ___

## Case 13 — `repair-exact-023`

- Domain: hard-wrapped prose
- Classification: exact deterministic
- Trigger: punctuation `.`
- Mutations: spelling mistake, spelling mistake, subject–verb disagreement
- Long or hard-wrapped: yes
- Input:

~~~text
The release checklist [verfy backups and notifiy owners] is ready for the rehearsal,
and Project Cedar have no other blocking issue.
~~~

- Human reference (not a required exact AI wording):

~~~text
The release checklist [verify backups and notify owners] is ready for the rehearsal,
and Project Cedar has no other blocking issue.
~~~

- Runtime record: NSSpellChecker issues ___; owner ___; visible proposal ___; direct/review-only ___; terminal reason ___; latency ___ ms; final text ___; undo ___; result ___

## Case 14 — `repair-exact-024`

- Domain: longer paragraph
- Classification: exact deterministic
- Trigger: punctuation `.`
- Mutations: missing comma, spelling mistake, subject–verb disagreement, spelling mistake
- Long or hard-wrapped: yes
- Input:

~~~text
After the first rehearsal the release managers cheked every backup, the support leads confirms the escalation list, and the documentation team publshed the recovery steps so each owner could review the plan before the scheduled maintenance window on September 4, 2026.
~~~

- Human reference (not a required exact AI wording):

~~~text
After the first rehearsal, the release managers checked every backup, the support leads confirmed the escalation list, and the documentation team published the recovery steps so each owner could review the plan before the scheduled maintenance window on September 4, 2026.
~~~

- Runtime record: NSSpellChecker issues ___; owner ___; visible proposal ___; direct/review-only ___; terminal reason ___; latency ___ ms; final text ___; undo ___; result ___

## Case 15 — `repair-ai-001`

- Domain: health-related message
- Classification: AI invariant
- Trigger: punctuation `.`
- Mutations: spelling mistake, subject–verb disagreement, run-on clause, subject–verb disagreement, spelling mistake
- Long or hard-wrapped: yes
- Input:

~~~text
My ankle did nt improve overnight after the new exercises the swelling look worse and the clinic have not replyed yet.
~~~

- Human reference (not a required exact AI wording):

~~~text
My ankle did not improve overnight after the new exercises; the swelling looks worse, and the clinic has not replied yet.
~~~

- Runtime record: NSSpellChecker issues ___; owner ___; visible proposal ___; direct/review-only ___; terminal reason ___; latency ___ ms; final text ___; undo ___; result ___

## Case 16 — `repair-protected-001`

- Domain: project summary
- Classification: protected / unsafe
- Trigger: punctuation `.`
- Mutations: spelling mistake
- Long or hard-wrapped: no
- Input:

~~~text
Use `tehFlag` in the example before running the command.
~~~

- Human reference (not a required exact AI wording):

~~~text
Use `theFlag` in the example before running the command.
~~~

- Runtime record: NSSpellChecker issues ___; owner ___; visible proposal ___; direct/review-only ___; terminal reason ___; latency ___ ms; final text ___; undo ___; result ___

## Case 17 — `repair-protected-002`

- Domain: project summary
- Classification: protected / unsafe
- Trigger: Return
- Mutations: spelling mistake
- Long or hard-wrapped: no
- Input:

~~~text
Keep this sample unchanged:
```swift
func load() { retrun value }
```
Then continue with the explanation.
~~~

- Human reference (not a required exact AI wording):

~~~text
Keep this sample unchanged:
```swift
func load() { return value }
```
Then continue with the explanation.
~~~

- Runtime record: NSSpellChecker issues ___; owner ___; visible proposal ___; direct/review-only ___; terminal reason ___; latency ___ ms; final text ___; undo ___; result ___

## Case 18 — `repair-protected-003`

- Domain: email
- Classification: protected / unsafe
- Trigger: punctuation `.`
- Mutations: spelling mistake
- Long or hard-wrapped: no
- Input:

~~~text
Open the reference at [the guide](https://example.com/teh-guide) after the meeting.
~~~

- Human reference (not a required exact AI wording):

~~~text
Open the reference at [the guide](https://example.com/the-guide) after the meeting.
~~~

- Runtime record: NSSpellChecker issues ___; owner ___; visible proposal ___; direct/review-only ___; terminal reason ___; latency ___ ms; final text ___; undo ___; result ___

## Case 19 — `repair-protected-004`

- Domain: planning note
- Classification: protected / unsafe
- Trigger: punctuation `.`
- Mutations: spelling mistake
- Long or hard-wrapped: no
- Input:

~~~text
Visit https://teh.example.com/releases before updating the launch checklist.
~~~

- Human reference (not a required exact AI wording):

~~~text
Visit https://the.example.com/releases before updating the launch checklist.
~~~

- Runtime record: NSSpellChecker issues ___; owner ___; visible proposal ___; direct/review-only ___; terminal reason ___; latency ___ ms; final text ___; undo ___; result ___

## Case 20 — `repair-protected-005`

- Domain: personal message
- Classification: protected / unsafe
- Trigger: punctuation `.`
- Mutations: spelling mistake
- Long or hard-wrapped: no
- Input:

~~~text
Send the receipt to teh.user@example.com after lunch today.
~~~

- Human reference (not a required exact AI wording):

~~~text
Send the receipt to the.user@example.com after lunch today.
~~~

- Runtime record: NSSpellChecker issues ___; owner ___; visible proposal ___; direct/review-only ___; terminal reason ___; latency ___ ms; final text ___; undo ___; result ___
