import Foundation

// Codable mirror of `hammer h:json`. The export is one hash:
//   commands => { group => { full_path => task_meta } }
// plus top-level metadata. We only decode what the GUI renders; unknown
// keys (location, switch, usage, negation, redefined) are ignored.

struct Spec: Decodable {
  let schema: Int
  let hammerVersion: String
  let programName: String
  let appDesc: String?
  let commands: [String: [String: TaskDef]]   // group -> full_path -> task

  enum CodingKeys: String, CodingKey {
    case schema, commands
    case hammerVersion = "hammer_version"
    case programName   = "program_name"
    case appDesc       = "app_desc"
  }
}

struct TaskDef: Decodable, Identifiable, Hashable {
  var id: String { path }
  let name: String
  let path: String
  let desc: String
  let brief: String
  let alts: [String]
  let needs: [String]
  let examples: [String]
  let options: [OptionDef]

  static func == (l: TaskDef, r: TaskDef) -> Bool { l.path == r.path }
  func hash(into h: inout Hasher) { h.combine(path) }
}

struct OptionDef: Decodable, Identifiable {
  var id: String { name }
  let name: String
  let type: String          // string | boolean | integer | float | array
  let `default`: JSONValue?
  let required: Bool
  let desc: String?
  let placeholder: String?
  let aliases: [String]
}

// `default` is heterogeneous (string / bool / number / array / null), so
// decode it loosely and project it onto a form field.
enum JSONValue: Decodable {
  case string(String), int(Int), double(Double), bool(Bool)
  case array([JSONValue]), object([String: JSONValue]), null

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null; return }
    if let b = try? c.decode(Bool.self)         { self = .bool(b);   return }
    if let i = try? c.decode(Int.self)          { self = .int(i);    return }
    if let d = try? c.decode(Double.self)       { self = .double(d); return }
    if let s = try? c.decode(String.self)       { self = .string(s); return }
    if let a = try? c.decode([JSONValue].self)  { self = .array(a);  return }
    if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
    self = .null
  }

  // Prefill text for a non-boolean field.
  var formText: String {
    switch self {
    case .string(let s): return s
    case .int(let i):    return String(i)
    case .double(let d): return String(d)
    case .bool(let b):   return b ? "true" : "false"
    case .array(let a):  return a.map { $0.formText }.joined(separator: ",")
    case .object, .null: return ""
    }
  }

  var boolValue: Bool {
    if case .bool(let b) = self { return b }
    return false
  }
}
