// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public func availableTransferName(_ name: String, existing: Set<String>) -> String {
    let ext = (name as NSString).pathExtension
    let base = (name as NSString).deletingPathExtension
    var candidate = name
    var number = 1
    while existing.contains(candidate) {
        candidate = "\(base) (\(number))" + (ext.isEmpty ? "" : ".\(ext)")
        number += 1
    }
    return candidate
}
