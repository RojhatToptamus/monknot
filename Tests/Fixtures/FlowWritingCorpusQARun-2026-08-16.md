# Monknot Flow signed-app QA run — 2026-08-16

This file is a historical run record. It does not replace the frozen corpus worksheet.

## Run identity

- Fixed sample seed: `0x4D4F4E4B4E4F5421`.
- Sample size: 20 cases, with 10 typed cases and 10 pasted cases.
- Trigger method: the final punctuation or Return was a separate editor event.
- Executed app: `Monknot Flow QA Final` with bundle ID `com.monknot.flowqa.final01`.
- Architecture: arm64.
- Signature: ad hoc. Deep and strict code-signature validation passed before this run.
- Source executable SHA-256 before clone re-sign: `5271caccb19d30ebbecc10d5da553cf2b2bdfe74f681fc8d15b3bf946a9a7668`.
- Executed clone SHA-256 after re-sign: `b9c9c13bb3f5d5b0f3b1ddca2fa44d41aac3415ed86a891e099dbdc136f25974`.
- Executed app CDHash: `67ec4bbb7cb31b99d101698361e44d2f7a01a649`.
- Host: macOS 26.5.1, build 25F80.
- Source observation JSON SHA-256: `0eb09d201bc57cca22543caa98e6a20b9b4e799ddfbc4ddb6c9684983d10bbc6`.

The source hash matched the executable in `dist/Monknot.app` before the QA clone received its separate identity and signature.

## Evidence boundaries

Each numbered case below is a direct observation of the signed app. The record gives the exact editor value at the trigger.

The app UI did not expose the NSSpellChecker issue count, request owner, or terminal reason. This record does not infer those values.

An AX help string attributed visible proposals to Apple spelling and grammar. That attribution does not give an issue count.

"No surface" means that no Flow surface was visible during the stated window. It does not prove an internal terminal reason.

The separate Foundation Models probe in case 15 did not operate through the signed editor. It supports only the stated fail-closed explanation.

AX labels and custom actions were inspected. VoiceOver spoken order was not tested. Apple Writing Tools proofreading output was not tested.

## Direct-run summary

- Direct signed-app cases: 20.
- Exact cases with the complete expected final text: 5 of 14.
- Exact cases with no Flow surface: 6 of 14.
- Exact cases with an incomplete or incorrect accepted proposal: 3 of 14.
- Protected cases with no mutation: 5 of 5.
- Long-model case: one explained safe rejection.
- Visible Flow surfaces: 8.
- Visible direct surfaces: 7.
- Visible review-only surfaces: 1.
- Median visible-proposal latency: 450 ms.
- Slowest visible-proposal latency: 481 ms.
- No-surface observation windows: 3,100 ms through 7,121 ms.

## Numbered cases

### Case 01 — `repair-exact-001`

~~~text
I will brnig the keys when I meet you outside.
~~~

- Input: typed. Trigger: punctuation `.`.
- Diagnostics: the issue count, request owner, and terminal reason were not exposed.
- Proposal: `I will bring the keys when I meet you outside.`
- Surface: direct at 481 ms. AX attributed it to Apple spelling and grammar.
- Final text: `I will bring the keys when I meet you outside.`
- Undo and redo: undo restored the trigger text. Redo restored the accepted text.
- Result: PASS. The complete expected correction was visible before acceptance.

### Case 02 — `repair-exact-002`

~~~text
The release notes is ready for review by the support team.
~~~

- Input: pasted. Trigger: punctuation `.`.
- Diagnostics: the issue count, request owner, and terminal reason were not exposed.
- Proposal: no visible proposal during a 3,100 ms observation window.
- Surface: none. This window was shorter than the later 7-second windows.
- Final text: unchanged from the trigger text.
- Undo: not applicable because Flow made no change.
- Result: FAIL. This exact case produced an unexplained no-result.

### Case 03 — `repair-exact-003`

~~~text
I attached a updated estimate for the client meeting.
~~~

- Input: typed. Trigger: punctuation `.`.
- Diagnostics: the issue count, request owner, and terminal reason were not exposed.
- Proposal: no visible proposal during a 6,985 ms observation window.
- Surface: none.
- Final text: unchanged from the trigger text.
- Undo: not applicable because Flow made no change.
- Result: FAIL. This exact case produced an unexplained no-result.

### Case 04 — `repair-exact-004`

~~~text
After the demo we will collect questions from the design team.
~~~

- Input: pasted. Trigger: punctuation `.`.
- Diagnostics: the issue count, request owner, and terminal reason were not exposed.
- Proposal: no visible proposal during a 6,893 ms observation window.
- Surface: none.
- Final text: unchanged from the trigger text.
- Undo: not applicable because Flow made no change.
- Result: FAIL. This exact case produced an unexplained no-result.

### Case 05 — `repair-exact-005`

~~~text
I need to rescheduel my appointment because I have a fever.
~~~

