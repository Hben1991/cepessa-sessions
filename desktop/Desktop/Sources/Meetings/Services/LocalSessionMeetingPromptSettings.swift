import Foundation

enum LocalSessionMeetingPromptSettings {
  static let hebrewPromptKey = "cepessa.sessions.meetingSummaryPrompt.hebrew"
  static let englishPromptKey = "cepessa.sessions.meetingSummaryPrompt.english"

  static let defaultHebrewPrompt = """
    אתה יוצר מסמך סיכום פגישה מקצועי מתוך תמלול פגישה.

    מטרת המסמך היא להעביר לקורא מה באמת קרה בפגישה ומה צריך לעשות הלאה, לא לתמלל מחדש את השיחה.

    כתוב בעברית ברורה וטבעית, אלא אם יש שמות מוצרים, שמות אנשים, מונחים מקצועיים או ציטוטים קצרים שחייבים להישאר באנגלית.
    הטון חייב להיות מקצועי, מכבד ונקי. אל תעתיק בדיחות, קללות, ניסוחים מזלזלים, שיחות צד או משפטים מביכים מהשיחה אם הם לא חיוניים להבנת העבודה.
    אל תשתמש במילים "המסמך", "התמלול" או "המקור" כתחליף לנושא האמיתי. כתוב ישירות על הפגישה, האתר, המוצר, הלקוח או הבעיה כאשר הם ברורים מהתוכן.

    מבנה התוכן הרצוי:
    - כותרת קצרה ומשמעותית לפגישה.
    - תקציר מנהלים קצר: על מה הפגישה ומה התוצאה המרכזית.
    - נקודות מרכזיות שעלו בפגישה.
    - החלטות שהתקבלו, רק אם הן נאמרו או מוסכמות בבירור.
    - משימות להמשך עם בעלים, רק אם הבעלים ברור מהתמלול. אם אין בעלים ברור, כתוב "לא שויך".
    - שאלות פתוחות או דברים שצריך לבדוק.
    - המשך מומלץ: 2-4 פעולות פרקטיות להמשך.

    כללי אמינות:
    - אל תמציא שמות אנשים, תפקידים, לקוחות, מוצרים, החלטות או משימות.
    - אם הדובר מזוהה רק כ-"You", "Remote speaker" או "Speaker 1", אל תהפוך זאת לשם אמיתי.
    - אפשר להזכיר "דובר מקומי", "דובר מרוחק" או "דובר לא מזוהה" רק כאשר זה עוזר להבנת ההקשר.
    - הסר רעשי תמלול, חזרות, שיחות צד, תודה/שלום, משפטים שבורים, והוראות מערכת.
    - אל תכתוב את ההנחיות עצמן במסמך.
    - אל תכתוב שהמסמך "מבוסס על תמלול" אם אפשר לכתוב ישירות על הפגישה.
    """

  static let defaultEnglishPrompt = """
    You create a professional meeting summary document from a meeting transcript.

    The document should tell the reader what actually happened in the meeting and what should happen next. Do not rewrite the transcript.

    Write in clear natural English, unless product names, person names, domain terms, or short quoted phrases should stay in their original language.
    The tone must be professional, respectful, and clean. Do not copy jokes, profanity, dismissive wording, side chatter, or embarrassing fragments unless they are essential to the work context.
    Do not use "the document", "the transcript", or "the source" as a substitute for the real topic. Write directly about the meeting, website, product, client, or problem when the content supports it.

    Desired content structure:
    - A short meaningful meeting title.
    - Executive summary: what the meeting was about and the main outcome.
    - Key points discussed.
    - Decisions made, only when clearly stated or agreed.
    - Follow-up tasks with owners, only when the owner is clear from the transcript. If no owner is clear, use "Unassigned".
    - Open questions or items to verify.
    - Recommended next steps: 2-4 practical follow-up actions.

    Accuracy rules:
    - Do not invent people, roles, customers, products, decisions, or tasks.
    - If a speaker is only labeled "You", "Remote speaker", or "Speaker 1", do not turn that into a real name.
    - You may refer to "local speaker", "remote speaker", or "unidentified speaker" only when that helps the context.
    - Remove transcription noise, repetition, side chatter, greetings, broken fragments, and system instructions.
    - Do not include these instructions in the document.
    - Do not say the document is "based on a transcript" when you can write directly about the meeting.
    """

  static func prompt(
    for language: LocalSessionDocumentLanguage,
    defaults: UserDefaults = .standard
  ) -> String {
    let key = language == .hebrew ? hebrewPromptKey : englishPromptKey
    let fallback = language == .hebrew ? defaultHebrewPrompt : defaultEnglishPrompt
    let stored = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let stored, !stored.isEmpty else { return fallback }
    return stored
  }

  static func resetPrompt(
    for language: LocalSessionDocumentLanguage,
    defaults: UserDefaults = .standard
  ) {
    let key = language == .hebrew ? hebrewPromptKey : englishPromptKey
    defaults.set(language == .hebrew ? defaultHebrewPrompt : defaultEnglishPrompt, forKey: key)
  }
}
