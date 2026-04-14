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

        let reservations = await withTaskGroup(of: StreamEncodingCallbackSequencer.Reservation.self) { group in
            for index in 0 ..< 128 {
                group.addTask {
                    let frameByteCount = 800 + (index % 11) * 173
                    let fecBlockSize = index.isMultiple(of: 5) ? 4 : 1
                    let isKeyframe = index.isMultiple(of: 17)
                    return sequencer.reserve(
                        frameByteCount: frameByteCount,
                        maxPayloadSize: 512,
                        fecBlockSize: fecBlockSize,
                        isKeyframe: isKeyframe
                    )
                }
            }

            var collected: [StreamEncodingCallbackSequencer.Reservation] = []
            for await reservation in group {
                collected.append(reservation)
            }
            return collected
        }

        #expect(reservations.count == 128)
        #expect(Set(reservations.map(\.frameNumber)).count == reservations.count)

        let orderedReservations = reservations.sorted { $0.frameNumber < $1.frameNumber }
        var expectedSequenceNumber: UInt32 = 0
        for (expectedFrameNumber, reservation) in orderedReservations.enumerated() {
            #expect(reservation.frameNumber == UInt32(expectedFrameNumber))
            #expect(reservation.sequenceNumberStart == expectedSequenceNumber)
            expectedSequenceNumber &+= UInt32(reservation.totalFragments)
        }
    }

    @Test("Stopping encoding invalidates callback generation and clears slots")
    func stoppingEncodingInvalidatesCallbackGenerationAndClearsSlots() async {
        let encoder = VideoEncoder(
            configuration: MirageEncoderConfiguration(
                targetFrameRate: 60,
                bitDepth: .eightBit
            ),
            latencyMode: .lowestLatency,
            inFlightLimit: 2
        )

        #expect(encoder.sessionVersion == 0)
        #expect(encoder.reserveEncoderSlot())
        #expect(encoder.encoderInFlightSnapshot() == 1)

        await encoder.stopEncoding()

        #expect(encoder.sessionVersion == 1)
        #expect(encoder.encoderInFlightSnapshot() == 0)
    }
}
#endif