- Input: typed. Trigger: punctuation `.`.
- Diagnostics: the issue count, request owner, and terminal reason were not exposed.
- Proposal: `I need to reschedule my appointment because I have a fever.`
- Surface: direct at 450 ms. AX attributed it to Apple spelling and grammar.
- Final text: `I need to reschedule my appointment because I have a fever.`
- Undo and redo: undo restored the trigger text. Redo restored the accepted text.
- Result: PASS. The complete expected correction was visible before acceptance.

### Case 06 — `repair-exact-013`

~~~text
The enginers is testing the backup process before tonight.
~~~

- Input: pasted. Trigger: punctuation `.`.
- Diagnostics: the issue count, request owner, and terminal reason were not exposed.
- Proposal: `The engineers are testing the backup process before tonight.`
- Surface: direct at 448 ms. AX attributed it to Apple spelling and grammar.
- Final text: `The engineers are testing the backup process before tonight.`
- Undo and redo: undo restored the trigger text. Redo restored the accepted text.
- Result: PASS. The complete expected correction was visible before acceptance.

### Case 07 — `repair-exact-014`

~~~text
We scheduled an review in Monday for the new prototype.
~~~

- Input: typed. Trigger: punctuation `.`.
- Diagnostics: the issue count, request owner, and terminal reason were not exposed.
- Proposal: no visible proposal during a 6,992 ms observation window.
- Surface: none.
- Final text: unchanged from the trigger text.
- Undo: not applicable because Flow made no change.
- Result: FAIL. This exact case produced an unexplained no-result.

### Case 08 — `repair-exact-015`

~~~text
after lunch Priya will chekc the figures and send the summary.
~~~

- Input: pasted. Trigger: punctuation `.`.
- Diagnostics: the issue count, request owner, and terminal reason were not exposed.
- Proposal: `after lunch Priya will check the figures and send the summary.`
- Surface: direct at 475 ms. AX attributed it to Apple spelling and grammar.
- Final text: `after lunch Priya will check the figures and send the summary.`
- Undo and redo: undo restored the trigger text. Redo restored the accepted text.
- Result: FAIL. The accepted proposal omitted the expected capitalization and comma changes.

### Case 09 — `repair-exact-016`

The fixed corpus input was `Can you confrim the adress before we leave.`

~~~text
Can you confirm the address before we leave.
~~~

- Input: typed. Trigger: punctuation `.`.
- Native behavior: AppKit changed `confrim` and `adress` before the trigger.
- Diagnostics: the issue count, request owner, and terminal reason were not exposed.
- Proposal: no visible proposal during a 6,958 ms observation window.
- Surface: none.
- Final text: unchanged from the trigger text.
- Undo: not applicable because Flow made no change.
- Result: FAIL. Native correction fixed two spellings, but Flow did not propose the expected question mark.

### Case 10 — `repair-exact-017`

~~~text
The meeting notes was uploded to the shared folder.
~~~

- Input: pasted. Trigger: punctuation `.`.
- Diagnostics: the issue count, request owner, and terminal reason were not exposed.
- Proposal: `The meeting notes were uploaded to the shared folder.`
- Surface: direct at 450 ms. AX attributed it to Apple spelling and grammar.
- Final text: `The meeting notes were uploaded to the shared folder.`
- Undo and redo: undo restored the trigger text. Redo restored the accepted text.
- Result: PASS. The complete expected correction was visible before acceptance.

### Case 11 — `repair-exact-021`

AppKit changed `critcal` to `critical` during entry. The value at the trigger was:

~~~text
The tehcnical review found no critical risks during the first pass,
but the second revieiw found a critical deployment warning.
~~~

- Input: typed. Trigger: punctuation `.`.
- Diagnostics: the issue count, request owner, and terminal reason were not exposed.
- Proposal: `The technical review found no critical risks during the first pass,` followed by `but the second review found a critical deployment warning.`
- Surface: direct at 436 ms. AX attributed it to Apple spelling and grammar.
- Final text: `The technical review found no critical risks during the first pass,` followed by `but the second review found a critical deployment warning.`
- Undo and redo: undo restored the post-native trigger value. Redo restored the accepted text.
- Result: PASS. Flow applied its two visible changes atomically after the native change.

### Case 12 — `repair-exact-022`

~~~text
In the final note, Sofia asked,
“Is the packages ready for the Berlin office.”
~~~

- Input: pasted. Trigger: punctuation `.` followed by one closing delimiter.
- Diagnostics: the issue count, request owner, and terminal reason were not exposed.
- Proposal: no visible proposal during a 6,999 ms observation window.
- Surface: none.
- Final text: unchanged from the trigger text.
- Undo: not applicable because Flow made no change.
- Result: FAIL. This exact case produced an unexplained no-result.

### Case 13 — `repair-exact-023`

~~~text
The release checklist [verfy backups and notifiy owners] is ready for the rehearsal,
and Project Cedar have no other blocking issue.
~~~

- Input: typed. Trigger: punctuation `.`.
- Diagnostics: the issue count, request owner, and terminal reason were not exposed.
- Proposal: `The release checklist [very backups and notify owners] is ready for the rehearsal,` followed by `and Project Cedar have no other blocking issue.`
- Surface: direct at 469 ms. AX attributed it to Apple spelling and grammar.
- Final text: the two proposal lines shown above. Flow applied `verfy` to `very` and `notifiy` to `notify`.
- Undo and redo: undo restored the trigger text. Redo restored the incorrect accepted text.
- Result: FAIL. The app showed and applied the unsafe `verfy` to `very` change.

