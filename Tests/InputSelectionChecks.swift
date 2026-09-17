import Foundation

@main struct InputSelectionChecks {
    static func main() {
        func device(_ id: UInt32, _ count: Int, _ name: String = "Microphone") -> InputDevice {
            InputDevice(id: id, name: name, uid: String(id), channelNames: (0..<count).map { "Input \($0)" })
        }
        let mono = device(1, 1), four = device(2, 4), five = device(3, 5), other = device(4, 5)
        precondition(AudioInputs.preferredDevice(in: [mono, four, five], defaultID: 1, preferredUID: "2") == five)
        precondition(AudioInputs.preferredDevice(in: [mono, four], defaultID: 1, preferredUID: "3") == four)
        precondition(AudioInputs.preferredDevice(in: [mono, device(6, 1)], defaultID: 1, preferredUID: "6") == mono)
        precondition(AudioInputs.preferredDevice(in: [five, other], defaultID: 3, preferredUID: "4") == other)
        precondition(AudioInputs.preferredDevice(in: [five, other], defaultID: 3, preferredUID: nil) == five)
        precondition(AudioInputs.preferredDevice(in: [mono, device(9, 32, "CADefaultDeviceAggregate-123-0")], defaultID: 1, preferredUID: "9") == mono)
        precondition(AudioInputs.preferredDevice(in: [], defaultID: 1, preferredUID: nil) == nil)
        precondition(AudioInputs.preferredDevice(in: [mono], defaultID: 99, preferredUID: nil) == mono)
        print("PASS: maximum channels, disconnect fallback, default mic, ties, temporary aggregates and empty list")
    }
}
