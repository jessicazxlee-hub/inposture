//
//  Item.swift
//  inposture2
//
//  Created by Jessica Lee on 3/9/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
