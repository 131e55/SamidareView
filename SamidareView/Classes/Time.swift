//
//  Time.swift
//  SamidareView
//
//  Created by Keisuke Kawamura on 2018/03/22.
//

import Foundation

public struct Time {

    public var hours: Int = 0 {
        didSet {
            hours = min(max(hours, 0), 24)
            if hours == 24 {
                minutes = 0
            }
        }
    }

    public var minutes: Int = 0 {
        didSet {
            let additionalHours = minutes / 60
            if additionalHours > 0 {
                hours += additionalHours
            }
            minutes = max(minutes % 60, 0)
        }
    }

    public var totalMinutes: Int { return hours * 60 + minutes }

    public init(hours: Int, minutes: Int) {
        setup(hours: hours, minutes: minutes)
    }

    private mutating func setup(hours h: Int, minutes m: Int) {
        hours = h
        minutes = m
    }
}

extension Time: Equatable {

    static public func ==(lfs: Time, rhs: Time) -> Bool {
        return lfs.hours == rhs.hours && lfs.minutes == rhs.minutes
    }
}
