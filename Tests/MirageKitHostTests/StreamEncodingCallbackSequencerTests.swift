//
//  StreamEncodingCallbackSequencerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/14/26.
//

@testable import MirageKitHost
import MirageKit
import Testing

#if os(macOS)
@Suite("Stream Encoding Callback Sequencer")
struct StreamEncodingCallbackSequencerTests {
    @Test("Concurrent reservations keep frame and packet numbering contiguous")
    func concurrentReservationsKeepFrameAndPacketNumberingContiguous() async {
        let sequencer = StreamEncodingCallbackSequencer()

        let reservations = await withTaskGroup(of: (StreamEncodingCallbackSequencer.Reservation, Int).self) { group in
            for index in 0 ..< 128 {
                group.addTask {
                    let frameByteCount = 800 + (index % 11) * 173
                    let fecBlockSize = index.isMultiple(of: 5) ? 4 : 1
                    let reservation = sequencer.reserve(
                        frameByteCount: frameByteCount,
                        maxPayloadSize: 512,
                        fecBlockSize: fecBlockSize
                    )
                    let dataFragments = (frameByteCount + 511) / 512
                    let parityFragments = fecBlockSize > 1
                        ? (dataFragments + fecBlockSize - 1) / fecBlockSize
                        : 0
                    return (reservation, dataFragments + parityFragments)
                }
            }

            var collected: [(StreamEncodingCallbackSequencer.Reservation, Int)] = []
            for await item in group {
                collected.append(item)
            }
            return collected
        }

        #expect(reservations.count == 128)
        #expect(Set(reservations.map { $0.0.frameNumber }).count == reservations.count)

        let orderedReservations = reservations.sorted { $0.0.frameNumber < $1.0.frameNumber }
        var expectedSequenceNumber: UInt32 = 0
        for (expectedFrameNumber, item) in orderedReservations.enumerated() {
            let (reservation, totalFragments) = item
            #expect(reservation.frameNumber == UInt32(expectedFrameNumber))
            #expect(reservation.sequenceNumberStart == expectedSequenceNumber)
            expectedSequenceNumber &+= UInt32(totalFragments)
        }
    }

    @Test("Stopping encoding invalidates callback generation and clears slots")
    func stoppingEncodingInvalidatesCallbackGenerationAndClearsSlots() async {
        let encoder = VideoEncoder(
            configuration: MirageEncoderConfiguration(
                targetFrameRate: 60,
                colorDepth: .standard
            ),
            latencyMode: .lowestLatency,
            inFlightLimit: 2
        )

        #expect(encoder.sessionVersion == 0)
        #expect(encoder.reserveEncoderSlot())
        #expect(encoder.encoderInFlightSnapshot == 1)

        await encoder.stopEncoding()

        #expect(encoder.sessionVersion == 1)
        #expect(encoder.encoderInFlightSnapshot == 0)
    }
}
#endif
