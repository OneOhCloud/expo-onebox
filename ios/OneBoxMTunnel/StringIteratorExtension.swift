import Foundation
import Libbox

/// Convenience extension to convert Libbox string iterators to Swift arrays.
/// This is a copy for the Network Extension target.
extension LibboxStringIteratorProtocol {
    func toArray() -> [String] {
        var result: [String] = []
        while hasNext() {
            let item = next()
            result.append(item)
        }
        return result
    }
}
