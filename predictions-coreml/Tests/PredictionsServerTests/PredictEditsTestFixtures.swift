import Foundation

func makePrompt(events: String, excerpt: String) -> String {
    "### Instruction:\nTest\n\n### User Edits:\n\n\(events)\n\n### User Excerpt:\n\n\(excerpt)\n\n### Response:\n"
}

func makeExcerpt(_ content: String) -> String {
    "```test.swift\n<|editable_region_start|>\n\(content)\n<|editable_region_end|>\n```"
}

func makeRequestJSON(events: String, excerpt: String) -> String {
    let prompt = makePrompt(events: events, excerpt: excerpt)
    let promptData = try! JSONEncoder().encode(prompt)
    let promptJSON = String(data: promptData, encoding: .utf8)!
    return #"{"model":"test","prompt":\#(promptJSON),"max_tokens":512}"#
}
