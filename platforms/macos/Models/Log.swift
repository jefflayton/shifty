import Foundation

func log(_ items: Any..., separator: String = " ", terminator: String = "\n") {
  let body = items.map { "\($0)" }.joined(separator: separator)
  print("[swift.menubar]", body, terminator: terminator)
}