### Case 14 — `repair-exact-024`

~~~text
After the first rehearsal the release managers cheked every backup, the support leads confirms the escalation list, and the documentation team publshed the recovery steps so each owner could review the plan before the scheduled maintenance window on September 4, 2026.
~~~

- Input: pasted. Trigger: punctuation `.`.
- Diagnostics: the issue count, request owner, and terminal reason were not exposed.
- Proposal: `After the first rehearsal the release managers checked every backup, the support leads confirms the escalation list, and the documentation team published the recovery steps so each owner could review the plan before the scheduled maintenance window on September 4, 2026.`
- Surface: review-only at 435 ms in the first run. The detailed replay showed the cue at 468 ms.
- Review AX: one `Writing correction review` group contained complete Original and Corrected rows.
- Review AX: it also contained two exact change rows, Cancel, Replace, and quiet source help.
- Final text: Replace applied the displayed proposal once.
- Undo and redo: undo restored the trigger text. Redo restored the accepted text.
- Result: FAIL for correction completeness. The review interaction passed, but the proposal omitted the comma and agreement changes.

### Case 15 — `repair-ai-001`

~~~text
I am nt be able to come today because yesterday I got sick so badly and now cannot get out of the bed wirhgth now.
~~~

- Input: typed. Trigger: punctuation `.`.
- Diagnostics: the issue count, request owner, and terminal reason were not exposed.
- Proposal: no visible proposal during a 7,022 ms observation window.
- Surface: none. The signed editor made no change.
- Independent probe: the production prompt returned `I am not able to come today because yesterday I got sick so badly that I cannot get out of bed with now.`
- Independent probe: the editor validator rejected that semantically invalid candidate.
- Final text: unchanged from the trigger text.
- Undo: not applicable because Flow made no change.
- Result: explained safe rejection. The fail-closed explanation comes from the independent probe, not the signed UI.

### Case 16 — `repair-protected-001`

~~~text
Use `tehFlag` in the example before running the command.
~~~

- Input: pasted. Trigger: punctuation `.`.
- Diagnostics: the issue count, request owner, and terminal reason were not exposed.
- Proposal: no visible proposal during a 7,121 ms observation window.
- Surface: none.
- Final text: protected content stayed byte-exact. Only the separate trigger was added.
- Undo: not applicable because Flow made no change.
- Result: PASS as a safe rejection.

### Case 17 — `repair-protected-002`

~~~markdown
Keep this sample unchanged:
```swift
func load() { retrun value }
```
Then continue with the explanation.
~~~

- Input: typed. Trigger: Return.
- Diagnostics: the issue count, request owner, and terminal reason were not exposed.
- Proposal: no visible proposal during a 7,097 ms observation window.
- Surface: none.
- Final text: protected content stayed byte-exact.
- Undo: not applicable because Flow made no change.
- Result: PASS as a safe rejection.

### Case 18 — `repair-protected-003`

~~~markdown
Open the reference at [the guide](https://example.com/teh-guide) after the meeting.
~~~

- Input: pasted. Trigger: punctuation `.`.
- Diagnostics: the issue count, request owner, and terminal reason were not exposed.
- Proposal: no visible proposal during a 7,075 ms observation window.
- Surface: none.
- Final text: the Markdown destination stayed byte-exact. Only the separate trigger was added.
- Undo: not applicable because Flow made no change.
- Result: PASS as a safe rejection.

### Case 19 — `repair-protected-004`

~~~text
Visit https://teh.example.com/releases before updating the launch checklist.
~~~

- Input: typed. Trigger: punctuation `.`.
- Diagnostics: the issue count, request owner, and terminal reason were not exposed.
- Proposal: no visible proposal during a 7,109 ms observation window.
- Surface: none.
- Final text: the URL stayed byte-exact. Only the separate trigger was added.
- Undo: not applicable because Flow made no change.
- Result: PASS as a safe rejection.

### Case 20 — `repair-protected-005`

~~~text
Send the receipt to teh.user@example.com after lunch today.
~~~

- Input: pasted. Trigger: punctuation `.`.
- Diagnostics: the issue count, request owner, and terminal reason were not exposed.
- Proposal: no visible proposal during a 7,093 ms observation window.
- Surface: none.
- Final text: the email address stayed byte-exact. Only the separate trigger was added.
- Undo: not applicable because Flow made no change.
- Result: PASS as a safe rejection.

## Review and Writing Tools

The detailed case 14 replay exposed exactly one review group through AX. No second inline surface was visible in the main window.

The compact editor actions remained in AX during review. The compact inline surface was not visible.

On a live case 01 cue, Edit > Show Writing Tools opened the system Writing Tools popover. AX showed the system popover.

The Flow surface and its AX help and actions disappeared immediately. The editor text stayed unchanged.

Escape closed Writing Tools. No Flow surface returned during the next 2,200 ms.

This observation proves priority and visible exclusivity only. It does not test a Writing Tools proofreading result.
