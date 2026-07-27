# Cloud-assisted transcription decision

## Speaker-recovery approach registry

This decision remains a provider gate, not authorization to download a model,
upload audio, or make a paid API call.

| ID | Approach family | Distinct mechanism | Status | Evidence | Exact gap | Reopen condition |
|---|---|---|---|---|---|---|
| S1 | Local SpeakerKit | Offline diarization clusters reconciled against WhisperKit word timestamps | Active boundary implemented | Provider-neutral word reconciliation and honest degraded fallback have focused tests | SpeakerKit model provisioning and real multi-speaker benchmark remain gated | A reviewed model packaging/provisioning plan and benchmark corpus |
| S2 | Separated capture channels | Preserve microphone and system ASR as source evidence even when diarization is unavailable | Survives contract tests | Mixed audio is now used only when no usable primary transcript exists | A channel is not a person; microphone attribution cannot confirm identity | Never promote source routing to identity without additional evidence |
| S3 | Manual correction | Append-only, content-hash-scoped speaker rename/undo events | Active boundary implemented | Events target stable speaker IDs without rewriting immutable ASR evidence | Session-scoped only; no automatic cross-session identity matching | A consented identity design and evaluation set |
| S4 | Cloud-assisted diarization | Provider returns word/speaker metadata | Research gate only | Quality, privacy, latency, and price comparison below | No provider selected or enabled | Explicit provider decision after local benchmark |

Minimum acceptance before any provider becomes the default:

1. Word order and text survive speaker-boundary splitting.
2. Ties, gaps, and engines without word timestamps remain explicitly uncertain.
3. Missing diarization never causes usable separated-source ASR to be discarded.
4. Source attribution and person identity remain separate claims.
5. Manual corrections are append-only, undoable, and scoped to the immutable
   evidence content hash.
6. A real two-to-four-speaker bilingual benchmark beats the current baseline
   without hidden audio uploads or silent fallback.

### Cleared local provisioning boundary

The local SpeakerKit lane is pinned to SDK `0.18.0` (`e2adabbe`) and the
`argmaxinc/speakerkit-coreml` snapshot
`86ec9c929b52208b6656eb6a6361ed0d822a1f78`. Cepessa downloads this snapshot
on demand into staging, validates the four required Core ML bundles, writes an
installation manifest, and only then atomically activates it. Inference uses
the verified local root with SDK downloads disabled, so meeting audio has no
network path through this feature.

The Settings attribution identifies the upstream model source and pinned
revision. It does not claim that Cepessa owns the models or has redistribution
rights, and model weights are not bundled with the app.

**Status:** decision gate only; no provider is enabled and no audio was uploaded
**Sources accessed:** 2026-07-27
**Scope:** final-output transcription for Hebrew-English meetings, including
speaker attribution. Live transcription is not the promotion target.

## Decision

Keep Cepessa local-first. The default path remains independent `mic.wav` and
`system.wav` transcription with local WhisperKit, local SpeakerKit diarization,
immutable evidence, and truthful quality gates.

For a non-sensitive meeting whose local result fails an explicit quality gate,
the best cloud candidate to benchmark is:

1. `gpt-4o-mini-transcribe` for only the uncertain time ranges;
2. escalate only unresolved ranges to `gpt-4o-transcribe`;
3. use `gpt-4o-transcribe-diarize` only when local speaker attribution also
   failed and speaker-aware cloud output is necessary.

This is a benchmark recommendation, not authorization to integrate OpenAI.
Promotion requires Cepessa's frozen Hebrew-English test set to prove an
improvement in omissions, insertions, names, code-switches, timestamps, and
speaker errors. No provider publishes a directly comparable official Hebrew
meeting benchmark, so every quality ranking below is an inference until that
test exists.

Amazon Transcribe is the only additional candidate worth keeping in the
benchmark: its official documentation explicitly supports Hebrew and English
multi-language identification in one file and speaker diarization. Deepgram
Nova-3 and Google Chirp 3 do not currently satisfy the complete Cepessa
requirement on their documented production surfaces.

## Current local baseline

Cepessa now has the right architecture for the default:

- separate local transcription of microphone and system tracks;
- multilingual WhisperKit rather than a mixed-master-only transcript;
- offline SpeakerKit clustering with stable anonymous speaker IDs;
- no network transfer or marginal API cost;
- original audio and raw ASR remain immutable.

The local path is also the only path that can be the privacy default. Its
remaining uncertainty is empirical quality and device latency, not data
handling. The frozen Cepessa benchmark must determine whether the chosen
compressed Whisper model is good enough for Hebrew, English, code-switches,
names, omissions, and long meetings.

## Provider fit

