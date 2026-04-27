import Foundation
import LlamaSwift

enum RunnerError: Error, CustomStringConvertible {
  case missingArgument(String)
  case modelLoadFailed(String)
  case contextLoadFailed
  case tokenizationFailed
  case promptEvaluationFailed
  case generationFailed

  var description: String {
    switch self {
    case .missingArgument(let name):
      return "Missing required argument: \(name)"
    case .modelLoadFailed(let path):
      return "Failed to load model at \(path)"
    case .contextLoadFailed:
      return "Failed to create model context"
    case .tokenizationFailed:
      return "Failed to tokenize prompt"
    case .promptEvaluationFailed:
      return "Failed to evaluate prompt"
    case .generationFailed:
      return "Generation failed"
    }
  }
}

struct RunnerOptions {
  let modelPath: String
  let maxTokens: Int

  init(arguments: [String]) throws {
    var modelPath: String?
    var maxTokens = 700
    var index = 1

    while index < arguments.count {
      switch arguments[index] {
      case "--model":
        index += 1
        guard index < arguments.count else { throw RunnerError.missingArgument("--model") }
        modelPath = arguments[index]
      case "--max-tokens":
        index += 1
        guard index < arguments.count else { throw RunnerError.missingArgument("--max-tokens") }
        maxTokens = max(1, Int(arguments[index]) ?? maxTokens)
      default:
        break
      }
      index += 1
    }

    guard let modelPath, !modelPath.isEmpty else {
      throw RunnerError.missingArgument("--model")
    }

    self.modelPath = modelPath
    self.maxTokens = maxTokens
  }
}

func tokenPiece(_ token: llama_token, vocab: OpaquePointer?) -> String {
  var buffer = [CChar](repeating: 0, count: 256)
  let length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
  guard length > 0 else { return "" }
  let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
  return String(decoding: bytes, as: UTF8.self)
}

func generate(prompt: String, options: RunnerOptions) throws -> String {
  llama_backend_init()
  defer { llama_backend_free() }

  let modelParams = llama_model_default_params()
  guard let model = llama_model_load_from_file(options.modelPath, modelParams) else {
    throw RunnerError.modelLoadFailed(options.modelPath)
  }
  defer { llama_model_free(model) }

  var contextParams = llama_context_default_params()
  contextParams.n_ctx = 4096
  contextParams.n_batch = 512
  let batchCapacity = max(1, Int(contextParams.n_batch))

  guard let context = llama_init_from_model(model, contextParams) else {
    throw RunnerError.contextLoadFailed
  }
  defer { llama_free(context) }

  let vocab = llama_model_get_vocab(model)
  let promptByteCount = prompt.utf8.count
  var tokens = [llama_token](repeating: 0, count: promptByteCount + 8)
  let tokenCount = llama_tokenize(
    vocab,
    prompt,
    Int32(promptByteCount),
    &tokens,
    Int32(tokens.count),
    true,
    true
  )

  guard tokenCount > 0 else {
    throw RunnerError.tokenizationFailed
  }

  let maxPromptTokens = max(1, Int(contextParams.n_ctx) - options.maxTokens - 1)
  let promptTokens = Array(tokens.prefix(Int(tokenCount)).suffix(maxPromptTokens))
  var batch = llama_batch_init(Int32(contextParams.n_batch), 0, 1)
  defer { llama_batch_free(batch) }

  var currentPosition = Int32(0)
  for chunkStart in stride(from: 0, to: promptTokens.count, by: batchCapacity) {
    let chunkEnd = min(chunkStart + batchCapacity, promptTokens.count)
    let chunk = promptTokens[chunkStart..<chunkEnd]

    batch.n_tokens = Int32(chunk.count)
    for chunkIndex in 0..<chunk.count {
      let absoluteIndex = chunkStart + chunkIndex
      batch.token[chunkIndex] = promptTokens[absoluteIndex]
      batch.pos[chunkIndex] = Int32(absoluteIndex)
      batch.n_seq_id[chunkIndex] = 1
      if let seqIDs = batch.seq_id, let seqID = seqIDs[chunkIndex] {
        seqID[0] = 0
      }
      batch.logits[chunkIndex] = chunkEnd == promptTokens.count && chunkIndex == chunk.count - 1 ? 1 : 0
    }

    guard llama_decode(context, batch) == 0 else {
      throw RunnerError.promptEvaluationFailed
    }
    currentPosition = Int32(chunkEnd)
  }

  var output = ""

  for _ in 0..<options.maxTokens {
    guard let logits = llama_get_logits_ith(context, batch.n_tokens - 1) else {
      throw RunnerError.generationFailed
    }

    let vocabSize = llama_vocab_n_tokens(vocab)
    var maxLogit = logits[0]
    var nextToken = llama_token(0)
    for index in 1..<Int(vocabSize) where logits[index] > maxLogit {
      maxLogit = logits[index]
      nextToken = llama_token(index)
    }

    if nextToken == llama_vocab_eos(vocab) {
      break
    }

    output += tokenPiece(nextToken, vocab: vocab)

    batch.n_tokens = 1
    batch.token[0] = nextToken
    batch.pos[0] = currentPosition
    batch.n_seq_id[0] = 1
    if let seqIDs = batch.seq_id, let seqID = seqIDs[0] {
      seqID[0] = 0
    }
    batch.logits[0] = 1
    currentPosition += 1

    guard llama_decode(context, batch) == 0 else {
      throw RunnerError.generationFailed
    }
  }

  return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

do {
  let options = try RunnerOptions(arguments: CommandLine.arguments)
  let promptData = FileHandle.standardInput.readDataToEndOfFile()
  let prompt = String(data: promptData, encoding: .utf8) ?? ""
  let output = try generate(prompt: prompt, options: options)
  print(output)
} catch {
  fputs("\(error)\n", stderr)
  exit(1)
}
