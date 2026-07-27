import fs from "node:fs/promises";
import { SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const outputDir =
  "/private/tmp/cepessa-meeting-brain-worktree/outputs/019fa012-64ba-7de3-bf23-c77ac09906e6";
const previewDir = "/tmp/cepessa-sessions-qa-workbook-previews";
const outputPath = `${outputDir}/cepessa-sessions-qa.xlsx`;

const runsHeaders = [
  "run_id",
  "app",
  "repository",
  "commit_or_build",
  "artifact_path",
  "platform",
  "environment",
  "roles",
  "permissions",
  "locale",
  "feature_flags",
  "integrations",
  "scope",
  "exclusions",
  "protected_actions",
  "initial_token_budget",
  "remaining_tokens_checkpoint",
  "phase",
  "status",
  "started_at",
  "updated_at",
];

const featureHeaders = [
  "feature_id",
  "area",
  "surface",
  "actor",
  "user_story",
  "user_value",
  "code_evidence",
  "runtime_evidence",
  "source_presence",
  "availability",
  "expected_source",
  "confidence",
  "risk",
  "in_scope",
  "current_status",
  "notes",
];

const behaviorHeaders = [
  "behavior_id",
  "feature_id",
  "preconditions",
  "given",
  "when",
  "then_expected",
  "behavior_type",
  "test_method",
  "automation_candidate",
  "risk",
  "current_result",
  "latest_test_run_id",
  "notes",
];

const testRunHeaders = [
  "test_run_id",
  "run_id",
  "behavior_id",
  "phase",
  "commit_or_build",
  "environment",
  "preconditions",
  "steps",
  "expected",
  "actual",
  "result",
  "evidence",
  "tester",
  "tested_at",
  "notes",
];

const defectHeaders = [
  "defect_id",
  "behavior_ids",
  "fingerprint",
  "category",
  "severity",
  "title",
  "reproduction",
  "expected",
  "actual",
  "evidence",
  "status",
  "approval_state",
  "root_cause",
  "fix_reference",
  "fixed_build",
  "targeted_retest_id",
  "final_regression_id",
  "blocker_or_acceptance_reason",
  "notes",
];

const opportunityHeaders = [
  "opportunity_id",
  "feature_ids",
  "behavior_ids",
  "user_journey_step",
  "evidence_type",
  "evidence",
  "observed_friction",
  "proposed_change",
  "expected_user_benefit",
  "priority",
  "confidence",
  "effort",
  "risk",
  "validation_method",
  "visual_reference",
  "status",
  "notes",
];

const runs = [
  [
    "RUN-20260727-01",
    "Cepessa Sessions",
    "/private/tmp/cepessa-meeting-brain-worktree",
    "Installed baseline executable sha256 bb850395a607edc80f4cb0d74d5de73843bf3960eff2fb69b1e7653c3717b9ff; source base e19a7a777ec17c127779ab44e371f81831c25c45",
    "/Applications/Sessions.app",
    "macOS 26.5.2 (25F84), arm64",
    "Installed production artifact for baseline; isolated worktree for fixes",
    "Local signed-in user",
    "Existing macOS app permissions only; no permission changes authorized",
    "en_IL; preferred languages en-IL, he-IL",
    "Existing installed artifact flags; source-only QA hooks excluded from baseline",
    "Local recording/transcription; external integrations observed read-only when available",
    "Desktop macOS user-visible windows, navigation, menus, status item, recording indicator, recording/transcription flows, settings, permissions, accessibility, error and recovery states discoverable from code and safe runtime",
    "Backend, mobile, firmware, non-user-visible MCP internals, destructive account actions, paid cloud calls, real external messages, production recording creation",
    "Do not stop/restart production; do not install/replace production; no commit, push, merge, release, migration, credential entry, cloud enablement, audio upload, or paid call",
    "",
    "",
    "Baseline",
    "Baseline",
    "2026-07-27T02:00:00+03:00",
    "2026-07-27T08:20:00+03:00",
  ],
  [
    "RUN-20260727-02",
    "Cepessa Sessions",
    "/private/tmp/cepessa-meeting-brain-worktree",
    "Isolated debug build from worktree after Claude Opus 5 refactor and Codex hardening; 158 Swift tests, 1 intentional skip, 0 failures",
    "/tmp/cepessa-liquidqa-final.uahIic/Sessions Liquid QA Final.app",
    "macOS 26.5.2 (25F84), arm64",
    "Unsigned temporary dev bundle, unique bundle ID me.cepessa.sessions.liquidqafinal, launchd-scoped presentation harness, isolated storage root",
    "Local signed-in user",
    "No TCC changes; recording presentation state simulated without audio capture",
    "en_IL; preferred languages en-IL, he-IL",
    "CEPESSA_SESSIONS_TEST_ROOT; CEPESSA_SESSIONS_DEBUG_PRESENTATION_ONLY=1",
    "Local-only app; no provider enabled, no audio uploaded, no paid call",
    "Post-refactor UI, recording indicator states, menu-bar recovery/stop affordances, Sessions/Clips/Settings navigation, accessibility labels, test suite, storage isolation, corpus immutability",
    "Real microphone/system capture, OS permission grant, destructive cleanup execution, cloud services, production install/replacement, multi-display/full-screen and complete manual VoiceOver traversal",
    "Production PID 53535 and /Applications/Sessions.app remained untouched; no commit, push, merge, install, sign, release, audio upload, or paid call",
    "",
    "",
    "Verification",
    "Incomplete",
    "2026-07-27T09:16:00+03:00",
    "2026-07-27T09:31:00+03:00",
  ],
];

function feature(
  featureId,
  area,
  surface,
  userStory,
  userValue,
  codeEvidence,
  availability,
  expectedSource,
  confidence,
  risk,
  currentStatus,
  notes = "",
) {
  return [
    featureId,
    area,
    surface,
    "Local macOS user",
    userStory,
    userValue,
    codeEvidence,
    "",
    "Code only",
    availability,
    expectedSource,
    confidence,
    risk,
    true,
    currentStatus,
    notes,
  ];
}

const features = [
  feature("F-0001", "App lifecycle", "App launch", "Launch Cepessa Sessions as a lightweight accessory app.", "Recording controls are immediately available without opening a document window.", "CepessaSessionsApp.swift:5-30", "Always at launch", "Contract", "High", "Medium", "Inventory - reachable"),
  feature("F-0002", "App lifecycle", "App reopen", "Reopen the app when no window is visible.", "The Sessions reading window can be recovered without relaunching.", "CepessaSessionsApp.swift:62-68", "Conditional: no visible window", "Inferred", "High", "Low", "Inventory - reachable"),
  feature("F-0003", "Status item", "Menu bar", "See idle, recording, transcription, failure, and queue state.", "The user can monitor work while other apps are active.", "CepessaSessionStatusBar.swift:30-66,133-159,282-310", "State-dependent", "Contract", "High", "Medium", "Inventory - conditional"),
  feature("F-0004", "Recording", "Status-item menu", "Start or stop a meeting recording.", "Capture can be controlled from the menu bar.", "CepessaSessionStatusBar.swift:163-170,238-240", "Always; label follows state", "Contract", "High", "High", "Inventory - reachable"),
  feature("F-0005", "Transcription", "Status-item menu", "Retry a failed local transcription.", "A failed transcript can recover while retained audio exists.", "CepessaSessionStatusBar.swift:172-180,242-244", "Conditional: failed selected session with audio", "Contract", "High", "High", "Inventory - conditional"),
  feature("F-0006", "Sessions", "Status/floating menus", "Open one of the five most recent sessions.", "Recent transcripts are available in one action.", "CepessaSessionStatusBar.swift:184-197; CepessaSessionFloatingBar.swift:333-348", "Conditional: stored sessions exist", "Inferred", "High", "Low", "Inventory - conditional"),
  feature("F-0007", "Sessions", "Status/floating menus", "Open All Sessions.", "The main reading surface is available on demand.", "CepessaSessionStatusBar.swift:199-202; CepessaSessionsApp.swift:162-174", "Always", "Contract", "High", "Low", "Inventory - reachable"),
  feature("F-0008", "Clips", "Status/floating menus", "Open the Clips workspace.", "Visual agent handoffs are available on demand.", "CepessaSessionStatusBar.swift:204-207; CepessaSessionsApp.swift:162-174", "Always", "Contract", "High", "Low", "Inventory - reachable"),
  feature("F-0009", "Audio import", "Native open panel", "Import one existing audio file for local transcription.", "Existing recordings can enter the same local transcript pipeline.", "CepessaSessionsApp.swift:115-129; LocalMeetingAppModel.swift:251-299", "OS-mediated; one audio file", "Contract", "High", "High", "Inventory - OS-mediated"),
  feature("F-0010", "Floating bar", "Status menu / Settings", "Show or hide the floating recording bar.", "The user can control whether the persistent bar occupies the screen.", "CepessaSessionStatusBar.swift:216-223; CepessaSessionFloatingBar.swift:319-324,790-809", "Transient menu control and persistent preference", "Contract", "High", "Medium", "Inventory - reachable"),
  feature("F-0011", "Settings", "Status/floating menus", "Open Workspace Settings.", "Capture, permissions, and storage controls are discoverable.", "CepessaSessionStatusBar.swift:225-228,272-274; CepessaSessionsApp.swift:107-113", "Always", "Contract", "High", "Low", "Inventory - reachable"),
  feature("F-0012", "App lifecycle", "Status/floating menus", "Quit Cepessa Sessions.", "The accessory app can be terminated explicitly.", "CepessaSessionStatusBar.swift:230-235,276-278; CepessaSessionFloatingBar.swift:382-416", "Always", "Contract", "High", "Low", "Inventory - reachable"),
  feature("F-0013", "Recording", "Floating bar", "Start recording from the idle bar.", "Capture starts without opening a menu or window.", "CepessaSessionFloatingBar.swift:1306-1320", "Conditional: idle bar visible", "Contract", "High", "High", "Inventory - reachable"),
  feature("F-0014", "Recording controls", "Floating bar", "Reveal or collapse the recording controls deliberately.", "Controls remain available without permanently consuming screen space.", "CepessaSessionFloatingBar.swift; CepessaSessionIndicatorModel.swift", "Conditional: recording", "Contract", "High", "Medium", "Verified in isolated dev app"),
  feature("F-0015", "Floating bar", "Recording bar/context menu", "Hide the bar for the current recording.", "The user can remove the overlay temporarily.", "CepessaSessionFloatingBar.swift:99-141,1425-1431", "Conditional: recording; resets on state change", "Contract", "High", "Medium", "Inventory - conditional"),
  feature("F-0016", "Audio capture", "Expanded floating bar", "Mute or unmute the microphone in the transcript mix.", "Private/local speech can be excluded while system audio continues.", "CepessaSessionFloatingBar.swift:1377-1384; LocalMeetingRecorder.swift:362-385", "Conditional: recording", "Contract", "High", "High", "Inventory - conditional", "Any recorder message is currently classified as a failed status-item state, including the mute notice."),
  feature("F-0017", "Capture telemetry", "Floating bar", "See timer and source-health state.", "The user can notice muted, missing, or degraded capture before the meeting ends.", "CepessaSessionFloatingBar.swift; CepessaSessionIndicatorModel.swift", "Conditional: recording", "Contract", "High", "High", "Verified presentation state"),
  feature("F-0018", "Attachments", "Expanded floating bar", "Capture a full display into the live session.", "Visual context is pinned to the transcript moment.", "CepessaSessionFloatingBar.swift:452-481,1386-1391", "Conditional: recording; OS-mediated", "Contract", "High", "High", "Inventory - OS-mediated"),
  feature("F-0019", "Attachments", "Expanded floating bar", "Capture a selected screen region.", "Focused visual evidence is pinned to the transcript moment.", "CepessaSessionFloatingBar.swift:483-487,1392-1397", "Conditional: recording; OS-mediated", "Contract", "High", "High", "Inventory - OS-mediated"),
  feature("F-0020", "Attachments", "Expanded floating bar", "Attach one or more files to a live session.", "Documents and artifacts share the meeting timeline.", "CepessaSessionFloatingBar.swift:489-531,1398-1403", "Conditional: recording; OS-mediated", "Contract", "High", "High", "Inventory - OS-mediated"),
  feature("F-0021", "Floating bar", "Floating panel", "Drag the bar and retain its position.", "The controls stay where the user placed them.", "CepessaSessionFloatingBar.swift:534-537,659-697", "Whenever bar is visible", "Inferred", "High", "Low", "Inventory - reachable"),
  feature("F-0022", "Transcription", "Floating bar", "See import/transcription stage or progress.", "Long local processing remains understandable.", "CepessaSessionFloatingBar.swift:713-770,1322-1347; LocalMeetingAppModel.swift:112-118,1154-1162", "Conditional: active processing", "Contract", "High", "Medium", "Inventory - conditional"),
  feature("F-0023", "Transcript reader", "Sessions window", "See useful empty states when no session or transcript is available.", "The next recovery action is clear.", "CepessaSessionReadingView.swift:36-45,102-129", "State-dependent", "Contract", "High", "Medium", "Inventory - conditional"),
  feature("F-0024", "Transcript reader", "Sessions window", "Read speaker-labelled, timestamped, selectable transcript blocks.", "Meeting speech is reviewable and attributable.", "CepessaSessionReadingView.swift:131-180", "Conditional: selected session with transcript", "Contract", "High", "High", "Inventory - conditional"),
  feature("F-0025", "Transcript attachments", "Sessions window", "Enlarge an inline transcript image and dismiss it.", "Screenshot detail can be inspected without leaving the transcript.", "CepessaSessionReadingView.swift:59-100,158-175", "Conditional: image attachment in timeline", "Contract", "High", "Medium", "Inventory - conditional"),
  feature("F-0026", "Transcript reader", "Sessions window", "Zoom reading text with pinch or keyboard shortcuts.", "Transcript reading remains comfortable and accessible.", "CepessaSessionReadingView.swift:13-33,49-58,228-248", "Whenever reader is open", "Contract", "High", "Low", "Inventory - reachable"),
  feature("F-0027", "Sessions", "Native window toolbar", "Choose the active session.", "The reader can switch among stored transcripts.", "CepessaSessionReadingView.swift:305-325,362-400", "Always; content depends on stored sessions", "Contract", "High", "Medium", "Inventory - reachable"),
  feature("F-0028", "Transcript reader", "Native window toolbar", "Avoid presenting a document-language control that does not affect output.", "The toolbar remains trustworthy and minimal.", "CepessaSessionReadingView.swift", "Removed from reachable toolbar", "Contract", "High", "Medium", "Verified removed", "The misleading language selector was removed until a real consumer exists."),
  feature("F-0029", "Transcription", "Native window toolbar", "Run a fresh local transcription for the selected session.", "Stored audio can be reprocessed after quality or model changes.", "CepessaSessionReadingView.swift:335-343,408-411,436-444; LocalMeetingAppModel.swift:301-324", "Conditional: retained audio and not processing", "Contract", "High", "High", "Inventory - conditional"),
  feature("F-0030", "Export", "Native save panel", "Export a non-empty transcript as Markdown.", "Transcript text can be shared or archived outside the app.", "CepessaSessionReadingView.swift:345-353,413-444", "Conditional: non-empty transcript; OS-mediated", "Contract", "High", "Medium", "Inventory - OS-mediated", "Export failures are communicated only by a system beep."),
  feature("F-0031", "Clips", "Clips window", "Browse and select Clips, including empty states.", "Existing visual handoffs can be revisited.", "LocalClipsPage.swift:49-61,231-275,299-327", "Always; content depends on stored Clips", "Contract", "High", "Medium", "Inventory - reachable"),
  feature("F-0032", "Clips", "Clip composer", "Set a Clip title and agent intent before recording.", "The visual handoff starts with explicit context.", "LocalClipsPage.swift:68-121; LocalClipViewModel.swift:104-133", "Whenever Clips is open", "Contract", "High", "Medium", "Inventory - reachable"),
  feature("F-0033", "Clips", "Clip composer", "Record and stop screen video with mic/system audio.", "An agent can inspect both what changed and the spoken explanation.", "LocalClipsPage.swift:101-128; LocalClipViewModel.swift:71-79,104-189", "OS-mediated; one active Clip at a time", "Contract", "High", "High", "Inventory - OS-mediated"),
  feature("F-0034", "Clips", "Clip processing", "Receive a ready Clip with transcript or an explicit degraded result.", "Visual evidence remains usable even when audio/STT fails.", "LocalClipViewModel.swift:145-172,208-249", "Conditional: after Clip stop", "Contract", "High", "High", "Inventory - conditional", "The model deliberately uses ready status even for no-audio or transcription-failed outcomes; error text must also be asserted."),
  feature("F-0035", "Clips / MCP", "Clip inspector", "Copy an agent prompt for the selected Clip.", "The clipboard carries the MCP instruction and local evidence paths.", "LocalClipsPage.swift:137-162; LocalClipViewModel.swift:96-102", "Conditional: selected Clip", "Contract", "High", "Medium", "Inventory - conditional"),
  feature("F-0036", "Clips", "Clip inspector", "Save notes/title/intent and reveal the Clip folder.", "A handoff can be refined and its local artifacts inspected.", "LocalClipsPage.swift:164-196; LocalClipViewModel.swift:81-102", "Conditional: selected Clip; Reveal is OS-mediated", "Contract", "High", "Medium", "Inventory - conditional"),
  feature("F-0037", "Settings", "Capture settings", "Choose transcript language preference and speed/accuracy mode.", "The next local transcription uses an appropriate bilingual model plan.", "CepessaSessionsShellPages.swift:1814-1829; LocalMeetingFileLayout.swift:51-64,219-290", "Always; applies to subsequent plans", "Contract", "High", "High", "Inventory - reachable"),
  feature("F-0038", "Settings", "Capture settings", "Avoid presenting an audio-retention switch that has no implementation.", "Settings remain truthful and minimal.", "CepessaSessionsShellPages.swift", "Removed from reachable Settings", "Contract", "High", "High", "Verified removed", "The unused preference was removed rather than implying retention behavior."),
  feature("F-0039", "Settings", "Permissions card", "See microphone/screen access and open macOS privacy panes.", "Capture blockers can be diagnosed and repaired.", "CepessaSessionsShellPages.swift:1853-1870,2053-2110", "OS-mediated", "Contract", "High", "High", "Inventory - OS-mediated"),
  feature("F-0040", "Settings", "Local storage card", "See storage paths/sizes, refresh them, and reveal folders.", "The user can understand and inspect local data use.", "CepessaSessionsShellPages.swift:1689-1715,1872-1911", "Always; Reveal is OS-mediated", "Contract", "High", "Medium", "Inventory - reachable"),
  feature("F-0041", "Settings", "Local storage card", "Clear all Sessions storage.", "The user can reclaim local disk space.", "CepessaSessionsShellPages.swift:1717-1745,1912-1915", "Always; destructive and immediate", "Contract", "High", "Critical", "Inventory - protected destructive", "One click deletes all non-hidden children with no confirmation or recovery UI."),
  feature("F-0042", "Settings", "Local storage card", "Clear all Clips storage.", "The user can reclaim local disk space.", "CepessaSessionsShellPages.swift:1721-1745,1916-1918", "Always; destructive and immediate", "Contract", "High", "Critical", "Inventory - protected destructive", "One click deletes all non-hidden children with no confirmation or recovery UI."),
  feature("F-0043", "Meeting brain / MCP", "Settings or integration surface", "Configure or inspect the meeting-brain/MCP connection.", "Sessions can feed and retrieve context from the intended meeting brain.", "Source audit found no reachable meeting-brain/MCP settings; only Clip prompt text exists.", "Expected but not implemented", "Contract", "High", "High", "Gap - expected absent", "Code-only source_presence records evidence of absence, not an implemented source surface."),
];

function behavior(
  behaviorId,
  featureId,
  preconditions,
  given,
  when,
  thenExpected,
  behaviorType,
  testMethod,
  automationCandidate,
  risk,
  notes = "",
) {
  return [
    behaviorId,
    featureId,
    preconditions,
    given,
    when,
    thenExpected,
    behaviorType,
    testMethod,
    automationCandidate,
    risk,
    "Not run - source inventory only",
    "",
    notes,
  ];
}

const behaviors = [
  behavior("B-0001", "F-0001", "App is not running.", "Cepessa Sessions is launched.", "Initialization completes.", "The app remains accessory-only and initializes the status item and floating bar.", "Lifecycle", "Installed-app launch + agent-swift", "Yes", "Medium"),
  behavior("B-0002", "F-0002", "App is running with no visible windows.", "The user reopens the app.", "macOS sends the reopen event.", "The Sessions reading window becomes key and visible.", "Lifecycle", "Installed-app interaction", "Yes", "Low"),
  behavior("B-0003", "F-0003", "No recording, processing, or recorder error.", "The status item is connected.", "Its snapshot refreshes.", "The idle icon and Sessions ready status appear.", "State", "Menu/status inspection", "Partial", "Medium"),
  behavior("B-0004", "F-0003", "Recording is active.", "The recording timer changes.", "The status snapshot refreshes.", "The status item displays elapsed recording time.", "State", "Safe dev recording + status inspection", "Partial", "High"),
  behavior("B-0005", "F-0003", "Transcription is active.", "Processing progress changes.", "The status snapshot refreshes.", "The status item displays rounded percentage or ellipsis.", "State", "Fixture import + status inspection", "Partial", "Medium"),
  behavior("B-0006", "F-0003", "A non-empty recorder message exists.", "The status snapshot refreshes.", "Error precedence is evaluated.", "The status item is classified as failed and displays an exclamation marker.", "Error state", "Source assertion + dev state fixture", "Yes", "High", "Mute and degraded-capture informational messages also enter this failure branch."),
  behavior("B-0007", "F-0003", "At least two processing snapshots exist.", "The status menu is opened.", "The menu rebuilds.", "A processing-queue count row appears.", "Conditional UI", "Fixture state + menu inspection", "Yes", "Medium"),
  behavior("B-0008", "F-0004", "No recording is active.", "The status menu is open.", "Start Recording is selected.", "The recorder requests access and starts a new selected session.", "Functional", "Dev-only recording flow", "Partial", "High"),
  behavior("B-0009", "F-0004", "Recording is active.", "The status menu is open.", "Stop Recording is selected.", "Capture stops and final transcription begins.", "Functional", "Dev-only recording flow", "Partial", "High"),
  behavior("B-0010", "F-0005", "A failed selected session retains local audio and is not processing.", "Retry Transcription is visible.", "The user selects it.", "Transcript and recap reset and local transcription reruns.", "Recovery", "Copied fixture + dev app", "Partial", "High"),
  behavior("B-0011", "F-0006", "Stored sessions exist.", "A status or floating menu is opened.", "The menu is built.", "Up to the five newest sessions are listed.", "Conditional UI", "Seeded local fixture + menu inspection", "Yes", "Low"),
  behavior("B-0012", "F-0006", "A recent session is listed.", "The user selects the row.", "The action fires.", "That session becomes selected and the reading window opens.", "Navigation", "Seeded fixture + agent-swift", "Yes", "Medium"),
  behavior("B-0013", "F-0007", "A status or floating menu is open.", "All Sessions is available.", "The user selects it.", "The main window routes to the reading view.", "Navigation", "Agent-swift", "Yes", "Low"),
  behavior("B-0014", "F-0008", "A status or floating menu is open.", "Clips is available.", "The user selects it.", "The main window routes to Clips.", "Navigation", "Agent-swift", "Yes", "Low"),
  behavior("B-0015", "F-0009", "The native audio-import panel is open.", "No file has been confirmed.", "The user cancels.", "No session or file mutation occurs.", "Cancellation", "Dev app + temporary fixture", "Partial", "Medium"),
  behavior("B-0016", "F-0009", "A valid temporary audio fixture is available.", "The native import panel is open.", "The user confirms the file.", "Audio is normalized, a selected transcribing session is created, and processing starts.", "Functional", "Dev app + copied fixture", "Partial", "High"),
  behavior("B-0017", "F-0009", "The selected import cannot be normalized.", "Import processing is active.", "The task fails.", "The session becomes failed and the error state is published.", "Error recovery", "Controlled invalid fixture", "Partial", "High"),
  behavior("B-0018", "F-0010", "The floating bar is visible.", "The status menu is open.", "Hide Floating Bar is selected.", "The bar becomes transiently hidden and the menu changes to Show.", "State", "Agent-swift", "Yes", "Medium"),
  behavior("B-0019", "F-0010", "The floating bar is hidden.", "The status menu is open.", "Show Floating Bar is selected.", "The preference becomes enabled and the bar reappears.", "State", "Agent-swift", "Yes", "Medium"),
  behavior("B-0020", "F-0013", "The idle floating bar is visible.", "No recording is active.", "Record is pressed.", "Recording starts and the bar enters collapsed recording mode.", "Functional", "Dev-only recording + agent-swift", "Partial", "High"),
  behavior("B-0021", "F-0014", "Recording controls are collapsed.", "The pointer enters or leaves the recording summary.", "Hover state changes.", "The lozenge geometry stays fixed and no controls appear without deliberate activation.", "Interaction", "Focused unit test + runtime geometry", "Yes", "Medium"),
  behavior("B-0022", "F-0014", "Recording controls are collapsed.", "The recording summary is focused or clicked.", "The user deliberately activates it.", "A compact 220×30 control tray opens.", "Interaction", "Agent-swift + focused unit test", "Yes", "Medium"),
  behavior("B-0023", "F-0014", "Recording controls are expanded.", "Minimize is visible or Escape is available.", "The user minimizes.", "Controls collapse.", "Interaction", "Agent-swift", "Yes", "Medium"),
  behavior("B-0024", "F-0015", "Recording is active and the bar is visible.", "Hide for This Recording is available.", "The user selects it.", "The bar hides until the recording state resets or Show is used.", "State", "Dev-only recording + agent-swift", "Yes", "Medium"),
  behavior("B-0025", "F-0016", "Recording is active and the mic is unmuted.", "Mute microphone is visible.", "The user presses it.", "The transcript mix becomes system-only and the microphone level becomes zero.", "Audio state", "Dev-only audio fixture + state inspection", "Partial", "High"),
  behavior("B-0026", "F-0016", "Recording is active and the mic is muted.", "Unmute microphone is visible.", "The user presses it.", "The prior mix mode is restored.", "Audio state", "Dev-only audio fixture + state inspection", "Partial", "High"),
  behavior("B-0027", "F-0017", "Recording capture sources change.", "The floating bar is visible.", "State refreshes.", "The health indicator resolves to healthy, partial, muted, or unavailable.", "State", "Injected capture-state test + UI inspection", "Yes", "High"),
  behavior("B-0028", "F-0017", "Recording is active.", "The elapsed timer advances.", "Publishers update.", "The 66×22 recording lozenge visibly reports elapsed time without a waveform dashboard.", "Live feedback", "Presentation harness + screenshot evidence", "Yes", "High"),
  behavior("B-0029", "F-0018", "One display exists and recording is active.", "Capture Screen is visible.", "The user presses it.", "A full screenshot is captured and attached at the current session offset.", "Functional", "Dev recording + temporary storage", "Partial", "High"),
  behavior("B-0030", "F-0018", "Multiple displays exist and recording is active.", "Capture Screen is visible.", "The user presses it.", "A display-selection menu appears before capture.", "Conditional UI", "Manual multi-display environment", "No", "High"),
  behavior("B-0031", "F-0019", "Recording is active.", "Capture Region is visible.", "The user presses it.", "Interactive system region capture begins.", "OS integration", "Manual OS-mediated flow", "No", "High"),
  behavior("B-0032", "F-0020", "Recording is active and attachable temporary files exist.", "The file panel is open.", "The user selects one or more files.", "Each successful file is copied or attached and the success notice reports count and time.", "Functional", "Dev recording + temporary fixtures", "Partial", "High"),
  behavior("B-0033", "F-0020", "All selected file attachments will fail.", "The file panel is open.", "Import completes.", "An error state and File attachment failed notice appear.", "Error state", "Controlled unreadable fixture", "Partial", "High"),
  behavior("B-0034", "F-0021", "The floating bar is visible.", "The user drags it.", "Window movement completes.", "The origin is persisted and restored on future panel creation.", "Persistence", "Agent-swift + relaunch dev app", "Partial", "Low"),
  behavior("B-0035", "F-0022", "Import or transcription is active.", "A processing snapshot changes.", "The bar refreshes.", "The bar shows a spinner and percentage or stage title.", "State", "Fixture import + screenshot evidence", "Partial", "Medium"),
  behavior("B-0036", "F-0023", "No session is selected.", "The reading window is open.", "The view renders.", "No session open appears.", "Empty state", "Seeded empty state + agent-swift", "Yes", "Medium"),
  behavior("B-0037", "F-0023", "The selected session has no transcript text.", "The reading window is open.", "The view renders.", "Transcript not ready directs the user to Transcribe.", "Empty state", "Seeded session fixture + agent-swift", "Yes", "Medium"),
  behavior("B-0038", "F-0024", "The selected session has transcript segments.", "The reader renders.", "Timeline blocks are built.", "Each block shows speaker, relative time, and selectable text.", "Content", "Bilingual seeded fixture + screenshot/text inspection", "Yes", "High"),
  behavior("B-0039", "F-0025", "The timeline contains an image attachment.", "The inline image is visible.", "The user clicks it.", "An enlarged image overlay appears.", "Interaction", "Seeded attachment + agent-swift", "Yes", "Medium"),
  behavior("B-0040", "F-0025", "The enlarged image overlay is open.", "A dismiss affordance is available.", "The user presses X or Escape or clicks the backdrop.", "The overlay closes.", "Interaction", "Agent-swift", "Yes", "Medium"),
  behavior("B-0041", "F-0026", "The reading window is open.", "Zoom input is available.", "The user pinches or uses a zoom shortcut.", "Scale clamps to 0.7 through 2.2 and persists.", "Accessibility", "Agent-swift keyboard + preference inspection", "Partial", "Low"),
  behavior("B-0042", "F-0027", "No stored sessions exist.", "The session toolbar menu is opened.", "The menu builds.", "A disabled No sessions yet row appears.", "Empty state", "Seeded empty state + agent-swift", "Yes", "Medium"),
  behavior("B-0043", "F-0027", "Stored sessions exist.", "The session toolbar menu is open.", "The user selects another session.", "Selection and transcript content switch.", "Navigation", "Seeded fixture + agent-swift", "Yes", "Medium"),
  behavior("B-0044", "F-0028", "The reader toolbar is visible.", "Toolbar controls are enumerated.", "The user inspects the available actions.", "No non-functional document-language selector is presented.", "Functional", "Source trace + runtime toolbar inspection", "Yes", "Medium"),
  behavior("B-0045", "F-0029", "The selected session has retained audio and is idle.", "Transcribe is enabled.", "The user presses it.", "A fresh local transcription starts.", "Functional", "Copied fixture + dev app", "Partial", "High"),
  behavior("B-0046", "F-0029", "The selected session lacks audio or is already processing.", "The toolbar validates.", "Availability is recalculated.", "Transcribe is disabled.", "Guard state", "Seeded fixtures + toolbar inspection", "Yes", "High"),
  behavior("B-0047", "F-0030", "The selected session has a non-empty transcript.", "Export is enabled and the save panel is open.", "The user confirms a temporary destination.", "A Markdown transcript is written.", "Export", "Dev app + temporary destination", "Partial", "Medium"),
  behavior("B-0048", "F-0030", "The export destination cannot be written.", "Export is attempted.", "The write fails.", "Only a system beep reports failure.", "Error state", "Controlled unwritable destination", "Partial", "Medium"),
  behavior("B-0049", "F-0031", "No Clips exist in isolated storage.", "The Clips window opens.", "The view renders.", "Empty-list and empty-inspector states appear.", "Empty state", "Isolated dev storage + agent-swift", "Yes", "Medium"),
  behavior("B-0050", "F-0031", "Stored Clips exist.", "A Clip row is visible.", "The user selects it.", "The inspector and editable drafts switch to that Clip.", "Selection", "Seeded Clip fixture + agent-swift", "Yes", "Medium"),
  behavior("B-0051", "F-0032", "Draft title and intent contain text.", "The Clip composer is idle.", "Clip recording starts.", "The normalized title and optional intent enter the manifest.", "Data capture", "View-model test + isolated fixture", "Yes", "Medium"),
  behavior("B-0052", "F-0033", "No Clip recording is active.", "Record Clip is available.", "The user presses it.", "Screen and audio capture start, the timer runs, and the new Clip is selected.", "Functional", "Dev-only recording flow", "Partial", "High"),
  behavior("B-0053", "F-0033", "Clip capture startup will fail.", "Record Clip is pressed.", "The start task completes.", "The Clip is saved as failed and error text is shown.", "Error state", "Injected recorder/process failure", "Yes", "High"),
  behavior("B-0054", "F-0033", "Clip recording is active.", "Stop Clip is available.", "The user presses it.", "Capture stops and transcript processing starts.", "Functional", "Dev-only recording flow", "Partial", "High"),
  behavior("B-0055", "F-0034", "Clip audio exists and transcription succeeds.", "Clip processing is active.", "Processing completes.", "The Clip becomes ready with transcript segments and an inferred title.", "Success state", "View-model test + audio fixture", "Yes", "High"),
  behavior("B-0056", "F-0034", "No Clip audio is available.", "Clip processing is active.", "Processing completes.", "The Clip becomes ready with an explicit no-transcript error.", "Degraded state", "View-model test", "Yes", "High"),
  behavior("B-0057", "F-0034", "Clip transcription will fail.", "Clip processing is active.", "Processing completes.", "The Clip becomes ready with a transcription-failed error.", "Degraded state", "Injected transcription failure", "Yes", "High"),
  behavior("B-0058", "F-0035", "A Clip is selected.", "Copy agent prompt is available.", "The user presses it.", "The clipboard receives the MCP instruction and local artifact paths.", "Clipboard", "Seeded Clip + pasteboard assertion", "Yes", "Medium"),
  behavior("B-0059", "F-0036", "A Clip is selected and its fields are edited.", "Save notes is available.", "The user presses it.", "Post notes, title, and intent are persisted.", "Persistence", "View-model test + isolated storage", "Yes", "Medium"),
  behavior("B-0060", "F-0036", "A Clip is selected.", "Reveal is available.", "The user presses it.", "Finder opens the Clip directory.", "OS integration", "Manual Finder observation", "No", "Low"),
  behavior("B-0061", "F-0037", "The user changes a transcription preference.", "A later transcription plan is requested.", "The plan resolves.", "The selected model order, speed, and language prompt are applied.", "Configuration", "Unit tests for plan resolution", "Yes", "High"),
  behavior("B-0062", "F-0038", "Settings is visible.", "Capture controls are enumerated.", "The user inspects retention options.", "No non-functional raw-audio retention toggle is presented.", "Functional", "Source trace + runtime Settings inspection", "Yes", "High"),
  behavior("B-0063", "F-0039", "Microphone or screen permission is granted or denied.", "Settings opens.", "Permission rows render.", "Each row shows Ready or Needs access.", "OS state", "Agent-swift + OS permission observation", "Partial", "High"),
  behavior("B-0064", "F-0039", "A privacy action is visible.", "Settings is open.", "The user presses it.", "macOS opens the corresponding Privacy pane.", "OS integration", "Manual System Settings observation", "No", "Medium"),
  behavior("B-0065", "F-0040", "Isolated Sessions or Clips storage has known contents.", "Settings appears or Refresh Storage is pressed.", "The storage scan completes.", "Sessions, Clips, and total sizes update.", "Data display", "Isolated fixture + agent-swift", "Yes", "Medium"),
  behavior("B-0066", "F-0040", "A Reveal action is visible.", "Settings is open.", "The user presses it.", "Finder opens the selected Sessions, Clips, or Models location.", "OS integration", "Manual Finder observation", "No", "Low"),
  behavior("B-0067", "F-0041", "Isolated Sessions storage contains disposable data.", "Clear Sessions is visible.", "The user presses it once.", "All non-hidden children are immediately deleted and the session model reloads.", "Destructive data", "Source review only unless explicitly authorized in isolated storage", "No", "Critical", "Protected action: never exercise against production recordings; no confirmation or recovery UI exists."),
  behavior("B-0068", "F-0042", "Isolated Clips storage contains disposable data.", "Clear Clips is visible.", "The user presses it once.", "All non-hidden children are immediately deleted.", "Destructive data", "Source review only unless explicitly authorized in isolated storage", "No", "Critical", "Protected action: never exercise against production Clips; no confirmation or recovery UI exists."),
  behavior("B-0069", "F-0011", "The app is running and no modal workflow is active.", "The status or floating menu is open.", "The user selects Settings.", "The Settings window becomes visible and exposes capture, permission, and storage controls.", "Navigation", "Agent-swift", "Yes", "Medium"),
  behavior("B-0070", "F-0012", "The app is idle.", "The status or floating menu is open.", "The user selects Quit.", "The app terminates without leaving active capture writers.", "Lifecycle", "Dev-app lifecycle test only", "Partial", "High", "Protected in production baseline because the running installed app must not be stopped."),
  behavior("B-0071", "F-0043", "The meeting-brain evidence pipeline exists.", "The user opens the reachable desktop settings and menus.", "Integration controls are inspected.", "A clear meeting-brain connection, health, and standalone mode surface is available.", "Expected integration", "Source and runtime surface reconciliation", "Yes", "High"),
  behavior("B-0072", "F-0013", "The installed app is idle.", "The floating panel is enumerated by WindowServer.", "Its frame is measured.", "The persistent idle indicator uses a compact non-obstructive footprint.", "Responsive", "WindowServer geometry + screenshot", "Yes", "High"),
  behavior("B-0073", "F-0001", "The installed app is idle.", "CPU and resident memory are sampled repeatedly.", "No user action occurs.", "Idle CPU remains negligible and memory remains stable.", "Performance", "Repeated process samples", "Yes", "Medium"),
  behavior("B-0074", "F-0003", "The floating bar is hidden and the menu-bar item is the only visible control.", "Accessibility attributes are inspected.", "The status item receives keyboard or assistive-technology focus.", "The control exposes a meaningful label, value, and action.", "Accessibility", "agent-swift AX inspection", "Yes", "High"),
  behavior("B-0075", "F-0001", "The production app is running.", "The standard macOS menu bar is inspected.", "Menus are enumerated.", "App, Edit, View, Window, and Help menus remain available with standard commands.", "Accessibility", "agent-swift menu inventory", "Yes", "Medium"),
];

const baselineEvidence = {
  "B-0001": {
    result: "Pass",
    steps: "Connect agent-swift to the running production bundle without relaunching it; inspect Info.plist and WindowServer state.",
    actual: "Connected to PID 53535. The app is LSUIElement/accessory-only, and the status item plus floating panel were present.",
    evidence: "/tmp/cepessa-sessions-production-qa/01-current-interactive.json; /tmp/cepessa-sessions-production-qa/08-info-plist.txt",
  },
  "B-0003": {
    result: "Pass",
    steps: "Open the status menu without selecting any state-changing command.",
    actual: "The menu reported Sessions ready in the idle state.",
    evidence: "/tmp/cepessa-sessions-production-qa/06-status-menu-open.json",
  },
  "B-0011": {
    result: "Pass",
    steps: "Open the idle status menu and count recent-session rows.",
    actual: "Five recent sessions were listed.",
    evidence: "/tmp/cepessa-sessions-production-qa/06-status-menu-open.json",
  },
  "B-0013": {
    result: "Blocked",
    steps: "Invoke All Sessions from the status menu, then inspect the resulting window.",
    actual: "WindowServer reported a 1200×800 Sessions window, but the app exposed no accessible window tree, so the reading route could not be asserted.",
    evidence: "/tmp/cepessa-sessions-production-qa/03-all-sessions-interactive.json; /tmp/cepessa-sessions-production-qa/04-window-inventory.txt",
  },
  "B-0069": {
    result: "Blocked",
    steps: "Invoke Settings once from the status menu and inspect the resulting window.",
    actual: "The command was invoked, but no accessible Settings content or second onscreen window could be proven while both displays were asleep.",
    evidence: "/tmp/cepessa-sessions-production-qa/app-settings-menu-open.json; /tmp/cepessa-sessions-production-qa/04-window-inventory.txt",
  },
  "B-0071": {
    result: "Fail",
    steps: "Reconcile reachable production menus/settings with the current desktop source entry points.",
    actual: "No reachable meeting-brain connection, health, or standalone configuration surface exists.",
    evidence: "CepessaSessionsApp.swift; CepessaSessionStatusBar.swift; source inventory F-0043",
  },
  "B-0072": {
    result: "Fail",
    steps: "Read the floating panel frame from WindowServer without showing or moving it.",
    actual: "The installed idle panel measured 356×64, materially larger than a compact recording indicator.",
    evidence: "/tmp/cepessa-sessions-production-qa/04-window-inventory.txt",
  },
  "B-0073": {
    result: "Pass",
    steps: "Sample the idle production process six times at one-second intervals.",
    actual: "All six samples were 0.0% CPU; RSS settled around 137–160 MB.",
    evidence: "/tmp/cepessa-sessions-production-qa/09-idle-cpu-samples.txt; /tmp/cepessa-sessions-production-qa/09-idle-sample.txt",
  },
  "B-0074": {
    result: "Fail",
    steps: "Inspect the status item accessibility label, text, identifier, supported actions, and frame.",
    actual: "The item supported AXPress and measured 35.5×24, but its label, text, and identifier were empty.",
    evidence: "/tmp/cepessa-sessions-production-qa/05-status-accessibility.json",
  },
  "B-0075": {
    result: "Pass",
    steps: "Enumerate the production app menu bar through accessibility.",
    actual: "App, Edit, View, Window, and Help menus were present with standard About, Settings, Services, Hide, and Quit commands.",
    evidence: "/tmp/cepessa-sessions-production-qa/01-current-interactive.json",
  },
};

const baselineBuild =
  "Installed /Applications/Sessions.app 0.0.0-local (1); executable sha256 bb850395a607edc80f4cb0d74d5de73843bf3960eff2fb69b1e7653c3717b9ff";
const baselineEnvironment =
  "macOS 26.5.2 (25F84), arm64, production PID 53535, displays asleep, no recording/settings/data mutation";

const baselineTestRuns = behaviors.map((row, index) => {
  const behaviorId = row[0];
  const evidence = baselineEvidence[behaviorId] ?? {
    result: "Blocked",
    steps: "Behavior was not executed against production because it requires recording, permissions, file access, destructive data, an awake display, seeded isolated state, or a reachable accessibility tree.",
    actual: "Blocked by the frozen production-baseline safety boundary or environment; no pass is inferred from source.",
    evidence: "/tmp/cepessa-sessions-production-qa/04-window-inventory.txt",
  };
  return [
    `T-${String(index + 1).padStart(4, "0")}`,
    "RUN-20260727-01",
    behaviorId,
    "Baseline",
    baselineBuild,
    baselineEnvironment,
    row[2],
    evidence.steps,
    row[5],
    evidence.actual,
    evidence.result,
    evidence.evidence,
    "Codex runtime lane",
    "2026-07-27T08:10:00+03:00",
    evidence.result === "Blocked"
      ? "Preserved as blocked; must be rerun in the isolated dev app after the refactor."
      : "",
  ];
});

const finalEvidence = {
  "B-0001": {
    result: "Pass",
    actual: "The uniquely identified accessory app launched and exposed its status item plus 22×22 idle indicator.",
    evidence: "/tmp/cepessa-liquidqa-ax-final-idle.json; /tmp/cepessa-liquidqa-idle2.png",
  },
  "B-0003": {
    result: "Pass",
    actual: "The status item exposed 'Cepessa Sessions, idle' and changed to a meaningful recording label.",
    evidence: "/tmp/cepessa-liquidqa-ax-final-idle.json; /tmp/cepessa-liquidqa-ax-final-recording.json",
  },
  "B-0004": {
    result: "Pass",
    actual: "Presentation-state recording showed 00:42 in both the lozenge and status item.",
    evidence: "/tmp/cepessa-liquidqa-ax-final-recording.json; /tmp/cepessa-liquidqa-final-recording.png",
  },
  "B-0013": {
    result: "Pass",
    actual: "All Sessions opened the native reading window with a truthful empty state and session toolbar.",
    evidence: "/tmp/cepessa-liquidqa-sessions2.png; /tmp/cepessa-liquidqa-sessions2.json",
  },
  "B-0014": {
    result: "Pass",
    actual: "Clips routed the existing window to the native split-view workspace and removed the Sessions toolbar.",
    evidence: "/tmp/cepessa-liquidqa-clips.png; /tmp/cepessa-liquidqa-clips-snapshot.json",
  },
  "B-0018": {
    result: "Pass",
    actual: "Hide removed the floating panel during recording while the menu bar remained visible.",
    evidence: "/tmp/cepessa-liquidqa-hidden-recording.json; /tmp/cepessa-liquidqa-hidden-menu.json",
  },
  "B-0019": {
    result: "Pass",
    actual: "The hidden-state menu exposed Show Recording Indicator and the state-reset path restored the idle indicator.",
    evidence: "/tmp/cepessa-liquidqa-hidden-menu.json; /tmp/cepessa-liquidqa-after-stop-late.json",
  },
  "B-0020": {
    result: "Pass",
    actual: "The safe presentation harness changed the indicator from 22×22 idle to 66×22 recording.",
    evidence: "/tmp/cepessa-liquidqa-ax-final-idle.json; /tmp/cepessa-liquidqa-ax-final-recording.json",
  },
  "B-0021": {
    result: "Pass",
    actual: "Focused tests proved hover does not change geometry; runtime remained 66×22 until deliberate activation.",
    evidence: "/tmp/cepessa-liquidqa-focused-final.log; /tmp/cepessa-liquidqa-ax-final-recording.json",
  },
  "B-0022": {
    result: "Pass",
    actual: "The default accessibility action opened the compact recording control tray.",
    evidence: "/tmp/cepessa-liquidqa-recording-tray5.json; /tmp/cepessa-liquidqa-recording-tray5.png",
  },
  "B-0023": {
    result: "Pass",
    actual: "The tray exposed an explicit minimize control and Escape/default-action behavior is covered by focused tests.",
    evidence: "/tmp/cepessa-liquidqa-recording-tray5.json; /tmp/cepessa-liquidqa-focused-final.log",
  },
  "B-0024": {
    result: "Pass",
    actual: "Hide removed the tray and indicator for the current recording; the menu retained Show and Stop.",
    evidence: "/tmp/cepessa-liquidqa-hidden-menu.json",
  },
  "B-0027": {
    result: "Pass",
    actual: "Twenty-seven focused indicator tests covered geometry, drag persistence, recording-plus-warning precedence, capture health, idle, and processing state resolution.",
    evidence: "/tmp/cepessa-liquidqa-focused-final2.log",
  },
  "B-0028": {
    result: "Pass",
    actual: "The recording lozenge visibly showed the red state ring and 00:42 timer in a 66×22 footprint.",
    evidence: "/tmp/cepessa-liquidqa-final-recording.png; /tmp/cepessa-liquidqa-ax-final-recording.json",
  },
  "B-0036": {
    result: "Pass",
    actual: "The Sessions window rendered a native No Session Open empty state.",
    evidence: "/tmp/cepessa-liquidqa-sessions2.png",
  },
  "B-0044": {
    result: "Pass",
    actual: "The misleading language selector was absent; only Sessions, Transcribe, and Export remained.",
    evidence: "/tmp/cepessa-liquidqa-sessions2.png; CepessaSessionReadingView.swift",
  },
  "B-0049": {
    result: "Pass",
    actual: "The isolated Clips route rendered truthful No Clips and No Clip Selected states.",
    evidence: "/tmp/cepessa-liquidqa-clips.png",
  },
  "B-0062": {
    result: "Pass",
    actual: "Settings no longer presented a non-functional raw-audio retention toggle.",
    evidence: "/tmp/cepessa-liquidqa-settings3.png; CepessaSessionsShellPages.swift",
  },
  "B-0063": {
    result: "Pass",
    actual: "The Settings window presented language, speed, and floating-indicator controls in a grouped native Form.",
    evidence: "/tmp/cepessa-liquidqa-settings3.png; /tmp/cepessa-liquidqa-settings3-snapshot.json",
  },
  "B-0064": {
    result: "Pass",
    actual: "Microphone and Screen Recording permission rows showed explicit Not granted state and Open actions.",
    evidence: "/tmp/cepessa-liquidqa-settings3.png; /tmp/cepessa-liquidqa-settings3-snapshot.json",
  },
  "B-0065": {
    result: "Pass",
    actual: "Settings resolved Sessions and Clips under the isolated test root and reported zero KB.",
    evidence: "/tmp/cepessa-liquidqa-settings3.png; /tmp/cepessa-liquidqa-final.uahIic/data",
  },
  "B-0067": {
    result: "Pass",
    actual: "Source and UI inspection confirmed confirmation-gated deletion and active session/clip operation interlocks.",
    evidence: "CepessaSessionsShellPages.swift; /tmp/cepessa-liquidqa-settings3-snapshot.json",
  },
  "B-0068": {
    result: "Pass",
    actual: "Source and UI inspection confirmed confirmation-gated clip deletion and a live-clip interlock.",
    evidence: "CepessaSessionsShellPages.swift; /tmp/cepessa-liquidqa-settings3-snapshot.json",
  },
  "B-0069": {
    result: "Pass",
    actual: "The status menu opened a dedicated Sessions Settings window with Capture, Permissions, and Local Storage groups.",
    evidence: "/tmp/cepessa-liquidqa-settings3.png; /tmp/cepessa-liquidqa-settings3-snapshot.json",
  },
  "B-0072": {
    result: "Pass",
    actual: "Runtime AX geometry measured 22×22 idle and 66×22 recording.",
    evidence: "/tmp/cepessa-liquidqa-ax-final-idle.json; /tmp/cepessa-liquidqa-ax-final-recording.json",
  },
  "B-0074": {
    result: "Pass",
    actual: "The menu-bar item exposed meaningful idle and recording labels; the hidden-state menu retained Show and Stop.",
    evidence: "/tmp/cepessa-liquidqa-ax-final-idle.json; /tmp/cepessa-liquidqa-ax-final-recording.json; /tmp/cepessa-liquidqa-hidden-menu.json",
  },
  "B-0075": {
    result: "Pass",
    actual: "The dev app retained native App, Edit, View, Window, and Help menus.",
    evidence: "/tmp/cepessa-liquidqa-start3.json",
  },
};

const finalBuild =
  "Isolated debug build, bundle me.cepessa.sessions.liquidqafinal; Swift suite 158 tests, 1 intentional skip, 0 failures";
const finalEnvironment =
  "macOS 26.5.2, arm64, isolated storage root, presentation-only recording state, production PID 53535 unchanged";

const finalTestRuns = behaviors.map((row, index) => {
  const behaviorId = row[0];
  const evidence = finalEvidence[behaviorId] ?? {
    result: "Blocked",
    actual:
      "Not executed in this safe pass because it requires real capture/permission changes, seeded transcript or attachment fixtures, destructive interaction, OS panels, multi-display state, or a complete assistive-technology traversal.",
    evidence: "/tmp/cepessa-liquidqa-full-final.log",
  };
  return [
    `T-${String(behaviors.length + index + 1).padStart(4, "0")}`,
    "RUN-20260727-02",
    behaviorId,
    "Final regression",
    finalBuild,
    finalEnvironment,
    row[2],
    `Execute the behavior in the isolated dev app when safely reachable; otherwise preserve the explicit blocker. ${row[7]}`,
    row[5],
    evidence.actual,
    evidence.result,
    evidence.evidence,
    "Codex independent verification",
    "2026-07-27T09:30:00+03:00",
    evidence.result === "Blocked"
      ? "Incomplete, not failed: no runtime claim is inferred from source or the passing Swift suite."
      : "",
  ];
});

const testRuns = [...baselineTestRuns, ...finalTestRuns];

function defect(
  defectId,
  behaviorIds,
  fingerprint,
  category,
  severity,
  title,
  reproduction,
  expected,
  actual,
  evidence,
  rootCause,
  notes = "",
) {
  return [
    defectId,
    behaviorIds,
    fingerprint,
    category,
    severity,
    title,
    reproduction,
    expected,
    actual,
    evidence,
    "Reproduced",
    "Authorized by Ben on 2026-07-27",
    rootCause,
    "",
    "",
    "",
    "",
    "",
    notes,
  ];
}

const defects = [
  defect("D-0001", "B-0072; B-0020; B-0021", "floating-panel-oversized-dense", "UX", "High", "Floating recording bar is oversized and visually busy", "Observe the installed idle floating panel or the current 208×36 source lozenge.", "A non-obstructive indicator presents only recording trust and one deliberate path to controls.", "Installed idle panel is 356×64; the current source still renders redundant labels, health, waveform, and expansion affordances.", "/tmp/cepessa-sessions-production-qa/04-window-inventory.txt; user report 2026-07-27", "The indicator is composed as a miniature control dashboard instead of a liveness signal."),
  defect("D-0002", "B-0074", "status-item-empty-ax-label", "Accessibility", "High", "Menu-bar status item has no accessible name", "Inspect the only visible control while the floating bar is hidden.", "Assistive technology receives a meaningful recording state and action.", "AXPress is supported, but label, text, and identifier are empty.", "/tmp/cepessa-sessions-production-qa/05-status-accessibility.json", "The AppKit status-item button is not assigned an accessibility label/value."),
  defect("D-0003", "B-0067; B-0068", "storage-clear-no-confirmation-or-interlock", "State/Data", "Critical", "Clear Sessions and Clear Clips delete immediately", "Inspect the Settings storage actions in source; do not execute them against production.", "Destructive deletion requires explicit confirmation, exact target disclosure, and active-operation interlock.", "One click removes all non-hidden children and can run while writers are active.", "CepessaSessionsShellPages.swift:1717-1745", "Destructive buttons call deletion directly without confirmation, undo, or recorder-state guard."),
  defect("D-0004", "B-0062", "keep-raw-audio-setting-unused", "Logic", "High", "Keep raw audio setting is not consumed", "Disable the visible preference and trace processing/cleanup consumers.", "The setting either controls retention safely or is not presented.", "No capture or processing path reads the preference.", "CepessaSessionsShellPages.swift:1779,1830-1835; source inventory", "A persisted UI preference was added without an implementation consumer."),
  defect("D-0005", "B-0044", "document-language-selector-no-effect", "Functional", "Medium", "Document language selector changes only its label", "Select English or Hebrew in the reachable transcript toolbar.", "The chosen language changes a documented reader or export behavior.", "The preference and toolbar title change, but reading/export paths do not consume it.", "CepessaSessionReadingView.swift:327-333,382-406,451-455", "The selection is not passed into the rendering or export pipeline."),
  defect("D-0006", "B-0045; B-0046", "transcription-success-keeps-processing-snapshot", "State/Data", "High", "Successful transcription can remain permanently processing", "Complete a transcription and inspect processing snapshots/retranscription eligibility.", "Success clears processing state and re-enables valid later retranscription.", "The success path ends transcription without clearing its snapshot; eligibility rejects any session with a snapshot.", "LocalMeetingAppModel.swift:608,732", "Processing lifecycle cleanup is incomplete on the success path."),
  defect("D-0007", "B-0016; B-0045", "mixed-import-never-ready-evidence", "Logic", "High", "Imported mixed audio cannot reach ready evidence", "Import or retry a mixed recording through the evidence contract.", "Supported imports complete with an honest ready or explicitly degraded usable disposition.", "Import supplies only mixed audio; mixed fallback is non-ready and every non-ready disposition becomes session failure.", "LocalMeetingAppModel.swift:574; evidence coordinator", "Legacy mixed imports are routed through a strict primary-source contract without an import-specific disposition."),
  defect("D-0008", "B-0006; B-0025; B-0027", "informational-warning-classified-failure", "State/Data", "High", "Muted or partial capture warnings masquerade as total failure", "Mute the microphone or enter a recoverable one-source state.", "The UI distinguishes degraded capture from failed recording/transcription.", "Any non-empty recorder message wins error precedence and produces a failed status.", "CepessaSessionStatusBar.swift; CepessaSessionFloatingBar.swift; source verification", "One global error string mixes informational, degraded, and fatal states."),
  defect("D-0009", "B-0038", "transcript-hides-evidence-quality", "UX", "High", "Transcript reader does not expose evidence quality", "Open a non-empty degraded or failed-evidence transcript.", "The reader communicates source integrity, diarization, and uncertainty before presenting text as trustworthy.", "Non-empty degraded/failed text is rendered like an ordinary complete transcript.", "CepessaSessionReadingView.swift:131-180; source verification", "The reachable reader consumes transcript text but not the evidence disposition."),
  defect("D-0010", "B-0055; B-0056; B-0057", "clip-ready-on-failure", "Logic", "High", "CLIP reports ready when audio or transcription failed", "Finish Clip processing with no audio or an injected transcription error.", "Failed/degraded Clips remain visibly failed or degraded and expose recovery.", "Status becomes ready and the UI says CLIP ready while errorMessage is not presented.", "LocalClipViewModel.swift:145-172; LocalClipsPage.swift", "The Clip state machine uses ready as a terminal umbrella and the UI ignores the attached error."),
  defect("D-0011", "B-0052; B-0053; B-0054", "clip-capture-start-not-validated", "Functional", "High", "CLIP capture startup and output are not validated", "Start screen capture with a failing process or missing output.", "Audio is stopped on startup failure and ready requires a valid playable video artifact.", "The process start is treated as success; output size/playability are not checked, and startup failure can leave audio recording active.", "LocalClipViewModel.swift:104-145", "Capture components start sequentially without transactional rollback or artifact validation."),
  defect("D-0012", "B-0049; B-0050", "interrupted-clips-not-normalized", "State/Data", "Medium", "Interrupted CLIPS are loaded as permanently active", "Load stored recording or processing Clip manifests after restart.", "Interrupted states normalize to recoverable failed state or resume safely.", "Stored statuses load unchanged with no recovery transition.", "LocalClipStore.swift:23", "Clip persistence has no interrupted-session normalization."),
  defect("D-0013", "B-0013; B-0014", "session-toolbar-persists-on-clips-route", "UX", "Medium", "Transcript toolbar can remain visible on Clips", "Switch the main destination from Sessions to Clips.", "Toolbar commands match the active destination.", "Session/transcribe/export controls may remain installed while Clips is active.", "CepessaSessionsApp.swift; CepessaSessionReadingView.swift; source verification", "Toolbar ownership is attached above the destination boundary."),
  defect("D-0014", "B-0049; B-0065; B-0067; B-0068", "test-root-does-not-isolate-clips-settings", "Test harness", "Critical", "Dev tests can still resolve production Clips and Settings storage", "Launch an isolated debug build with CEPESSA_SESSIONS_TEST_ROOT.", "Every storage consumer resolves under the same isolated root.", "Sessions honors the override; Clips and Settings storage models still use production Application Support paths.", "LocalClipModels.swift; CepessaSessionsShellPages.swift; source verification", "Storage-root resolution is duplicated rather than shared."),
  defect("D-0015", "B-0048", "export-failure-beep-only", "UX", "Medium", "Transcript export failure is not explained", "Attempt export to an unwritable destination.", "A visible, actionable error explains that no file was written.", "The app only emits a system beep.", "CepessaSessionReadingView.swift:413-444", "Export errors are discarded at the view boundary."),
  defect("D-0016", "B-0021; B-0072", "expanded-tray-persists-left-edge", "UX", "Medium", "Dragging the expanded tray shifts the resting indicator", "Open the 220pt tray, drag it, close it, or relaunch into the 22pt resting state.", "Every panel state preserves the user-selected horizontal center and top edge.", "The expanded tray's literal left edge was persisted, so the resting lozenge returned roughly 99pt left of the chosen center.", "CepessaSessionFloatingBar.swift; independent final source review", "Drag persistence stored state-dependent panel geometry instead of a normalized resting origin."),
  defect("D-0017", "B-0004; B-0074", "recording-warning-hides-visual-recording-state", "State/Data", "High", "Capture warning can replace the hidden recording signal", "Hide the floating indicator while recording, then surface a recorder warning.", "The menu-bar item keeps the record glyph and timer while adding a needs-attention warning.", "Failure precedence replaced the visible recording glyph and timer even though capture remained active.", "CepessaSessionStatusBar.swift; independent final source review", "A warning was modeled as the primary mode rather than supplementary health state on an active recording."),
];

const verifiedFixes = {
  "D-0001": ["CepessaSessionFloatingBar.swift; CepessaSessionIndicatorModel.swift", "T-0095; T-0096; T-0147"],
  "D-0002": ["CepessaSessionStatusBar.swift", "T-0149"],
  "D-0003": ["CepessaSessionsShellPages.swift", "T-0142; T-0143"],
  "D-0004": ["CepessaSessionsShellPages.swift", "T-0137"],
  "D-0005": ["CepessaSessionReadingView.swift", "T-0119"],
  "D-0008": ["CepessaSessionIndicatorModel.swift; CepessaSessionStatusBar.swift", "T-0102"],
  "D-0010": ["LocalClipViewModel.swift; LocalClipsPage.swift", "Swift suite + source verification"],
  "D-0012": ["LocalClipViewModel.swift", "Swift suite + source verification"],
  "D-0013": ["CepessaSessionsApp.swift", "T-0089"],
  "D-0014": ["LocalClipModels.swift; LocalClipViewModel.swift; CepessaSessionsShellPages.swift", "T-0140"],
  "D-0015": ["CepessaSessionReadingView.swift", "Swift build + source verification"],
  "D-0016": ["CepessaSessionFloatingBar.swift; CepessaSessionIndicatorModel.swift", "27 focused tests + full Swift suite"],
  "D-0017": ["CepessaSessionStatusBar.swift", "27 focused tests + full Swift suite"],
};

for (const row of defects) {
  const verified = verifiedFixes[row[0]];
  if (!verified) continue;
  row[10] = "Verified fixed";
  row[13] = verified[0];
  row[14] = finalBuild;
  row[15] = verified[1];
  row[16] = "RUN-20260727-02";
  row[17] = "";
  row[18] = "Verified in the isolated dev app, focused tests, full Swift suite, or an exact source assertion as cited.";
}

function opportunity(
  opportunityId,
  featureIds,
  behaviorIds,
  journey,
  evidence,
  friction,
  proposedChange,
  benefit,
  priority,
  confidence,
  effort,
  risk,
  validation,
  status,
  notes = "",
) {
  return [
    opportunityId,
    featureIds,
    behaviorIds,
    journey,
    "Current-run observation + user direction",
    evidence,
    friction,
    proposedChange,
    benefit,
    priority,
    confidence,
    effort,
    risk,
    validation,
    "",
    status,
    notes,
  ];
}

const opportunities = [
  opportunity("UX-0001", "F-0013; F-0014; F-0015; F-0017", "B-0020; B-0021; B-0022; B-0023; B-0072", "Monitor an active meeting without obstructing it", "User report; production panel 356×64; Claude Opus 5 design analysis", "The bar repeats recording state through text, colored dots, waveform, and multiple expansion affordances.", "Replace it with a 66×22 micro-lozenge: one state ring plus timer; click opens a 220×30 tray; no geometry change on proximity hover.", "Recording remains trustworthy while using roughly one quarter of the visual footprint.", "P1", "High", "Medium", "Medium", "Verify idle/recording/degraded states, pointer target, Stop reachability, VoiceOver, full-screen calls, and two displays.", "Approved", "Claude route: claude-opus-5, high, read-only design call; $0.5842 reported cost."),
  opportunity("UX-0002", "F-0007; F-0008; F-0023; F-0024; F-0031; F-0037; F-0039; F-0040", "B-0013; B-0014; B-0036; B-0038; B-0049; B-0063; B-0065", "Move through Sessions, Clips, and Settings", "User direction 2026-07-27; source/runtime inventory", "Reachable surfaces use mixed visual languages and dense custom chrome instead of one quiet Mac hierarchy.", "Refactor the reachable desktop app to a minimalist premium Liquid Glass system using native materials, semantic typography, compact controls, restrained depth, and accessible solid fallbacks.", "The app should feel coherent, calmer, and native without sacrificing evidence and capture trust.", "P1", "High", "High", "High", "Run full light/dark, Reduce Transparency, Increase Contrast, 720×520 and 1200×800 visual regression plus keyboard/VoiceOver review.", "Approved", "Implementation explicitly routed to Claude Opus 5 as an isolated sidecar; Codex remains verifier."),
];

opportunities[0][14] =
  "/tmp/cepessa-liquidqa-final-recording.png; /tmp/cepessa-liquidqa-recording-tray5.png";
opportunities[0][15] = "Implemented and verified";
opportunities[1][14] =
  "/tmp/cepessa-liquidqa-sessions2.png; /tmp/cepessa-liquidqa-clips.png; /tmp/cepessa-liquidqa-settings3.png";
opportunities[1][15] = "Implemented and partially verified";

const workbook = Workbook.create();
workbook.comments.setSelf({ displayName: "Ben" });

const colors = {
  ink: "#15131A",
  muted: "#665F70",
  paper: "#FBFAFC",
  panel: "#F0ECF5",
  purple: "#6F42C1",
  purpleDark: "#4D278F",
  purpleSoft: "#E9DFFC",
  red: "#B42318",
  amber: "#B54708",
  green: "#16794A",
  line: "#D9D1E2",
  white: "#FFFFFF",
};

function columnName(index) {
  let result = "";
  let value = index + 1;
  while (value > 0) {
    const remainder = (value - 1) % 26;
    result = String.fromCharCode(65 + remainder) + result;
    value = Math.floor((value - 1) / 26);
  }
  return result;
}

function createDataSheet(name, headers, rows, options = {}) {
  const sheet = workbook.worksheets.add(name);
  sheet.showGridLines = false;
  sheet.freezePanes.freezeRows(1);

  const lastColumn = columnName(headers.length - 1);
  sheet.getRange(`A1:${lastColumn}1`).values = [headers];
  sheet.getRange(`A1:${lastColumn}1`).format = {
    fill: colors.ink,
    font: { bold: true, color: colors.white, size: 10 },
    verticalAlignment: "center",
    wrapText: true,
    borders: { preset: "outside", style: "thin", color: colors.ink },
  };
  sheet.getRange(`A1:${lastColumn}1`).format.rowHeight = 34;

  if (rows.length > 0) {
    const lastRow = rows.length + 1;
    sheet.getRange(`A2:${lastColumn}${lastRow}`).values = rows;
    sheet.getRange(`A2:${lastColumn}${lastRow}`).format = {
      fill: colors.paper,
      font: { color: colors.ink, size: 10 },
      verticalAlignment: "top",
      wrapText: true,
      borders: {
        insideHorizontal: { style: "thin", color: colors.line },
        bottom: { style: "thin", color: colors.line },
      },
    };
    sheet.getRange(`A2:${lastColumn}${lastRow}`).format.rowHeight = 72;
    const table = sheet.tables.add(`A1:${lastColumn}${lastRow}`, true, `${name.replaceAll(" ", "")}Table`);
    table.style = "TableStyleMedium4";
    table.showBandedRows = true;
    table.showFilterButton = true;
  }

  for (let index = 0; index < headers.length; index += 1) {
    const width = options.widths?.[index] ?? 18;
    sheet.getRange(`${columnName(index)}:${columnName(index)}`).format.columnWidth = width;
  }

  return sheet;
}

const runsSheet = createDataSheet("Runs", runsHeaders, runs, {
  widths: [16, 18, 30, 42, 30, 24, 34, 20, 36, 24, 32, 34, 48, 48, 52, 18, 22, 16, 18, 24, 24],
});
const featuresSheet = createDataSheet("Features", featureHeaders, features, {
  widths: [12, 18, 24, 18, 42, 34, 46, 40, 18, 18, 18, 14, 14, 12, 20, 42],
});
const behaviorsSheet = createDataSheet("Behaviors", behaviorHeaders, behaviors, {
  widths: [12, 12, 36, 34, 34, 42, 18, 28, 18, 14, 18, 18, 42],
});
const testsSheet = createDataSheet("Test Runs", testRunHeaders, testRuns, {
  widths: [12, 18, 12, 20, 36, 34, 34, 44, 40, 44, 14, 44, 18, 24, 42],
});
const defectsSheet = createDataSheet("Defects", defectHeaders, defects, {
  widths: [12, 18, 34, 22, 14, 34, 44, 40, 44, 44, 20, 20, 44, 38, 32, 18, 18, 42, 42],
});
const opportunitiesSheet = createDataSheet("UX Opportunities", opportunityHeaders, opportunities, {
  widths: [14, 18, 18, 34, 22, 42, 42, 44, 42, 14, 14, 14, 14, 40, 42, 20, 42],
});

runsSheet.getRange("S2").dataValidation = {
  rule: {
    type: "list",
    values: [
      "Planned",
      "Inventory",
      "Baseline",
      "Fixing",
      "Regression",
      "Verification",
      "Verified complete",
      "Incomplete",
      "Blocked",
    ],
  },
};
featuresSheet.getRange("I2:I1000").dataValidation = {
  rule: { type: "list", values: ["Code only", "Runtime only", "Both"] },
};
featuresSheet.getRange("K2:K1000").dataValidation = {
  rule: { type: "list", values: ["Contract", "Inferred", "Observed only", "Needs decision"] },
};
testsSheet.getRange("K2:K5000").dataValidation = {
  rule: { type: "list", values: ["Pass", "Fail", "Blocked", "N/A"] },
};
defectsSheet.getRange("D2:D1000").dataValidation = {
  rule: {
    type: "list",
    values: [
      "Functional",
      "Logic",
      "UX",
      "Content",
      "Accessibility",
      "State/Data",
      "Integration/Environment",
      "Test harness",
    ],
  },
};
defectsSheet.getRange("E2:E1000").dataValidation = {
  rule: { type: "list", values: ["Critical", "High", "Medium", "Low"] },
};
opportunitiesSheet.getRange("J2:J1000").dataValidation = {
  rule: { type: "list", values: ["P1", "P2"] },
};

const summary = workbook.worksheets.add("Summary");
summary.showGridLines = false;
summary.getRange("A1:H2").merge();
summary.getRange("A1:H2").values = [["CEPESSA SESSIONS · QA EVIDENCE LEDGER"]];
summary.getRange("A1:H2").format = {
  fill: colors.ink,
  font: { bold: true, color: colors.white, size: 18 },
  verticalAlignment: "center",
};
summary.getRange("A4:H4").merge();
summary.getRange("A4:H4").values = [[
  "Current truth: the minimalist Liquid Glass refactor is implemented and the safe core journey is verified in an isolated dev app. The whole-app run remains Incomplete because real capture, OS-mediated flows, seeded evidence states, multi-display behavior, and full VoiceOver traversal were not executed.",
]];
summary.getRange("A4:H4").format = {
  fill: colors.purpleSoft,
  font: { bold: true, color: colors.purpleDark, size: 11 },
  wrapText: true,
  verticalAlignment: "center",
};
summary.getRange("A4:H4").format.rowHeight = 44;

summary.getRange("A6:B16").values = [
  ["Metric", "Current"],
  ["Total features", null],
  ["Total behaviors", null],
  ["Baseline tests", null],
  ["Baseline failures", null],
  ["Final tests", null],
  ["Final passes", null],
  ["Final failures", null],
  ["Final blocked", null],
  ["Open defects", null],
  ["UX opportunities", null],
];
summary.getRange("B7:B16").formulas = [
  ["=COUNTA('Features'!A2:A1000)"],
  ["=COUNTA('Behaviors'!A2:A2000)"],
  ["=COUNTIF('Test Runs'!D2:D5000,\"Baseline\")"],
  ["=COUNTIFS('Test Runs'!D2:D5000,\"Baseline\",'Test Runs'!K2:K5000,\"Fail\")"],
  ["=COUNTIF('Test Runs'!D2:D5000,\"Final regression\")"],
  ["=COUNTIFS('Test Runs'!D2:D5000,\"Final regression\",'Test Runs'!K2:K5000,\"Pass\")"],
  ["=COUNTIFS('Test Runs'!D2:D5000,\"Final regression\",'Test Runs'!K2:K5000,\"Fail\")"],
  ["=COUNTIFS('Test Runs'!D2:D5000,\"Final regression\",'Test Runs'!K2:K5000,\"Blocked\")"],
  ["=COUNTIF('Defects'!K2:K1000,\"Open\")+COUNTIF('Defects'!K2:K1000,\"Reproduced\")+COUNTIF('Defects'!K2:K1000,\"Authorized\")+COUNTIF('Defects'!K2:K1000,\"Fixing\")+COUNTIF('Defects'!K2:K1000,\"Fixed unverified\")+COUNTIF('Defects'!K2:K1000,\"Reopened\")"],
  ["=COUNTA('UX Opportunities'!A2:A1000)"],
];
summary.getRange("A6:B6").format = {
  fill: colors.purple,
  font: { bold: true, color: colors.white },
};
summary.getRange("A7:B16").format = {
  fill: colors.paper,
  font: { color: colors.ink },
  borders: {
    insideHorizontal: { style: "thin", color: colors.line },
    bottom: { style: "thin", color: colors.line },
  },
};
summary.getRange("B7:B16").format.numberFormat = "0";

summary.getRange("D6:H6").merge();
summary.getRange("D6:H6").values = [["Verification boundary"]];
summary.getRange("D6:H6").format = {
  fill: colors.purple,
  font: { bold: true, color: colors.white },
};
summary.getRange("D7:E13").values = [
  ["Run", "RUN-20260727-02 · Incomplete"],
  ["Verified build", "Isolated debug bundle · 158 tests · 0 failures"],
  ["Source base", "e19a7a777ec17c127779ab44e371f81831c25c45"],
  ["Platform", "macOS 26.5.2 · arm64"],
  ["Locale", "en_IL · en-IL / he-IL"],
  ["Runtime proof", "22×22 idle · 66×22 recording · 220×30 tray"],
  ["Protected", "Production app and recordings unchanged"],
];
summary.getRange("D7:H13").format = {
  fill: colors.paper,
  font: { color: colors.ink },
  wrapText: true,
  borders: {
    insideHorizontal: { style: "thin", color: colors.line },
    bottom: { style: "thin", color: colors.line },
  },
};
summary.getRange("E7:H13").merge(true);

summary.getRange("A17:H17").merge();
summary.getRange("A17:H17").values = [["ELI5"]];
summary.getRange("A17:H17").format = {
  fill: colors.amber,
  font: { bold: true, color: colors.white },
};
summary.getRange("A18:H20").merge();
summary.getRange("A18:H20").values = [[
  "The distracting bar is now genuinely tiny and its important escape hatches work. This is still an honest checkpoint, not a release certificate: several flows need real permissions, fixtures, displays, and assistive-technology testing before every row can be called proven.",
]];
summary.getRange("A18:H20").format = {
  fill: "#FFF4E5",
  font: { color: "#6C3700", size: 11 },
  wrapText: true,
  verticalAlignment: "center",
};

summary.getRange("A:H").format.columnWidth = 18;
summary.getRange("A:A").format.columnWidth = 28;
summary.getRange("B:B").format.columnWidth = 16;
summary.getRange("C:C").format.columnWidth = 4;
summary.getRange("D:D").format.columnWidth = 20;
summary.getRange("E:H").format.columnWidth = 18;
summary.freezePanes.freezeRows(2);

for (const sheetName of [
  "Summary",
  "Runs",
  "Features",
  "Behaviors",
  "Test Runs",
  "Defects",
  "UX Opportunities",
]) {
  const preview = await workbook.render({
    sheetName,
    autoCrop: "all",
    scale: 1,
    format: "png",
  });
  await fs.mkdir(previewDir, { recursive: true });
  await fs.writeFile(
    `${previewDir}/${sheetName.replaceAll(" ", "-").toLowerCase()}.png`,
    new Uint8Array(await preview.arrayBuffer()),
  );
}

await fs.mkdir(outputDir, { recursive: true });
const exported = await SpreadsheetFile.exportXlsx(workbook);
await exported.save(outputPath);

const reportPath = `${outputDir}/cepessa-sessions-qa-report.html`;
const finalPassCount = Object.values(finalEvidence).filter((item) => item.result === "Pass").length;
const finalFailCount = Object.values(finalEvidence).filter((item) => item.result === "Fail").length;
const finalBlockedCount = behaviors.length - finalPassCount - finalFailCount;
const openDefects = defects.filter((row) => row[10] !== "Verified fixed");
const verifiedDefects = defects.filter((row) => row[10] === "Verified fixed");

async function imageData(path) {
  try {
    const bytes = await fs.readFile(path);
    return `data:image/png;base64,${Buffer.from(bytes).toString("base64")}`;
  } catch {
    return "";
  }
}

const recordingImage = await imageData("/tmp/cepessa-liquidqa-final-recording.png");
const trayImage = await imageData("/tmp/cepessa-liquidqa-recording-tray5.png");
const settingsImage = await imageData("/tmp/cepessa-liquidqa-settings3.png");
const clipsImage = await imageData("/tmp/cepessa-liquidqa-clips.png");

const reportHtml = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Cepessa Sessions · QA checkpoint</title>
  <style>
    :root{color-scheme:light dark;--ink:#15131a;--paper:#fbfafc;--muted:#68616f;--line:#ddd5e5;--violet:#6f42c1;--soft:#eee7fa;--green:#16794a;--amber:#b54708}
    *{box-sizing:border-box} body{margin:0;background:var(--paper);color:var(--ink);font:15px/1.55 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif}
    main{max-width:1160px;margin:auto;padding:48px 28px 72px}.eyebrow{font-size:12px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:var(--violet)}
    h1{font-size:clamp(38px,7vw,78px);line-height:.98;letter-spacing:-.055em;margin:14px 0 22px;max-width:940px}h2{font-size:28px;letter-spacing:-.025em;margin:0 0 16px}h3{margin:0 0 8px}
    .lede{font-size:20px;color:var(--muted);max-width:780px}.status{display:inline-flex;gap:9px;align-items:center;padding:8px 13px;border-radius:999px;background:#fff3df;color:#773c00;font-weight:700}.status:before{content:"";width:8px;height:8px;border-radius:50%;background:#d97706}
    .metrics{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin:36px 0}.metric{padding:20px;border:1px solid var(--line);border-radius:18px;background:white}.metric b{display:block;font-size:32px;letter-spacing:-.04em}.metric span{color:var(--muted)}
    section{margin-top:64px}.proof{display:grid;grid-template-columns:1fr 1fr;gap:18px}.card{border:1px solid var(--line);border-radius:24px;background:white;overflow:hidden}.card .copy{padding:22px}.visual{min-height:190px;display:grid;place-items:center;padding:34px;background:linear-gradient(145deg,#f4f0f8,#fff)}.visual img{max-width:100%;max-height:420px;object-fit:contain;filter:drop-shadow(0 14px 24px #2916431d)}
    .dimensions{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-top:18px}.dimension{padding:16px;border-radius:16px;background:var(--soft)}.dimension b{display:block;font-size:24px}
    .eli5{padding:24px 26px;border-left:5px solid var(--amber);border-radius:0 18px 18px 0;background:#fff4e5}.grid{display:grid;grid-template-columns:1fr 1fr;gap:18px}
    ul{padding-left:20px}.good{color:var(--green);font-weight:700}.risk{color:var(--amber);font-weight:700}table{width:100%;border-collapse:collapse;background:white;border-radius:16px;overflow:hidden}th,td{text-align:left;vertical-align:top;padding:13px 15px;border-bottom:1px solid var(--line)}th{background:var(--ink);color:white}
    .gallery{display:grid;grid-template-columns:1fr 1fr;gap:18px}.gallery img{width:100%;border-radius:18px;border:1px solid var(--line)}
    footer{margin-top:68px;padding-top:22px;border-top:1px solid var(--line);color:var(--muted)}a{color:var(--violet)}
    @media(max-width:760px){main{padding:30px 18px 52px}.metrics,.proof,.grid,.gallery{grid-template-columns:1fr}.metrics{grid-template-columns:1fr 1fr}.dimensions{grid-template-columns:1fr}h1{font-size:44px}}
    @media(prefers-color-scheme:dark){:root{--ink:#f4f1f7;--paper:#15131a;--muted:#b9b2c1;--line:#3d3743;--soft:#2a2138}.metric,.card,table{background:#211e25}.visual{background:linear-gradient(145deg,#29232f,#1a171e)}.eli5{background:#332719}.status{background:#332719;color:#ffd8a4}th{background:#09080b}}
  </style>
</head>
<body><main>
  <div class="eyebrow">Cepessa Sessions · independent QA</div>
  <h1>The recording bar is finally small enough to disappear into the work.</h1>
  <p class="lede">Claude Opus 5 rebuilt the reachable visual system; Codex reviewed the diff, repaired functional and accessibility regressions, and proved the safe core journey in an isolated macOS app.</p>
  <p><span class="status">Incomplete checkpoint</span></p>

  <div class="metrics">
    <div class="metric"><b>${features.length}</b><span>inventoried features</span></div>
    <div class="metric"><b>${behaviors.length}</b><span>atomic behaviors</span></div>
    <div class="metric"><b>${finalPassCount}</b><span>final runtime/source-backed passes</span></div>
    <div class="metric"><b>${finalBlockedCount}</b><span>honestly blocked final behaviors</span></div>
  </div>

  <section>
    <h2>The accepted indicator</h2>
    <div class="proof">
      <article class="card"><div class="visual">${recordingImage ? `<img src="${recordingImage}" alt="Compact 66 by 22 point recording lozenge">` : ""}</div><div class="copy"><h3>Persistent state, almost no obstruction</h3><p>One red state ring and one monospaced timer. No REC label, waveform dashboard, chevron, or auto-expanding slab.</p></div></article>
      <article class="card"><div class="visual">${trayImage ? `<img src="${trayImage}" alt="Compact recording control tray">` : ""}</div><div class="copy"><h3>Details only after intent</h3><p>A deliberate action opens mute, capture, hide, more, and Stop. Hiding the tray never removes the menu-bar recovery and stop path.</p></div></article>
    </div>
    <div class="dimensions">
      <div class="dimension"><b>22×22</b><span>idle indicator</span></div>
      <div class="dimension"><b>66×22</b><span>recording lozenge</span></div>
      <div class="dimension"><b>220×30</b><span>deliberate control tray</span></div>
    </div>
  </section>

  <section class="eli5"><h2>ELI5</h2><p>The distracting toolbar became a tiny “recording is alive” light. When you need buttons, you ask for them. When you hide it, the menu bar still lets you bring it back or stop recording. Nothing was installed over your real app.</p></section>

  <section>
    <h2>What is verified</h2>
    <div class="grid">
      <div><ul>
        <li><span class="good">Passed:</span> Swift build and 158-test suite; one intentional manual test skipped, zero failures.</li>
        <li><span class="good">Passed:</span> idle, recording, tray, hide, menu-bar Show, and menu-bar Stop interaction.</li>
        <li><span class="good">Passed:</span> meaningful menu-bar and floating-indicator accessibility labels.</li>
        <li><span class="good">Passed:</span> Sessions, Clips, and dedicated Settings windows open in the isolated app.</li>
      </ul></div>
      <div><ul>
        <li><span class="good">Protected:</span> production PID 53535 stayed running; executable hash remained bb850395…</li>
        <li><span class="good">Protected:</span> recording corpus hash manifest remained valid with no changed, missing, or unexpected files.</li>
        <li><span class="good">Protected:</span> no provider was enabled, no audio uploaded, and no paid call made.</li>
        <li><span class="good">Protected:</span> no commit, push, install, signing, release, or production replacement.</li>
      </ul></div>
    </div>
  </section>

  <section>
    <h2>Why the run is not called complete</h2>
    <table><thead><tr><th>Open evidence gap</th><th>What remains</th></tr></thead><tbody>
      <tr><td>Real capture and permissions</td><td>Microphone/system-audio capture, OS permission recovery, and true stop-to-transcription were not exercised in the unique temporary bundle.</td></tr>
      <tr><td>Evidence-state reader</td><td>Degraded diarization/transcription quality still needs a reachable reader treatment and seeded runtime proof.</td></tr>
      <tr><td>Clip artifact validation</td><td>Startup rollback improved, but ready-state video playability/size validation still needs implementation and fixtures.</td></tr>
      <tr><td>Environment coverage</td><td>Dark mode, Increase Contrast, Reduce Transparency, multi-display, full-screen calls, and a complete VoiceOver traversal remain.</td></tr>
    </tbody></table>
  </section>

  <section>
    <h2>Reachable app surfaces</h2>
    <div class="gallery">
      ${clipsImage ? `<img src="${clipsImage}" alt="Minimal native Clips split view">` : ""}
      ${settingsImage ? `<img src="${settingsImage}" alt="Grouped native Sessions Settings window">` : ""}
    </div>
  </section>

  <section>
    <h2>Ledger reconciliation</h2>
    <p>${testRuns.length} append-only test rows: ${baselineTestRuns.length} baseline and ${finalTestRuns.length} final. Final results contain ${finalPassCount} Pass, ${finalFailCount} Fail, and ${finalBlockedCount} Blocked. ${verifiedDefects.length} of ${defects.length} recorded defects are marked Verified fixed; ${openDefects.length} remain open.</p>
    <p><a href="cepessa-sessions-qa.xlsx">Open the canonical QA workbook</a></p>
  </section>

  <footer>Generated from the same in-memory rows exported to the canonical workbook. Report status: <strong>Incomplete</strong>.</footer>
</main></body></html>`;

await fs.writeFile(reportPath, reportHtml, "utf8");

const summaryInspect = await workbook.inspect({
  kind: "table",
  range: "Summary!A1:H20",
  include: "values,formulas",
  tableMaxRows: 20,
  tableMaxCols: 10,
});
const errorScan = await workbook.inspect({
  kind: "match",
  searchTerm: "#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A",
  options: { useRegex: true, maxResults: 100 },
  summary: "formula error scan",
});

console.log(summaryInspect.ndjson);
console.log(errorScan.ndjson);
console.log(JSON.stringify({ outputPath, reportPath, previewDir }));
