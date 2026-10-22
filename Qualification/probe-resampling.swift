import AVFoundation
import Foundation

func probe(from: Double, to: Double, block: Int) throws {
    let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false)!
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false)!
    let converter = AVAudioConverter(from: source, to: target)!
    converter.primeMethod = .none
    converter.channelMap = [0]
    var rendered: [Float] = []
    var costs: [Double] = []
    var counts: [Int] = []
    let impulse = block * 4
    for index in 0..<100 {
        let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(block))!
        input.frameLength = AVAudioFrameCount(block)
        input.floatChannelData![0].initialize(repeating: 0, count: block)
        if index == 4 { input.floatChannelData![0][0] = 1 }
        let start = DispatchTime.now().uptimeNanoseconds
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(Double(block) * to/from)) + 64)!
        var supplied = false
        var emitted = 0
        for _ in 0..<16 {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            if let error { throw error }
            emitted += Int(output.frameLength)
            rendered.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            if status != .haveData { break }
        }
        costs.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1e6)
        counts.append(emitted)
    }
    let peak = rendered.indices.max { abs(rendered[$0]) < abs(rendered[$1]) }!
    let expected = Double(impulse)*to/from
    let result: [String: Any] = ["from_hz":from,"to_hz":to,"input_block":block,"first_output_counts":Array(counts.prefix(8)),"peak_delay_ms":(Double(peak)-expected)/to*1000,"mean_cpu_ms":costs.reduce(0,+)/Double(costs.count),"max_cpu_ms":costs.max()!,"scope":"Offline converter with primeMethod none; not engine or acoustic delay"]
    print(String(data:try JSONSerialization.data(withJSONObject: result,options:[.sortedKeys]),encoding:.utf8)!)
}
try probe(from: 48000, to: 16000, block: 512)
try probe(from: 24000, to: 48000, block: 1920)