| Candidate | Hebrew + English | Code-switching | Speaker handling | Final-output features | Fit |
| --- | --- | --- | --- | --- | --- |
| Local WhisperKit + SpeakerKit | Multilingual Whisper locally | Supported by the underlying multilingual model; Cepessa-specific accuracy still unproven | Local clusters, stable anonymous IDs; actual names require separate evidence | Segment timing, independent channels, immutable revisions; custom prompts are under Cepessa control | **Default** |
| OpenAI `gpt-4o-mini-transcribe` / `gpt-4o-transcribe` | The Transcriptions endpoint [lists Hebrew and English](https://developers.openai.com/api/docs/guides/speech-to-text#supported-languages) | Multilingual transcription is supported, but OpenAI publishes no Hebrew-English code-switch score | The normal models have no built-in speaker labels; `gpt-4o-transcribe-diarize` adds them | Normal models support prompts and logprobs. Diarize returns speaker, segment start/end, and accepts up to four 2–10 second known-speaker references, but does not support prompts, logprobs, or word timestamps ([guide](https://developers.openai.com/api/docs/guides/speech-to-text#identify-speakers)) | **Best cloud benchmark candidate** |
| Amazon Transcribe batch | Official multi-language identification includes `he-IL` and English and explicitly handles speakers changing languages ([docs](https://docs.aws.amazon.com/transcribe/latest/dg/lang-id-batch.html)) | Explicitly supported in batch | Up to 30 anonymous speakers with word/utterance timestamps ([docs](https://docs.aws.amazon.com/transcribe/latest/dg/diarization.html)) | Word timestamps/confidence; language identification and diarization included in standard price. Multi-language mode does not support custom language models | **Second benchmark candidate** |
| Deepgram Nova-3 | Hebrew is available as monolingual `he` | **Not eligible:** Nova-3's documented `language=multi` list is English, Spanish, French, German, Hindi, Russian, Portuguese, Japanese, Italian, and Dutch; Hebrew appears only as a monolingual option ([model list](https://developers.deepgram.com/docs/models-languages-overview), [code-switch guide](https://developers.deepgram.com/docs/multilingual-code-switching)) | Diarization is available for Nova batch/streaming and returns word-level speaker confidence ([docs](https://developers.deepgram.com/docs/diarization)) | Word timing/confidence, smart formatting, and up to 100 keyterms ([docs](https://developers.deepgram.com/docs/keyterm)) | **Reject for Hebrew-English meetings until Hebrew joins `multi`** |
| Google Cloud STT V2, Chirp 3 | Hebrew `iw-IL` is only Preview; English is GA | The documented automatic mode transcribes the **dominant/prevalent** language, not a verified per-span Hebrew-English transcript | **Not eligible:** Hebrew is absent from Chirp 3's diarization-language list ([docs](https://docs.cloud.google.com/speech-to-text/docs/models/chirp-3#language_availability_for_diarization)) | Phrase biasing and a Preview formatting prompt; word timestamps can degrade transcription and returned word confidence is not a true confidence score ([limitations](https://docs.cloud.google.com/speech-to-text/docs/models/chirp-3#feature_support_and_limitations)) | **Reject for current requirement** |

### Quality evidence and its limits

- OpenAI states that GPT-4o transcription improves WER, language recognition,
  accents, noise, and speech-rate robustness over Whisper
  ([official announcement](https://openai.com/index/introducing-our-next-generation-audio-models/)).
  It does not publish Cepessa-comparable Hebrew, code-switch, or diarization
  scores. Treat “best cloud candidate” as a product-fit inference.
- Deepgram reports large aggregate Nova-3 WER improvements, but its documented
  multilingual test set and `multi` surface do not include Hebrew. Those claims
  cannot establish Hebrew-English quality for Cepessa.
- Google describes Chirp 3 as more accurate and faster, but Hebrew remains
  Preview and is excluded from diarization. There is no comparable official
  Hebrew meeting score.
- AWS documents the exact required feature combination, but publishes no
  comparable current Hebrew meeting WER/DER. It is a useful challenger, not a
  quality winner by documentation.

## Privacy and data handling

| Path | Training / improvement | Retention and location | Required Cepessa posture |
| --- | --- | --- | --- |
| Local | None | Audio and evidence stay on the user's Mac | Default for every meeting |
| OpenAI Audio Transcriptions | API data is not used for training unless the customer opts in. The current endpoint table says `/v1/audio/transcriptions` has no abuse-monitoring retention and no application-state retention and is Zero Data Retention eligible ([data controls](https://developers.openai.com/api/docs/guides/your-data#default-usage-policies-by-endpoint)) | Regional processing documentation currently names `gpt-4o-transcribe` and `gpt-4o-mini-transcribe`; it does not list the diarize model in that regional model table. Do not assume regional diarize processing without written confirmation | Upload only consent-eligible ranges; never upload by default; do not send known-speaker voice references without separate biometric consent |
| AWS Transcribe | By default, AWS stores and uses processed voice inputs for service improvement; an AWS Organizations policy opts out and removes historical improvement copies ([Transcribe opt-out](https://docs.aws.amazon.com/transcribe/latest/dg/opt-out.html), [policy behavior](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_ai-opt-out.html)) | Batch jobs require S3 input/output objects, whose retention is customer-controlled | Provider is ineligible until account-level AI-service opt-out is verified and input/output lifecycle deletion is enforced |
| Deepgram | `mip_opt_out=true` excludes a request from model improvement and retains data only as needed to process it; since 2026-03-05 opt-out does not change listed PAYG pricing ([program](https://developers.deepgram.com/docs/the-deepgram-model-improvement-partnership-program), [pricing update](https://developers.deepgram.com/changelog/2026/3/5)) | Dedicated EU endpoint is available ([pricing/security](https://deepgram.com/pricing)) | Still feature-ineligible for Hebrew-English code-switch meetings |
| Google Cloud STT | By default, Cloud STT does not log customer audio or transcripts; logging for model improvement is an explicit opt-in ([data logging](https://docs.cloud.google.com/speech-to-text/docs/v1/data-logging)) | Batch audio longer than 60 seconds is stored in customer Cloud Storage; EU and US regional endpoints are documented ([batch](https://docs.cloud.google.com/speech-to-text/docs/batch-recognize), [regional endpoints](https://docs.cloud.google.com/speech-to-text/docs/v1/endpoints)) | Keep data logging disabled and use short-lived storage lifecycle rules; still feature-ineligible |

OpenAI currently has the cleanest documented API data posture for this narrow
endpoint. That does not make cloud equivalent to local privacy: audio still
leaves the device, and known-speaker reference clips are biometric evidence.

## Latency and workflow

| Candidate | Relevant mode | Implication for final transcript |
| --- | --- | --- |
| Local | Post-meeting on-device | No network dependency; completion time depends on Mac/model and must be measured on 30/60/120-minute soaks |
| OpenAI | Completed-file transcription can stream output over SSE. The diarize model emits completed segments but is not supported by the Realtime API ([guide](https://developers.openai.com/api/docs/guides/speech-to-text#identify-speakers)) | Good fit for bounded post-meeting retries; not a reason to replace the local live indicator |
| AWS | Batch from S3 or streaming | Batch fits final-output retries but adds upload, job polling, and object lifecycle work |
| Deepgram | Pre-recorded REST or live streaming | Operationally fast/flexible, but current Hebrew code-switch gap is disqualifying |
| Google | Sync under one minute; batch for longer files; dynamic batch trades lower cost for higher latency | Standard batch needs Cloud Storage. Dynamic batch is suitable only when delayed final output is acceptable |

## Pricing normalized to recorded audio

USD, pay-as-you-go, excluding taxes, network transfer, and object storage.
Google numbers use the first V2 tier (the largest modeled band below is 60,000
minutes, below its 500,000-minute threshold). AWS uses US East (N. Virginia).

| Configuration | Official price/min | Price/recorded hour | Notes |
| --- | ---: | ---: | --- |
| Local WhisperKit + SpeakerKit | $0 | $0 | Mac time/energy excluded |
| OpenAI `gpt-4o-mini-transcribe` | $0.003 estimated | $0.18 estimated | Official pricing is token-based; OpenAI publishes this estimated minute cost |
| OpenAI `gpt-4o-transcribe` | $0.006 estimated | $0.36 estimated | [Official pricing](https://developers.openai.com/api/docs/pricing#transcription-models) |
| OpenAI `gpt-4o-transcribe-diarize` | not published as a fixed minute tariff | **$0.36 planning estimate** | Its official model page lists the same $2.50/M input and $10/M output token rates as `gpt-4o-transcribe` ([model](https://developers.openai.com/api/docs/models/gpt-4o-transcribe-diarize)); actual billed tokens must be measured |
| AWS Transcribe standard batch | $0.006 | $0.36 | Current pricing includes language identification and diarization and bills by second, 15-second minimum ([pricing](https://aws.amazon.com/transcribe/pricing/)) |
| Deepgram Nova-3 multilingual, pre-recorded + diarization | $0.0092 + $0.0020 = $0.0112 | $0.672 | Add keyterm prompting: +$0.0013/min, total $0.75/hour ([pricing](https://deepgram.com/pricing)) |
| Google V2 standard | $0.016 | $0.96 | Storage extra |
| Google V2 dynamic batch | $0.003 | $0.18 | Higher latency, batch only; storage extra ([pricing](https://cloud.google.com/speech-to-text/pricing)) |

### Monthly cost if every recorded minute is sent once

| Recorded hours/month | OpenAI mini | OpenAI full | AWS batch | Deepgram + diarization | Deepgram + diarization + keyterms | Google dynamic | Google standard |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | $1.80 | $3.60 | $3.60 | $6.72 | $7.50 | $1.80 | $9.60 |
| 50 | $9.00 | $18.00 | $18.00 | $33.60 | $37.50 | $9.00 | $48.00 |
| 200 | $36.00 | $72.00 | $72.00 | $134.40 | $150.00 | $36.00 | $192.00 |
| 1,000 | $180.00 | $360.00 | $360.00 | $672.00 | $750.00 | $180.00 | $960.00 |

### Recommended uncertainty-triggered budget

Planning assumptions:

- 20% of recorded duration is marked uncertain and uniquely uploaded;
- every uploaded range gets one OpenAI mini pass;
- 25% of the uploaded duration (5% of all recorded audio) remains unresolved
  and gets one full/diarize pass;
- cost per recorded hour =
  `(0.20 × $0.18) + (0.05 × $0.36) = $0.054`;
- unique audio leaving the Mac is 20%; provider-processed audio, counting the
  second pass, is 25%.

| Recorded hours/month | Unique hours uploaded | Billable processed hours | Estimated cloud cost |
| ---: | ---: | ---: | ---: |
| 10 | 2 | 2.5 | $0.54 |
| 50 | 10 | 12.5 | $2.70 |
| 200 | 40 | 50 | $10.80 |
| 1,000 | 200 | 250 | $54.00 |

These percentages are budget parameters, not a target. A trustworthy quality
gate should drive them down and must cap both unique uploaded duration and
second-pass duration per meeting. A whole-meeting one-pass OpenAI full fallback
is $0.36 per recorded hour; it should be exceptional and explicit.

## Routing policy

| Meeting / result | Default route | Cloud action |
| --- | --- | --- |
| Ordinary meeting; local capture complete; transcript passes quality gates | Local | None |
| Sensitive, legal, medical, HR, credential, confidential-client, or participant-disallowed meeting | Local-only | Never upload; surface uncertainty for human correction |
| Hebrew-English meeting with a few low-confidence or language-confused ranges, participant cloud consent present, no sensitive content | Local first | Mini retry for exact bounded ranges only |
| Bounded ranges still fail after mini, or contain critical names/numbers/negation | Local evidence remains authoritative pending review | Full retry for only those ranges; compare, never silently overwrite |
| Local diarization fails on a non-sensitive consented range | Local stable anonymous IDs remain the safe fallback | Benchmark diarize only for that range; cloud names are candidates, never identity authority |
| Capture is missing, malformed, stalled, truncated, or unexpectedly silent | Not ready | Cloud cannot repair audio that was never captured; do not upload |
| Severe whole-meeting local ASR failure, non-sensitive, explicit per-meeting consent | Local run retained | Offer a deliberate whole-meeting cloud retry with displayed scope/cost before upload |

Cloud output must be stored as a separate immutable ASR run with provider,
model, parameters, hashes, uploaded ranges, cost/usage, and timestamps. A
deterministic comparison or user-approved correction may become the active
revision; cloud text must never silently replace local evidence.

## Promotion gate

Before any provider integration:

1. Compare local, OpenAI mini/full/diarize, and AWS batch on the same locked
   non-sensitive or explicitly consented Hebrew-English corpus.
2. Score WER/CER, deletions, insertions, code-switch WER, named-term recall,
   timestamp coverage, DER, speaker consistency, hallucination on silence,
   latency, actual token/minute cost, and upload percentage.
3. Require material improvement over local on failed ranges, not merely a
   better-looking transcript.
4. Verify provider account data controls: OpenAI project controls, or AWS
   organization-wide Transcribe opt-out and S3 lifecycle deletion.
5. Keep cloud disabled when offline, when consent is absent, when privacy class
   forbids it, or when the monthly/per-meeting upload budget is exceeded.

**Final recommendation:** build the decision boundary and benchmark contract,
not a provider integration. If the locked evaluation confirms the official
product-fit inference, use OpenAI as an uncertainty-triggered, range-bounded
assistant behind local Cepessa evidence. Keep AWS as the challenger. Do not
promote Deepgram or Chirp 3 for Hebrew-English diarized meetings on their
currently documented capabilities.
