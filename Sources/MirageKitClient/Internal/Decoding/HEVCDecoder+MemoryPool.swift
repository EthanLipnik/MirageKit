//
//  HEVCDecoder+MemoryPool.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  HEVC decoder extensions.
//

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import MirageKit

extension HEVCDecoder {
    private func configureMemoryPoolIfNeeded() {
        guard memoryPool == nil else { return }
        let options: [CFString: Any] = [
            kCMMemoryPoolOption_AgeOutPeriod: NSNumber(value: memoryPoolAgeOutSeconds),
        ]
        memoryPool = CMMemoryPoolCreate(options: options as CFDictionary)
    }

    func memoryPoolAllocator() -> CFAllocator {
        configureMemoryPoolIfNeeded()
        guard let memoryPool else { return kCFAllocatorDefault }
        return CMMemoryPoolGetAllocator(memoryPool)
    }

    func flushMemoryPool() {
        guard let memoryPool else { return }
        CMMemoryPoolFlush(memoryPool)
    }

    func invalidateMemoryPool() {
        guard let memoryPool else { return }
        CMMemoryPoolInvalidate(memoryPool)
        self.memoryPool = nil
    }
}
