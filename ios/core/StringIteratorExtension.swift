import Foundation
import Libbox

/// Convenience extension to convert Libbox's iterator-based string collections to Swift arrays.
extension LibboxStringIteratorProtocol {
    func toArray() -> [String] {
        var array: [String] = []
        while hasNext() {
            array.append(next())
        }
        return array
    }
}
