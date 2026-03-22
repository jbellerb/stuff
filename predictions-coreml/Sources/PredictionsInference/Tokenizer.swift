/// Protocol for tokenizers used by Generator.
public protocol Tokenizer {
    func encode(_ text: String) -> [Int32]
    func decode(_ tokenIds: [Int32]) -> String
}
