// A real device check before XCTest; a skipped Metal test cannot qualify.
import Foundation
import Metal

guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
      let buffer = device.makeBuffer(length: 4, options: .storageModeShared),
      let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else {
    fatalError("A working native Metal device is required.")
}
blit.fill(buffer: buffer, range: 0..<4, value: 0x5a)
blit.endEncoding()
command.commit()
command.waitUntilCompleted()
guard command.status == .completed, command.error == nil,
      buffer.contents().load(as: UInt32.self) == 0x5a5a5a5a else {
    fatalError("Metal GPU write did not complete correctly.")
}
print("device\t\(device.name)")
print("native_gpu_write\tPASS")
